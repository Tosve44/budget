import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Store, toCents, shiftMonth, normalizeItem, createInitialData, pricePerUnit, cleanItem, storeTrend } from '../store.js';
import { rowToTx } from '../sync.js';
import { parseReceipt, findStore } from '../receipt.js';

class MemStorage { constructor() { this.m = {}; } getItem(k) { return this.m[k] ?? null; } setItem(k, v) { this.m[k] = String(v); } }

test('toCents handles common ways of typing money', () => {
  const cases = { '12': 1200, '12,5': 1250, '12.50': 1250, '0,99': 99, '1.299,00': 129900, '1,299.00': 129900, ' 7 ': 700, '': NaN, 'abc': NaN };
  for (const [inp, want] of Object.entries(cases)) {
    const got = toCents(inp);
    if (Number.isNaN(want)) assert.ok(Number.isNaN(got), inp); else assert.equal(got, want, inp);
  }
  assert.equal(toCents('0.1') + toCents('0.2'), 30); // no floating point drift
});

test('shiftMonth crosses years', () => {
  assert.equal(shiftMonth('2026-12', 1), '2027-01');
  assert.equal(shiftMonth('2026-01', -1), '2025-12');
});

test('initial data has all categories in the right spaces', () => {
  const d = createInitialData();
  const names = (spaceId, kind) => d.categories.filter((c) => c.spaceId === spaceId && c.kind === kind).map((c) => c.name);
  for (const sp of ['sp_personal_tosve', 'sp_personal_milica']) {
    for (const n of ['Car', 'Rent', 'Groceries', 'Food & Drinks', 'Lunch at work', 'Nicotine', 'Gym & Sports', 'Shopping', 'Gas', 'Traveling', 'Saving', 'Partner balance', 'Investing', 'Cash (ATM)', 'Barber', 'Beauty', 'Toiletries']) {
      assert.ok(names(sp, 'expense').includes(n), `${sp} missing ${n}`);
    }
  }
  assert.deepEqual(names('sp_house', 'expense'), ['Groceries', 'Savings', 'Shopping', 'Travel', 'Unexpected expenses']);
  assert.ok(names('sp_personal_milica', 'income').includes('Partner balance'));
  assert.ok(!names('sp_personal_tosve', 'income').includes('Partner balance'));
  assert.equal(new Set(d.categories.map((c) => c.id)).size, d.categories.length, 'category ids unique');
});

function freshStore() { return new Store(new MemStorage()); }
const catId = (s, spaceId, name, kind = 'expense') => s.categories(spaceId).find((c) => c.name === name && c.kind === kind).id;

test('monthly summary: budget, spent, income, only that month and space', () => {
  const s = freshStore();
  const P = 'sp_personal_tosve';
  s.updateCategory(catId(s, P, 'Groceries'), { budget: 30000 });
  s.updateCategory(catId(s, P, 'Rent'), { budget: 50000 });
  s.addTransaction({ spaceId: P, categoryId: catId(s, P, 'Groceries'), kind: 'expense', amount: 4550, date: '2026-11-03' });
  s.addTransaction({ spaceId: P, categoryId: catId(s, P, 'Groceries'), kind: 'expense', amount: 1000, date: '2026-11-30' });
  s.addTransaction({ spaceId: P, categoryId: catId(s, P, 'Groceries'), kind: 'expense', amount: 9999, date: '2026-10-31' });
  s.addTransaction({ spaceId: P, categoryId: catId(s, P, 'Salary', 'income'), kind: 'income', amount: 200000, date: '2026-11-01' });
  s.addTransaction({ spaceId: 'sp_house', categoryId: catId(s, 'sp_house', 'Groceries'), kind: 'expense', amount: 777, date: '2026-11-05' });
  const sum = s.monthSummary(P, '2026-11');
  assert.equal(sum.spent, 5550);
  assert.equal(sum.income, 200000);
  assert.equal(sum.budget, 80000);
  assert.equal(sum.byCategory.get(catId(s, P, 'Groceries')), 5550);
  assert.equal(s.monthSummary('sp_house', '2026-11').spent, 777);
});

