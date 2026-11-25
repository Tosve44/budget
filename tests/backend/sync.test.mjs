// Two simulated phones (Tosve and Milica) syncing through Supabase, using the real
// supabase-js library and the app's real Store and Sync code.
// Needs the fake Supabase server running (tests/backend/fake-supabase.cjs), or point
// SUPABASE_URL / SUPABASE_ANON_KEY at a real project.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { Store } from '../../store.js';
import { Sync } from '../../sync.js';

const require = createRequire(process.env.NODE_MODULES_DIR ? `${process.env.NODE_MODULES_DIR}/` : import.meta.url);
const { createClient } = require('@supabase/supabase-js');

const URL = process.env.SUPABASE_URL || 'http://localhost:54321';
let KEY = process.env.SUPABASE_ANON_KEY;
const run = Date.now().toString(36);

class Mem { constructor() { this.m = {}; } getItem(k) { return this.m[k] ?? null; } setItem(k, v) { this.m[k] = String(v); } removeItem(k) { delete this.m[k]; } }
class Photos { constructor() { this.m = new Map(); } async get(id) { return this.m.get(id); } async put(id, b) { this.m.set(id, b); } async del(id) { this.m.delete(id); } }

function phone() {
  const mem = new Mem();
  const store = new Store(mem);
  const client = createClient(URL, KEY, { auth: { storage: mem, persistSession: true, autoRefreshToken: false } });
  const photos = new Photos();
  const sync = new Sync({ store, client, photos, storage: mem });
  return { mem, store, client, photos, sync };
}
const faults = (f) => fetch(`${URL}/__test/faults`, { method: 'POST', body: JSON.stringify(f) });
const cat = (store, space, name, kind = 'expense') => store.categories(space.id, { includeArchived: true }).find((c) => c.name === name && c.kind === kind);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let T, M; // the two phones
const email = (n) => `${n}-${run}@example.test`;

before(async () => {
  if (!KEY) KEY = (await (await fetch(`${URL}/__test/anon-key`)).json()).key;
  T = phone();
  M = phone();
});

test('Tosve used the app before syncing: his entries are kept and uploaded', async () => {
  const s = T.store;
  s.addTransaction({ spaceId: s.personalSpace().id, categoryId: cat(s, s.personalSpace(), 'Gas').id, kind: 'expense', amount: 6000, date: '2026-11-10' });
  s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Groceries').id, kind: 'expense', amount: 4520, date: '2026-11-11', items: [{ name: 'Mleko 1L', price: 129 }] });
  s.updateCategory(cat(s, s.houseSpace(), 'Groceries').id, { budget: 40000 });
  await T.sync.signUp(email('tosve'), 'secret123');
  const h = await T.sync.createHousehold('Tosve');
  assert.match(h.invite_code, /^[0-9A-F]{8}$/);
  assert.equal(T.sync.pendingCount(), 0, 'everything uploaded');
  assert.equal(s.currentUser.name, 'Tosve');
  assert.equal(s.transactions(s.personalSpace().id).length, 1);
  assert.equal(s.transactions(s.houseSpace().id).length, 1);
  const { data } = await T.client.from('transactions').select('id');
  assert.equal(data.length, 2);
});

test('Milica joins with the code; her House entries merge into the shared categories', async () => {
  const s = M.store;
  s.setSetting('currentUserId', 'u_milica');
  s.addTransaction({ spaceId: s.personalSpace().id, categoryId: cat(s, s.personalSpace(), 'Beauty').id, kind: 'expense', amount: 2500, date: '2026-11-12' });
  s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Groceries').id, kind: 'expense', amount: 1800, date: '2026-11-12' });
  await M.sync.signUp(email('milica'), 'secret456');
  await assert.rejects(M.sync.joinHousehold('NOTACODE', 'Milica'), /not found/);
  await M.sync.joinHousehold(T.store.data.settings.inviteCode, 'Milica');
  const house = s.houseSpace();
  const groceries = s.categories(house.id).filter((c) => c.name === 'Groceries');
  assert.equal(groceries.length, 1, 'one Groceries category, not two');
  assert.equal(groceries[0].budget, 40000, "Tosve's budget is used");
  assert.equal(s.transactions(house.id).length, 2, "both people's House entries");
  assert.ok(s.transactions(house.id).every((t) => t.categoryId === groceries[0].id));
  assert.equal(s.transactions(s.personalSpace().id).length, 1, 'her personal entry kept');
  assert.deepEqual(s.data.users.map((u) => u.name).sort(), ['Milica', 'Tosve']);
});

