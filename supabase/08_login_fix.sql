-- login por usuário: confere a senha só da conta digitada (convidados não têm senha)
create or replace function public.login_email(p_username text, p_password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  u text := lower(trim(p_username));
  la login_attempts;
  em text;
  pw text;
  ok boolean := false;
begin
  select * into la from login_attempts where username = u;
  if found and la.fails >= 5 and la.last_fail > now() - interval '15 minutes' then
    raise exception 'bloqueado';
  end if;
  select au.email, au.encrypted_password into em, pw
  from profiles p join auth.users au on au.id = p.id
  where p.username = u and not p.is_guest;
  if em is not null and pw is not null and pw like '$2%' then
    ok := (extensions.crypt(p_password, pw) = pw);
  end if;
  if not ok then
    insert into login_attempts (username, fails, last_fail) values (u, 1, now())
    on conflict (username) do update set
      fails = case when login_attempts.last_fail < now() - interval '15 minutes' then 1 else login_attempts.fails + 1 end,
      last_fail = now();
    return null;
  end if;
  delete from login_attempts where username = u;
  return em;
end $$;