test('hidden categories drop out of the budget total but keep their entries', () => {
  const s = freshStore();
  const P = 'sp_personal_tosve';
  const car = catId(s, P, 'Car');
  s.updateCategory(car, { budget: 10000 });
  s.addTransaction({ spaceId: P, categoryId: car, kind: 'expense', amount: 500, date: '2026-11-02' });
  s.updateCategory(car, { archived: true });
  assert.equal(s.monthSummary(P, '2026-11').budget, 0);
  assert.equal(s.transactions(P, '2026-11').length, 1);
});

test('personal spaces are separate per person', () => {
  const s = freshStore();
  assert.equal(s.personalSpace().id, 'sp_personal_tosve');
  s.setSetting('currentUserId', 'u_milica');
  assert.equal(s.personalSpace().id, 'sp_personal_milica');
  const t = s.addTransaction({ spaceId: 'sp_house', categoryId: catId(s, 'sp_house', 'Travel'), kind: 'expense', amount: 100, date: '2026-11-01' });
  assert.equal(t.createdBy, 'u_milica');
});

test('edit, delete, reorder, add category', () => {
  const s = freshStore();
  const P = 'sp_personal_tosve';
  const t = s.addTransaction({ spaceId: P, categoryId: catId(s, P, 'Gas'), kind: 'expense', amount: 100, date: '2026-11-01' });
  s.updateTransaction(t.id, { amount: 250 });
  assert.equal(s.transactions(P)[0].amount, 250);
  s.deleteTransaction(t.id);
  assert.equal(s.transactions(P).length, 0);
  const first = s.categories(P).filter((c) => c.kind === 'expense');
  s.moveCategory(first[1].id, -1);
  const after = s.categories(P).filter((c) => c.kind === 'expense');
  assert.equal(after[0].id, first[1].id);
  s.moveCategory(after[0].id, -1); // already first: no change, no crash
  const pets = s.addCategory({ spaceId: P, name: 'Pets', kind: 'expense', budget: 2000 });
  assert.equal(s.categories(P).filter((c) => c.kind === 'expense').at(-1).id, pets.id);
});

test('data survives a reload and backup/restore round-trips', () => {
  const mem = new MemStorage();
  const s = new Store(mem);
  const P = 'sp_personal_tosve';
  s.addTransaction({ spaceId: P, categoryId: catId(s, P, 'Barber'), kind: 'expense', amount: 1500, date: '2026-11-01', items: [{ name: 'Cut', price: 1500 }] });
  const s2 = new Store(mem);
  assert.equal(s2.transactions(P).length, 1);
  assert.equal(s2.transactions(P)[0].items[0].name, 'Cut');
  const backup = s2.exportJSON();
  const s3 = freshStore();
  s3.importJSON(backup);
  assert.deepEqual(s3.data, s2.data);
  assert.throws(() => s3.importJSON('{"hello":1}'));
  assert.throws(() => s3.importJSON('not json'));
  assert.equal(s3.transactions(P).length, 1, 'failed import keeps old data');
});

test('corrupt saved data falls back to a fresh start instead of crashing', () => {
  const mem = new MemStorage();
  mem.setItem('budget.v1', '{broken');
  const s = new Store(mem);
  assert.equal(s.data.transactions.length, 0);
});

test('price comparison finds the latest earlier purchase and ignores later ones', () => {
  const s = freshStore();
  const P = 'sp_personal_tosve', G = catId(s, P, 'Groceries');
  s.addTransaction({ spaceId: P, categoryId: G, kind: 'expense', amount: 1, date: '2026-09-01', items: [{ name: 'MLEKO 3,5% 1L', price: 109 }] });
  s.addTransaction({ spaceId: 'sp_house', categoryId: catId(s, 'sp_house', 'Groceries'), kind: 'expense', amount: 1, date: '2026-10-01', items: [{ name: 'Mleko 3,5%  1L', price: 119 }] });
  s.addTransaction({ spaceId: P, categoryId: G, kind: 'expense', amount: 1, date: '2026-12-01', items: [{ name: 'mleko 3,5% 1l', price: 139 }] });
  const prev = s.previousPrice('Mleko 3,5% 1L', '2026-11-15');
  assert.deepEqual(prev, { date: '2026-10-01', price: 119 });
  assert.equal(s.previousPrice('Kruh', '2026-11-15'), null);
  const hist = s.itemHistory().get(normalizeItem('MLEKO 3,5% 1L'));
  assert.deepEqual(hist.entries.map((e) => e.price), [109, 119, 139]);
});

