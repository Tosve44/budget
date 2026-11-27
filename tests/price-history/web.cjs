// Six months of weekly grocery receipts, read by the web app's real receipt reader, then
// checks the Prices screen shows each item's price trend.
// Run: python3 tests/price-history/make-receipts.py; python3 -m http.server 8123 &
//      node tests/price-history/web.cjs   (SHOTS=dir to save screenshots)
// Everything stays in the browser's local storage (no sign-in, nothing is sent anywhere).
const { chromium, devices } = require('playwright');
const path = require('path');
const fs = require('fs');
const URL = process.env.APP_URL || 'http://localhost:8123/';
const SHOTS = process.env.SHOTS || null;
const expected = JSON.parse(fs.readFileSync(path.join(__dirname, 'expected.json'), 'utf8'));
const cents = (s) => Math.round(Number(String(s).replace(/[^\d,.-]/g, '').replace(/\.(?=\d{3}\b)/g, '').replace(',', '.')) * 100);
const norm = (s) => String(s).toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^\p{L}\p{N}%]+/gu, ' ').trim();

let pass = 0, fail = 0;
const out = [];
function check(name, ok, detail = '') { ok ? pass++ : fail++; out.push(`${ok ? '✓' : '✗'} ${name}${ok || !detail ? '' : `\n    ${detail}`}`); }

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ...devices['iPhone 13'], locale: 'sl-SI', timezoneId: 'Europe/Ljubljana', colorScheme: 'light' });
  const p = await ctx.newPage();
  p.setDefaultTimeout(10000);
  const errors = [];
  p.on('pageerror', (e) => errors.push(e.message));
  await p.goto(URL);

  const read = []; // what the app read from each receipt
  for (const r of expected.receipts) {
    await p.click('#addBtn');
    await p.fill('#date', r.date);
    await p.setInputFiles('#photoInput', path.join(__dirname, 'receipts', r.file));
    await p.waitForFunction(() => /Found|Could not/.test(document.querySelector('#ocrStatus')?.textContent || ''), null, { timeout: 180000 });
    const status = await p.textContent('#ocrStatus');
    const items = await p.$$eval('.item-row', (rs) => rs.map((x) => ({ name: x.querySelector('.item-name').value, price: x.querySelector('.item-price').value })));
    const amount = await p.inputValue('#amount');
    if (SHOTS && r.week === 25) await p.screenshot({ path: `${SHOTS}/web-receipt-week25.png`, fullPage: true });
    const got = items.map((i) => ({ name: i.name, price: cents(i.price) }));
    const fixes = await correctLikeAPerson(r, got);
    if (SHOTS && fixes.length && !fs.existsSync(`${SHOTS}/web-receipt-warning.png`) && /add up/.test(status)) {
      await p.locator('#ocrStatus').scrollIntoViewIfNeeded();
      await p.screenshot({ path: `${SHOTS}/web-receipt-warning.png` });
    }
    if (cents(amount) !== r.total) await p.fill('#amount', String(r.total / 100).replace('.', ','));
    await p.click('#saveTx2');
    await p.waitForFunction(() => !document.querySelector('#sheet').open);
    read.push({ r, status, amount: cents(amount), items: got, fixes });
    process.stdout.write(`${r.file} ${r.store}: ${items.length}/${r.items.length} items, total ${amount}${fixes.length ? `, fixed by hand: ${fixes.join('; ')}` : ''}\n`);
  }

  // What a person does after "Check names and prices": fix misread names and prices, remove
  // lines that aren't items, add lines the reader missed. Returns what was changed.
  async function correctLikeAPerson(r, got) {
    const fixes = [];
    const rows = got.map((g, i) => ({ ...g, i, done: false }));
    const todo = [];
    for (const e of r.items) {
      const ok = rows.find((x) => !x.done && norm(x.name) === norm(e.name) && x.price === e.price);
      if (ok) ok.done = true; else todo.push(e);
    }
    const fill = async (i, f, v) => p.fill(`input[data-i="${i}"][data-f=${f}]`, v);
    const later = [];
    for (const e of todo) {
      const x = rows.find((y) => !y.done && norm(y.name) === norm(e.name)) || rows.find((y) => !y.done && y.price === e.price) || rows.find((y) => !y.done);
      if (!x) { later.push(e); continue; }
      x.done = true;
      if (norm(x.name) !== norm(e.name)) await fill(x.i, 'name', e.name);
      if (x.price !== e.price) await fill(x.i, 'price', String(e.price / 100).replace('.', ','));
      fixes.push(`"${x.name}" ${x.price / 100} → "${e.name}" ${e.price / 100}`);
      e.fixedByHand = x.price !== e.price ? 'price' : 'name';
    }
    for (const x of rows.filter((y) => !y.done).reverse()) { await p.click(`[data-rm="${x.i}"]`); fixes.push(`removed "${x.name}" ${x.price / 100}`); }
    for (const e of later) {
      await p.click('#addItem');
      const i = (await p.locator('.item-row').count()) - 1;
      await fill(i, 'name', e.name);
      await fill(i, 'price', String(e.price / 100).replace('.', ','));
      fixes.push(`added "${e.name}" ${e.price / 100}`);
      e.fixedByHand = 'added';
    }
    return fixes;
  }
  fs.writeFileSync(path.join(SHOTS || '/tmp', 'web-read.json'), JSON.stringify(read, null, 1));

  // 1. Every receipt: the right number of items, the right prices and total.
  let lines = 0, right = 0;
  for (const { r, amount, items } of read) {
    if (amount !== r.total) out.push(`    ${r.file}: total read as ${amount / 100}, printed ${r.total / 100}`);
    const left = items.slice();
    for (const e of r.items) {
      lines++;
      const i = left.findIndex((x) => norm(x.name) === norm(e.name) && x.price === e.price);
      if (i >= 0) { right++; left.splice(i, 1); } else out.push(`    ${r.file}: missing "${e.name}" ${e.price / 100}`);
    }
    for (const x of left) out.push(`    ${r.file}: extra "${x.name}" ${x.price / 100}`);
  }
  const pctRead = Math.round((right / lines) * 1000) / 10;
  const totalsRight = read.filter((x) => x.amount === x.r.total).length;
  check(`receipt total read right on ${totalsRight}/${read.length} receipts (want ≥ 90%)`, totalsRight / read.length >= 0.9);
  check(`receipt reader got ${right}/${lines} lines exactly right (${pctRead}%, want ≥ 90%)`, pctRead >= 90);
  const misread = read.filter((x) => x.fixes.some((f) => / → /.test(f) && !/^"[^"]*" ([\d.]+) → "[^"]*" \1$/.test(f)));
  const warned = misread.filter((x) => /add up/.test(x.status));
  out.push(`    ${misread.length} receipts had a misread price; the "doesn't add up" warning showed on ${warned.length}`);
  check('no warning on receipts that were read right', read.filter((x) => !x.fixes.length && /add up/.test(x.status) && !x.r.discount).length === 0);

  // 2. Prices screen: one row per item name, newest price and change since the first purchase.
  await p.click('[data-tab=prices]');
  await p.waitForFunction(() => !document.querySelector('.toast.show, #toast:not([hidden])'), null, { timeout: 5000 }).catch(() => {});
  await p.waitForTimeout(2500); // let the "Added" message fade before screenshots
  const rows = await p.$$eval('.price-row', (rs) => rs.map((x) => ({
    name: x.querySelector('.tx-cat').textContent, price: x.querySelector('.tx-amt').textContent,
    badge: x.querySelector('.badge')?.textContent || '', meta: x.querySelector('.tx-meta').textContent })));
  fs.writeFileSync(path.join(SHOTS || '/tmp', 'web-prices.json'), JSON.stringify(rows, null, 1));
  const byName = new Map();
  for (const r of expected.receipts) for (const it of r.items) {
    const k = norm(it.name);
    if (!byName.has(k)) byName.set(k, { key: it.key, list: [] });
    byName.get(k).list.push({ date: r.date, ...it });
  }
  check(`Prices shows ${byName.size} items`, rows.length === byName.size, `shows ${rows.length}`);
  const report = [];
  for (const [k, { key, list }] of byName) {
    const row = rows.find((x) => norm(x.name) === k);
    if (!row) { check(`${k} on Prices`, false, 'missing'); continue; }
    const first = list[0], last = list.at(-1);
    const wantUnitPct = list.length > 1 ? Math.round(((last.unitPrice - first.unitPrice) / first.unitPrice) * 1000) / 10 : null;
    const shownPct = /new/.test(row.badge) ? null : /same/.test(row.badge) ? 0 : Number(row.badge.replace(/[^\d.-]/g, '')) * (/▼/.test(row.badge) ? 1 : 1);
    report.push({ item: row.name, trend: expected.trends[key], times: list.length, first: first.unitPrice / 100, last: last.unitPrice / 100, wantUnitPct, shown: row.badge, shownPrice: row.price });
    // A line added by hand has no quantity, so by-weight items typed in by hand count as the line
    // total; a corrected price is divided by the quantity (can be a cent off the printed price).
    const want = (e) => (e.fixedByHand === 'added' ? e.price : e.unitPrice);
    const near = (a, b, tol) => a === b || (a !== null && b !== null && Math.abs(a - b) <= tol);
    const fuzzy = first.fixedByHand || last.fixedByHand;
    const wp = list.length > 1 ? Math.round(((want(last) - want(first)) / want(first)) * 1000) / 10 : null;
    check(`${row.name}: latest ${row.price}, ${row.badge || '(bought once)'}`, near(cents(row.price), want(last), fuzzy ? 1 : 0) && near(shownPct, wp, fuzzy ? 0.3 : 0) && (last.unit === 'kg') === row.price.includes('/kg'),
      `want ${want(last) / 100}${last.unit === 'kg' ? '/kg' : ''} ${wp}% (per ${last.unit === 'kg' ? 'kg' : 'piece'} ${first.unitPrice / 100} → ${last.unitPrice / 100})`);
  }
  console.table(report);
  if (SHOTS) {
    await p.screenshot({ path: `${SHOTS}/web-prices.png`, fullPage: true });
    for (const q of ['kava', 'banane', 'jogurt', 'maslo']) {
      await p.fill('#priceSearch', q);
      const row = p.locator('.price-row button').first();
      await row.click();
      await p.screenshot({ path: `${SHOTS}/web-prices-${q}.png`, fullPage: true });
      await row.click();
    }
  }
  check('no page errors', errors.length === 0, errors.join('; '));
  console.log(out.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  await browser.close();
  process.exit(fail ? 1 : 0);
})();
