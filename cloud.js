// Connects the app to Supabase (if configured) and keeps it syncing in the background.
import { CONFIG } from './config.js';
import { Sync } from './sync.js';
import { getPhoto, putPhoto, deletePhoto } from './photos.js';

function config() {
  // A test run can point the app at a local test server.
  try {
    const o = JSON.parse(localStorage.getItem('budget.config.override') || 'null');
    if (o?.supabaseUrl) return o;
  } catch {}
  return CONFIG;
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error('Could not load the sync library.'));
    document.head.appendChild(s);
  });
}

// On bad Wi-Fi a request can hang without ever failing. Give up after a while, so syncing is
// never stuck: the app shows "offline" and tries again later.
function fetchWithTimeout(input, init = {}) {
  const url = String(input?.url || input);
  const ms = url.includes('/storage/') ? 90000 : 20000;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(new DOMException('The connection timed out.', 'TimeoutError')), ms);
  init.signal?.addEventListener('abort', () => ctrl.abort(init.signal.reason));
  return fetch(input, { ...init, signal: ctrl.signal }).finally(() => clearTimeout(timer));
}

export async function startCloud(store) {
  const cfg = config();
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) return null;
  if (!window.supabase) await loadScript(new URL('vendor/supabase/supabase.js', import.meta.url).href);
  const client = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: 'budget.auth' },
    global: { fetch: fetchWithTimeout },
  });
  const sync = new Sync({ store, client, photos: { get: getPhoto, put: putPhoto, del: deletePhoto } });

  const kick = () => { if (sync.connected && document.visibilityState === 'visible') sync.syncNow().catch(() => {}); };
  document.addEventListener('visibilitychange', kick);
  window.addEventListener('online', kick);
  window.addEventListener('focus', kick);
  setInterval(kick, 30000);
  return sync;
}

// A receipt photo on this phone, or downloaded from the cloud (and kept) if the partner took it.
export async function loadPhoto(sync, id) {
  const local = await getPhoto(id).catch(() => null);
  if (local || !id.startsWith('cloud:') || !sync) return local;
  const blob = await sync.downloadPhoto(id.slice(6));
  await putPhoto(id, blob).catch(() => {});
  return blob;
}