test('normalizeItem merges case, accents and punctuation differences', () => {
  assert.equal(normalizeItem('Čokolada  MILKA, 100g'), normalizeItem('cokolada milka 100g'));
  assert.notEqual(normalizeItem('Mleko 1L'), normalizeItem('Mleko 0,5L'));
});

// ---- receipt text parsing (what the reader gets back from a photo) ----
const MERCATOR = `MERCATOR d.o.o.
Dunajska cesta 107, Ljubljana
ID za DDV: SI45884595
Račun št.: 12-34-5678
MLEKO ALPSKO 3,5% 1L        1,29 C
KRUH BELI 500G              1,49 C
2 x 0,89
JOGURT NAVADNI 180G         1,78 C
BANANE
0,856 kg x 1,49 EUR/kg      1,28 C
ČOKOLADA MILKA 100G         1,59 A
Popust                     -0,30
SKUPAJ EUR                  7,13
Gotovina                   10,00
Vračilo                     2,87
DDV 9,5%  osnova 5,27       0,50
ZOI: 3a5f9c2e
EOR: 7d1b-22aa`;

test('parses a Mercator-style receipt', () => {
  assert.deepEqual(parseReceipt(MERCATOR), [
    { name: 'MLEKO ALPSKO 3,5% 1L', price: 129 },
    { name: 'KRUH BELI 500G', price: 149 },
    { name: 'JOGURT NAVADNI 180G', price: 178, qty: 2, unitPrice: 89 },
    { name: 'BANANE', price: 128, qty: 0.856, unit: 'kg', unitPrice: 149 },
    { name: 'ČOKOLADA MILKA 100G', price: 159 },
  ]);
});

const LIDL = `Lidl Slovenija d.o.o. k.d.
EUR
Jajca M 10/1           2,49 B
Maslo 250g             2,99 B
Testenine špageti      0,89 B
Paradižnik             1,15 B
  0,620 kg x 1,85 EUR/kg
Skupaj                 7,52
Kartica                7,52`;

test('parses a Lidl-style receipt with the weight line below the item', () => {
  assert.deepEqual(parseReceipt(LIDL), [
    { name: 'Jajca M 10/1', price: 249 },
    { name: 'Maslo 250g', price: 299 },
    { name: 'Testenine špageti', price: 89 },
    { name: 'Paradižnik', price: 115, qty: 0.62, unit: 'kg', unitPrice: 185 },
  ]);
});

const SPAR = `SPAR Slovenija
Kava Barcaffe 400g   € 5,49
Sir Edamec 300g      € 3,99
Pivo Laško 0,5L 4x   € 4,36
ZA PLAČILO           €13,84`;

test('parses prices written with a euro sign in front', () => {
  assert.deepEqual(parseReceipt(SPAR).map((i) => [i.name, i.price]), [
    ['Kava Barcaffe 400g', 549], ['Sir Edamec 300g', 399], ['Pivo Laško 0,5L 4x', 436],
  ]);
});

test('OCR noise: colons, stray marks, spaces in prices; dates and times are not items', () => {
  const t = `25.11.2026 10:15
MLEKO 1L 1:29 C
JABOLKA 2:15:C
Kava 400g € 5, 49
Sir 300g e 3,99
KRUH 5006 1,49 C`;
  assert.deepEqual(parseReceipt(t), [
    { name: 'MLEKO 1L', price: 129 }, { name: 'JABOLKA', price: 215 }, { name: 'Kava 400g', price: 549 },
    { name: 'Sir 300g', price: 399 }, { name: 'KRUH 500G', price: 149 },
  ]);
});

