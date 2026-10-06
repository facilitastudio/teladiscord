// Skipper: baixa um GIF/imagem de um link da internet e guarda uma cópia no perfil do usuário.
// Só aceita links https públicos e arquivos de imagem de verdade, até 4 MB.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MAX = 4 * 1024 * 1024;
const TYPES: Record<string, string> = { "image/gif": "gif", "image/webp": "webp", "image/png": "png", "image/jpeg": "jpg" };

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  try { const v = JSON.parse(raw); const first = Object.values(v)[0]; if (typeof first === "string") return first; } catch { /* formato simples */ }
  return Deno.env.get("SUPABASE_SECRET_KEY") || raw;
}

// link de página do GIPHY vira o link direto do GIF
function normalize(u: string): string {
  const m = u.match(/giphy\.com\/(?:gifs|stickers)\/(?:[^/?#]*-)?([A-Za-z0-9]+)(?:$|[/?#])/);
  if (m) return `https://media.giphy.com/media/${m[1]}/giphy.gif`;
  return u;
}
// bloqueia endereços internos (proteção contra SSRF)
function blockedHost(h: string): boolean {
  h = h.toLowerCase().replace(/^\[|\]$/g, "");
  return /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|0\.|::1$|fc|fd|fe80)/.test(h) ||
    h.endsWith(".local") || h.endsWith(".internal") || h.endsWith("supabase.co") || h.endsWith("supabase.com") || !h.includes(".");
}
function sniff(b: Uint8Array): string | null {
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "image/gif";
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return "image/webp";
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user }, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !user) return json({ error: "Faça login para usar isso." }, 401);
  if (user.is_anonymous) return json({ error: "Convidados não podem trocar a foto. Crie uma conta." }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Dados inválidos." }, 400); }
  const kind = body.kind === "banner" ? "banner" : "avatar";
  let url: URL;
  try { url = new URL(normalize(String(body.url ?? "").trim())); } catch { return json({ error: "Link inválido." }, 400); }
  if (url.protocol !== "https:" || blockedHost(url.hostname)) return json({ error: "Use um link https público de uma imagem ou GIF." }, 400);

  let res: Response;
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 10000);
    res = await fetch(url.toString(), { signal: ctl.signal, redirect: "follow", headers: { "User-Agent": "SkipperBot/1.0" } });
    clearTimeout(t);
  } catch { return json({ error: "Não consegui baixar esse link." }, 400); }
  try { if (blockedHost(new URL(res.url).hostname)) return json({ error: "Link não permitido." }, 400); } catch { /* ignora */ }
  if (!res.ok || !res.body) return json({ error: "Não consegui baixar esse link." }, 400);
  if (Number(res.headers.get("content-length") || 0) > MAX) return json({ error: "Arquivo maior que 4 MB." }, 400);

  const reader = res.body.getReader();
  const chunks: Uint8Array[] = []; let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > MAX) { try { await reader.cancel(); } catch { /* ok */ } return json({ error: "Arquivo maior que 4 MB." }, 400); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size); let off = 0;
  for (const c of chunks) { bytes.set(c, off); off += c.length; }
  const type = sniff(bytes);
  if (!type) return json({ error: "Esse link não é de uma imagem. No GIF, clique com o botão direito e use 'Copiar endereço da imagem'." }, 400);

  const path = `${user.id}/${kind}-${Date.now()}.${TYPES[type]}`;
  const { error: upErr } = await admin.storage.from("profile-media").upload(path, bytes, { contentType: type });
  if (upErr) return json({ error: "Não consegui salvar a imagem." }, 500);
  const pub = admin.storage.from("profile-media").getPublicUrl(path).data.publicUrl;
  return json({ ok: true, url: pub });
});
