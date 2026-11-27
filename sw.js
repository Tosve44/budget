// Offline support: keep a copy of the app files so it opens without internet.
// Bump VERSION whenever app files change so phones pick up the new version.
const VERSION = 'budget-v11';
const FILES = ['./', 'index.html', 'styles.css', 'app.js', 'store.js', 'photos.js', 'receipt.js', 'sync.js', 'cloud.js', 'config.js', 'manifest.webmanifest',
  'icons/icon.svg', 'icons/apple-touch-icon.png', 'icons/icon-192.png', 'icons/icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
// Network first, fall back to the saved copy when offline. 'no-cache' makes the phone check
// with the server every time instead of reusing its own short-term copy (GitHub Pages lets
// phones keep files for 10 minutes), so a new version shows up on the next open.
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(
    fetch(e.request, { cache: 'no-cache' }).then((res) => {
      const copy = res.clone();
      caches.open(VERSION).then((c) => c.put(e.request, copy));
      return res;
    }).catch(() => caches.match(e.request).then((r) => r || caches.match('index.html')))
  );
});
