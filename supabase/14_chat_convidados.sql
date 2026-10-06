-- =====================================================================
-- Skipper: convidados podem conversar no chat do Skipper geral
-- (sem links, sem imagens, sem se passar pelo bot e no máximo 5 mensagens a cada 10 segundos)
-- =====================================================================
drop policy if exists no_guest_write on public.messages;
create policy no_guest_write on public.messages as restrictive for insert to authenticated
  with check (
    not public.is_guest()
    or (
      public.channel_server(channel_id) = '00000000-0000-0000-0000-000000000001'
      and image_url = ''
      and not is_bot
      and content !~* '(https?://|www\.|\m[a-z0-9-]+\.(com|net|org|br|io|gg|me|tv|xyz|app|dev|ly|co|info|site|link|store|shop)\M)'
      and (select count(*) from public.messages m
           where m.user_id = auth.uid() and m.created_at > now() - interval '10 seconds') < 5
    )
  );
