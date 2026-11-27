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
    const shop = await p.inputValue('#shop');
    if (SHOTS && r.week === 25) await p.screenshot({ path: `${SHOTS}/web-receipt-week25.png`, fullPage: true });
    const got = items.map((i) => ({ name: i.name, price: cents(i.price) }));
    const fixes = await correctLikeAPerson(r, got);
    if (SHOTS && fixes.length && !fs.existsSync(`${SHOTS}/web-receipt-warning.png`) && /add up/.test(status)) {
      await p.locator('#ocrStatus').scrollIntoViewIfNeeded();
      await p.screenshot({ path: `${SHOTS}/web-receipt-warning.png` });
    }
    const realShop = r.store === 'Tus' ? 'Tuš' : r.store;
    if (shop !== realShop) await p.fill('#shop', realShop); // a person would fix a wrong shop too
    if (cents(amount) !== r.total) await p.fill('#amount', String(r.total / 100).replace('.', ','));
    await p.click('#saveTx2');
    await p.waitForFunction(() => !document.querySelector('#sheet').open);
    read.push({ r, status, shop, amount: cents(amount), items: got, fixes });
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
    // A person first finds the line by its name, then by its price, and only then takes a
    // line that is left over.
    const pick = new Map();
    for (const test of [(y, e) => norm(y.name) === norm(e.name), (y, e) => y.price === e.price, () => true]) {
      for (const e of todo) {
        if (pick.has(e)) continue;
        const x = rows.find((y) => !y.done && test(y, e));
        if (x) { x.done = true; pick.set(e, x); }
      }
    }
    for (const e of todo) {
      const x = pick.get(e);
      if (!x) { later.push(e); continue; }
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

  const shopName = (st) => (st === 'Tus' ? 'Tuš' : st);
  const shopsRight = read.filter((x) => x.shop === shopName(x.r.store)).length;
  check(`shop read from the receipt: ${shopsRight}/${read.length}`, shopsRight === read.length,
    read.filter((x) => x.shop !== shopName(x.r.store)).map((x) => `${x.r.file}: "${x.shop}" not ${shopName(x.r.store)}`).join('; '));

  // 2. Every price in the history must be the real price of one piece / one kilo that day, at
  // that shop. A line whose quantity doesn't add up is left out (counted) rather than shown wrong.
  const truth = new Map(); // item -> date -> line
  for (const r of expected.receipts) for (const it of r.items) {
    const k = norm(it.name);
    if (!truth.has(k)) truth.set(k, { key: it.key, byDate: new Map() });
    truth.get(k).byDate.set(r.date, { ...it, date: r.date, store: shopName(r.store) });
  }
  const history = await p.evaluate(async () => {
    const m = await import('./store.js');
    const s = new m.Store(localStorage);
    return [...s.itemHistory().values()].map((g) => ({ key: g.key, name: g.name, entries: g.entries.map(({ date, price, unit, store }) => ({ date, price, unit, store })), trend: m.storeTrend(g.entries) }));
  });
  check(`history has ${truth.size} items`, history.length === truth.size, `has ${history.length}`);
  let wrong = 0, skipped = 0;
  const want = (e) => (e.fixedByHand === 'added' ? e.price : e.unitPrice);
  for (const [k, { byDate }] of truth) {
    const g = history.find((h) => h.key === k);
    if (!g) { check(`${k} in the history`, false); continue; }
    for (const e of g.entries) {
      const t = byDate.get(e.date);
      const tol = t?.fixedByHand ? 1 : 0;
      if (!t || Math.abs(e.price - want(t)) > tol || e.store !== t.store || (e.unit === 'kg') !== (t.unit === 'kg' && t.fixedByHand !== 'added')) {
        wrong++; out.push(`    WRONG ${k} ${e.date}: ${e.price} ${e.unit || ''} at ${e.store}, real ${t ? `${t.unitPrice} at ${t.store}` : 'not bought'}`);
      }
    }
    skipped += byDate.size - g.entries.length;
  }
  check('every price in the history is the real one for that day and shop', wrong === 0, `${wrong} wrong`);
  out.push(`    ${skipped} purchases left out because their quantity line did not add up`);

  // 3. Prices screen: newest price, and the change since the first purchase at the same shop.
  await p.click('[data-tab=prices]');
  await p.waitForTimeout(2500); // let the "Added" message fade before screenshots
  const rowsOf = () => p.$$eval('.price-row', (rs) => rs.map((x) => ({
    name: x.querySelector('.tx-cat').textContent, price: x.querySelector('.tx-amt').textContent,
    badge: x.querySelector('.badge')?.textContent || '', meta: x.querySelector('.tx-meta').textContent })));
  const rows = await rowsOf();
  fs.writeFileSync(path.join(SHOTS || '/tmp', 'web-prices.json'), JSON.stringify(rows, null, 1));
  check(`Prices shows ${truth.size} items`, rows.length === truth.size, `shows ${rows.length}`);
  const badgeOf = (c) => (c === null ? 'new' : c === 0 ? 'same' : `${c > 0 ? '▲ +' : '▼ '}${c}%`);
  const report = [];
  for (const [k, { key, byDate }] of truth) {
    const row = rows.find((x) => norm(x.name) === k);
    const g = history.find((h) => h.key === k);
    if (!row || !g) continue;
    // The same change worked out from the real prices at the shop of the newest purchase.
    const real = [...byDate.values()].filter((e) => e.store === g.trend.store && g.entries.some((x) => x.date === e.date));
    const rc = real.length > 1 ? Math.round(((want(real.at(-1)) - want(real[0])) / want(real[0])) * 1000) / 10 : null;
    const fuzzy = real.some((e) => e.fixedByHand);
    const shown = g.entries.length > 1 ? row.badge : '';
    report.push({ item: row.name, trend: expected.trends[key], shop: g.trend.store, times: real.length, shown: row.badge, real: badgeOf(rc), price: row.price });
    const ok = g.entries.length === 1 ? shown === '' : (fuzzy && rc !== null && g.trend.change !== null ? Math.abs(g.trend.change - rc) <= 0.3 && shown === badgeOf(g.trend.change) : shown === badgeOf(rc));
    check(`${row.name} at ${g.trend.store}: ${row.price}, ${row.badge || '(bought once)'}`, ok && row.meta.startsWith(`${g.trend.store} · `), `real change ${badgeOf(rc)}, meta "${row.meta}"`);
  }
  console.table(report);
  // Picking a shop shows only what was bought there.
  await p.click('[data-shop="Lidl"]');
  const lidl = await rowsOf();
  const lidlItems = [...truth.entries()].filter(([, v]) => [...v.byDate.values()].some((e) => e.store === 'Lidl')).length;
  check(`Lidl chip: ${lidl.length} items bought at Lidl`, lidl.length === lidlItems && lidl.every((r) => r.meta.startsWith('Lidl · ')), `${lidl.length} rows, want ${lidlItems}`);
  if (SHOTS) await p.screenshot({ path: `${SHOTS}/web-prices-lidl.png`, fullPage: true });
  await p.click('[data-shop=""]');
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