import { findTotal } from '../receipt.js';
test('finds the printed total (with discount) and ignores tax lines', () => {
  assert.equal(findTotal(MERCATOR), 713);
  assert.equal(findTotal(SPAR), 1384);
  assert.equal(findTotal('DDV skupaj 0,50\nnothing'), null);
});

test('lowercase tax letters and "g" misread as 9', () => {
  assert.deepEqual(parseReceipt('Jogurt Ego 150g 0,69 c\nCips Chio 1509 1,99 A'), [
    { name: 'Jogurt Ego 150g', price: 69 }, { name: 'Cips Chio 150g', price: 199 },
  ]);
});

import { categoryIcon, ICON_CHOICES, DEFAULT_ICON } from '../store.js';
test('category icons: default by name, a chosen icon wins, unknown names get a tag', () => {
  assert.equal(categoryIcon('Groceries'), '🛒');
  assert.equal(categoryIcon('  groceries '), '🛒');
  assert.equal(categoryIcon('Cash (ATM)'), '🏧');
  assert.equal(categoryIcon('Travel'), '✈️');
  assert.equal(categoryIcon('Pets'), DEFAULT_ICON);
  assert.equal(categoryIcon({ name: 'Groceries', icon: '' }), '🛒');
  assert.equal(categoryIcon({ name: 'Pets', icon: '🐶' }), '🐶');
  const d = createInitialData();
  for (const c of d.categories) assert.notEqual(categoryIcon(c), DEFAULT_ICON, `${c.name} has no icon`);
  assert.equal(ICON_CHOICES.length, 40);
  assert.equal(new Set(ICON_CHOICES).size, 40);
});

test('a chosen icon is kept to the database limit and saved with the category', () => {
  const s = new Store(null);
  const c = s.addCategory({ spaceId: s.houseSpace().id, name: 'Pets', kind: 'expense', icon: '🐶' });
  assert.equal(s.category(c.id).icon, '🐶');
  s.updateCategory(c.id, { icon: 'x'.repeat(40) });
  assert.ok(s.category(c.id).icon.length <= 16);
});

// ---- quantities: price tracking compares the price of one piece / one kilo ----
test('quantity and weight lines give the price of one piece or one kilo', () => {
  const items = parseReceipt(`JOGURT NAVADNI 180G
  2 x 0,59                 1,18 C
BANANE
  1,020 kg x 1,47          1,50 C
PIŠČANČJE PRSI
  0,612 kg x 10,07         6,16 C
SKUPAJ                     8,84`);
  assert.deepEqual(items, [
    { name: 'JOGURT NAVADNI 180G', price: 118, qty: 2, unitPrice: 59 },
    { name: 'BANANE', price: 150, qty: 1.02, unit: 'kg', unitPrice: 147 },
    { name: 'PIŠČANČJE PRSI', price: 616, qty: 0.612, unit: 'kg', unitPrice: 1007 },
  ]);
  assert.deepEqual(items.map(pricePerUnit), [59, 147, 1007]);
});

test('a quantity line that does not add up is left out of the price history until it is fixed', () => {
  const [it] = parseReceipt('BANANE\n 0,856 kg x 7,49      1,28 C');
  assert.deepEqual(it, { name: 'BANANE', price: 128, qty: 0.856, unit: 'kg', unitPrice: 749 });
  assert.equal(pricePerUnit(it), null); // 0,856 × 7,49 is not 1,28: something is misread
  const s = freshStore();
  const P = 'sp_personal_tosve', G = catId(s, P, 'Groceries');
  s.addTransaction({ spaceId: P, categoryId: G, kind: 'expense', amount: 1, date: '2026-06-06', items: [it, { name: 'Kruh', price: 149 }] });
  assert.equal(s.itemHistory().get('banane'), undefined);
  assert.equal(s.previousPrice('BANANE', '2026-12-01'), null);
  // The total fixed by hand so it adds up again (6,41): back in the history, per kilo.
  s.updateTransaction(s.data.transactions[0].id, { items: [{ ...it, price: 641 }] });
  assert.deepEqual(s.itemHistory().get('banane').entries.map((e) => e.price), [749]);
  // A quantity read from the wrong line (butter with the apples' weight) stays out too.
  assert.equal(pricePerUnit({ name: 'MASLO', price: 294, qty: 0.665, unit: 'kg', unitPrice: 179 }), null);
});

