// Syncs this phone's data with Supabase so both phones share the House space.
// The app always works from the copy on the phone (works offline); this file uploads local
// changes and downloads the partner's changes whenever there is a connection.
// The cloud tables are described in supabase/migrations/*.sql and SYNC.md.

import { uid, createInitialData } from './store.js';

const META_KEY = 'budget.sync.v1';
const PAGE = 1000;           // Supabase returns at most 1000 rows per request
const PULL_OVERLAP_MS = 15000; // re-read a little before the last pull, in case a write landed late

const TABLES = ['categories', 'transactions'];

// ---------- local <-> cloud row mapping ----------
export function categoryToRow(c) {
  return {
    id: c.id, space_id: c.spaceId, name: c.name, kind: c.kind, budget: c.budget || 0,
    sort_order: c.order || 0, archived: !!c.archived, deleted: !!c.deleted,
    updated_at: c.updatedAt || '2000-01-01T00:00:00.000Z',
  };
}
export function rowToCategory(r) {
  return {
    id: r.id, spaceId: r.space_id, name: r.name, kind: r.kind, budget: Number(r.budget),
    order: r.sort_order, archived: r.archived, updatedAt: iso(r.updated_at),
  };
}
export function txToRow(t, receiptPath) {
  return {
    id: t.id, space_id: t.spaceId, category_id: t.categoryId, kind: t.kind, amount: t.amount,
    date: t.date, note: t.note || '', items: t.items || [], receipt_path: receiptPath ?? null,
    created_by: t.createdBy, created_at: t.createdAt, updated_at: t.updatedAt, deleted: !!t.deleted,
  };
}
export function rowToTx(r) {
  const t = {
    id: r.id, spaceId: r.space_id, categoryId: r.category_id, kind: r.kind, amount: Number(r.amount),
    date: String(r.date).slice(0, 10), note: r.note || '', createdBy: r.created_by,
    createdAt: iso(r.created_at), updatedAt: iso(r.updated_at),
  };
  if (Array.isArray(r.items) && r.items.length) t.items = r.items.map((i) => ({ name: i.name, price: Number(i.price) }));
  if (r.receipt_path) t.receiptId = `cloud:${r.receipt_path}`;
  return t;
}
// Postgres sends times like 2026-11-25T11:30:00.123456+00:00. Some Safari versions cannot read
// more than 3 decimals, so trim them before parsing.
export function parseTs(v) {
  if (!v) return 0;
  if (v instanceof Date) return v.getTime();
  return new Date(String(v).replace(' ', 'T').replace(/(\.\d{3})\d+/, '$1').replace(/([+-]\d\d)$/, '$1:00')).getTime();
}
const iso = (v) => new Date(parseTs(v)).toISOString();
const newer = (a, b) => parseTs(a) > parseTs(b);

function emptyMeta() {
  return { userId: null, householdId: null, lastPull: {}, dirty: { categories: {}, transactions: {} }, tombstones: { categories: {}, transactions: {} }, uploaded: {}, lastSyncAt: null, lastError: null };
}

export class Sync {
  /**
   * @param {object} opts
   * @param {import('./store.js').Store} opts.store
   * @param {object} opts.client   a supabase-js client
   * @param {object} [opts.photos] { get(id), put(id, blob), del(id) } for receipt photos
   * @param {Storage} [opts.storage] where to keep sync bookkeeping (localStorage)
   */
  constructor({ store, client, photos, storage }) {
    this.store = store;
    this.client = client;
    this.photos = photos;
    this.storage = storage === undefined ? safeLocalStorage() : storage;
    this.meta = this.loadMeta();
    this.running = null;
    this.again = false;
    this.listeners = new Set();
    this.status = { state: 'idle', lastSyncAt: this.meta.lastSyncAt, error: null };
    store.onLocalChange = (table, id, deletedRow) => this.markDirty(table, id, deletedRow);
  }

  // ---------- bookkeeping ----------
  loadMeta() {
    try { const raw = this.storage?.getItem(META_KEY); if (raw) return { ...emptyMeta(), ...JSON.parse(raw) }; } catch {}
    return emptyMeta();
  }
  saveMeta() { try { this.storage?.setItem(META_KEY, JSON.stringify(this.meta)); } catch {} }
  get connected() { return !!(this.meta.userId && this.meta.householdId); }

