// Data layer. Everything the app knows lives in one plain JSON object, so it can be
// exported, backed up, synced, or moved into a future native iPhone app unchanged.
//
// Shape (schemaVersion 1):
// {
//   schemaVersion: 1,
//   settings:     { currency: "EUR", currentUserId: "u_tosve" },
//   users:        [{ id, name }],
//   spaces:       [{ id, type: "personal" | "house", name, ownerId | null, memberIds: [] }],
//   categories:   [{ id, spaceId, name, kind: "expense" | "income", budget, order, archived, updatedAt? }],
//   transactions: [{ id, spaceId, categoryId, kind, amount, date, note, createdBy, createdAt, updatedAt,
//                    receiptId?,            // id of the receipt photo (stored separately, see photos.js)
//                    store?,                // the shop ("Mercator"), read from the receipt or typed
//                    items?: [{ name, price, qty?, unit?, unitPrice? }] }]  // receipt lines, price = line total in cents;
//                    // qty: how many (2) or how much (0.856 with unit "kg") when the receipt says so,
//                    // unitPrice: the printed price of one piece or one kilo
// }
// Money is always stored as whole cents (integers) to avoid rounding errors.
// Dates are "YYYY-MM-DD" strings; months are "YYYY-MM".

const STORAGE_KEY = 'budget.v1';
export const SCHEMA_VERSION = 1;
// Limits that match the cloud database, so a row the phone saves can always be uploaded.
export const LIMITS = { amount: 1000000000, note: 500, categoryName: 60, items: 300, itemName: 120, store: 60 }; // amount: 10 million, in cents

const PERSONAL_EXPENSES = [
  'Car', 'Rent', 'Groceries', 'Food & Drinks', 'Lunch at work', 'Nicotine', 'Gym & Sports',
  'Shopping', 'Gas', 'Traveling', 'Saving', 'Partner balance', 'Investing',
  'Cash (ATM)', 'Barber', 'Beauty', 'Toiletries',
];
const PERSONAL_INCOME = ['Salary', 'Other income'];
const HOUSE_EXPENSES = ['Groceries', 'Savings', 'Shopping', 'Travel', 'Unexpected expenses'];
const HOUSE_INCOME = ['Contributions'];

export function uid(prefix = 'id') {
  const rnd = (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36));
  return `${prefix}_${rnd.replace(/-/g, '').slice(0, 16)}`;
}

export function createInitialData() {
  const users = [
    { id: 'u_tosve', name: 'Tosve' },
    { id: 'u_milica', name: 'Milica' },
  ];
  const spaces = [
    { id: 'sp_personal_tosve', type: 'personal', name: 'Personal', ownerId: 'u_tosve', memberIds: ['u_tosve'] },
    { id: 'sp_personal_milica', type: 'personal', name: 'Personal', ownerId: 'u_milica', memberIds: ['u_milica'] },
    { id: 'sp_house', type: 'house', name: 'House', ownerId: null, memberIds: ['u_tosve', 'u_milica'] },
  ];
  const categories = [];
  const add = (spaceId, names, kind) => names.forEach((name) => {
    categories.push({ id: uid('cat'), spaceId, name, kind, budget: 0, order: categories.length, archived: false });
  });
  for (const sp of spaces) {
    if (sp.type === 'personal') {
      add(sp.id, PERSONAL_EXPENSES, 'expense');
      add(sp.id, PERSONAL_INCOME, 'income');
      // Milica receives the partner balance, so on her side it is also an income category.
      if (sp.ownerId === 'u_milica') add(sp.id, ['Partner balance'], 'income');
    } else {
      add(sp.id, HOUSE_EXPENSES, 'expense');
      add(sp.id, HOUSE_INCOME, 'income');
    }
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    settings: { currency: 'EUR', currentUserId: 'u_tosve' },
    users, spaces, categories, transactions: [],
  };
}

export function validateData(d) {
  if (!d || typeof d !== 'object') throw new Error('Not a backup file.');
  if (d.schemaVersion !== SCHEMA_VERSION) throw new Error(`Unsupported backup version: ${d.schemaVersion}`);
  for (const k of ['users', 'spaces', 'categories', 'transactions']) {
    if (!Array.isArray(d[k])) throw new Error(`Backup is missing "${k}".`);
  }
  if (!d.settings) throw new Error('Backup is missing settings.');
  return d;
}

export class Store {
  constructor(storage) {
    if (storage === undefined) { try { storage = globalThis.localStorage; } catch { storage = null; } }
    this.storage = storage;
    this.listeners = new Set();
    // Called with (table, id, deletedRow?) whenever this phone changes a record, so sync.js
    // knows what to upload. Changes that come from the cloud do not call it.
    this.onLocalChange = null;
    this.data = this.load();
  }

