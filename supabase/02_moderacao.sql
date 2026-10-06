-- =====================================================================
-- xcordbr: moderação (denúncias, administrador, banimento por conta e IP)
-- =====================================================================

alter table public.profiles add column if not exists is_admin boolean not null default false;
alter table public.profiles add column if not exists banned boolean not null default false;
alter table public.profiles add column if not exists banned_at timestamptz;

-- ninguém pode se dar admin ou se desbanir: só estes campos são editáveis pelo próprio usuário
revoke update on public.profiles from authenticated, anon;
grant update (display_name, bio, avatar, banner_color) on public.profiles to authenticated;

-- IPs banidos
create table if not exists public.banned_ips (
  ip text primary key,
  user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.banned_ips enable row level security;

-- denúncias
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter uuid not null references public.profiles(id) on delete cascade,
  target uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (char_length(reason) between 3 and 1000),
  media_path text not null default '',
  media_type text not null default '',
  status text not null default 'aberta' check (status in ('aberta', 'resolvida')),
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;

-- IP de quem está fazendo a requisição (vem do cabeçalho do proxy do Supabase)
create or replace function public.request_ip() returns text
language plpgsql stable as $$
declare h json; v text;
begin
  begin h := current_setting('request.headers', true)::json; exception when others then return null; end;
  if h is null then return null; end if;
  v := coalesce(h->>'cf-connecting-ip', split_part(coalesce(h->>'x-forwarded-for', ''), ',', 1), h->>'x-real-ip');
  return nullif(trim(v), '');
end $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

-- conta banida ou IP banido
create or replace function public.is_blocked() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select banned from profiles where id = auth.uid()), false)
      or exists (select 1 from banned_ips where ip = public.request_ip());
$$;

-- o site chama isto logo após o login
create or replace function public.my_status() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('blocked', public.is_blocked(), 'admin', public.is_admin());
$$;

-- bloqueia tudo para quem está banido (políticas restritivas somam com as outras)
do $$
declare t text;
begin
  foreach t in array array['profiles','servers','server_members','channels','messages','channel_music','friendships','dm_messages','reports'] loop
    execute format('drop policy if exists block_banned on public.%I', t);
    execute format('create policy block_banned on public.%I as restrictive for all to authenticated using (not public.is_blocked()) with check (not public.is_blocked())', t);
  end loop;
end $$;

drop policy if exists realtime_members_read on realtime.messages;
create policy realtime_members_read on realtime.messages for select to authenticated
  using (realtime.topic() like 'srv:%' and not public.is_blocked() and public.is_member(substring(realtime.topic() from 5)::uuid));
drop policy if exists realtime_members_write on realtime.messages;
create policy realtime_members_write on realtime.messages for insert to authenticated
  with check (realtime.topic() like 'srv:%' and not public.is_blocked() and public.is_member(substring(realtime.topic() from 5)::uuid));

-- admin pode apagar qualquer mensagem
drop policy if exists messages_admin_delete on public.messages;
create policy messages_admin_delete on public.messages for delete to authenticated using (public.is_admin());

-- privado: também vale conversa com quem já trocou mensagem (ex.: denúncia enviada ao admin)
drop policy if exists dm_insert on public.dm_messages;
create policy dm_insert on public.dm_messages for insert to authenticated
  with check (sender = auth.uid() and (public.are_friends(sender, receiver)
    or exists (select 1 from profiles where id = receiver and is_admin)
    or public.is_admin()));

