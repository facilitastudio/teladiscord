-- =====================================================================
-- Skipper: convidados (entram sem conta, só voz, câmera e tela no Skipper geral)
-- =====================================================================
alter table public.profiles add column if not exists is_guest boolean not null default false;

create or replace function public.is_guest() returns boolean
language sql stable as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
$$;

-- conta nova: convidado ganha um usuário automático (conv_xxxxxxxx) e o apelido escolhido
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  guest boolean := coalesce(new.is_anonymous, false);
  uname text;
  nick text := left(trim(coalesce(new.raw_user_meta_data->>'display_name', '')), 32);
begin
  if guest then
    uname := 'conv_' || substr(replace(new.id::text, '-', ''), 1, 8);
    if nick = '' then nick := 'Convidado'; end if;
  else
    uname := lower(coalesce(new.raw_user_meta_data->>'username', ''));
    if nick = '' then nick := uname; end if;
  end if;
  insert into profiles (id, username, display_name, is_guest) values (new.id, uname, nick, guest);
  insert into server_members (server_id, user_id)
  values ('00000000-0000-0000-0000-000000000001', new.id) on conflict do nothing;
  return new;
end $$;

-- convidado não escreve: mensagens, privado, música (links), amizades, servidores, denúncias
do $$
declare t text;
begin
  foreach t in array array['messages','dm_messages','channel_music','friendships','servers','reports'] loop
    execute format('drop policy if exists no_guest_write on public.%I', t);
    execute format('create policy no_guest_write on public.%I as restrictive for insert to authenticated with check (not public.is_guest())', t);
  end loop;
end $$;

-- convidado não envia imagens
drop policy if exists chat_images_upload on storage.objects;
create policy chat_images_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-images' and not public.is_guest() and (storage.foldername(name))[1] = auth.uid()::text);

-- convidado não entra em servidor por convite nem adiciona amigos
create or replace function public.join_by_invite(p_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if auth.uid() is null then raise exception 'sem login'; end if;
  if public.is_guest() then raise exception 'convidados precisam criar uma conta'; end if;
  select id into sid from servers where invite_code = p_code and not is_public;
  if sid is null then raise exception 'convite inválido'; end if;
  insert into server_members (server_id, user_id) values (sid, auth.uid()) on conflict do nothing;
  return sid;
end $$;

create or replace function public.add_friend(p_username text) returns text
language plpgsql security definer set search_path = public as $$
declare other uuid; f friendships;
begin
  if public.is_guest() then return 'convidado'; end if;
  select id into other from profiles where username = lower(trim(p_username)) and not is_guest;
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

-- denúncia também só para quem tem conta
create or replace function public.submit_report(p_target text, p_reason text, p_media_path text, p_media_type text) returns text
language plpgsql security definer set search_path = public as $$
declare tid uuid; rid bigint; a record;
begin
  if auth.uid() is null or public.is_blocked() then raise exception 'sem acesso'; end if;
  if public.is_guest() then return 'convidado'; end if;
  select id into tid from profiles where username = lower(trim(both '@ ' from p_target));
  if tid is null then return 'nao_existe'; end if;
  if tid = auth.uid() then return 'voce'; end if;
  if p_media_path <> '' and split_part(p_media_path, '/', 1) <> auth.uid()::text then raise exception 'arquivo inválido'; end if;
  insert into reports (reporter, target, reason, media_path, media_type)
  values (auth.uid(), tid, left(p_reason, 1000), coalesce(p_media_path, ''), coalesce(p_media_type, ''))
  returning id into rid;
  for a in select id from profiles where is_admin loop
    insert into dm_messages (sender, receiver, content)
    values (auth.uid(), a.id, 'DENÚNCIA #' || rid || E'\nContra: @' || lower(trim(both '@ ' from p_target)) || E'\nMotivo: ' || left(p_reason, 900)
      || case when p_media_path <> '' then E'\n(anexo no Painel de administração)' else '' end);
  end loop;
  return 'ok';
end $$;