  _changed(table, id, deletedRow) { if (this.onLocalChange) this.onLocalChange(table, id, deletedRow); }

  load() {
    let raw = null;
    try {
      raw = this.storage && this.storage.getItem(STORAGE_KEY);
      if (raw) return validateData(JSON.parse(raw));
    } catch (e) {
      console.warn('Could not load saved data, starting fresh.', e);
      // Keep the damaged copy, so it can still be rescued from a backup or by hand.
      try { if (raw) this.storage.setItem(`${STORAGE_KEY}.damaged`, raw); } catch {}
    }
    return createInitialData();
  }

  save() {
    this.saveFailed = false;
    try { this.storage && this.storage.setItem(STORAGE_KEY, JSON.stringify(this.data)); }
    catch (e) { console.warn('Could not save data.', e); this.saveFailed = true; }
    this.listeners.forEach((fn) => fn(this.data));
    return !this.saveFailed;
  }

  subscribe(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }

  // ---- reads ----
  get currentUser() { return this.data.users.find((u) => u.id === this.data.settings.currentUserId) || this.data.users[0]; }
  user(id) { return this.data.users.find((u) => u.id === id); }
  personalSpace(userId = this.currentUser.id) { return this.data.spaces.find((s) => s.type === 'personal' && s.ownerId === userId); }
  houseSpace() { return this.data.spaces.find((s) => s.type === 'house'); }
  space(id) { return this.data.spaces.find((s) => s.id === id); }

  categories(spaceId, { includeArchived = false } = {}) {
    return this.data.categories
      .filter((c) => c.spaceId === spaceId && (includeArchived || !c.archived))
      .sort((a, b) => a.order - b.order);
  }
  category(id) { return this.data.categories.find((c) => c.id === id); }

  transactions(spaceId, month) {
    return this.data.transactions
      .filter((t) => t.spaceId === spaceId && (!month || t.date.startsWith(month)))
      .sort((a, b) => (b.date + b.createdAt).localeCompare(a.date + a.createdAt));
  }

  monthSummary(spaceId, month) {
    const txs = this.transactions(spaceId, month);
    const byCategory = new Map();
    let income = 0, spent = 0;
    for (const t of txs) {
      if (t.kind === 'income') income += t.amount; else spent += t.amount;
      byCategory.set(t.categoryId, (byCategory.get(t.categoryId) || 0) + t.amount);
    }
    const cats = this.categories(spaceId);
    const budget = cats.filter((c) => c.kind === 'expense').reduce((s, c) => s + (c.budget || 0), 0);
    return { income, spent, budget, byCategory, count: txs.length };
  }

  // ---- writes ----
  setSetting(key, value) { this.data.settings[key] = value; this.save(); }

  renameUser(id, name) { const u = this.user(id); if (u) { u.name = name; this.save(); } }

  addTransaction({ spaceId, categoryId, kind, amount, date, note, items, receiptId, store }) {
    const now = new Date().toISOString();
    const t = { id: uid('tx'), spaceId, categoryId, kind, amount, date, note: clip(note, LIMITS.note), createdBy: this.currentUser.id, createdAt: now, updatedAt: now };
    if (items && items.length) t.items = cleanItems(items);
    if (receiptId) t.receiptId = receiptId;
    if (store && String(store).trim()) t.store = clip(String(store).trim(), LIMITS.store);
    this.data.transactions.push(t);
    this._changed('transactions', t.id);
    this.save();
    return t;
  }

  updateTransaction(id, patch) {
    const t = this.data.transactions.find((x) => x.id === id);
    if (!t) return null;
    if ('note' in patch) patch = { ...patch, note: clip(patch.note, LIMITS.note) };
    if ('store' in patch) patch = { ...patch, store: clip(String(patch.store || '').trim(), LIMITS.store) };
    if (patch.items) patch = { ...patch, items: cleanItems(patch.items) };
    Object.assign(t, patch, { updatedAt: new Date().toISOString() });
    this._changed('transactions', id);
    this.save();
    return t;
  }

  deleteTransaction(id) {
    const t = this.data.transactions.find((x) => x.id === id);
    if (!t) return;
    this.data.transactions = this.data.transactions.filter((x) => x.id !== id);
    this._changed('transactions', id, { ...t, updatedAt: new Date().toISOString() });
    this.save();
  }

  addCategory({ spaceId, name, kind, budget = 0, icon = '' }) {
    const order = Math.max(-1, ...this.data.categories.map((c) => c.order)) + 1;
    const c = { id: uid('cat'), spaceId, name: clip(name, LIMITS.categoryName), icon: clip(icon, 16), kind, budget, order, archived: false, updatedAt: new Date().toISOString() };
    this.data.categories.push(c);
    this._changed('categories', c.id);
    this.save();
    return c;
  }

