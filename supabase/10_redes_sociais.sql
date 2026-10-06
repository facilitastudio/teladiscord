-- redes sociais no perfil (guardamos só o @ de cada rede; o link é montado pelo site)
alter table public.profiles add column if not exists socials jsonb not null default '{}'::jsonb
  check (jsonb_typeof(socials) = 'object' and length(socials::text) <= 1500);
grant update (display_name, bio, avatar, banner_color, status_text, banner, socials) on public.profiles to authenticated;
