// Skipper: service worker simples. Guarda a "casca" do app para abrir rápido,
// mas sempre tenta a versão nova da página primeiro. Nada do Supabase passa por aqui.
const CACHE = 'skipper-v1';
const SHELL = ['/', '/logo.svg', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png', '/badges/skipper1.gif'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return; // Supabase, PeerJS, CDNs: direto da rede
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put('/', copy)); return r; }).catch(() => caches.match('/')));
    return;
  }
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
    if (r.ok && /^\/(icons|badges|vendor)\//.test(url.pathname)) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
    return r;
  })));
});
