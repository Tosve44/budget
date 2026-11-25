// Click-through tests in an iPhone-sized browser. Run: python3 -m http.server 8123 & node tests/e2e.cjs
const { chromium, devices } = require('playwright');
const path = require('path');
const URL = process.env.APP_URL || 'http://localhost:8123/';
const SHOTS = process.env.SHOTS || null;
let pass = 0, fail = 0;
const results = [];
async function check(name, fn) {
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n')[0]}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }
const money = (s) => Number(String(s).replace(/[^\d,.-]/g, '').replace(/\.(?=\d{3}\b)/g, '').replace(',', '.'));

(async () => {
  const browser = await chromium.launch();
  for (const devName of (process.env.DEVICES || 'iPhone SE,iPhone 13,iPhone 14 Pro Max').split(',')) {
    const ctx = await browser.newContext({ ...devices[devName], locale: 'sl-SI', timezoneId: 'Europe/Ljubljana' });
    const p = await ctx.newPage();
    p.setDefaultTimeout(8000);
    const errors = [];
    p.on('pageerror', (e) => errors.push(e.message));
    p.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
    await p.goto(URL);
    const D = `[${devName}]`;
    const tab = (t) => p.click(`[data-tab=${t}]`);
    const addEntry = async ({ amount, cat, kind = 'expense', date, note }) => {
      await p.click('#addBtn');
      if (kind === 'income') await p.click('.seg [data-kind=income]');
      await p.fill('#amount', amount);
      await p.locator('[data-chip]', { hasText: cat }).first().click();
      if (date) await p.fill('#date', date);
      if (note) await p.fill('#note', note);
      await p.click('#saveTx2');
      await p.waitForFunction(() => !document.querySelector('#sheet').open);
    };
    const noOverflow = async (where) => assert(!(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1)), `sideways scroll on ${where}`);

    await check(`${D} opens on Personal with the current month and no errors`, async () => {
      assert((await p.textContent('#title')) === 'Personal');
      assert((await p.textContent('main')).includes('No entries yet'));
      await noOverflow('Personal');
    });

    await check(`${D} set budgets in Settings`, async () => {
      await tab('settings');
      for (const [name, b] of [['Groceries', '250'], ['Rent', '500'], ['Gas', '80']]) {
        await p.locator('.set-list li', { hasText: name }).first().locator('[data-editcat]').click();
        await p.fill('#catBudget', b);
        await p.click('#saveCat2');
      }
      assert(/Budget (€\s?250|250\s?€)/.test(await p.textContent('main')), 'budget shown in settings');
      await noOverflow('Settings');
    });

    await check(`${D} add expenses and income; totals add up`, async () => {
      await tab('personal');
      await addEntry({ amount: '42,30', cat: 'Groceries', note: 'Weekly shop' });
      await addEntry({ amount: '500', cat: 'Rent' });
      await addEntry({ amount: '95', cat: 'Gas' });
      await addEntry({ amount: '2100', cat: 'Salary', kind: 'income' });
      const vals = await p.$$eval('.stat .val', (els) => els.map((e) => e.textContent));
      assert(money(vals[0]) === 2100, `income ${vals[0]}`);
      assert(Math.abs(money(vals[1]) - 637.3) < 0.001, `spent ${vals[1]}`);
      assert(money(vals[2]) === 830, `budget ${vals[2]}`);
      const left = await p.textContent('.big');
      assert(Math.abs(money(left) - 192.7) < 0.001, `left ${left}`);
    });

    await check(`${D} over-budget category is shown in red`, async () => {
      const gasRow = p.locator('.cat-row', { hasText: 'Gas' });
      assert(await gasRow.locator('.bar.over').count() === 1, 'gas 95/80 should be over');
    });

    await check(`${D} tapping a category filters the entries`, async () => {
      await p.locator('.cat-row button', { hasText: 'Rent' }).click();
      assert(await p.locator('.tx').count() === 1, 'only rent');
      await p.click('#clearFilter');
      assert(await p.locator('.tx').count() === 4);
    });

    await check(`${D} edit an entry (amount and category) and delete one`, async () => {
      await p.locator('.tx', { hasText: 'Gas' }).locator('button').click();
      await p.fill('#amount', '60');
      await p.click('#saveTx2');
      await p.waitForFunction(() => !document.querySelector('#sheet').open);
      assert((await p.locator('.tx', { hasText: 'Gas' }).textContent()).includes('60'));
      await p.locator('.tx', { hasText: 'Rent' }).locator('button').click();
      await p.click('#delTx');
      await p.waitForFunction(() => !document.querySelector('#sheet').open);
      assert(await p.locator('.tx', { hasText: 'Rent' }).count() === 0, 'rent deleted');
    });

    await check(`${D} entries go to the right month; month arrows work`, async () => {
      await addEntry({ amount: '12', cat: 'Barber', date: '2026-10-15' });
      assert((await p.textContent('#monthLabel')).toLowerCase().includes('okt') || (await p.textContent('#monthLabel')).toLowerCase().includes('oct'), 'jumped to October');
      assert(await p.locator('.tx').count() === 1);
      await p.click('#nextMonth');
      assert(await p.locator('.tx').count() === 3, 'November still has 3');
      await p.click('#nextMonth');
      assert((await p.textContent('main')).includes('No entries yet'), 'December empty');
      await p.click('#prevMonth');
    });

    await check(`${D} validation: no amount or no category is refused`, async () => {
      await p.click('#addBtn');
      await p.click('#saveTx2');
      assert(await p.$eval('#sheet', (d) => d.open), 'sheet stays open without amount');
      await p.fill('#amount', '5');
      await p.click('#saveTx2');
      assert(await p.$eval('#sheet', (d) => d.open), 'sheet stays open without category');
      await p.click('[data-close]');
    });

    await check(`${D} Milica has her own private Personal space`, async () => {
      await tab('settings');
      await p.click('[data-user=u_milica]');
      await tab('personal');
      assert((await p.textContent('#who')) === 'Milica');
      assert((await p.textContent('main')).includes('No entries yet'), 'Milica personal empty');
      await p.click('#addBtn');
      await p.click('.seg [data-kind=income]');
      assert(await p.locator('[data-chip]', { hasText: 'Partner balance' }).count() === 1, 'Milica can receive partner balance');
      await p.click('[data-close]');
    });

    await check(`${D} House is shared and shows who added each entry`, async () => {
      await tab('house');
      await addEntry({ amount: '80', cat: 'Groceries' });
      await tab('settings');
      await p.click('[data-user=u_tosve]');
      await tab('house');
      await addEntry({ amount: '35', cat: 'Unexpected expenses' });
      const txt = await p.textContent('.tx-list');
      assert(txt.includes('Milica') && txt.includes('Tosve'), 'both names shown');
      await tab('personal');
      assert(await p.locator('.tx').count() === 3, 'Tosve personal untouched');
    });

    await check(`${D} add, rename, hide and reorder categories`, async () => {
      await tab('settings');
      await p.locator('[data-addcat=sp_house][data-kind=expense]').click();
      await p.fill('#catName', 'Pets');
      await p.fill('#catBudget', '40');
      await p.click('#saveCat2');
      await p.locator('.set-list li', { hasText: 'Pets' }).locator('[data-editcat]').click();
      await p.fill('#catName', 'Pet food');
      await p.click('#saveCat2');
      assert((await p.textContent('main')).includes('Pet food'));
      await p.locator('.set-list li', { hasText: 'Pet food' }).locator('[data-move][data-dir="-1"]').click();
      await p.locator('.set-list li', { hasText: 'Nicotine' }).locator('[data-editcat]').click();
      await p.click('#archCat');
      await tab('personal');
      await p.click('#addBtn');
      assert(await p.locator('[data-chip]', { hasText: 'Nicotine' }).count() === 0, 'hidden category not offered');
      await p.click('[data-close]');
      await tab('house');
      await p.click('#addBtn');
      assert(await p.locator('[data-chip]', { hasText: 'Pet food' }).count() === 1, 'new category offered');
      await p.click('[data-close]');
    });

    await check(`${D} receipt photo: items read, prices compared, Prices tab history`, async () => {
      await tab('personal');
      // first shop, typed by hand, a month earlier
      await p.click('#addBtn');
      await p.fill('#amount', '5');
      await p.locator('[data-chip]', { hasText: 'Groceries' }).click();
      await p.fill('#date', '2026-10-02');
      await p.click('#addItem');
      await p.fill('input[data-i="0"][data-f=name]', 'MLEKO ALPSKO 3,5% 1L');
      await p.fill('input[data-i="0"][data-f=price]', '1,19');
      await p.click('#saveTx2');
      await p.waitForFunction(() => !document.querySelector('#sheet').open);
      await p.click('#nextMonth');
      await p.click('#addBtn');
      await p.fill('#date', '2026-11-20');
      await p.setInputFiles('#photoInput', path.join(__dirname, 'mercator.jpg'));
      await p.waitForFunction(() => /Found|Could not/.test(document.querySelector('#ocrStatus')?.textContent || ''), null, { timeout: 120000 });
      assert((await p.textContent('#ocrStatus')).startsWith('Found'), await p.textContent('#ocrStatus'));
      assert(await p.locator('[data-chip].on', { hasText: 'Groceries' }).count() === 1, 'Groceries picked automatically');
      assert(money(await p.inputValue('#amount')) === 8.39, `amount from printed total, got ${await p.inputValue('#amount')}`);
      const rows = await p.$$eval('.item-row', (rs) => rs.map((r) => [r.querySelector('.item-name').value, r.querySelector('.item-cmp').textContent]));
      const milk = rows.find(([n]) => n.startsWith('MLEKO'));
      assert(milk && milk[1].includes('+8.4%') && /1,19|1\.19/.test(milk[1]), `milk comparison: ${JSON.stringify(rows)}`);
      if (SHOTS) await p.screenshot({ path: `${SHOTS}/${devName}-receipt.png`, fullPage: true });
      await p.click('#saveTx2');
      await p.waitForFunction(() => !document.querySelector('#sheet').open, null, { timeout: 5000 });
      await tab('prices');
      const row = p.locator('.price-row', { hasText: 'MLEKO ALPSKO' });
      assert((await row.textContent()).includes('+8.4%'));
      await row.locator('button').click();
      assert(await p.locator('.price-hist li').count() === 2, 'two purchases in history');
      await p.fill('#priceSearch', 'kruh');
      assert(await p.locator('.price-row').count() === 1, 'search');
      await noOverflow('Prices');
      if (SHOTS) await p.screenshot({ path: `${SHOTS}/${devName}-prices.png` });
    });

    await check(`${D} receipt photo is kept and shown again when the entry is opened`, async () => {
      await tab('personal');
      await p.locator('.tx', { hasText: 'items' }).first().locator('button').click();
      await p.waitForFunction(() => !document.querySelector('#thumb').hidden, null, { timeout: 3000 });
      assert(await p.locator('.item-row').count() === 6, 'items kept');
      await p.click('[data-close]');
    });

    await check(`${D} data survives closing and reopening the app`, async () => {
      await p.reload();
      assert(await p.locator('.tx').count() >= 3);
    });

    await check(`${D} backup download and restore`, async () => {
      await tab('settings');
      const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#exportBtn')]);
      const file = await dl.path();
      const before = await p.evaluate(() => localStorage['budget.v1']);
      await p.click('#resetBtn');
      await p.click('#confirmYes');
      assert(JSON.parse(await p.evaluate(() => localStorage['budget.v1'])).transactions.length === 0, 'erased');
      await p.setInputFiles('#importFile', file);
      await p.waitForTimeout(300);
      assert((await p.evaluate(() => localStorage['budget.v1'])) === before, 'restored identical');
    });

    await check(`${D} dark mode renders and every tab fits the screen`, async () => {
      await p.emulateMedia({ colorScheme: 'dark' });
      for (const t of ['personal', 'house', 'prices', 'settings']) {
        await tab(t);
        await noOverflow(t + ' (dark)');
        if (SHOTS && devName === 'iPhone SE') await p.screenshot({ path: `${SHOTS}/${devName}-${t}-dark.png` });
      }
      const bg = await p.evaluate(() => getComputedStyle(document.body).backgroundColor);
      assert(bg === 'rgb(21, 21, 23)', `dark background, got ${bg}`);
      await p.emulateMedia({ colorScheme: 'light' });
      await tab('personal');
      if (SHOTS) await p.screenshot({ path: `${SHOTS}/${devName}-personal.png`, fullPage: true });
    });

    await check(`${D} works offline after the first visit`, async () => {
      await p.evaluate(() => navigator.serviceWorker.ready);
      await p.reload();
      await ctx.setOffline(true);
      await p.reload();
      assert((await p.textContent('#title')) === 'Personal', 'app opened offline');
      await ctx.setOffline(false);
    });

    await check(`${D} no script errors`, async () => assert(errors.length === 0, errors.join(' | ')));
    await ctx.close();
  }
  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