test('a small l read as 1 in volumes is put back', () => {
  const names = parseReceipt('Mleko pilos 3,5% 11   0,99 C\nRadenska 1,51   0,99 C\nOljčno olje 0,751  9,07 C\nOlje vita d\'or 11  1,94 C\nMASLO 1509   2,49 C').map((i) => i.name);
  assert.deepEqual(names, ['Mleko pilos 3,5% 1l', 'Radenska 1,5l', 'Oljčno olje 0,75l', 'Olje vita d\'or 1l', 'MASLO 150G']);
});

test('price history and comparison use the price per piece / per kilo', () => {
  const s = freshStore();
  const P = 'sp_personal_tosve', G = catId(s, P, 'Groceries');
  s.addTransaction({ spaceId: P, categoryId: G, kind: 'expense', amount: 1, date: '2026-06-06', items: [{ name: 'BANANE', price: 72, qty: 0.483, unit: 'kg', unitPrice: 149 }, { name: 'Jogurt', price: 59 }] });
  s.addTransaction({ spaceId: P, categoryId: G, kind: 'expense', amount: 1, date: '2026-11-21', items: [{ name: 'Banane', price: 160, qty: 1.24, unit: 'kg', unitPrice: 129 }, { name: 'JOGURT', price: 138, qty: 2, unitPrice: 69 }] });
  const h = s.itemHistory();
  assert.deepEqual(h.get('banane').entries.map((e) => [e.price, e.unit]), [[149, 'kg'], [129, 'kg']]);
  assert.deepEqual(h.get('jogurt').entries.map((e) => e.price), [59, 69]);
  assert.deepEqual(s.previousPrice('banane', '2026-12-01'), { date: '2026-11-21', price: 129, unit: 'kg' });
  // Stored as given (line total kept, so the bill still adds up).
  assert.equal(s.data.transactions.at(-1).items[0].price, 160);
});

test('bad quantities are dropped instead of spoiling the price history', () => {
  assert.deepEqual(cleanItem({ name: 'a', price: 100, qty: 0 }), { name: 'a', price: 100 });
  assert.deepEqual(cleanItem({ name: 'a', price: 100, qty: 'x', unit: 'kg' }), { name: 'a', price: 100 });
  assert.deepEqual(cleanItem({ name: 'a', price: 100, qty: 1, unit: 'kg' }), { name: 'a', price: 100 });
  assert.deepEqual(cleanItem({ name: 'a', price: 100, qty: 2, unit: 'lb', unitPrice: 50 }), { name: 'a', price: 100, qty: 2, unitPrice: 50 });
  // A price of one that doesn't add up is kept (the line is left out of the history, see above).
  assert.deepEqual(cleanItem({ name: 'a', price: 120, qty: 2, unitPrice: 50 }), { name: 'a', price: 120, qty: 2, unitPrice: 50 });
  assert.deepEqual(cleanItem({ name: 'a', price: 120, qty: 2, unitPrice: -5 }), { name: 'a', price: 120, qty: 2 });
  assert.equal(pricePerUnit({ price: 120, qty: 2 }), 60); // no printed price of one: worked out
});

test('quantities survive the trip through the cloud', () => {
  const t = rowToTx({ id: 't', space_id: 's', category_id: 'c', kind: 'expense', amount: 150, date: '2026-11-21', items: [{ name: 'BANANE', price: 150, qty: 1.02, unit: 'kg', unitPrice: 147 }, { name: 'MLEKO', price: 119 }], created_at: '2026-11-21T10:00:00Z', updated_at: '2026-11-21T10:00:00Z' });
  assert.deepEqual(t.items, [{ name: 'BANANE', price: 150, qty: 1.02, unit: 'kg', unitPrice: 147 }, { name: 'MLEKO', price: 119 }]);
});