  updateCategory(id, patch) {
    const c = this.category(id);
    if (!c) return;
    if ('name' in patch) patch = { ...patch, name: clip(patch.name, LIMITS.categoryName) };
    if ('icon' in patch) patch = { ...patch, icon: clip(patch.icon, 16) };
    Object.assign(c, patch, { updatedAt: new Date().toISOString() });
    this._changed('categories', id);
    this.save();
  }

  moveCategory(id, dir) {
    const c = this.category(id);
    if (!c) return;
    const list = this.categories(c.spaceId, { includeArchived: true }).filter((x) => x.kind === c.kind);
    const i = list.findIndex((x) => x.id === id);
    const j = i + dir;
    if (j < 0 || j >= list.length) return;
    [list[i].order, list[j].order] = [list[j].order, list[i].order];
    const now = new Date().toISOString();
    for (const x of [list[i], list[j]]) { x.updatedAt = now; this._changed('categories', x.id); }
    this.save();
  }

  // ---- receipt items / price tracking ----
  // Every receipt line ever saved, grouped by item name, oldest first.
  itemHistory() {
    const map = new Map();
    for (const t of this.data.transactions) {
      for (const it of t.items || []) {
        const key = normalizeItem(it.name);
        if (!key || pricePerUnit(it) === null) continue;
        if (!map.has(key)) map.set(key, { key, name: it.name, entries: [] });
        // price: of one piece or one kilo (see pricePerUnit), so buying two, or a bigger bunch of
        // bananas, does not look like a price rise.
        map.get(key).entries.push({ date: t.date, price: pricePerUnit(it), unit: it.unit, store: t.store || '', txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt });
      }
    }
    for (const g of map.values()) g.entries.sort((a, b) => (a.date + a.createdAt).localeCompare(b.date + b.createdAt));
    return map;
  }

  // The most recent earlier price for an item name, not counting transaction `excludeTxId`.
  // With `store`: the latest earlier price at that shop, or at any shop when it was never bought
  // there (then the result's `store` says where).
  previousPrice(name, beforeDate, excludeTxId, store) {
    const key = normalizeItem(name);
    let best = null, here = null;
    for (const t of this.data.transactions) {
      if (t.id === excludeTxId || t.date > beforeDate) continue;
      for (const it of t.items || []) {
        if (normalizeItem(it.name) !== key || pricePerUnit(it) === null) continue;
        const p = { date: t.date, price: pricePerUnit(it), ...(it.unit ? { unit: it.unit } : {}), ...(t.store ? { store: t.store } : {}) };
        if (!best || t.date >= best.date) best = p;
        if (store && sameStore(t.store, store) && (!here || t.date >= here.date)) here = p;
      }
    }
    return here || best;
  }

  exportJSON() { return JSON.stringify(this.data, null, 2); }

  importJSON(text) {
    this.data = validateData(JSON.parse(text));
    this.data.categories.forEach((c) => this._changed('categories', c.id));
    this.data.transactions.forEach((t) => this._changed('transactions', t.id));
    this.save();
  }

  // Replace the whole data set without marking anything as changed (used by sync.js).
  replaceData(data) { this.data = data; this.save(); }

  reset() { this.data = createInitialData(); this.save(); }
}

// ---- helpers shared with the UI ----
// An icon for each category, picked from its name (the same list is used by the phone apps).
// Names not in the list, such as categories people add themselves, get a tag.
const ICONS = {
  'car': '🚗', 'rent': '🏠', 'groceries': '🛒', 'food & drinks': '🍽️', 'lunch at work': '🥪',
  'nicotine': '🚬', 'gym & sports': '🏋️', 'shopping': '🛍️', 'gas': '⛽', 'traveling': '✈️',
  'travel': '✈️', 'saving': '🐷', 'savings': '🐷', 'partner balance': '🤝', 'investing': '📈',
  'cash (atm)': '🏧', 'barber': '💈', 'beauty': '💅', 'toiletries': '🧴', 'salary': '💼',
  'other income': '💰', 'contributions': '💶', 'unexpected expenses': '⚠️',
};
export const DEFAULT_ICON = '🏷️';
// Icons a person can pick for a category (the phone apps show the same grid in this order).
export const ICON_CHOICES = ['🛒', '🍽️', '☕', '🥪', '🍕', '🍺', '🍷', '🚬', '🚗', '⛽', '🚌', '🚕', '✈️', '🏨', '🏠', '💡', '💧', '📱', '🌐', '🛍️',
  '👕', '👟', '💄', '💅', '💈', '🧴', '💊', '🏥', '🏋️', '⚽', '🎬', '🎮', '📚', '🎁', '🐶', '👶', '🐷', '📈', '💵', '🏷️'];
