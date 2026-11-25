/*
 * Deer Camp service worker — keeps the app shell available offline.
 *
 * Safety rules:
 *  - Hunting records live in IndexedDB, never in these caches. Updating or
 *    deleting caches can never remove a saved observation.
 *  - A new version installs in the background and only takes over when the
 *    hunter taps "UPDATE NOW" (SKIP_WAITING), so an update never interrupts
 *    an entry in progress.
 *  - Map tiles, weather and Supabase requests are NOT intercepted: they go to
 *    the network as normal (satellite imagery needs a connection).
 */
// __BUILD__ is replaced with the commit id by the GitHub Pages workflow, so every
// deploy installs fresh app files. Bump the version by hand if you deploy another way.
const VERSION = 'deer-camp-v1.3.1-__BUILD__';
const SHELL_CACHE = 'deer-camp-shell-' + VERSION;
const SHELL = [
  './',
  './index.html',
  './config.js',
  './js/core.js',
  './manifest.webmanifest',
  './vendor/leaflet/leaflet.js',
  './vendor/leaflet/leaflet.css',
  './vendor/leaflet/images/layers.png',
  './vendor/leaflet/images/layers-2x.png',
  './vendor/leaflet/images/marker-icon.png',
  './vendor/leaflet/images/marker-icon-2x.png',
  './vendor/leaflet/images/marker-shadow.png',
  './vendor/leaflet-heat.js',
  './vendor/supabase.js',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) =>
      // cache: 'reload' bypasses the HTTP cache so a new version gets fresh files
      Promise.all(SHELL.map((url) => fetch(new Request(url, { cache: 'reload' })).then((res) => {
        if (!res.ok) throw new Error('Failed to cache ' + url + ' (' + res.status + ')');
        return cache.put(url, res);
      })))
    )
  );
  // First install: activate right away so the app works offline after one visit.
  if (!self.registration.active) self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('deer-camp-shell-') && k !== SHELL_CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // tiles, weather, Supabase: network only

  if (req.mode === 'navigate') {
    // App shell: answer from cache instantly (works with no or weak signal).
    event.respondWith((async () => {
      const cache = await caches.open(SHELL_CACHE);
      const cached = await cache.match('./index.html');
      if (cached) return cached;
      try { return await fetch(req); } catch (e) {
        return new Response('<h1>Deer Camp is not available offline yet</h1><p>Open it once with internet so it can be saved on this phone.</p>',
          { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  event.respondWith((async () => {
    const cache = await caches.open(SHELL_CACHE);
    const cached = await cache.match(req, { ignoreSearch: true });
    if (cached) return cached;
    try {
      return await fetch(req);
    } catch (e) {
      return new Response('', { status: 504, statusText: 'Offline' });
    }
  })());
});
