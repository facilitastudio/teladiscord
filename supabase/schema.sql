-- =====================================================================
-- xcordbr: estrutura do banco no Supabase
-- Rode este arquivo inteiro no SQL Editor do projeto (uma vez só).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Perfis
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_.]{3,20}$'),
  display_name text not null default '' check (char_length(display_name) <= 32),
  bio text not null default '' check (char_length(bio) <= 190),
  avatar text not null default '' check (char_length(avatar) <= 120000),
  banner_color text not null default '#5b67f1' check (banner_color ~ '^#[0-9a-fA-F]{6}$'),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Servidores, membros e canais
-- ---------------------------------------------------------------------
create table if not exists public.servers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 40),
  owner_id uuid references public.profiles(id) on delete cascade,
  is_public boolean not null default false,
  invite_code text unique,
  created_at timestamptz not null default now()
);
-- cada conta pode criar só 1 servidor privado
create unique index if not exists one_private_server_per_owner
  on public.servers(owner_id) where not is_public;

create table if not exists public.server_members (
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (server_id, user_id)
);

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 32),
  kind text not null default 'voice' check (kind in ('voice', 'music')),
  max_users int not null default 0 check (max_users between 0 and 99),
  position int not null default 0,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Mensagens dos canais
-- ---------------------------------------------------------------------
create table if not exists public.messages (
  id bigint generated always as identity primary key,
  channel_id uuid not null references public.channels(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  content text not null default '' check (char_length(content) <= 2000),
  image_url text not null default '',
  is_bot boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists messages_channel_idx on public.messages(channel_id, created_at desc);

-- música tocando em cada canal de voz (uma por vez: chave primária no canal)
create table if not exists public.channel_music (
  channel_id uuid primary key references public.channels(id) on delete cascade,
  server_id uuid not null references public.servers(id) on delete cascade,
  kind text not null check (kind in ('yt', 'sp')),
  media_id text not null check (media_id ~ '^[A-Za-z0-9_-]{6,40}$'),
  title text not null default 'Música' check (char_length(title) <= 120),
  requested_by uuid references public.profiles(id) on delete set null,
  started_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Amigos e mensagens privadas
-- ---------------------------------------------------------------------
create table if not exists public.friendships (
  id bigint generated always as identity primary key,
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists friendships_pair
  on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table if not exists public.dm_messages (
  id bigint generated always as identity primary key,
  sender uuid not null references public.profiles(id) on delete cascade,
  receiver uuid not null references public.profiles(id) on delete cascade,
  content text not null default '' check (char_length(content) <= 2000),
  image_url text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists dm_pair_idx on public.dm_messages (least(sender, receiver), greatest(sender, receiver), created_at desc);

-- tentativas de login erradas (para bloquear chute de senha)
create table if not exists public.login_attempts (
  username text primary key,
  fails int not null default 0,
  last_fail timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Funções auxiliares
-- ---------------------------------------------------------------------
create or replace function public.is_member(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from server_members where server_id = sid and user_id = auth.uid());
$$;

create or replace function public.is_owner(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from servers where id = sid and owner_id = auth.uid());
$$;

create or replace function public.channel_server(cid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select server_id from channels where id = cid;
$$;

create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendships where status = 'accepted'
    and ((requester = a and addressee = b) or (requester = b and addressee = a)));
$$;

create or replace function public.random_code() returns text
language sql volatile as $$
  select string_agg(substr('abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 54)::int, 1), '')
  from generate_series(1, 8);
$$;

-- servidor público xcordbr (fixo)
insert into public.servers (id, name, is_public)
values ('00000000-0000-0000-0000-000000000001', 'xcordbr', true)
on conflict (id) do nothing;

insert into public.channels (server_id, name, kind, max_users, position)
select '00000000-0000-0000-0000-000000000001', v.name, v.kind, v.max_users, v.pos
from (values
  ('Sala geral', 'voice', 0, 0),
  ('Sala 01', 'voice', 0, 1),
  ('Sala 02', 'voice', 0, 2),
  ('Sala 03', 'voice', 0, 3),
  ('Privada 01', 'voice', 2, 4),
  ('Privada 02', 'voice', 2, 5),
  ('pedir-música', 'music', 0, 6)
) as v(name, kind, max_users, pos)
where not exists (select 1 from public.channels where server_id = '00000000-0000-0000-0000-000000000001');

-- ao criar conta: cria o perfil e entra no xcordbr
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare uname text := lower(coalesce(new.raw_user_meta_data->>'username', ''));
begin
  insert into profiles (id, username, display_name)
  values (new.id, uname, coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), uname));
  insert into server_members (server_id, user_id)
  values ('00000000-0000-0000-0000-000000000001', new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ao criar servidor privado: dono vira membro, ganha código de convite e canais iniciais
create or replace function public.handle_new_server() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_public then return new; end if;
  insert into server_members (server_id, user_id) values (new.id, new.owner_id) on conflict do nothing;
  insert into channels (server_id, name, kind, position) values
    (new.id, 'Sala geral', 'voice', 0),
    (new.id, 'pedir-música', 'music', 99);
  return new;
end $$;

create or replace function public.before_new_server() returns trigger
language plpgsql as $$
begin
  if new.invite_code is null then new.invite_code := public.random_code(); end if;
  return new;
end $$;

drop trigger if exists on_server_before on public.servers;
create trigger on_server_before before insert on public.servers
  for each row execute function public.before_new_server();
drop trigger if exists on_server_created on public.servers;
create trigger on_server_created after insert on public.servers
  for each row execute function public.handle_new_server();

-- ---------------------------------------------------------------------
-- RPCs usadas pelo site
-- ---------------------------------------------------------------------

-- usuário livre?
create or replace function public.username_available(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from profiles where username = lower(p_username));
$$;

-- login por nome de usuário: devolve o email da conta só se a senha estiver certa.
-- Bloqueia por 15 minutos depois de 5 erros seguidos.
create or replace function public.login_email(p_username text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  u text := lower(trim(p_username));
  la login_attempts;
  em text;
begin
  select * into la from login_attempts where username = u;
  if found and la.fails >= 5 and la.last_fail > now() - interval '15 minutes' then
    raise exception 'bloqueado';
  end if;
  select au.email into em
  from auth.users au join profiles p on p.id = au.id
  where p.username = u and au.encrypted_password = extensions.crypt(p_password, au.encrypted_password);
  if em is null then
    insert into login_attempts (username, fails, last_fail) values (u, 1, now())
    on conflict (username) do update set
      fails = case when login_attempts.last_fail < now() - interval '15 minutes' then 1 else login_attempts.fails + 1 end,
      last_fail = now();
    return null;
  end if;
  delete from login_attempts where username = u;
  return em;
end $$;

-- entrar num servidor pelo código de convite
create or replace function public.join_by_invite(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if auth.uid() is null then raise exception 'sem login'; end if;
  select id into sid from servers where invite_code = p_code and not is_public;
  if sid is null then raise exception 'convite inválido'; end if;
  insert into server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  return sid;
end $$;

-- ver nome do servidor antes de aceitar o convite
create or replace function public.invite_info(p_code text) returns table(id uuid, name text, members bigint)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, (select count(*) from server_members m where m.server_id = s.id)
  from servers s where s.invite_code = p_code and not s.is_public;
$$;

-- dono gera um novo código (o link antigo para de funcionar)
create or replace function public.new_invite(p_server uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text := random_code();
begin
  update servers set invite_code = c where id = p_server and owner_id = auth.uid() and not is_public;
  if not found then raise exception 'só o dono pode fazer isso'; end if;
  return c;
end $$;

-- pedir amizade pelo nome de usuário
create or replace function public.add_friend(p_username text) returns text
language plpgsql security definer set search_path = public as $$
declare other uuid; f friendships;
begin
  select id into other from profiles where username = lower(trim(p_username));
  if other is null then return 'nao_existe'; end if;
  if other = auth.uid() then return 'voce'; end if;
  select * into f from friendships
   where (requester = auth.uid() and addressee = other) or (requester = other and addressee = auth.uid());
  if found then
    if f.status = 'accepted' then return 'ja_amigos'; end if;
    if f.addressee = auth.uid() then
      update friendships set status = 'accepted' where id = f.id;
      return 'aceito';
    end if;
    return 'ja_pedido';
  end if;
  insert into friendships (requester, addressee) values (auth.uid(), other);
  return 'enviado';
end $$;

-- ---------------------------------------------------------------------
-- Segurança por linha (RLS)
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.servers enable row level security;
alter table public.server_members enable row level security;
alter table public.channels enable row level security;
alter table public.messages enable row level security;
alter table public.channel_music enable row level security;
alter table public.friendships enable row level security;
alter table public.dm_messages enable row level security;
alter table public.login_attempts enable row level security;

-- perfis: qualquer pessoa logada vê; cada um edita o seu
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- servidores: vê os que participa; cria só privado e como dono; dono edita/apaga
drop policy if exists servers_select on public.servers;
create policy servers_select on public.servers for select to authenticated
  using (is_public or public.is_member(id));
drop policy if exists servers_insert on public.servers;
create policy servers_insert on public.servers for insert to authenticated
  with check (owner_id = auth.uid() and not is_public);
drop policy if exists servers_update on public.servers;
create policy servers_update on public.servers for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid() and not is_public);
drop policy if exists servers_delete on public.servers;
create policy servers_delete on public.servers for delete to authenticated
  using (owner_id = auth.uid() and not is_public);

-- membros: vê os membros dos seus servidores; sai sozinho ou o dono remove
drop policy if exists members_select on public.server_members;
create policy members_select on public.server_members for select to authenticated
  using (public.is_member(server_id));
drop policy if exists members_delete on public.server_members;
create policy members_delete on public.server_members for delete to authenticated
  using ((user_id = auth.uid() and server_id <> '00000000-0000-0000-0000-000000000001') or public.is_owner(server_id));

-- canais: membros veem; dono cria, edita e apaga
drop policy if exists channels_select on public.channels;
create policy channels_select on public.channels for select to authenticated
  using (public.is_member(server_id));
drop policy if exists channels_insert on public.channels;
create policy channels_insert on public.channels for insert to authenticated
  with check (public.is_owner(server_id) and kind = 'voice');
drop policy if exists channels_update on public.channels;
create policy channels_update on public.channels for update to authenticated
  using (public.is_owner(server_id)) with check (public.is_owner(server_id));
drop policy if exists channels_delete on public.channels;
create policy channels_delete on public.channels for delete to authenticated
  using (public.is_owner(server_id) and kind = 'voice');

-- mensagens: membros do servidor leem e escrevem
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (public.is_member(public.channel_server(channel_id)));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (user_id = auth.uid() and public.is_member(public.channel_server(channel_id)));
drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages for delete to authenticated
  using (user_id = auth.uid() or public.is_owner(public.channel_server(channel_id)));

-- música: membros veem, pedem (uma por canal) e pulam
drop policy if exists music_select on public.channel_music;
create policy music_select on public.channel_music for select to authenticated
  using (public.is_member(server_id));
drop policy if exists music_insert on public.channel_music;
create policy music_insert on public.channel_music for insert to authenticated
  with check (requested_by = auth.uid() and public.is_member(server_id)
              and server_id = public.channel_server(channel_id));
drop policy if exists music_delete on public.channel_music;
create policy music_delete on public.channel_music for delete to authenticated
  using (public.is_member(server_id));

-- amizades: só as suas
drop policy if exists friends_select on public.friendships;
create policy friends_select on public.friendships for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());
drop policy if exists friends_update on public.friendships;
create policy friends_update on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (addressee = auth.uid() and status = 'accepted');
drop policy if exists friends_delete on public.friendships;
create policy friends_delete on public.friendships for delete to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

-- privado: só entre amigos
drop policy if exists dm_select on public.dm_messages;
create policy dm_select on public.dm_messages for select to authenticated
  using (sender = auth.uid() or receiver = auth.uid());
drop policy if exists dm_insert on public.dm_messages;
create policy dm_insert on public.dm_messages for insert to authenticated
  with check (sender = auth.uid() and public.are_friends(sender, receiver));

-- login_attempts: ninguém acessa direto (só a função de login)

-- ---------------------------------------------------------------------
-- Tempo real
-- ---------------------------------------------------------------------
alter table public.messages replica identity full;
alter table public.channel_music replica identity full;
alter table public.channels replica identity full;
alter table public.server_members replica identity full;
alter table public.friendships replica identity full;

do $$
declare t text;
begin
  foreach t in array array['messages','channel_music','channels','server_members','friendships','dm_messages','profiles','servers'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- presença nas salas de voz: canal privado do Realtime só para membros do servidor
drop policy if exists realtime_members_read on realtime.messages;
create policy realtime_members_read on realtime.messages for select to authenticated
  using (realtime.topic() like 'srv:%' and public.is_member(substring(realtime.topic() from 5)::uuid));
drop policy if exists realtime_members_write on realtime.messages;
create policy realtime_members_write on realtime.messages for insert to authenticated
  with check (realtime.topic() like 'srv:%' and public.is_member(substring(realtime.topic() from 5)::uuid));

-- ---------------------------------------------------------------------
-- Imagens do chat (Storage)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-images', 'chat-images', true, 3145728, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do nothing;

drop policy if exists chat_images_upload on storage.objects;
create policy chat_images_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-images' and (storage.foldername(name))[1] = auth.uid()::text);
