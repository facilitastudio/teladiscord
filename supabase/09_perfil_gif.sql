-- =====================================================================
-- Skipper: foto e fundo de perfil com GIF, e insígnias
-- =====================================================================
alter table public.profiles add column if not exists banner text not null default '' check (char_length(banner) <= 500);
alter table public.profiles add column if not exists badges text[] not null default '{}';
-- insígnias não são editáveis pelo usuário (só pela função de resgate)
grant update (display_name, bio, avatar, banner_color, status_text, banner) on public.profiles to authenticated;

-- armazenamento das fotos e fundos (GIF, PNG, JPG, WEBP até 4 MB)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-media', 'profile-media', true, 4194304, array['image/gif','image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

drop policy if exists profile_media_upload on storage.objects;
create policy profile_media_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'profile-media' and not public.is_guest() and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists profile_media_delete on storage.objects;
create policy profile_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'profile-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- resgatar insígnia: Skipper #1 é de quem criou conta em 2026
create or replace function public.claim_badge(p_badge text) returns text
language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = auth.uid();
  if not found or p.is_guest then return 'nao_elegivel'; end if;
  if p_badge = 'skipper1' then
    if extract(year from (p.created_at at time zone 'America/Sao_Paulo')) <> 2026 then return 'nao_elegivel'; end if;
  else
    return 'nao_existe';
  end if;
  if p_badge = any(p.badges) then return 'ja_tem'; end if;
  update profiles set badges = array_append(badges, p_badge) where id = auth.uid();
  return 'ok';
end $$;
