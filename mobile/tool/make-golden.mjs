// Makes the "golden" test files that check the phone app gives exactly the same answers as the
// web app. It runs the web app's own code (store.js, receipt.js) on thousands of generated inputs
// and writes the inputs plus the web app's answers to test/fixtures/.
//
//   node tool/make-golden.mjs /path/to/budget   (from mobile/)
//
// test/golden_test.dart then runs the same inputs through the app's code and compares.
import { writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const webDir = resolve(process.argv[2] || '../budget-app');
const out = resolve(dirname(fileURLToPath(import.meta.url)), '../test/fixtures');
mkdirSync(out, { recursive: true });

// Repeatable random numbers, so the files only change when the web app's code changes.
let seed = 20261125;
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = (a) => a[Math.floor(rnd() * a.length)];
const int = (a, b) => a + Math.floor(rnd() * (b - a + 1));

// Ids made by the web app are random; make them repeatable too.
let n = 0;
if (!globalThis.crypto) globalThis.crypto = (await import('node:crypto')).webcrypto;
globalThis.crypto.randomUUID = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;

const store = await import(pathToFileURL(`${webDir}/store.js`));
const receipt = await import(pathToFileURL(`${webDir}/receipt.js`));

// ---------- receipt text ----------
const names = ['MLEKO ALPSKO 3,5% 1L', 'KRUH BELI 500G', 'Jajca M 10/1', 'Maslo 250g', 'Testenine špageti', 'Paradižnik',
  'ČOKOLADA MILKA 100G', 'Kava Barcaffe 400g', 'Sir Edamec 300g', 'Pivo Laško 0,5L 4x', 'JOGURT NAVADNI 180G', 'BANANE',
  'Cips Chio 1509', 'KRUH 5006', 'Šunka Pivka 100g', 'Žito pecivo', 'Ćevapčići 400g', 'Đuveč', 'jabolka', 'Voda Radenska 1,5L',
  'Toaletni papir 10/1', 'DETERGENT ARIEL 2,2kg', 'a', 'X', '12', 'Müsli Crunchy', 'Ægir', 'Ołówek', 'Ser Gouda', 'Paprika rdeča',
  'Mleko 3,5%  1L', 'COCA COLA 0,5 L', 'Pizza*Margherita', 'Čaj | Twinings', 'Med #cvetlični', '"Dobro" jutro', 'Sol~morska'];
const skipLines = ['SKUPAJ EUR', 'ZA PLAČILO', 'DDV 9,5% osnova 5,27', 'Gotovina', 'Vračilo', 'ZOI: 3a5f9c2e', 'EOR: 7d1b-22aa',
  'Kartica', 'TOTAL', 'Popust', 'Račun št.: 12-34-5678', 'Blagajnik: Ana', 'Hvala za nakup', 'UKUPNO', 'PDV 22%', 'Datum 25.11.2026',
  'Total EUR', 'Summe', 'Visa', 'Tel 01 234 56 78', 'www.mercator.si', 'Za uplatu', 'Davčna št'];
const qty = () => pick([`${int(1, 6)} x ${price()}`, `${int(0, 2)},${int(100, 999)} kg x ${price()} EUR/kg`, `${int(1, 4)} kom x ${price()}`, `${int(1, 3)}*${price()}`]);
const price = () => {
  const e = int(0, rnd() < 0.1 ? 2500 : 30), c = String(int(0, 99)).padStart(2, '0');
  return pick([`${e},${c}`, `${e}.${c}`, `${e}:${c}`, `${e};${c}`, `${e}, ${c}`, e >= 1000 ? `${Math.floor(e / 1000)}.${String(e % 1000).padStart(3, '0')},${c}` : `${e},${c}`, `-${e},${c}`]);
};
const tail = () => pick(['', '', ' C', ' A', ' B', ' c', ' a', ' €', '.€', '/:C', ':C', ' EUR', ' E', ' Č', ' ž', ' DD', ' XYZW', '|', ' *']);
const pad = () => pick([' ', '  ', '      ', '\t', '   ', ' ']);
const pre = () => pick(['', '', '', ' € ', ' e ', ' E ', ' EUR ', '€']);
function line() {
  const r = rnd();
  if (r < 0.55) return `${pick(names)}${pad()}${pre()}${price()}${tail()}`;
  if (r < 0.65) return pick(names);
  if (r < 0.75) return qty() + (rnd() < 0.5 ? `${pad()}${price()}${tail()}` : '');
  if (r < 0.88) return `${pick(skipLines)}${pad()}${rnd() < 0.8 ? price() : ''}${tail()}`;
  if (r < 0.92) return `${int(1, 28)}.${int(1, 12)}.2026 ${int(0, 23)}:${String(int(0, 59)).padStart(2, '0')}`;
  if (r < 0.96) return '';
  return pick(['---', '***', '12345', `${int(1, 99)} ${price()}`, `  ${pick(names).toLowerCase()} ${price()}`]);
}
const receipts = [];
for (let i = 0; i < 4000; i++) {
  const text = Array.from({ length: int(1, 18) }, line).join(rnd() < 0.2 ? '\r\n' : '\n');
  receipts.push({ text, items: receipt.parseReceipt(text), total: receipt.findTotal(text) });
}
writeFileSync(`${out}/receipts.json`, JSON.stringify(receipts));

// ---------- money typing ----------
const chars = "0123456789,.,.000 -+abceErRuU€'\u00a0\u202fe";
const money = [];
for (let i = 0; i < 4000; i++) {
  const s = Array.from({ length: int(0, 9) }, () => pick(chars)).join('');
  const v = store.toCents(s);
  money.push({ input: s, cents: Number.isFinite(v) ? v : null });
}
for (const s of ['12', '12,5', '12.50', '0,99', '1.299,00', '1,299.00', ' 7 ', '', 'abc', '0.1', '0.2', '1,15', '2,675', '-0,30', '5.', ',5', '.', '1.005', '19,99', '0,005',
  '1.000', '1.000.000', '12.500,50', '0.500', '00.500', '.500', '1.0000', '1e5', '1E5', '0x10', '+5', 'Infinity', 'NaN',
  '12,50 €', '€12,50', '12,50 EUR', '12,50eur', 'eur12', '€ 1.000', "1'000", '1\u00a0000,50', '1\u202f000', '12,50 €€',
  '9999999,99', '10000000', '1,2,3', '1..2', ',', '.,', '0', '0,00']) {
  const v = store.toCents(s);
  money.push({ input: s, cents: Number.isFinite(v) ? v : null });
}
writeFileSync(`${out}/money.json`, JSON.stringify(money));

// ---------- item names ----------
const nameChars = 'aAčČšŠžŽćĆđĐäöüßéÉ0123456789 ,.%-_/()"\'#ﬁ①Ⅻ½';
const normalized = [];
for (const nm of names) normalized.push({ input: nm, key: store.normalizeItem(nm) });
for (let i = 0; i < 3000; i++) {
  const s = Array.from({ length: int(0, 14) }, () => pick([...nameChars])).join('');
  normalized.push({ input: s, key: store.normalizeItem(s) });
}
writeFileSync(`${out}/normalize.json`, JSON.stringify(normalized));

// ---------- a full data file made by the web app, and its answers ----------
class Mem { constructor() { this.m = {}; } getItem(k) { return this.m[k] ?? null; } setItem(k, v) { this.m[k] = String(v); } }
const s = new store.Store(new Mem());
const spaces = s.data.spaces.map((x) => x.id);
for (const c of s.data.categories) if (c.kind === 'expense' && rnd() < 0.6) s.updateCategory(c.id, { budget: int(1, 400) * 100 });
const someCats = s.data.categories.filter((c) => rnd() < 0.15);
for (const c of someCats) s.updateCategory(c.id, { archived: true });
const months = ['2026-09', '2026-10', '2026-11', '2026-12'];
for (let i = 0; i < 600; i++) {
  const sp = pick(spaces);
  const cats = s.data.categories.filter((c) => c.spaceId === sp);
  const c = pick(cats);
  s.setSetting('currentUserId', pick(['u_tosve', 'u_milica']));
  const items = rnd() < 0.3 ? Array.from({ length: int(1, 5) }, () => ({ name: pick(names), price: int(10, 2000) })) : undefined;
  s.addTransaction({ spaceId: sp, categoryId: c.id, kind: c.kind, amount: int(1, 100000), date: `${pick(months)}-${String(int(1, 28)).padStart(2, '0')}`, note: rnd() < 0.2 ? pick(names) : '', items, receiptId: items && rnd() < 0.5 ? `rc_${i}` : undefined });
}
s.setSetting('currentUserId', 'u_tosve');
const summaries = [];
for (const sp of spaces) for (const m of months) {
  const x = s.monthSummary(sp, m);
  summaries.push({ spaceId: sp, month: m, income: x.income, spent: x.spent, budget: x.budget, count: x.count, byCategory: Object.fromEntries(x.byCategory) });
}
const entryOrder = spaces.map((sp) => ({ spaceId: sp, month: '2026-11', ids: s.transactions(sp, '2026-11').map((t) => t.id) }));
const history = [...s.itemHistory().values()].map((g) => ({ key: g.key, name: g.name, prices: g.entries.map((e) => e.price), txIds: g.entries.map((e) => e.txId) }));
const previous = [];
for (let i = 0; i < 300; i++) {
  const nm = pick(names), d = `${pick(months)}-${String(int(1, 28)).padStart(2, '0')}`;
  const ex = rnd() < 0.3 ? pick(s.data.transactions).id : undefined;
  previous.push({ name: nm, before: d, excluding: ex ?? null, result: s.previousPrice(nm, d, ex) });
}
writeFileSync(`${out}/webdata.json`, s.exportJSON());
writeFileSync(`${out}/webanswers.json`, JSON.stringify({ summaries, entryOrder, history, previous }));
writeFileSync(`${out}/webinitial.json`, JSON.stringify(store.createInitialData()));
console.log(`Wrote golden files to ${out}: ${receipts.length} receipts, ${money.length} money inputs, ${normalized.length} names, ${s.data.transactions.length} entries.`);
