-- mensagem de status (ex.: "estudando para a prova")
alter table public.profiles add column if not exists status_text text not null default '' check (char_length(status_text) <= 80);
grant update (display_name, bio, avatar, banner_color, status_text) on public.profiles to authenticated;

-- presença: salas dos servidores (só membros) e o canal "online" (todos logados, para a lista de contatos)
drop policy if exists realtime_members_read on realtime.messages;
create policy realtime_members_read on realtime.messages for select to authenticated
  using (not public.is_blocked() and (realtime.topic() = 'online'
    or (realtime.topic() like 'srv:%' and public.is_member(substring(realtime.topic() from 5)::uuid))));
drop policy if exists realtime_members_write on realtime.messages;
create policy realtime_members_write on realtime.messages for insert to authenticated
  with check (not public.is_blocked() and (realtime.topic() = 'online'
    or (realtime.topic() like 'srv:%' and public.is_member(substring(realtime.topic() from 5)::uuid))));
