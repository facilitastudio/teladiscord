-- foto (ícone) de cada servidor
alter table public.servers add column if not exists icon text not null default '' check (char_length(icon) <= 150000);

-- dono troca a foto do próprio servidor; admin troca a do xcordbr
create or replace function public.set_server_icon(p_server uuid, p_icon text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_icon <> '' and (p_icon not like 'data:image/%' or char_length(p_icon) > 150000) then raise exception 'imagem inválida'; end if;
  update servers set icon = p_icon
  where id = p_server and ((owner_id = auth.uid() and not is_public) or (is_public and public.is_admin()));
  if not found then raise exception 'sem permissão'; end if;
end $$;