-- denúncias: quem denunciou vê as suas; admin vê e resolve todas
drop policy if exists reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated using (reporter = auth.uid() or public.is_admin());
drop policy if exists reports_update on public.reports;
create policy reports_update on public.reports for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- enviar denúncia: grava e manda no privado de cada admin
create or replace function public.submit_report(p_target text, p_reason text, p_media_path text, p_media_type text) returns text
language plpgsql security definer set search_path = public as $$
declare tid uuid; rid bigint; a record; me text;
begin
  if auth.uid() is null or public.is_blocked() then raise exception 'sem acesso'; end if;
  select id into tid from profiles where username = lower(trim(both '@ ' from p_target));
  if tid is null then return 'nao_existe'; end if;
  if tid = auth.uid() then return 'voce'; end if;
  if p_media_path <> '' and split_part(p_media_path, '/', 1) <> auth.uid()::text then raise exception 'arquivo inválido'; end if;
  insert into reports (reporter, target, reason, media_path, media_type)
  values (auth.uid(), tid, left(p_reason, 1000), coalesce(p_media_path, ''), coalesce(p_media_type, ''))
  returning id into rid;
  select username into me from profiles where id = auth.uid();
  for a in select id from profiles where is_admin loop
    insert into dm_messages (sender, receiver, content)
    values (auth.uid(), a.id, 'DENÚNCIA #' || rid || E'\nContra: @' || lower(trim(both '@ ' from p_target)) || E'\nMotivo: ' || left(p_reason, 900)
      || case when p_media_path <> '' then E'\n(anexo no Painel de administração)' else '' end);
  end loop;
  return 'ok';
end $$;

-- painel: lista de usuários sem email
create or replace function public.admin_users(p_search text default '') returns table(
  id uuid, username text, display_name text, avatar text, created_at timestamptz, banned boolean, is_admin boolean, reports bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'só administrador'; end if;
  return query
    select p.id, p.username, p.display_name, p.avatar, p.created_at, p.banned, p.is_admin,
           (select count(*) from reports r where r.target = p.id)
    from profiles p
    where p_search = '' or p.username ilike '%' || p_search || '%' or p.display_name ilike '%' || p_search || '%'
    order by p.created_at desc
    limit 500;
end $$;

-- IPs usados por cada conta (gravados a cada login) e banimento por conta e IP
create table if not exists public.login_ips (
  user_id uuid not null references public.profiles(id) on delete cascade,
  ip text not null,
  last_seen timestamptz not null default now(),
  primary key (user_id, ip)
);
alter table public.login_ips enable row level security;

create or replace function public.touch_ip() returns void
language sql security definer set search_path = public as $$
  insert into login_ips (user_id, ip) select auth.uid(), public.request_ip()
  where auth.uid() is not null and public.request_ip() is not null
  on conflict (user_id, ip) do update set last_seen = now();
$$;

create or replace function public.admin_ban(p_user uuid, p_ban boolean, p_ip boolean default false) returns integer
language plpgsql security definer set search_path = public, auth as $$
declare n integer := 0;
begin
  if not public.is_admin() then raise exception 'só administrador'; end if;
  if p_user = auth.uid() then raise exception 'você não pode se banir'; end if;
  update profiles set banned = p_ban, banned_at = case when p_ban then now() else null end where id = p_user;
  if p_ban then
    delete from server_members where user_id = p_user;
    delete from friendships where requester = p_user or addressee = p_user;
    if p_ip then
      insert into banned_ips (ip, user_id) select ip, p_user from login_ips where user_id = p_user on conflict do nothing;
      begin
        insert into banned_ips (ip, user_id)
        select distinct host(s.ip), p_user from auth.sessions s where s.user_id = p_user and s.ip is not null
        on conflict do nothing;
      exception when others then null;
      end;
      select count(*) into n from banned_ips where user_id = p_user;
    end if;
    begin delete from auth.sessions where user_id = p_user; exception when others then null; end;
  else
    delete from banned_ips where user_id = p_user;
    insert into server_members (server_id, user_id) values ('00000000-0000-0000-0000-000000000001', p_user) on conflict do nothing;
  end if;
  return n;
end $$;

create or replace function public.admin_resolve(p_report bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'só administrador'; end if;
  update reports set status = 'resolvida' where id = p_report;
end $$;

-- arquivos das denúncias (privado: só quem enviou e o admin)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('report-media', 'report-media', false, 26214400,
        array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict (id) do nothing;

drop policy if exists report_media_upload on storage.objects;
create policy report_media_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'report-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists report_media_read on storage.objects;
create policy report_media_read on storage.objects for select to authenticated
  using (bucket_id = 'report-media' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

alter table public.reports replica identity full;
do $$ begin
  execute 'alter publication supabase_realtime add table public.reports';
exception when duplicate_object then null; end $$;