test("Personal stays private: Tosve's phone never receives Milica's personal data", async () => {
  await T.sync.syncNow();
  const tx = T.store.data.transactions;
  assert.equal(tx.length, 3, 'his personal entry + 2 House entries');
  assert.ok(!tx.some((t) => t.amount === 2500), "Milica's Beauty entry is not on Tosve's phone");
  assert.ok(!T.store.data.categories.some((c) => c.name === 'Beauty' && c.spaceId === M.store.personalSpace().id));
  assert.equal(T.store.data.spaces.length, 2, 'his Personal + House only');
});

test('a House entry added on one phone shows up on the other', async () => {
  const s = T.store;
  const t = s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Travel').id, kind: 'expense', amount: 12000, date: '2026-11-15', note: 'Bled weekend' });
  await T.sync.syncNow();
  await M.sync.syncNow();
  const got = M.store.data.transactions.find((x) => x.id === t.id);
  assert.ok(got, 'arrived');
  assert.equal(got.note, 'Bled weekend');
  assert.equal(got.createdBy, T.sync.meta.userId);
  assert.equal(M.store.user(got.createdBy).name, 'Tosve');
});

test('both phones edit the same entry while offline: the later edit wins on both', async () => {
  const id = T.store.transactions(T.store.houseSpace().id).find((t) => t.note === 'Bled weekend').id;
  T.store.updateTransaction(id, { amount: 13000 });
  await sleep(20);
  M.store.updateTransaction(id, { amount: 14000, note: 'Bled + parking' });
  await M.sync.syncNow(); // Milica's (later) edit reaches the server first
  await T.sync.syncNow(); // Tosve's older edit is refused by the server, his phone takes Milica's
  await M.sync.syncNow();
  for (const p of [T, M]) {
    const t = p.store.data.transactions.find((x) => x.id === id);
    assert.equal(t.amount, 14000);
    assert.equal(t.note, 'Bled + parking');
  }
  assert.equal(T.sync.pendingCount(), 0);
});

test('the same conflict the other way round (older edit synced first) also ends with the later edit', async () => {
  const id = T.store.transactions(T.store.houseSpace().id).find((t) => t.note === 'Bled + parking').id;
  T.store.updateTransaction(id, { amount: 15000 });
  await sleep(20);
  M.store.updateTransaction(id, { amount: 16000 });
  await T.sync.syncNow(); // older edit first
  await M.sync.syncNow(); // newer edit overwrites
  await T.sync.syncNow();
  for (const p of [T, M]) assert.equal(p.store.data.transactions.find((x) => x.id === id).amount, 16000);
});

test('deleting an entry removes it on the other phone', async () => {
  const id = T.store.transactions(T.store.houseSpace().id).find((t) => t.amount === 16000).id;
  M.store.deleteTransaction(id);
  await M.sync.syncNow();
  await T.sync.syncNow();
  assert.ok(!T.store.data.transactions.find((x) => x.id === id));
  assert.ok(!M.store.data.transactions.find((x) => x.id === id));
});

test('delete on one phone vs a later edit on the other: the later edit wins', async () => {
  const s = T.store;
  const t = s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Shopping').id, kind: 'expense', amount: 999, date: '2026-11-16' });
  await T.sync.syncNow(); await M.sync.syncNow();
  T.store.deleteTransaction(t.id);
  await sleep(20);
  M.store.updateTransaction(t.id, { amount: 1099 });
  await T.sync.syncNow();
  await M.sync.syncNow();
  await T.sync.syncNow();
  for (const p of [T, M]) assert.equal(p.store.data.transactions.find((x) => x.id === t.id)?.amount, 1099);
});