// ---- shops ----
test('the shop is read from the top of the receipt', () => {
  assert.equal(findStore(MERCATOR), 'Mercator');
  assert.equal(findStore(LIDL), 'Lidl');
  assert.equal(findStore('ENGROTUS d.o.o.\nSupermarket Tus Bezigrad'), 'Tuš');
  assert.equal(findStore('INTERSPAR Vič\nKRUH 1,49'), 'Spar');
  assert.equal(findStore('HOFER trgovina d.o.o.'), 'Hofer');
  assert.equal(findStore('MERCAT0R d.o.o.'), 'Mercator'); // 0 read for O
  // The name at the top wins over a product lower down.
  assert.equal(findStore('Eurospin Slovenija\nA\nB\nC\nD\nE\nSPAR jogurt  0,59'), 'Eurospin');
  assert.equal(findStore('Trgovina Kos\nMLEKO 1,19'), null);
  assert.equal(findStore('Sparkling water 0,99'), null);
  // Š and other letters count as letters: "TUŠ" is found, "tuševa" (part of a word) is not.
  assert.equal(findStore('TUŠ d.o.o.'), 'Tuš');
  assert.equal(findStore('Engrotuš d.o.o., Celje'), 'Tuš');
  assert.equal(findStore('MÜLLER Ljubljana'), 'Müller');
  assert.equal(findStore('Trgovina tuševa 3'), null);
});

test('the shop is kept on an entry, and prices are compared at the same shop', () => {
  const s = freshStore();
  const P = 'sp_personal_tosve', G = catId(s, P, 'Groceries');
  const add = (date, store, price) => s.addTransaction({ spaceId: P, categoryId: G, kind: 'expense', amount: price, date, store, items: [{ name: 'MLEKO 1L', price }] });
  add('2026-06-06', 'Mercator', 119);
  add('2026-06-13', '  Lidl ', 99);
  add('2026-11-14', 'Mercator', 129);
  const t = add('2026-11-21', 'Lidl', 109);
  assert.equal(s.data.transactions[1].store, 'Lidl', 'trimmed');
  assert.equal(add('2026-11-22', '   ', 1).store, undefined, 'no empty shop saved');
  s.deleteTransaction(s.data.transactions.at(-1).id);
  // Per shop: Lidl 0,99 → 1,09 (+10.1%), not Mercator 1,19 → Lidl 1,09.
  const g = s.itemHistory().get('mleko 1l');
  assert.deepEqual(storeTrend(g.entries).store, 'Lidl');
  assert.equal(storeTrend(g.entries).change, 10.1);
  assert.equal(storeTrend(g.entries, 'Mercator').change, 8.4);
  assert.equal(storeTrend(g.entries, 'mercator').entries.length, 2, 'shop names match like item names');
  // "was ..." on the entry screen: the same shop first, any shop when never bought there.
  assert.deepEqual(s.previousPrice('Mleko 1L', '2026-11-20', null, 'Mercator'), { date: '2026-11-14', price: 129, store: 'Mercator' });
  assert.deepEqual(s.previousPrice('Mleko 1L', '2026-11-20', null, 'Lidl'), { date: '2026-06-13', price: 99, store: 'Lidl' });
  assert.deepEqual(s.previousPrice('Mleko 1L', '2026-11-20', null, 'Spar'), { date: '2026-11-14', price: 129, store: 'Mercator' });
  s.updateTransaction(t.id, { store: 'Hofer' });
  assert.equal(s.data.transactions.find((x) => x.id === t.id).store, 'Hofer');
  // A purchase without a shop (typed by hand, or from before shops were kept) counts for every
  // shop, so old history still shows a change.
  const old = [{ date: '2026-05-01', price: 100, store: '' }, { date: '2026-06-01', price: 110, store: 'Spar' }, { date: '2026-07-01', price: 90, store: 'Lidl' }];
  assert.equal(storeTrend(old).change, -10);
  assert.equal(storeTrend(old, 'Spar').change, 10);
  assert.equal(storeTrend([{ price: 100, store: '' }, { price: 120, store: 'Spar' }, { price: 125, store: '' }]).change, 25, 'no shop: every purchase');
});
