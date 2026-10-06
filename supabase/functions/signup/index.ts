// Skipper: cadastro de contas feito pelo servidor.
// Cria a conta já confirmada (sem mandar email) e só faz isso.
// A chave de administrador fica nas variáveis secretas do Supabase, nunca no site.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MAX_PER_HOUR = 5; // cadastros por conexão (IP) por hora

// chave secreta do projeto (injetada automaticamente pelo Supabase nas funções)
function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  try { const v = JSON.parse(raw); const first = Object.values(v)[0]; if (typeof first === "string") return first; } catch { /* formato simples */ }
  return Deno.env.get("SUPABASE_SECRET_KEY") || raw;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Dados inválidos." }, 400); }

  const username = String(body.username ?? "").trim().toLowerCase();
  const display = String(body.display_name ?? "").trim().slice(0, 32);
  const password = String(body.password ?? "");
  const email = String(body.email ?? "").trim().toLowerCase();

  if (!/^[a-z0-9_.]{3,20}$/.test(username)) return json({ error: "Usuário inválido: use de 3 a 20 letras minúsculas, números, ponto ou _." }, 400);
  if (password.length < 6 || password.length > 72) return json({ error: "A senha precisa ter de 6 a 72 caracteres." }, 400);
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Email inválido." }, 400);

  const ip = (req.headers.get("cf-connecting-ip") || (req.headers.get("x-forwarded-for") || "").split(",")[0] || "").trim();
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });

  if (ip) {
    const { data: banned } = await admin.from("banned_ips").select("ip").eq("ip", ip).maybeSingle();
    if (banned) return json({ error: "Acesso bloqueado." }, 403);
    const since = new Date(Date.now() - 3600_000).toISOString();
    const { count } = await admin.from("signup_ips").select("id", { count: "exact", head: true }).eq("ip", ip).gte("created_at", since);
    if ((count ?? 0) >= MAX_PER_HOUR) return json({ error: "Muitos cadastros desta conexão. Tente daqui a 1 hora." }, 429);
  }

  const { data: exists } = await admin.from("profiles").select("id").eq("username", username).maybeSingle();
  if (exists) return json({ error: "Esse usuário já existe. Escolha outro." }, 409);

  // sem email: endereço interno que não recebe nada (não é ligado a nenhum domínio real de pessoa)
  const candidates = email ? [email] : [`${username}@skipper.invalid`, `${username}@example.com`];
  let lastError = "";
  for (const em of candidates) {
    const { error } = await admin.auth.admin.createUser({
      email: em,
      password,
      email_confirm: true,
      user_metadata: { username, display_name: display },
    });
    if (!error) {
      if (ip) await admin.from("signup_ips").insert({ ip });
      return json({ ok: true, email: em });
    }
    lastError = error.message;
    if (/already|registered|exists/i.test(lastError)) {
      return json({ error: email ? "Esse email já está em uso." : "Esse usuário já existe. Escolha outro." }, 409);
    }
  }
  return json({ error: "Não consegui criar a conta: " + lastError }, 400);
});
