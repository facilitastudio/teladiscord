-- Skipper: ligação entre amigos pode passar pelo servidor do LiveKit quando a conexão direta falha
alter table public.dm_calls add column if not exists relay boolean not null default false;
grant update (status, callee_peer, ended_at, relay) on public.dm_calls to authenticated;
