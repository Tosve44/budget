// Tries to break the privacy rules through the public API, the way an attacker would:
// someone not signed in, a stranger with their own account, and the partner trying to reach
// the other person's Personal data. Works against the local test server or the real project
// (set SUPABASE_URL and SUPABASE_ANON_KEY). Creates test-…@example.com accounts.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { Store } from '../../store.js';
import { Sync } from '../../sync.js';

const require = createRequire(process.env.NODE_MODULES_DIR ? `${process.env.NODE_MODULES_DIR}/` : import.meta.url);
const { createClient } = require('@supabase/supabase-js');

const URL = process.env.SUPABASE_URL || 'http://localhost:54321';
let KEY = process.env.SUPABASE_ANON_KEY;
const LIVE = !!process.env.SUPABASE_URL;
const run = Date.now().toString(36);
const email = (n) => `test-${n}-${run}@example.com`;

class Mem { constructor() { this.m = {}; } getItem(k) { return this.m[k] ?? null; } setItem(k, v) { this.m[k] = String(v); } removeItem(k) { delete this.m[k]; } }
class Photos { constructor() { this.m = new Map(); } async get(id) { return this.m.get(id); } async put(id, b) { this.m.set(id, b); } async del(id) { this.m.delete(id); } }
function phone() {
  const mem = new Mem();
  const store = new Store(mem);
  const client = createClient(URL, KEY, { auth: { storage: mem, persistSession: true, autoRefreshToken: false } });
  const photos = new Photos();
  return { mem, store, client, photos, sync: new Sync({ store, client, photos, storage: mem }) };
}
const cat = (s, space, name, kind = 'expense') => s.categories(space.id).find((c) => c.name === name && c.kind === kind);
// A tiny valid JPEG (1×1 pixel).
const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=', 'base64');

let T, M, X, anon;
let tPersonal, mPersonal, house, tPersTx, houseTx, tPersCat, houseCat;

before(async () => {
  if (!KEY) KEY = (await (await fetch(`${URL}/__test/anon-key`)).json()).key;
  T = phone(); M = phone(); X = phone();
  anon = createClient(URL, KEY, { auth: { persistSession: false } });
  await T.sync.signUp(email('atk-tosve'), 'secret123');
  await T.sync.createHousehold('Tosve');
  M.store.setSetting('currentUserId', 'u_milica');
  await M.sync.signUp(email('atk-milica'), 'secret456');
  await M.sync.joinHousehold(T.store.data.settings.inviteCode, 'Milica');
  await X.sync.signUp(email('atk-stranger'), 'secret789');
  await X.sync.createHousehold('Stranger');

  const s = T.store;
  tPersonal = s.personalSpace(); house = s.houseSpace();
  tPersCat = cat(s, tPersonal, 'Gas'); houseCat = cat(s, house, 'Groceries');
  tPersTx = s.addTransaction({ spaceId: tPersonal.id, categoryId: tPersCat.id, kind: 'expense', amount: 5000, date: '2026-11-20', note: 'secret personal' });
  houseTx = s.addTransaction({ spaceId: house.id, categoryId: houseCat.id, kind: 'expense', amount: 3000, date: '2026-11-20', note: 'house' });
  await T.sync.syncNow();
  // Photos: one in Tosve's Personal space, one in the House.
  for (const sp of [tPersonal.id, house.id]) {
    const { error } = await T.client.storage.from('receipts').upload(`${sp}/tx_photo${run}.jpg`, JPEG, { contentType: 'image/jpeg', upsert: true });
    assert.ifError(error);
  }
  await M.sync.syncNow();
  mPersonal = M.store.personalSpace();
});

const TABLES = ['households', 'members', 'spaces', 'categories', 'transactions'];

test('not signed in: every table is closed', async () => {
  for (const t of TABLES) {
    const { data, error } = await anon.from(t).select('*').limit(5);
    assert.ok(error || data.length === 0, `${t} readable without signing in`);
  }
});

test('not signed in: cannot write, call the sign-up functions, or touch photos', async () => {
  const ins = await anon.from('transactions').insert({ id: `tx_anon${run}`, space_id: house.id, category_id: houseCat.id, kind: 'expense', amount: 1, date: '2026-11-20' });
  assert.ok(ins.error, 'anon insert worked');
  const rpc = await anon.rpc('join_household', { code: T.store.data.settings.inviteCode, display_name: 'x', personal_space_id: `sp_personal_${run}anon` });
  assert.ok(rpc.error, 'anon could join');
  const dl = await anon.storage.from('receipts').download(`${house.id}/tx_photo${run}.jpg`);
  assert.ok(dl.error, 'anon downloaded a photo');
  const list = await anon.storage.from('receipts').list(house.id);
  assert.ok(list.error || list.data.length === 0, 'anon listed photos');
  const up = await anon.storage.from('receipts').upload(`${house.id}/evil${run}.jpg`, JPEG, { contentType: 'image/jpeg' });
  assert.ok(up.error, 'anon uploaded a photo');
});