test('no connection: changes wait on the phone and go up once the connection is back', async () => {
  const s = M.store;
  const t = s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Unexpected expenses').id, kind: 'expense', amount: 4200, date: '2026-11-17', note: 'Plumber' });
  await faults({ failNext: 50 });
  await assert.rejects(M.sync.syncNow());
  assert.equal(M.sync.status.state, 'error');
  assert.ok(M.sync.pendingCount() >= 1, 'still waiting to upload');
  assert.ok(M.store.data.transactions.find((x) => x.id === t.id), 'still shown on the phone');
  await faults({ failNext: 0 });
  await M.sync.syncNow();
  assert.equal(M.sync.pendingCount(), 0);
  await T.sync.syncNow();
  assert.ok(T.store.data.transactions.find((x) => x.id === t.id));
});

test('connection drops halfway through a sync: nothing is lost or doubled', async () => {
  const s = T.store;
  const ids = [];
  for (let i = 0; i < 5; i++) ids.push(s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Groceries').id, kind: 'expense', amount: 100 + i, date: '2026-11-18' }).id);
  await faults({ failNext: 0 });
  // let the upload go through but break the following download
  const realFrom = T.client.from.bind(T.client);
  let calls = 0;
  T.client.from = (table) => { if (++calls === 3) { faults({ failNext: 1 }); } return realFrom(table); };
  await T.sync.syncNow().catch(() => {});
  T.client.from = realFrom;
  await faults({ failNext: 0 });
  await T.sync.syncNow();
  await M.sync.syncNow();
  for (const p of [T, M]) {
    const found = p.store.data.transactions.filter((x) => ids.includes(x.id));
    assert.equal(found.length, 5, 'each entry exactly once');
  }
});

test('category changes sync: rename, budget, new category, hide', async () => {
  const s = T.store;
  const travel = cat(s, s.houseSpace(), 'Travel');
  s.updateCategory(travel.id, { name: 'Holidays', budget: 30000 });
  const pets = s.addCategory({ spaceId: s.houseSpace().id, name: 'Pets', kind: 'expense', budget: 5000 });
  s.updateCategory(cat(s, s.houseSpace(), 'Savings').id, { archived: true });
  await T.sync.syncNow(); await M.sync.syncNow();
  const m = M.store;
  assert.equal(m.category(travel.id).name, 'Holidays');
  assert.equal(m.category(travel.id).budget, 30000);
  assert.equal(m.category(pets.id).name, 'Pets');
  assert.equal(cat(m, m.houseSpace(), 'Savings').archived, true);
});

test('receipt photo taken on one phone can be opened on the other', async () => {
  const s = T.store;
  const bytes = new Uint8Array(50_000).map((_, i) => (i * 31) % 256);
  const blob = new Blob([bytes], { type: 'image/jpeg' });
  await T.photos.put('photo_local_1', blob);
  const t = s.addTransaction({ spaceId: s.houseSpace().id, categoryId: cat(s, s.houseSpace(), 'Groceries').id, kind: 'expense', amount: 839, date: '2026-11-19', receiptId: 'photo_local_1', items: [{ name: 'Kruh', price: 149 }] });
  await T.sync.syncNow();
  await M.sync.syncNow();
  const there = M.store.data.transactions.find((x) => x.id === t.id);
  assert.equal(there.receiptId, `cloud:${there.spaceId}/${t.id}.jpg`);
  const down = await M.sync.downloadPhoto(there.receiptId.slice(6));
  assert.deepEqual(new Uint8Array(await down.arrayBuffer()), bytes);
  assert.equal(T.store.data.transactions.find((x) => x.id === t.id).receiptId, 'photo_local_1', 'Tosve keeps his own copy');
  // deleting the entry deletes the photo in the cloud too
  T.store.deleteTransaction(t.id);
  await T.sync.syncNow();
  await sleep(50);
  await assert.rejects(M.sync.downloadPhoto(there.receiptId.slice(6)));
});

test("Milica cannot read Tosve's personal receipt photos", async () => {
  const s = T.store;
  await T.photos.put('photo_private', new Blob([new Uint8Array(100)], { type: 'image/jpeg' }));
  const t = s.addTransaction({ spaceId: s.personalSpace().id, categoryId: cat(s, s.personalSpace(), 'Barber').id, kind: 'expense', amount: 1500, date: '2026-11-19', receiptId: 'photo_private' });
  await T.sync.syncNow();
  await assert.rejects(M.sync.downloadPhoto(`${s.personalSpace().id}/${t.id}.jpg`));
  const up = await M.client.storage.from('receipts').upload(`${s.personalSpace().id}/evil.jpg`, new Blob([new Uint8Array(10)], { type: 'image/jpeg' }));
  assert.ok(up.error, 'cannot upload into his personal folder');
});

test('many entries: 2,500 entries sync both ways (more than one page)', async () => {
  const s = T.store;
  const groc = cat(s, s.houseSpace(), 'Groceries').id;
  for (let i = 0; i < 2500; i++) {
    s.addTransaction({ spaceId: s.houseSpace().id, categoryId: groc, kind: 'expense', amount: 1 + i, date: `2026-${String(1 + (i % 11)).padStart(2, '0')}-0${1 + (i % 9)}` });
  }
  const t0 = Date.now();
  await T.sync.syncNow();
  const up = Date.now() - t0;
  const t1 = Date.now();
  await M.sync.syncNow();
  const down = Date.now() - t1;
  const count = (p) => p.store.data.transactions.filter((x) => x.spaceId === p.store.houseSpace().id).length;
  assert.equal(count(M), count(T));
  assert.ok(count(M) > 2500);
  console.log(`    2,500 entries: upload ${up} ms, download ${down} ms`);
});

test('signing in on a new phone brings everything back', async () => {
  const N = phone();
  await N.sync.signIn(email('milica'), 'secret456');
  assert.ok(N.sync.connected);
  assert.equal(N.store.currentUser.name, 'Milica');
  const pers = N.store.transactions(N.store.personalSpace().id);
  assert.equal(pers.length, 1);
  assert.equal(pers[0].amount, 2500);
  assert.equal(N.store.transactions(N.store.houseSpace().id).length, M.store.transactions(M.store.houseSpace().id).length);
  // only one set of categories, not the new phone's defaults on top
  const names = N.store.categories(N.store.houseSpace().id, { includeArchived: true }).map((c) => c.name);
  assert.equal(names.length, new Set(names).size, 'no duplicate categories');
});

test('wrong password and duplicate sign-up give clear messages', async () => {
  const X = phone();
  await assert.rejects(X.sync.signIn(email('tosve'), 'nope-wrong'), /Wrong email or password/);
  await assert.rejects(X.sync.signUp(email('tosve'), 'secret123'), /already has an account/);
  await assert.rejects(X.sync.signUp(`short-${run}@example.test`, '123'), /too short/);
});

test('currency and names sync', async () => {
  await T.sync.setCurrency('EUR');
  await M.sync.rename('Milica S.');
  await T.sync.syncNow();
  assert.equal(T.store.user(M.sync.meta.userId).name, 'Milica S.');
  await M.sync.rename('Milica');
});

test('syncing again with no changes changes nothing', async () => {
  await T.sync.syncNow(); await M.sync.syncNow();
  const before = JSON.stringify(M.store.data);
  await M.sync.syncNow();
  assert.equal(JSON.stringify(M.store.data), before);
  assert.equal(M.sync.pendingCount(), 0);
});

test('signing out and back in on the same phone: nothing duplicated, authors kept', async () => {
  const before = M.store.data.transactions.length;
  const authors = new Map(M.store.data.transactions.map((t) => [t.id, t.createdBy]));
  await M.sync.signOut();
  await M.sync.signIn(email('milica'), 'secret456');
  assert.equal(M.store.data.transactions.length, before);
  assert.equal(new Set(M.store.data.transactions.map((t) => t.id)).size, before);
  for (const t of M.store.data.transactions) assert.equal(t.createdBy, authors.get(t.id));
  assert.equal(M.sync.pendingCount(), 0);
});