// A chosen icon wins; otherwise the default for the name. Accepts a category or just a name.
export function categoryIcon(catOrName) {
  if (catOrName && typeof catOrName === 'object') {
    if (catOrName.icon) return catOrName.icon;
    catOrName = catOrName.name;
  }
  return ICONS[String(catOrName || '').trim().toLowerCase()] || DEFAULT_ICON;
}

function clip(s, max) { return String(s || '').slice(0, max); }
function cleanItems(items) {
  return items.slice(0, LIMITS.items).map((it) => cleanItem({ ...it, name: clip(it.name, LIMITS.itemName) }));
}

// Keep a receipt line's quantity only when it makes sense. The printed price of one is kept even
// when it doesn't add up (see pricePerUnit).
export function cleanItem(it) {
  const out = { ...it };
  delete out.qty; delete out.unit; delete out.unitPrice;
  const qty = Number(it.qty);
  if (Number.isFinite(qty) && qty > 0 && qty <= 999 && qty !== 1) {
    out.qty = Math.round(qty * 1000) / 1000;
    if (it.unit === 'kg') out.unit = 'kg';
    const up = Number(it.unitPrice);
    if (Number.isInteger(up) && up > 0 && up <= LIMITS.amount) out.unitPrice = up;
  }
  return out;
}

// Price of one piece, or of one kilo, for comparing prices between shopping trips.
// "2 x 0,59 = 1,18" is 0,59; "0,856 kg x 1,49 = 1,28" is 1,49 per kilo.
// null when the quantity line doesn't add up to the line total (quantity × price of one ≠ total):
// one of the three numbers was misread, and nobody can see or fix the quantity, so such a line is
// left out of the price history rather than showing a made-up price. Fixing the total so it adds
// up again brings it back.
export function pricePerUnit(it) {
  if (!(it.qty > 0)) return it.price;
  if (!(it.unitPrice > 0)) return Math.round(it.price / it.qty);
  return Math.abs(Math.round(it.qty * it.unitPrice) - it.price) <= 1 ? it.unitPrice : null;
}

export function sameStore(a, b) {
  return normalizeItem(a || '') === normalizeItem(b || '');
}

// An item's price trend at one shop: prices change from shop to shop, so the change is worked out
// between purchases at the same shop (by default the shop of the newest purchase). A purchase
// without a shop (typed by hand, or saved before shops were kept) could be from any shop, so it
// counts for every shop; with no shop at all, every purchase counts. entries: oldest first, as
// in itemHistory().
export function storeTrend(entries, store) {
  const shop = store ?? (entries.at(-1)?.store || '');
  const list = entries.filter((e) => !shop || !e.store || sameStore(e.store, shop));
  const first = list[0], last = list.at(-1);
  const change = list.length > 1 && first.price ? Math.round(((last.price - first.price) / first.price) * 1000) / 10 : null;
  return { store: shop, entries: list, first, last, change };
}

export function toCents(input) {
  if (typeof input === 'number') return Math.round(input * 100);
  const s = String(input).trim().replace(/[\s\u00a0\u202f']/g, '').replace(/€|eur$/i, '');
  if (!/^\d[\d.,]*$|^[.,]\d+$/.test(s)) return NaN;
  // Accept "12,50" and "12.50"; the last separator is the decimal point, except a dot followed by
  // exactly three digits, which is the Slovenian thousands separator ("1.000" is one thousand).
  const lastSep = Math.max(s.lastIndexOf(','), s.lastIndexOf('.'));
  let normalized;
  if (lastSep === -1) normalized = s;
  else {
    const intPart = s.slice(0, lastSep).replace(/[.,]/g, '');
    const frac = s.slice(lastSep + 1);
    const mixed = s.includes(',') && s.includes('.');
    if (s[lastSep] === '.' && frac.length === 3 && !mixed && intPart && Number(intPart) > 0) normalized = intPart + frac;
    else normalized = `${intPart || '0'}.${frac}`;
  }
  const n = Number(normalized);
  return Number.isFinite(n) ? Math.round(n * 100) : NaN;
}

export function normalizeItem(name) {
  return String(name || '').toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^\p{L}\p{N}%]+/gu, ' ').trim();
}

export function monthKey(date = new Date()) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
}

export function todayKey(date = new Date()) {
  return `${monthKey(date)}-${String(date.getDate()).padStart(2, '0')}`;
}

export function shiftMonth(month, delta) {
  const [y, m] = month.split('-').map(Number);
  return monthKey(new Date(y, m - 1 + delta, 1));
}