test('not signed in: the public photo URL does not work (bucket is private)', async () => {
  const { data } = anon.storage.from('receipts').getPublicUrl(`${house.id}/tx_photo${run}.jpg`);
  const r = await fetch(data.publicUrl);
  assert.notEqual(r.status, 200, 'photo is public');
});

test('a stranger with an account sees nothing of the household, even by id', async () => {
  for (const t of ['categories', 'transactions']) {
    const { data } = await X.client.from(t).select('id').in('space_id', [house.id, tPersonal.id, mPersonal.id]);
    assert.equal(data.length, 0, t);
  }
  const { data: sp } = await X.client.from('spaces').select('id').in('id', [house.id, tPersonal.id]);
  assert.equal(sp.length, 0);
  const { data: mem } = await X.client.from('members').select('user_id');
  assert.equal(mem.length, 1, 'only sees themselves');
});

test('a stranger cannot overwrite an entry by sending its id (insert-or-update)', async () => {
  const r = await X.client.from('transactions').upsert({ id: houseTx.id, space_id: house.id, category_id: houseCat.id, kind: 'expense', amount: 1, date: '2026-11-20', note: 'hacked', updated_at: '2099-01-01T00:00:00Z' }, { onConflict: 'id' });
  assert.ok(r.error, 'upsert accepted');
  const { data } = await T.client.from('transactions').select('amount,note').eq('id', houseTx.id).single();
  assert.deepEqual(data, { amount: 3000, note: 'house' });
  const r2 = await X.client.from('transactions').update({ note: 'hacked' }).eq('id', houseTx.id).select('id');
  assert.equal(r2.data?.length || 0, 0);
});

test('a stranger cannot add into the House, join the full household, or reach photos', async () => {
  const ins = await X.client.from('transactions').insert({ id: `tx_x${run}`, space_id: house.id, category_id: houseCat.id, kind: 'expense', amount: 1, date: '2026-11-20' });
  assert.ok(ins.error);
  const cins = await X.client.from('categories').insert({ id: `cat_x${run}`, space_id: house.id, name: 'Evil', kind: 'expense' });
  assert.ok(cins.error);
  const dl = await X.client.storage.from('receipts').download(`${house.id}/tx_photo${run}.jpg`);
  assert.ok(dl.error, 'stranger downloaded the House photo');
  const up = await X.client.storage.from('receipts').upload(`${house.id}/tx_photo${run}.jpg`, JPEG, { contentType: 'image/jpeg', upsert: true });
  assert.ok(up.error, 'stranger replaced the House photo');
  const rm = await X.client.storage.from('receipts').remove([`${house.id}/tx_photo${run}.jpg`]);
  assert.ok(rm.error || rm.data.length === 0, 'stranger deleted the House photo');
  const { data: still } = await T.client.storage.from('receipts').list(house.id, { search: `tx_photo${run}` });
  assert.equal(still.length, 1, 'House photo still there');
});

test('a third person cannot join with the code once two people are in', async () => {
  const Y = phone();
  await Y.sync.signUp(email('atk-third'), 'secret000');
  await assert.rejects(Y.sync.joinHousehold(T.store.data.settings.inviteCode, 'Third'), /full|household/i);
});

test("the partner cannot read Tosve's Personal entries, categories or photos, even by id", async () => {
  const a = await M.client.from('transactions').select('id').eq('id', tPersTx.id);
  assert.equal(a.data.length, 0);
  const b = await M.client.from('categories').select('id').eq('space_id', tPersonal.id);
  assert.equal(b.data.length, 0);
  const c = await M.client.from('spaces').select('id').eq('id', tPersonal.id);
  assert.equal(c.data.length, 0);
  const d = await M.client.storage.from('receipts').download(`${tPersonal.id}/tx_photo${run}.jpg`);
  assert.ok(d.error, 'partner downloaded a personal photo');
  const e = await M.client.storage.from('receipts').list(tPersonal.id);
  assert.ok(e.error || e.data.length === 0, 'partner listed personal photos');
  assert.ok(!M.store.data.transactions.some((t) => t.id === tPersTx.id), 'nothing personal synced to her phone');
});

test("the partner cannot change, hide or overwrite Tosve's Personal data", async () => {
  const up = await M.client.from('transactions').upsert({ id: tPersTx.id, space_id: house.id, category_id: houseCat.id, kind: 'expense', amount: 1, date: '2026-11-20', updated_at: '2099-01-01T00:00:00Z' }, { onConflict: 'id' });
  assert.ok(up.error, 'partner took over a personal entry by id');
  const del = await M.client.from('transactions').update({ deleted: true }).eq('id', tPersTx.id).select('id');
  assert.equal(del.data?.length || 0, 0);
  const cu = await M.client.from('categories').update({ name: 'x' }).eq('id', tPersCat.id).select('id');
  assert.equal(cu.data?.length || 0, 0);
  const ph = await M.client.storage.from('receipts').upload(`${tPersonal.id}/tx_photo${run}.jpg`, JPEG, { contentType: 'image/jpeg', upsert: true });
  assert.ok(ph.error, "partner overwrote a personal photo");
  const { data } = await T.client.from('transactions').select('amount,deleted,space_id').eq('id', tPersTx.id).single();
  assert.deepEqual(data, { amount: 5000, deleted: false, space_id: tPersonal.id });
});

