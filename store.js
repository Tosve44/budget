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
//                    items?: [{ name, price }] }]  // receipt lines, price = line total in cents
// }
// Money is always stored as whole cents (integers) to avoid rounding errors.
// Dates are "YYYY-MM-DD" strings; months are "YYYY-MM".

const STORAGE_KEY = 'budget.v1';
export const SCHEMA_VERSION = 1;
// Limits that match the cloud database, so a row the phone saves can always be uploaded.
export const LIMITS = { amount: 1000000000, note: 500, categoryName: 60, items: 300, itemName: 120 }; // amount: 10 million, in cents

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

  addTransaction({ spaceId, categoryId, kind, amount, date, note, items, receiptId }) {
    const now = new Date().toISOString();
    const t = { id: uid('tx'), spaceId, categoryId, kind, amount, date, note: clip(note, LIMITS.note), createdBy: this.currentUser.id, createdAt: now, updatedAt: now };
    if (items && items.length) t.items = cleanItems(items);
    if (receiptId) t.receiptId = receiptId;
    this.data.transactions.push(t);
    this._changed('transactions', t.id);
    this.save();
    return t;
  }

  updateTransaction(id, patch) {
    const t = this.data.transactions.find((x) => x.id === id);
    if (!t) return null;
    if ('note' in patch) patch = { ...patch, note: clip(patch.note, LIMITS.note) };
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
        if (!key) continue;
        if (!map.has(key)) map.set(key, { key, name: it.name, entries: [] });
        map.get(key).entries.push({ date: t.date, price: it.price, txId: t.id, spaceId: t.spaceId, createdAt: t.createdAt });
      }
    }
    for (const g of map.values()) g.entries.sort((a, b) => (a.date + a.createdAt).localeCompare(b.date + b.createdAt));
    return map;
  }

  // The most recent earlier price for an item name, not counting transaction `excludeTxId`.
  previousPrice(name, beforeDate, excludeTxId) {
    const key = normalizeItem(name);
    let best = null;
    for (const t of this.data.transactions) {
      if (t.id === excludeTxId || t.date > beforeDate) continue;
      for (const it of t.items || []) {
        if (normalizeItem(it.name) === key && (!best || t.date >= best.date)) best = { date: t.date, price: it.price };
      }
    }
    return best;
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
  return items.slice(0, LIMITS.items).map((it) => ({ ...it, name: clip(it.name, LIMITS.itemName) }));
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
