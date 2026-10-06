-- =====================================================================
-- Skipper: ligar para um amigo (chamada de voz/vídeo direta)
-- A conversa em si vai direto entre os navegadores (P2P). O banco só
-- guarda quem ligou para quem, para tocar o telefone do outro lado.
-- =====================================================================
create table if not exists public.dm_calls (
  id uuid primary key default gen_random_uuid(),
  caller uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  callee uuid not null references public.profiles(id) on delete cascade,
  caller_peer text not null check (char_length(caller_peer) between 1 and 80),
  callee_peer text check (char_length(callee_peer) <= 80),
  status text not null default 'ringing' check (status in ('ringing', 'active', 'ended', 'declined', 'missed')),
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create index if not exists dm_calls_callee on public.dm_calls (callee, created_at desc);
create index if not exists dm_calls_caller on public.dm_calls (caller, created_at desc);

alter table public.dm_calls enable row level security;
alter table public.dm_calls replica identity full;

drop policy if exists calls_select on public.dm_calls;
create policy calls_select on public.dm_calls for select to authenticated
  using (caller = auth.uid() or callee = auth.uid());

-- só liga para amigo, convidado não liga, e no máximo 10 ligações por minuto
drop policy if exists calls_insert on public.dm_calls;
create policy calls_insert on public.dm_calls for insert to authenticated
  with check (
    caller = auth.uid() and callee <> auth.uid() and status = 'ringing'
    and not public.is_guest() and public.are_friends(auth.uid(), callee)
    and (select count(*) from public.dm_calls c where c.caller = auth.uid() and c.created_at > now() - interval '1 minute') < 10
  );

drop policy if exists calls_update on public.dm_calls;
create policy calls_update on public.dm_calls for update to authenticated
  using (caller = auth.uid() or callee = auth.uid())
  with check (caller = auth.uid() or callee = auth.uid());

-- só dá para mudar o andamento da ligação, nunca quem ligou ou para quem
revoke update on public.dm_calls from authenticated;
grant select, insert on public.dm_calls to authenticated;
grant update (status, callee_peer, ended_at) on public.dm_calls to authenticated;

-- banidos não ligam
drop policy if exists block_banned on public.dm_calls;
create policy block_banned on public.dm_calls as restrictive for all to authenticated
  using (not public.is_blocked()) with check (not public.is_blocked());

do $$ begin
  execute 'alter publication supabase_realtime add table public.dm_calls';
exception when duplicate_object then null; end $$;