test("the partner cannot move a House entry into Tosve's Personal space or use his categories", async () => {
  const a = await M.client.from('transactions').update({ space_id: tPersonal.id, category_id: tPersCat.id }).eq('id', houseTx.id).select('id');
  assert.ok(a.error || a.data.length === 0);
  const b = await M.client.from('transactions').update({ category_id: tPersCat.id }).eq('id', houseTx.id).select('id');
  assert.ok(b.error || b.data.length === 0);
  const c = await M.client.from('transactions').insert({ id: `tx_m${run}`, space_id: tPersonal.id, category_id: tPersCat.id, kind: 'expense', amount: 1, date: '2026-11-20' });
  assert.ok(c.error);
});

test('nobody can hard-delete rows, rename the other person, change the invite code or make spaces', async () => {
  const del = await M.client.from('transactions').delete().eq('id', houseTx.id).select('id');
  assert.ok(del.error || del.data.length === 0);
  const { data: still } = await T.client.from('transactions').select('id').eq('id', houseTx.id);
  assert.equal(still.length, 1);
  const tUser = (await T.sync.currentUser()).id;
  const ren = await M.client.from('members').update({ display_name: 'Hacked' }).eq('user_id', tUser).select('user_id');
  assert.ok(ren.error || ren.data.length === 0);
  const code = await M.client.from('households').update({ invite_code: 'AAAAAAAA' }).neq('id', '00000000-0000-0000-0000-000000000000').select('id');
  assert.ok(code.error, 'invite code changed');
  const sp = await M.client.from('spaces').insert({ id: `sp_house_${run}x`, household_id: M.sync.meta.householdId, type: 'house', name: 'x' });
  assert.ok(sp.error, 'made a space');
  const mem = await X.client.from('members').insert({ household_id: M.sync.meta.householdId, user_id: (await X.sync.currentUser()).id, display_name: 'x' });
  assert.ok(mem.error, 'stranger added themselves as a member');
});

test('the author of an entry and the server clock cannot be faked', async () => {
  const id = `tx_fake${run}`;
  const tUser = (await T.sync.currentUser()).id;
  const w = await M.client.from('transactions').insert({ id, space_id: house.id, category_id: houseCat.id, kind: 'expense', amount: 100, date: '2026-11-20', created_by: tUser, server_updated_at: '2099-01-01T00:00:00Z' });
  if (w.error) return; // refusing the write is also fine
  const r = await T.client.from('transactions').select('created_by,server_updated_at').eq('id', id).single();
  assert.notEqual(r.data.created_by, tUser, 'Milica made an entry look like it was Tosve\'s');
  assert.ok(new Date(r.data.server_updated_at) < new Date('2098-01-01'), 'server clock was faked; the other phone would stop receiving changes');
});

test('the database functions behind the privacy rules cannot be misused from outside', async () => {
  const a = await anon.rpc('my_household');
  assert.ok(a.error || a.data === null);
  const b = await X.client.rpc('can_access_space', { sid: house.id });
  assert.ok(b.error || b.data === false);
  const c = await X.client.rpc('create_household', { display_name: 'again', house_space_id: `sp_house_${run}y`, personal_space_id: `sp_personal_${run}y` });
  assert.ok(c.error, 'second household for the same person');
});

test('the GraphQL endpoint does not leak data', { skip: !LIVE && 'live project only' }, async () => {
  const q = '{ transactionsCollection { edges { node { id note } } } }';
  for (const c of [anon, X.client]) {
    const token = (await c.auth.getSession()).data.session?.access_token || KEY;
    const r = await fetch(`${URL}/graphql/v1`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: q }) });
    const body = await r.text();
    assert.ok(!body.includes('secret personal') && !body.includes(houseTx.id), `GraphQL leaked: ${body.slice(0, 200)}`);
  }
});

test('photos must be JPEG and at most 3 MB', async () => {
  const html = await T.client.storage.from('receipts').upload(`${house.id}/x${run}.jpg`, Buffer.from('<script>alert(1)</script>'), { contentType: 'text/html' });
  assert.ok(html.error, 'HTML file accepted as a photo');
  const big = await T.client.storage.from('receipts').upload(`${house.id}/big${run}.jpg`, Buffer.alloc(3.2 * 1024 * 1024, 1), { contentType: 'image/jpeg' });
  assert.ok(big.error, '3.2 MB file accepted');
});
