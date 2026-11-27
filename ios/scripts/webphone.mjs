// TEST ONLY: plays "a phone using the web app" for the iPhone app's sync tests, so the tests can
// check that the iPhone app and the web app really share data. It runs the web app's own
// store.js and sync.js with supabase-js. Everything the web app would keep in the browser is
// kept in a JSON state file between calls.
//
//   node webphone.mjs <web-app-dir> <state-file> <command> [json-args]
//
// Prints one JSON line with the result. Commands: signup, signin, create, join, sync, add,
// update, delete, rename-category, add-photo-entry, download, dump.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [webDir, stateFile, command, rawArgs] = process.argv.slice(2);
const args = rawArgs ? JSON.parse(rawArgs) : {};
const require = createRequire(`${process.env.NODE_MODULES_DIR || process.cwd()}/`);
const { createClient } = require('@supabase/supabase-js');
const { Store } = await import(pathToFileURL(`${webDir}/store.js`));
const { Sync } = await import(pathToFileURL(`${webDir}/sync.js`));

const saved = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : { mem: {}, photos: {} };
class Mem { constructor(m) { this.m = m; } getItem(k) { return this.m[k] ?? null; } setItem(k, v) { this.m[k] = String(v); } removeItem(k) { delete this.m[k]; } }
const mem = new Mem(saved.mem);
const photos = {
  async get(id) { return saved.photos[id] ? new Blob([Buffer.from(saved.photos[id], 'base64')], { type: 'image/jpeg' }) : undefined; },
  async put(id, b) { saved.photos[id] = Buffer.from(await b.arrayBuffer()).toString('base64'); },
  async del(id) { delete saved.photos[id]; },
};
const store = new Store(mem);
const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_ANON_KEY, { auth: { storage: mem, persistSession: true, autoRefreshToken: false } });
const sync = new Sync({ store, client, photos, storage: mem });
const cat = (spaceId, name, kind = 'expense') => store.categories(spaceId, { includeArchived: true }).find((c) => c.name === name && c.kind === kind);
const space = (which) => (which === 'house' ? store.houseSpace() : store.personalSpace());

let out = {};
try {
  switch (command) {
    case 'signup': await sync.signUp(args.email, args.password); break;
    case 'signin': out = await sync.signIn(args.email, args.password); break;
    case 'create': out = { inviteCode: (await sync.createHousehold(args.name)).invite_code }; break;
    case 'join': await sync.joinHousehold(args.code, args.name); break;
    case 'sync': await sync.syncNow(); break;
    case 'add': {
      const sp = space(args.space);
      const t = store.addTransaction({ spaceId: sp.id, categoryId: cat(sp.id, args.category, args.kind || 'expense').id, kind: args.kind || 'expense', amount: args.amount, date: args.date, note: args.note || '', items: args.items });
      out = { id: t.id };
      break;
    }
    case 'add-photo-entry': {
      const sp = space(args.space);
      await photos.put('web_photo_1', new Blob([Buffer.from(args.photoBase64, 'base64')]));
      const t = store.addTransaction({ spaceId: sp.id, categoryId: cat(sp.id, args.category).id, kind: 'expense', amount: args.amount, date: args.date, receiptId: 'web_photo_1' });
      out = { id: t.id };
      break;
    }
    case 'update': store.updateTransaction(args.id, args.patch); break;
    case 'delete': store.deleteTransaction(args.id); break;
    case 'rename-category': { const c = cat(space(args.space).id, args.from); store.updateCategory(c.id, { name: args.to, ...(args.budget != null ? { budget: args.budget } : {}) }); break; }
    case 'download': out = { base64: Buffer.from(await (await sync.downloadPhoto(args.path)).arrayBuffer()).toString('base64') }; break;
    case 'dump': break;
    default: throw new Error(`unknown command ${command}`);
  }
  if (sync.timer) clearTimeout(sync.timer);
  out = { ok: true, ...out, data: store.data, pending: sync.pendingCount(), userId: sync.meta.userId };
} catch (e) {
  if (sync.timer) clearTimeout(sync.timer);
  out = { ok: false, error: String(e.message || e) };
}
writeFileSync(stateFile, JSON.stringify(saved));
process.stdout.write(JSON.stringify(out) + '\n');
process.exit(0);
