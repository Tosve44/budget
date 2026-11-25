// Edge cases, accessibility and large text, in iPhone-sized browsers.
// Run: python3 -m http.server 8123 & node tests/e2e-edge.cjs
// Needs axe-core installed (npm i axe-core) for the accessibility scan.
const { chromium, devices } = require('playwright');
const path = require('path');
const fs = require('fs');

const APP = process.env.APP_URL || 'http://localhost:8123/';
let pass = 0, fail = 0;
const results = [];
let mainPage = null;
async function check(name, fn) {
  // Start every check from a clean screen, even if the previous one failed half-way.
  if (mainPage) await mainPage.evaluate(() => { const d = document.querySelector('#sheet'); if (d.open) d.close(); document.querySelectorAll('.toast').forEach((t) => t.remove()); }).catch(() => {});
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n').slice(0, 3).join('\n    ')}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }
let axeSource = null;
try { axeSource = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8'); } catch {}

const SB_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
let KEY;
(async () => {
  KEY = (await (await fetch(`${SB_URL}/__test/anon-key`)).json()).key;
  const browser = await chromium.launch();
  async function phone(device = 'iPhone 13', extra = {}) {
    const ctx = await browser.newContext({ ...devices[device], locale: 'sl-SI', timezoneId: 'Europe/Ljubljana', ...extra });
    // Point the app at the local test server (never at the real project); nobody signs in here.
    await ctx.addInitScript(([u, k]) => { try { localStorage.setItem('budget.config.override', JSON.stringify({ supabaseUrl: u, supabaseAnonKey: k })); } catch {} }, [SB_URL, KEY]);
    const p = await ctx.newPage();
    p.setDefaultTimeout(8000);
    p.errors = [];
    p.on('pageerror', (e) => p.errors.push(e.message));
    await p.goto(APP);
    return { ctx, p };
  }
  const tab = (p, t) => p.click(`[data-tab=${t}]`);
  const isOpen = (p) => p.evaluate(() => document.querySelector('#sheet').open);
  const closed = (p) => p.waitForFunction(() => !document.querySelector('#sheet').open);
  const data = (p) => p.evaluate(() => JSON.parse(localStorage['budget.v1']));
  const openAdd = async (p, { amount, cat = 'Groceries', note, date }) => {
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount'); // the app focuses it right after opening
    if (amount !== undefined) await p.fill('#amount', amount);
    if (cat) await p.locator('[data-chip]', { hasText: cat }).first().click();
    if (date) await p.fill('#date', date);
    if (note !== undefined) await p.fill('#note', note);
  };
  const add = async (p, o) => { await openAdd(p, o); await p.click('#saveTx2'); await closed(p); };
  const lastTx = async (p) => (await data(p)).transactions.at(-1);
  const toastText = (p) => p.waitForSelector('.toast').then((t) => t.textContent());
  const clearToasts = (p) => p.evaluate(() => document.querySelectorAll('.toast').forEach((t) => t.remove()));
  const cancel = async (p) => { if (await isOpen(p)) { await p.click('[data-close]'); await closed(p); } };

  const { p, ctx } = await phone();
  mainPage = p;

  // ---------- amounts ----------
  await check('amounts typed the Slovenian way are read right (1.000 = one thousand, 1.234,56, 12,5)', async () => {
    for (const [typed, cents] of [['1.000', 100000], ['1.234,56', 123456], ['12,5', 1250], ['12.50', 1250], ['0,99', 99], [' 7 ', 700], ['2 500', 250000], ['1,000.50', 100050]]) {
      await add(p, { amount: typed });
      const t = await lastTx(p);
      assert(t.amount === cents, `"${typed}" saved as ${t.amount / 100} €, expected ${cents / 100} €`);
    }
  });

  await check('nonsense, zero, negative and absurdly large amounts are refused with a message', async () => {
    const before = (await data(p)).transactions.length;
    for (const typed of ['abc', '0', '-5', '', '99999999999', '1e5']) {
      await openAdd(p, { amount: typed });
      await clearToasts(p);
      await p.click('#saveTx2');
      const msg = await toastText(p);
      const open = await isOpen(p);
      await cancel(p);
      assert(open, `"${typed}" was saved (${msg})`);
      assert(/amount/i.test(msg), `"${typed}" message: ${msg}`);
    }
    assert((await data(p)).transactions.length === before, 'nothing was saved');
  });

  await check('saving without a category asks for one', async () => {
    await openAdd(p, { amount: '5', cat: null });
    await clearToasts(p);
    await p.click('#saveTx2');
    assert(/category/i.test(await toastText(p)));
    await cancel(p);
  });

  // ---------- text ----------
  await check('a very long note is cut to what the cloud accepts (500 characters)', async () => {
    await add(p, { amount: '3', note: 'x'.repeat(800) });
    const t = await lastTx(p);
    assert(t.note.length <= 500, `note saved with ${t.note.length} characters`);
  });

  await check('a very long category name is cut to what the cloud accepts (60 characters)', async () => {
    await tab(p, 'settings');
    await p.locator('[data-addcat][data-kind=expense]').first().click();
    await p.fill('#catName', 'Y'.repeat(100));
    await p.click('#saveCat2');
    await closed(p);
    const c = (await data(p)).categories.at(-1);
    assert(c.name.length <= 60, `category saved with ${c.name.length} characters`);
  });

  await check('HTML or script typed into a note, category or item is shown as plain text', async () => {
    await tab(p, 'settings');
    await p.locator('[data-addcat][data-kind=expense]').first().click();
    await p.fill('#catName', '<b>Bold</b><img src=x onerror="window.__pwned=1">');
    await p.click('#saveCat2');
    await closed(p);
    await tab(p, 'personal');
    await p.click('#addBtn');
    await p.fill('#amount', '4');
    await p.locator('[data-chip]', { hasText: '<b>Bold</b>' }).click();
    await p.fill('#note', '"><script>window.__pwned=2</script><img src=x onerror="window.__pwned=3">');
    await p.click('#addItem');
    await p.fill('.item-name', '<img src=x onerror="window.__pwned=4">');
    await p.fill('.item-price', '4');
    await p.click('#saveTx2');
    await closed(p);
    await tab(p, 'prices'); await tab(p, 'personal');
    await p.locator('.tx', { hasText: '<b>Bold</b>' }).first().locator('button').click();
    await cancel(p);
    assert(await p.evaluate(() => window.__pwned) === undefined, 'script ran');
    assert((await p.textContent('main')).includes('<b>Bold</b>'), 'name shown literally');
  });

  await check('ids from the other phone cannot break out of the page (quotes in ids)', async () => {
    await p.evaluate(() => {
      const d = JSON.parse(localStorage['budget.v1']);
      const sp = d.spaces.find((s) => s.type === 'house');
      const c = d.categories.find((x) => x.spaceId === sp.id && x.kind === 'expense');
      d.transactions.push({ id: 'tx_"><img src=x onerror="window.__pwned=5">', spaceId: sp.id, categoryId: c.id, kind: 'expense', amount: 100, date: new Date().toISOString().slice(0, 10), note: 'odd id', createdBy: 'u_milica', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
      localStorage['budget.v1'] = JSON.stringify(d);
    });
    await p.reload();
    await tab(p, 'house');
    await p.waitForTimeout(300);
    const ran = await p.evaluate(() => window.__pwned);
    if (ran !== undefined) { await p.evaluate(() => { const d = JSON.parse(localStorage['budget.v1']); d.transactions = d.transactions.filter((t) => t.note !== 'odd id'); localStorage['budget.v1'] = JSON.stringify(d); }); await p.reload(); }
    assert(ran === undefined, 'script ran from an id');
    await p.locator('.tx', { hasText: 'odd id' }).locator('button').click();
    const opened = await isOpen(p);
    await cancel(p);
    await p.evaluate(() => { const d = JSON.parse(localStorage['budget.v1']); d.transactions = d.transactions.filter((t) => t.note !== 'odd id'); localStorage['budget.v1'] = JSON.stringify(d); });
    await p.reload();
    assert(opened, 'entry with an odd id can still be opened');
  });

  // ---------- dates and months ----------
  await check('month edges: New Year\'s Eve, New Year, and 29 February land in the right month', async () => {
    await tab(p, 'personal');
    await add(p, { amount: '10', date: '2026-12-31', note: 'NYE' });
    assert((await p.textContent('#monthLabel')).includes('2026'), 'jumped to the entry month');
    assert((await p.textContent('main')).includes('NYE'));
    await p.click('#nextMonth');
    assert((await p.textContent('#monthLabel')).includes('2027'));
    assert(!(await p.textContent('main')).includes('NYE'));
    await add(p, { amount: '11', date: '2027-01-01', note: 'NewYear' });
    await p.click('#prevMonth');
    assert(!(await p.textContent('main')).includes('NewYear'), 'Jan entry not in December');
    await add(p, { amount: '12', date: '2028-02-29', note: 'Leap' });
    assert((await p.textContent('main')).includes('Leap'));
  });

  await check('changing an entry\'s date moves it to the other month', async () => {
    await p.locator('.tx', { hasText: 'Leap' }).locator('button').click();
    await p.fill('#date', '2028-03-01');
    await p.click('#saveTx2');
    await closed(p);
    assert((await p.textContent('#monthLabel')).toLowerCase().includes('2028'));
    assert((await p.textContent('main')).includes('Leap'));
    await p.click('#prevMonth');
    assert(!(await p.textContent('main')).includes('Leap'));
  });

  await check('clearing the date asks for a date', async () => {
    await openAdd(p, { amount: '5' });
    await p.fill('#date', '');
    await clearToasts(p);
    await p.click('#saveTx2');
    assert(/date/i.test(await toastText(p)));
    await cancel(p);
  });

  // ---------- double taps, hidden categories, deletes from the other phone ----------
  await check('tapping Save twice quickly saves only one entry (with a receipt photo)', async () => {
    const before = (await data(p)).transactions.length;
    await p.click('#addBtn');
    await p.setInputFiles('#photoInput', path.join(__dirname, 'spar.jpg'));
    await p.waitForFunction(() => /Found|Could not/.test(document.querySelector('#ocrStatus')?.textContent || ''), null, { timeout: 120000 });
    await p.evaluate(() => { const b = document.querySelector('#saveTx2'); b.click(); b.click(); document.querySelector('#saveTx').click(); });
    await closed(p);
    await p.waitForTimeout(500);
    const n = (await data(p)).transactions.length - before;
    assert(n === 1, `${n} entries saved`);
  });

  await check('hiding a category keeps its past entries visible but removes it from the add screen', async () => {
    await tab(p, 'personal');
    await add(p, { amount: '20', cat: 'Barber', note: 'haircut', date: new Date().toISOString().slice(0, 10) });
    await tab(p, 'settings');
    await p.locator('.set-list li', { hasText: 'Barber' }).first().locator('[data-editcat]').click();
    await p.click('#archCat');
    await closed(p);
    await tab(p, 'personal');
    assert((await p.textContent('main')).includes('haircut'), 'old entry still shown');
    await p.click('#addBtn');
    assert(await p.locator('[data-chip]', { hasText: 'Barber' }).count() === 0, 'hidden category offered');
    await cancel(p);
  });

  await check('if the other phone deletes an entry while you edit it, you are told instead of losing the edit silently', async () => {
    await tab(p, 'personal');
    await p.locator('.tx', { hasText: 'haircut' }).locator('button').click();
    await p.fill('#note', 'haircut edited');
    // Simulate the sync removing it while the sheet is open.
    await p.evaluate(async () => {
      const d = JSON.parse(localStorage['budget.v1']);
      const t = d.transactions.find((x) => x.note === 'haircut');
      window.__deletedId = t.id;
    });
    await clearToasts(p);
    await p.evaluate(() => window.__budgetStore.replaceData({ ...window.__budgetStore.data, transactions: window.__budgetStore.data.transactions.filter((t) => t.id !== window.__deletedId) }));
    await p.click('#saveTx2');
    const msg = await toastText(p);
    assert(/deleted|removed/i.test(msg), `message: ${msg}`);
    assert((await data(p)).transactions.some((t) => t.note === 'haircut edited'), 'edit kept as an entry');
  });

  // ---------- storage ----------
  await check('a broken backup file is refused and nothing is lost', async () => {
    const before = (await data(p)).transactions.length;
    await tab(p, 'settings');
    const f = path.join(require('os').tmpdir(), 'bad-backup.json');
    fs.writeFileSync(f, '{"hello": "world"}');
    await clearToasts(p);
    await p.setInputFiles('#importFile', f);
    const msg = await toastText(p);
    assert(/backup|missing|version/i.test(msg), msg);
    assert((await data(p)).transactions.length === before);
  });

  await check('when phone storage is full, you are warned instead of losing entries silently', async () => {
    const { p: q, ctx: c2 } = await phone('iPhone SE');
    await q.evaluate(() => {
      const chunk = 'x'.repeat(1024 * 1024);
      for (let i = 0; i < 200; i++) { try { localStorage.setItem('filler' + i, chunk); } catch { break; } }
      for (let n = 512 * 1024; n >= 16; n = Math.floor(n / 2)) { try { localStorage.setItem('filler_s' + n, 'x'.repeat(n)); } catch {} }
    });
    await tab(q, 'personal');
    await openAdd(q, { amount: '9', note: 'too full' });
    await q.click('#saveTx2');
    await q.waitForTimeout(400);
    const msg = await q.$$eval('.toast, [role=alert]', (els) => els.map((e) => e.textContent).join(' | '));
    const warned = /storage|full/i.test(msg);
    await c2.close();
    assert(warned, `no warning; last message: "${msg}"`);
  });

  await check('a damaged save does not wipe the data silently (a copy is kept)', async () => {
    const { p: q, ctx: c2 } = await phone('iPhone SE');
    await q.evaluate(() => { localStorage.setItem('budget.v1', '{"schemaVersion":1,"settings":{}, "users": BROKEN'); });
    await q.reload();
    const kept = await q.evaluate(() => Object.keys(localStorage).some((k) => k !== 'budget.v1' && (localStorage[k] || '').includes('BROKEN')));
    await c2.close();
    assert(kept, 'the damaged data was overwritten with no copy');
  });

  // ---------- lots of data ----------
  await check('5 years of data (6,000 entries, 1,500 receipts) stays fast and fits in storage', async () => {
    const { p: q, ctx: c2 } = await phone('iPhone SE');
    const size = await q.evaluate(() => {
      const d = JSON.parse(JSON.stringify(window.__budgetStore.data));
      const sp = d.spaces.find((s) => s.type === 'house');
      const cats = d.categories.filter((c) => c.spaceId === sp.id && c.kind === 'expense');
      const names = Array.from({ length: 400 }, (_, i) => `Izdelek št. ${i} 500g`);
      const start = Date.now() - 5 * 365 * 864e5 + 864e5;
      for (let i = 0; i < 6000; i++) {
        const date = new Date(start + (i / 6000) * 5 * 365 * 864e5).toISOString().slice(0, 10);
        const t = { id: 'tx_bulk' + i.toString(16).padStart(8, '0'), spaceId: sp.id, categoryId: cats[i % cats.length].id, kind: 'expense', amount: 1000 + i, date, note: i % 3 ? '' : 'Mercator', createdBy: 'u_tosve', createdAt: date + 'T10:00:00.000Z', updatedAt: date + 'T10:00:00.000Z' };
        if (i % 4 === 0) { t.items = Array.from({ length: 20 }, (_, k) => ({ name: names[(i + k * 7) % 400], price: 100 + ((i + k) % 500) })); t.receiptId = 'photo_' + i; }
        d.transactions.push(t);
      }
      const s = JSON.stringify(d);
      localStorage['budget.v1'] = s;
      return s.length;
    });
    const t0 = Date.now();
    await q.reload();
    await q.waitForSelector('.tabbar');
    await tab(q, 'house');
    await q.waitForSelector('.tx');
    const tHouse = Date.now() - t0;
    let t1 = Date.now();
    await tab(q, 'prices');
    await q.waitForSelector('.price-row');
    const tPrices = Date.now() - t1;
    t1 = Date.now();
    await q.fill('#priceSearch', 'izdelek 12');
    const tSearch = Date.now() - t1;
    await tab(q, 'house');
    t1 = Date.now();
    await q.click('#addBtn');
    await q.waitForSelector('#amount');
    const tSheet = Date.now() - t1;
    await c2.close();
    const mb = (size * 2 / 1024 / 1024).toFixed(1);
    results.push(`    (data ${(size / 1024 / 1024).toFixed(1)} MB; open+House ${tHouse} ms, Prices ${tPrices} ms, search ${tSearch} ms, add sheet ${tSheet} ms)`);
    assert(tHouse < 3000 && tPrices < 3000 && tSheet < 1500 && tSearch < 3000, 'too slow');
    assert(size < 4.5 * 1024 * 1024, `5 years of data is ${mb} MB in storage; Safari allows about 5 MB`);
  });

  // ---------- iPhone screen details ----------
  await check('typing never makes iPhone zoom in (every text box uses at least 16 px text)', async () => {
    await tab(p, 'house');
    await p.click('#addBtn');
    await p.click('#addItem');
    let small = await p.$$eval('input:not([type=file]):not([hidden]), select, textarea', (els) => els.filter((e) => e.offsetParent && parseFloat(getComputedStyle(e).fontSize) < 16).map((e) => e.id || e.className));
    await cancel(p);
    await tab(p, 'settings');
    small = small.concat(await p.$$eval('input:not([type=file]):not([hidden]), select', (els) => els.filter((e) => e.offsetParent && parseFloat(getComputedStyle(e).fontSize) < 16).map((e) => e.id || e.className)));
    await tab(p, 'prices');
    small = small.concat(await p.$$eval('input', (els) => els.filter((e) => e.offsetParent && parseFloat(getComputedStyle(e).fontSize) < 16).map((e) => e.id || e.className)));
    assert(!small.length, `small text boxes: ${small.join(', ')}`);
  });

  await check('buttons are big enough to tap (at least 44×44 px, Apple\'s guideline)', async () => {
    const small = [];
    for (const t of ['personal', 'house', 'settings']) {
      await tab(p, t);
      small.push(...await p.$$eval('button, label.secondary, select, a', (els, t) => els.filter((e) => e.offsetParent).map((e) => [e, e.getBoundingClientRect()]).filter(([, r]) => r.height < 43.5 || r.width < 43.5).map(([e, r]) => `${t}:${(e.id || e.getAttribute('aria-label') || e.textContent).trim().slice(0, 16)} ${Math.round(r.width)}×${Math.round(r.height)}`), t));
    }
    await tab(p, 'house');
    await p.click('#addBtn');
    await p.click('#addItem');
    small.push(...await p.$$eval('#sheet button, #sheet label.secondary', (els) => els.filter((e) => e.offsetParent).map((e) => [e, e.getBoundingClientRect()]).filter(([, r]) => r.height < 43.5 || r.width < 43.5).map(([e, r]) => `sheet:${(e.id || e.getAttribute('aria-label') || e.textContent).trim().slice(0, 16)} ${Math.round(r.width)}×${Math.round(r.height)}`)));
    await cancel(p);
    const uniq = [...new Set(small)];
    assert(!uniq.length, `${uniq.length} small: ${uniq.slice(0, 12).join('; ')}`);
  });

  await check('landscape: everything fits and the add screen scrolls', async () => {
    const { p: q, ctx: c2 } = await phone('iPhone 13 landscape');
    for (const t of ['personal', 'house', 'prices', 'settings']) {
      await tab(q, t);
      assert(!(await q.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1)), `overflow on ${t}`);
    }
    await tab(q, 'house');
    await q.click('#addBtn');
    await q.locator('#saveTx2').scrollIntoViewIfNeeded();
    assert(await q.locator('#saveTx2').isVisible(), 'Save reachable');
    await c2.close();
  });

  for (const scale of [1.5, 2]) {
    await check(`large text (${scale * 100}% iPhone text size): nothing cut off or sideways-scrolling`, async () => {
      const dev = devices['iPhone 13'];
      // Safari's page zoom / Larger Text makes the page behave like a narrower screen.
      const { p: q, ctx: c2 } = await phone('iPhone 13', { viewport: { width: Math.round(dev.viewport.width / scale), height: Math.round(dev.viewport.height / scale) }, deviceScaleFactor: dev.deviceScaleFactor * scale });
      const problems = [];
      for (const t of ['personal', 'house', 'prices', 'settings']) {
        await tab(q, t);
        if (await q.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1)) problems.push(`sideways scroll on ${t}`);
        const clipped = await q.$$eval('button, .tx-cat, .cat-name, .stat .val, h1, .big', (els) => els.filter((e) => e.offsetParent && e.scrollWidth > e.clientWidth + 2 && getComputedStyle(e).textOverflow !== 'ellipsis').map((e) => (e.id || e.textContent).trim().slice(0, 20)));
        if (clipped.length) problems.push(`${t}: cut off ${clipped.slice(0, 4).join(', ')}`);
      }
      await tab(q, 'house');
      await q.click('#addBtn');
      if (await q.evaluate(() => document.querySelector('#sheet').scrollWidth > document.querySelector('#sheet').clientWidth + 1)) problems.push('add screen scrolls sideways');
      await c2.close();
      assert(!problems.length, problems.join('; '));
    });
  }

  await check('Dynamic Type: when the iPhone text size is set larger, the app text grows too', async () => {
    const { p: q, ctx: c2 } = await phone('iPhone 13');
    const base = await q.$eval('.tabbar button', (e) => parseFloat(getComputedStyle(e).fontSize));
    await q.addStyleTag({ content: 'html { font-size: 26px !important; }' }); // what -apple-system-body becomes at a larger setting
    const big = await q.$eval('.tabbar button', (e) => parseFloat(getComputedStyle(e).fontSize));
    const usesSystem = await q.evaluate(() => [...document.styleSheets].some((s) => { try { return [...s.cssRules].some((r) => /-apple-system-body/.test(r.cssText)); } catch { return false; } }));
    await c2.close();
    assert(usesSystem && big > base, `text does not follow the iPhone text size (tab label ${base}px → ${big}px)`);
  });

  for (const [system, pick, want] of [['dark', 'light', 'light'], ['light', 'dark', 'dark'], ['dark', 'system', 'dark']]) {
    await check(`appearance: phone set to ${system}, app set to ${pick === 'system' ? 'Automatic' : pick} → ${want} look, kept after reopening`, async () => {
      const { p: q, ctx: c2 } = await phone('iPhone SE', { colorScheme: system });
      await tab(q, 'settings');
      await q.click(`[data-theme-choice=${pick}]`);
      const bg = () => q.evaluate(() => getComputedStyle(document.body).backgroundColor);
      const isLight = (c) => { const [r, g, b] = c.match(/\d+/g).map(Number); return r + g + b > 600; };
      assert(isLight(await bg()) === (want === 'light'), `background ${await bg()}`);
      await q.reload();
      await q.waitForSelector('.tabbar');
      assert(isLight(await bg()) === (want === 'light'), `after reopening: ${await bg()}`);
      await tab(q, 'settings');
      assert(await q.$eval(`[data-theme-choice=${pick}]`, (b) => b.classList.contains('on')), 'choice not shown as selected');
      if (axeSource && pick !== 'system') {
        await tab(q, 'personal');
        await add(q, { amount: '5', note: 'theme' });
        await q.addScriptTag({ content: axeSource });
        const bad = await q.evaluate(async () => (await window.axe.run(document, { runOnly: ['color-contrast'] })).violations.map((v) => v.nodes.length));
        assert(!bad.length, `contrast problems: ${bad}`);
      }
      await c2.close();
    });
  }

  if (axeSource) {
    for (const scheme of ['light', 'dark']) {
      await check(`screen reader and contrast scan (axe), ${scheme} mode: no serious problems`, async () => {
        const { p: q, ctx: c2 } = await phone('iPhone 13', { colorScheme: scheme });
        await add(q, { amount: '5', note: 'axe' });
        const found = [];
        const scan = async (where) => {
          await q.addScriptTag({ content: axeSource });
          const r = await q.evaluate(async () => (await window.axe.run(document, { resultTypes: ['violations'] })).violations.filter((v) => ['serious', 'critical'].includes(v.impact)).map((v) => `${v.id} (${v.nodes.length}: ${v.nodes.slice(0, 2).map((n) => n.target.join(' ')).join(', ')})`));
          found.push(...r.map((x) => `${where}: ${x}`));
        };
        for (const t of ['personal', 'house', 'prices', 'settings']) { await tab(q, t); await scan(t); }
        await tab(q, 'house'); await q.click('#addBtn'); await q.click('#addItem'); await scan('add screen');
        await c2.close();
        assert(!found.length, found.join('\n'));
      });
    }
  }

  await check('no script errors', async () => { assert(p.errors.length === 0, p.errors.join(' | ')); });
  await ctx.close();
  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