  onStatus(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  setStatus(patch) { Object.assign(this.status, patch); this.listeners.forEach((fn) => fn(this.status)); }

  markDirty(table, id, deletedRow) {
    if (!this.connected) return;
    if (deletedRow) {
      delete this.meta.dirty[table][id];
      this.meta.tombstones[table][id] = { ...deletedRow, deleted: true };
    } else {
      this.meta.dirty[table][id] = true;
    }
    this.saveMeta();
    this.schedule();
  }

  schedule(delay = 1200) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.syncNow().catch(() => {}), delay);
  }

  pendingCount() {
    return TABLES.reduce((n, t) => n + Object.keys(this.meta.dirty[t]).length + Object.keys(this.meta.tombstones[t]).length, 0);
  }

  // ---------- account ----------
  async currentUser() {
    const { data } = await this.client.auth.getSession();
    return data.session?.user || null;
  }

  async signUp(email, password) {
    const { data, error } = await this.client.auth.signUp({ email, password });
    if (error) throw friendly(error);
    return { needsConfirmation: !data.session };
  }

  async signIn(email, password) {
    const { error } = await this.client.auth.signInWithPassword({ email, password });
    if (error) throw friendly(error);
    return this.resume();
  }

  async signOut() {
    await this.client.auth.signOut().catch(() => {});
    this.meta = emptyMeta();
    this.saveMeta();
    this.setStatus({ state: 'idle', error: null });
  }

  // After sign-in: if this account already belongs to a household, connect to it.
  async resume() {
    const user = await this.currentUser();
    if (!user) return { connected: false };
    const { data, error } = await this.client.from('members').select('household_id').eq('user_id', user.id).maybeSingle();
    if (error) throw friendly(error);
    if (!data) return { connected: false, needsHousehold: true };
    if (this.meta.householdId !== data.household_id || this.meta.userId !== user.id) {
      await this.adopt(user, data.household_id);
    }
    await this.syncNow();
    return { connected: true };
  }

  async createHousehold(displayName) {
    const user = await this.currentUser();
    if (!user) throw new Error('Please sign in first.');
    const houseId = uid('sp_house');
    const personalId = uid('sp_personal');
    const { data, error } = await this.client.rpc('create_household', { display_name: displayName, house_space_id: houseId, personal_space_id: personalId });
    if (error) throw friendly(error);
    await this.adopt(user, data.id);
    await this.syncNow();
    return data;
  }

  async joinHousehold(code, displayName) {
    const user = await this.currentUser();
    if (!user) throw new Error('Please sign in first.');
    const { data, error } = await this.client.rpc('join_household', { code, display_name: displayName, personal_space_id: uid('sp_personal') });
    if (error) throw friendly(error);
    await this.adopt(user, data.id);
    await this.syncNow();
    return data;
  }

  // Move what is on this phone into the cloud household:
  // this phone's Personal space becomes the user's cloud Personal space, and its House space
  // is merged into the cloud House. Categories with the same name are merged into one.
  async adopt(user, householdId) {
    const [households, members, spaces] = await Promise.all([
      this.fetchAll('households'), this.fetchAll('members'), this.fetchAll('spaces'),
    ]);
    const cloudPersonal = spaces.find((s) => s.type === 'personal' && s.owner_id === user.id);
    const cloudHouse = spaces.find((s) => s.type === 'house');
    if (!cloudPersonal || !cloudHouse) throw new Error('Household spaces are missing.');
    const cloudCats = await this.fetchAll('categories');
    const cloudTx = await this.fetchAll('transactions');

    const d = this.store.data;
    const localPersonal = this.store.personalSpace();
    const localHouse = this.store.houseSpace();
    const spaceMap = new Map([[localPersonal?.id, cloudPersonal.id], [localHouse?.id, cloudHouse.id]]);
    const catMap = new Map();
    const keep = [];
    const cloudCatIds = new Map(cloudCats.map((r) => [r.id, r]));
    const cloudTxIds = new Map(cloudTx.map((r) => [r.id, r]));
    for (const c of d.categories) {
      const target = spaceMap.get(c.spaceId);
      if (!target) continue; // another person's local space on this phone: not uploaded
      const known = cloudCatIds.get(c.id);
      if (known) { // already in the cloud (e.g. signing in again): keep whichever is newer
        catMap.set(c.id, c.id);
        if (c.updatedAt && newer(c.updatedAt, known.updated_at)) keep.push({ ...c, spaceId: target });
        continue;
      }
      const same = cloudCats.find((r) => r.space_id === target && !r.deleted && r.kind === c.kind && r.name.trim().toLowerCase() === c.name.trim().toLowerCase());
      if (same) catMap.set(c.id, same.id);
      else { catMap.set(c.id, c.id); keep.push({ ...c, spaceId: target, updatedAt: c.updatedAt || new Date().toISOString() }); }
    }
    const txs = [];
    for (const t of d.transactions) {
      const target = spaceMap.get(t.spaceId);
      if (!target || !catMap.has(t.categoryId)) continue;
      const known = cloudTxIds.get(t.id);
      if (known && !newer(t.updatedAt, known.updated_at)) continue; // the cloud copy is current
      // entries made before signing in carry a placeholder author ("u_tosve"): they are yours
      const createdBy = String(t.createdBy || '').startsWith('u_') || !t.createdBy ? user.id : t.createdBy;
      txs.push({ ...t, spaceId: target, categoryId: catMap.get(t.categoryId), createdBy });
    }

    const meta = emptyMeta();
    meta.userId = user.id;
    meta.householdId = householdId;
    keep.forEach((c) => { meta.dirty.categories[c.id] = true; });
    txs.forEach((t) => { meta.dirty.transactions[t.id] = true; });
    this.meta = meta;

    const next = createInitialData();
    next.settings = { ...d.settings, currentUserId: user.id };
    next.users = members.map((m) => ({ id: m.user_id, name: m.display_name }));
    next.spaces = spaces.map((s) => ({ id: s.id, type: s.type, name: s.name, ownerId: s.owner_id, memberIds: s.type === 'house' ? members.map((m) => m.user_id) : [s.owner_id] }));
    const hh = households.find((h) => h.id === householdId);
    if (hh) { next.settings.currency = hh.currency; next.settings.inviteCode = hh.invite_code; }
    const keepIds = new Set(keep.map((c) => c.id));
    const txIds = new Set(txs.map((t) => t.id));
    next.categories = [...cloudCats.filter((r) => !r.deleted && !keepIds.has(r.id)).map(rowToCategory), ...keep];
    next.transactions = [...cloudTx.filter((r) => !r.deleted && !txIds.has(r.id)).map(rowToTx), ...txs];
    // keep photos that are already on this phone
    for (const t of next.transactions) {
      const old = d.transactions.find((x) => x.id === t.id);
      if (old?.receiptId && t.receiptId?.startsWith('cloud:')) t.receiptId = old.receiptId.startsWith('cloud:') ? t.receiptId : old.receiptId;
    }
    this.store.replaceData(next);
    this.saveMeta();
  }

  // ---------- syncing ----------
  async syncNow() {
    if (!this.connected) return;
    if (this.running) { this.again = true; return this.running; }
    this.running = (async () => {
      this.setStatus({ state: 'syncing', error: null });
      try {
        do {
          this.again = false;
          await this.push();
          await this.pull();
        } while (this.again);
        this.meta.lastSyncAt = new Date().toISOString();
        this.meta.lastError = null;
        this.saveMeta();
        this.setStatus({ state: 'idle', lastSyncAt: this.meta.lastSyncAt, error: null });
      } catch (e) {
        this.meta.lastError = String(e.message || e);
        this.saveMeta();
        this.setStatus({ state: 'error', error: friendly(e).message });
        throw e;
      } finally {
        this.running = null;
      }
    })();
    return this.running;
  }

  async fetchAll(table, since) {
    const out = [];
    for (let from = 0; ; from += PAGE) {
      let q = this.client.from(table).select('*');
      if (since) q = q.gt('server_updated_at', since);
      q = q.order('server_updated_at', { ascending: true }).order(table === 'members' ? 'user_id' : 'id', { ascending: true }).range(from, from + PAGE - 1);
      const { data, error } = await q;
      if (error) throw friendly(error);
      out.push(...data);
      if (data.length < PAGE) return out;
    }
  }

  async push() {
    const d = this.store.data;
    // 1. receipt photos first, so the entry can point at them
    const photoPaths = {};
    for (const id of Object.keys(this.meta.dirty.transactions)) {
      const t = d.transactions.find((x) => x.id === id);
      if (!t?.receiptId) continue;
      if (t.receiptId.startsWith('cloud:')) { photoPaths[id] = t.receiptId.slice(6); continue; }
      const path = `${t.spaceId}/${t.id}.jpg`;
      if (this.meta.uploaded[t.receiptId] !== path && this.photos) {
        const blob = await this.photos.get(t.receiptId);
        if (blob) {
          const { error } = await this.client.storage.from('receipts').upload(path, blob, { upsert: true, contentType: 'image/jpeg' });
          if (error) throw friendly(error);
          this.meta.uploaded[t.receiptId] = path;
          this.saveMeta();
        }
      }
      if (this.meta.uploaded[t.receiptId] === path) photoPaths[id] = path;
    }

    // 2. categories before entries (entries point to categories)
    for (const table of TABLES) {
      const rows = [];
      const sent = {};
      for (const id of Object.keys(this.meta.dirty[table])) {
        const local = table === 'categories' ? d.categories.find((x) => x.id === id) : d.transactions.find((x) => x.id === id);
        if (!local) { delete this.meta.dirty[table][id]; continue; }
        rows.push(table === 'categories' ? categoryToRow(local) : txToRow(local, photoPaths[id]));
        sent[id] = local.updatedAt;
      }
      for (const [id, dead] of Object.entries(this.meta.tombstones[table])) {
        rows.push(table === 'categories' ? categoryToRow(dead) : txToRow(dead, dead.receiptId?.startsWith('cloud:') ? dead.receiptId.slice(6) : null));
        sent[id] = dead.updatedAt;
      }
      if (!rows.length) continue;
      for (let i = 0; i < rows.length; i += 200) {
        const chunk = rows.slice(i, i + 200);
        const { data, error } = await this.client.from(table).upsert(chunk, { onConflict: 'id' }).select('id');
        if (error) throw friendly(error);
        // The server ignores an edit that is older than its own copy (the partner changed it
        // later). Fetch the winning version of those rows so this phone shows it.
        const accepted = new Set((data || []).map((r) => r.id));
        const lost = chunk.filter((r) => !accepted.has(r.id)).map((r) => r.id);
        if (lost.length) {
          const { data: winners, error: e2 } = await this.client.from(table).select('*').in('id', lost);
          if (e2) throw friendly(e2);
          this.applyRows(table, winners, { force: true });
        }
      }
      // forget what was sent, unless it changed again meanwhile
      const now = this.store.data;
      for (const [id, at] of Object.entries(sent)) {
        if (this.meta.tombstones[table][id]?.updatedAt === at) {
          const dead = this.meta.tombstones[table][id];
          delete this.meta.tombstones[table][id];
          if (table === 'transactions' && dead.receiptId) await this.removePhoto(dead).catch((e) => console.warn('photo not removed', e));
        }
        const local = (table === 'categories' ? now.categories : now.transactions).find((x) => x.id === id);
        if (this.meta.dirty[table][id] && (!local || local.updatedAt === at)) delete this.meta.dirty[table][id];
      }
      this.saveMeta();
    }
  }

  async removePhoto(dead) {
    const path = dead.receiptId.startsWith('cloud:') ? dead.receiptId.slice(6) : this.meta.uploaded[dead.receiptId];
    if (path) await this.client.storage.from('receipts').remove([path]);
    if (this.photos) await this.photos.del(dead.receiptId).catch(() => {});
    delete this.meta.uploaded[dead.receiptId];
  }

  async pull() {
    const since = (table) => {
      const t = this.meta.lastPull[table];
      return t ? new Date(parseTs(t) - PULL_OVERLAP_MS).toISOString() : null;
    };
    const results = {};
    for (const table of ['households', 'members', 'spaces', ...TABLES]) {
      const rows = await this.fetchAll(table, since(table));
      results[table] = rows;
      if (rows.length) {
        const latest = rows.reduce((m, r) => (newer(r.server_updated_at, m) ? r.server_updated_at : m), rows[0].server_updated_at);
        this.meta.lastPull[table] = iso(latest);
      }
    }
    const d = this.store.data;
    let changed = false;
    for (const h of results.households) {
      if (h.id !== this.meta.householdId) continue;
      if (d.settings.currency !== h.currency || d.settings.inviteCode !== h.invite_code) {
        d.settings.currency = h.currency; d.settings.inviteCode = h.invite_code; changed = true;
      }
    }
    for (const m of results.members) {
      const u = d.users.find((x) => x.id === m.user_id);
      if (!u) { d.users.push({ id: m.user_id, name: m.display_name }); changed = true; }
      else if (u.name !== m.display_name) { u.name = m.display_name; changed = true; }
      const house = d.spaces.find((s) => s.type === 'house');
      if (house && !house.memberIds.includes(m.user_id)) { house.memberIds.push(m.user_id); changed = true; }
    }
    for (const s of results.spaces) {
      if (!d.spaces.find((x) => x.id === s.id)) {
        d.spaces.push({ id: s.id, type: s.type, name: s.name, ownerId: s.owner_id, memberIds: [] });
        changed = true;
      }
    }
    if (this.applyRows('categories', results.categories, { save: false })) changed = true;
    if (this.applyRows('transactions', results.transactions, { save: false })) changed = true;
    if (this.mergeDuplicateCategories()) changed = true;
    this.saveMeta();
    if (changed) this.store.replaceData(d);
  }

  // Both phones added a category with the same name (for example both offline). Keep one,
  // move the entries to it and delete the other. Both phones pick the same one (lowest id),
  // so they agree without talking to each other. Hidden categories are left alone.
  mergeDuplicateCategories() {
    const d = this.store.data;
    const groups = new Map();
    for (const c of d.categories) {
      if (c.archived) continue;
      const k = `${c.spaceId}\n${c.kind}\n${c.name.trim().toLocaleLowerCase()}`;
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(c);
    }
    const now = new Date().toISOString();
    let changed = false;
    for (const list of groups.values()) {
      if (list.length < 2) continue;
      list.sort((a, b) => (a.id < b.id ? -1 : 1));
      const [keep, ...dups] = list;
      for (const dup of dups) {
        if (!keep.budget && dup.budget) { keep.budget = dup.budget; keep.updatedAt = now; this.markDirty('categories', keep.id); }
        for (const t of d.transactions) {
          if (t.categoryId === dup.id) { t.categoryId = keep.id; t.updatedAt = now; this.markDirty('transactions', t.id); }
        }
        d.categories = d.categories.filter((c) => c !== dup);
        this.markDirty('categories', dup.id, { ...dup, updatedAt: now });
        changed = true;
      }
    }
    return changed;
  }

  // Merge rows from the cloud into the phone's copy. A row this phone changed more recently
  // (and has not uploaded yet) is kept; otherwise the cloud version wins.
  applyRows(table, rows, { force = false, save = true } = {}) {
    if (!rows?.length) return false;
    const d = this.store.data;
    const list = table === 'categories' ? d.categories : d.transactions;
    let changed = false;
    for (const r of rows) {
      const i = list.findIndex((x) => x.id === r.id);
      const local = i >= 0 ? list[i] : null;
      const dead = this.meta.tombstones[table][r.id];
      if (!force) {
        if (local && this.meta.dirty[table][r.id] && !newer(r.updated_at, local.updatedAt || 0)) continue;
        if (dead && !newer(r.updated_at, dead.updatedAt)) continue;
      }
      if (dead) delete this.meta.tombstones[table][r.id];
      delete this.meta.dirty[table][r.id];
      if (r.deleted) {
        if (i >= 0) { list.splice(i, 1); changed = true; }
        continue;
      }
      const next = table === 'categories' ? rowToCategory(r) : rowToTx(r);
      if (table === 'transactions' && local?.receiptId && next.receiptId && this.meta.uploaded[local.receiptId] === r.receipt_path) {
        next.receiptId = local.receiptId; // keep using the photo already on this phone
      }
      if (!local) { list.push(next); changed = true; }
      else if (JSON.stringify(local) !== JSON.stringify({ ...local, ...next })) { list[i] = { ...local, ...next }; if (!next.items) delete list[i].items; changed = true; }
    }
    if (changed && save) this.store.replaceData(d);
    return changed;
  }

  async setCurrency(code) {
    const { error } = await this.client.from('households').update({ currency: code }).eq('id', this.meta.householdId);
    if (error) throw friendly(error);
  }

  async rename(displayName) {
    const { error } = await this.client.from('members').update({ display_name: displayName }).eq('user_id', this.meta.userId);
    if (error) throw friendly(error);
    await this.syncNow();
  }

  // Receipt photo stored in the cloud (for an entry the partner added).
  async downloadPhoto(path) {
    const { data, error } = await this.client.storage.from('receipts').download(path);
    if (error) throw friendly(error);
    return data;
  }
}

function safeLocalStorage() { try { return globalThis.localStorage; } catch { return null; } }

export function friendly(e) {
  const msg = String(e?.message || e || 'Unknown error');
  if (/Invalid login credentials/i.test(msg)) return new Error('Wrong email or password.');
  if (/already registered|already been registered/i.test(msg)) return new Error('This email already has an account. Sign in instead.');
  if (/Password should be/i.test(msg)) return new Error('Password is too short (at least 6 characters).');
  if (/invite code not found/i.test(msg)) return new Error('That invite code was not found.');
  if (/household is full/i.test(msg)) return new Error('That household already has two people.');
  if (/already in a household/i.test(msg)) return new Error('This account is already in a household.');
  if (/Email not confirmed/i.test(msg)) return new Error('Please confirm your email first (check your inbox), then sign in.');
  if (/Failed to fetch|NetworkError|Load failed|network|timed out|aborted/i.test(msg)) return new Error('No connection. Your changes are saved on this phone and will sync later.');
  return e instanceof Error ? e : new Error(msg);
}
