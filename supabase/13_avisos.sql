-- =====================================================================
-- Skipper: avisos do administrador geral (aparecem uma vez para cada pessoa)
-- =====================================================================
create table if not exists public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 80),
  body text not null check (char_length(body) between 1 and 2000),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.announcements enable row level security;

drop policy if exists ann_select on public.announcements;
create policy ann_select on public.announcements for select to authenticated using (true);
drop policy if exists ann_insert on public.announcements;
create policy ann_insert on public.announcements for insert to authenticated
  with check (public.is_admin() and created_by = auth.uid());
drop policy if exists ann_delete on public.announcements;
create policy ann_delete on public.announcements for delete to authenticated using (public.is_admin());
revoke update on public.announcements from authenticated;

-- quem já viu cada aviso
create table if not exists public.announcement_seen (
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (user_id, announcement_id)
);
alter table public.announcement_seen enable row level security;
drop policy if exists seen_select on public.announcement_seen;
create policy seen_select on public.announcement_seen for select to authenticated using (user_id = auth.uid());
drop policy if exists seen_insert on public.announcement_seen;
create policy seen_insert on public.announcement_seen for insert to authenticated with check (user_id = auth.uid());

do $$ begin
  execute 'alter publication supabase_realtime add table public.announcements';
exception when duplicate_object then null; end $$;
