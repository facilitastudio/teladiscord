// Skipper: entrega a "chave de entrada" de uma sala do LiveKit.
// Só para quem pode estar naquela sala (membro da comunidade) ou naquela ligação.
// Segredos usados: LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const PUBLIC_ID = "00000000-0000-0000-0000-000000000001";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PEER = /^[A-Za-z0-9_-]{6,64}$/;

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  try { const v = JSON.parse(raw); const first = Object.values(v)[0]; if (typeof first === "string") return first; } catch { /* formato simples */ }
  return Deno.env.get("SUPABASE_SECRET_KEY") || raw;
}

const b64url = (data: Uint8Array | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let s = ""; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
async function signJwt(payload: Record<string, unknown>, secret: string): Promise<string> {
  const head = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify(payload));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(head + "." + body)));
  return head + "." + body + "." + b64url(sig);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  const LK_URL = Deno.env.get("LIVEKIT_URL"), LK_KEY = Deno.env.get("LIVEKIT_API_KEY"), LK_SECRET = Deno.env.get("LIVEKIT_API_SECRET");
  if (!LK_URL || !LK_KEY || !LK_SECRET) return json({ error: "LiveKit não configurado." }, 503);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: { user }, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !user) return json({ error: "Faça login." }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Dados inválidos." }, 400); }
  const kind = String(body.kind || ""), target = String(body.id || ""), peer = String(body.peer || "");
  if (!UUID.test(target) || !PEER.test(peer)) return json({ error: "Dados inválidos." }, 400);

  const { data: prof } = await admin.from("profiles").select("id, display_name, username, banned, is_guest").eq("id", user.id).maybeSingle();
  if (!prof || prof.banned) return json({ error: "Sem acesso." }, 403);

  let room = "", maxUsers = 0;
  if (kind === "room") {
    const { data: ch } = await admin.from("channels").select("id, server_id, kind, max_users").eq("id", target).maybeSingle();
    if (!ch || ch.kind !== "voice") return json({ error: "Sala não encontrada." }, 404);
    if (prof.is_guest && ch.server_id !== PUBLIC_ID) return json({ error: "Sem acesso." }, 403);
    if (ch.server_id !== PUBLIC_ID) {
      const { data: mem } = await admin.from("server_members").select("user_id").eq("server_id", ch.server_id).eq("user_id", user.id).maybeSingle();
      if (!mem) return json({ error: "Você não faz parte dessa comunidade." }, 403);
    }
    room = "ch-" + ch.id; maxUsers = ch.max_users || 0;
  } else if (kind === "dm") {
    const { data: call } = await admin.from("dm_calls").select("id, caller, callee, status").eq("id", target).maybeSingle();
    if (!call || (call.caller !== user.id && call.callee !== user.id) || call.status !== "active") return json({ error: "Ligação não encontrada." }, 404);
    room = "dm-" + call.id; maxUsers = 2;
  } else return json({ error: "Dados inválidos." }, 400);

  const now = Math.floor(Date.now() / 1000);
  // salas com limite (ex.: privada de 2): confere quantos já estão lá dentro
  if (maxUsers > 0) {
    try {
      const adminJwt = await signJwt({ iss: LK_KEY, sub: "skipper-server", nbf: now - 10, exp: now + 60, video: { room, roomAdmin: true } }, LK_SECRET);
      const api = LK_URL.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
      const r = await fetch(api + "/twirp/livekit.RoomService/ListParticipants", {
        method: "POST", headers: { Authorization: "Bearer " + adminJwt, "Content-Type": "application/json" }, body: JSON.stringify({ room }),
      });
      if (r.ok) {
        const j = await r.json();
        const others = (j.participants || []).filter((p: { identity: string }) => !String(p.identity).startsWith(user.id + "|"));
        if (others.length >= maxUsers) return json({ error: "Essa sala está cheia." }, 409);
      }
    } catch { /* sala ainda não existe: tudo certo */ }
  }

  const identity = user.id + "|" + peer;
  const jwt = await signJwt({
    iss: LK_KEY, sub: identity, nbf: now - 10, exp: now + 6 * 3600,
    name: prof.display_name || prof.username || "Usuário",
    metadata: JSON.stringify({ uid: user.id }),
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: false },
  }, LK_SECRET);
  return json({ ok: true, url: LK_URL, token: jwt, room });
});
