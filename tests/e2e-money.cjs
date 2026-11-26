// Income, spending, balance and budget numbers on the overview, checked against a separate
// calculation, for many combinations (budgets set or not, decimals, several months, both spaces,
// edits that switch income/expense, deletes), plus a long random sequence.
// Run: python3 -m http.server 8123 & node tests/e2e-money.cjs
const { chromium, devices } = require('playwright');

const APP = process.env.APP_URL || 'http://localhost:8123/';
const SB_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
let pass = 0, fail = 0;
const results = [];
let page = null;
async function check(name, fn) {
  if (page) await page.evaluate(() => { const d = document.querySelector('#sheet'); if (d.open) d.close(); }).catch(() => {});
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n').slice(0, 3).join('\n    ')}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }
// "1.234,56 €", "−5 €", "+12 €" -> cents
const cents = (s) => {
  const t = String(s).replace(/[^\d,.\-−+]/g, '');
  const neg = /[-−]/.test(t);
  const n = Number(t.replace(/[-−+]/g, '').replace(/\./g, '').replace(',', '.'));
  return Math.round(n * 100) * (neg ? -1 : 1);
};
const eur = (c) => (c / 100).toFixed(2).replace('.', ',');

(async () => {
  const key = (await (await fetch(`${SB_URL}/__test/anon-key`)).json()).key;
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ...devices['iPhone SE'], locale: 'sl-SI', timezoneId: 'Europe/Ljubljana' });
  await ctx.addInitScript(([u, k]) => localStorage.setItem('budget.config.override', JSON.stringify({ supabaseUrl: u, supabaseAnonKey: k })), [SB_URL, key]);
  const p = await ctx.newPage();
  p.setDefaultTimeout(8000);
  page = p;
  const errors = [];
  p.on('pageerror', (e) => errors.push(e.message));
  await p.goto(APP);

  const tab = (t) => p.click(`[data-tab=${t}]`);
  const closed = () => p.waitForFunction(() => !document.querySelector('#sheet').open);
  const month = () => p.evaluate(() => document.querySelector('#monthLabel').textContent);
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Ljubljana' });
  const thisMonth = today.slice(0, 7);
  const shift = (m, d) => { const [y, mo] = m.split('-').map(Number); const x = new Date(y, mo - 1 + d, 1); return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}`; };

  // ----- independent model of what the overview should say -----
  const model = { tx: [], budgets: {} }; // tx: {id?, space, kind, cat, amount, date, note}
  let viewMonth = thisMonth, viewSpace = 'personal';
  function expected(space = viewSpace, m = viewMonth) {
    const txs = model.tx.filter((t) => t.space === space && t.date.startsWith(m));
    const income = txs.filter((t) => t.kind === 'income').reduce((s, t) => s + t.amount, 0);
    const spent = txs.filter((t) => t.kind === 'expense').reduce((s, t) => s + t.amount, 0);
    const budget = Object.entries(model.budgets).filter(([k]) => k.startsWith(space + ':')).reduce((s, [, v]) => s + v, 0);
    return { income, spent, balance: income - spent, budget, left: budget - spent };
  }
  async function shown() {
    const val = (sel) => p.$eval(sel, (e) => e.textContent);
    const r = { income: cents(await val('[data-add=income] .val')), spent: cents(await val('[data-add=expense] .val')), balance: cents(await val('#balance .val')) };
    r.balanceColor = await p.$eval('#balance .val', (e) => e.className);
    const main = await p.textContent('.card');
    r.hasBudget = /Left this month|Over budget/.test(main);
    if (r.hasBudget) { r.left = cents(await val('.summary-main .big')) * (/Over budget/.test(main) ? -1 : 1); r.over = /Over budget/.test(main); }
    else r.spentBig = cents(await val('.card .big'));
    return r;
  }
  async function verify(label) {
    const e = expected(), s = await shown();
    const where = `${label} [${viewSpace} ${viewMonth}]`;
    assert(s.income === e.income, `${where}: Income shows ${eur(s.income)}, expected ${eur(e.income)}`);
    assert(s.spent === e.spent, `${where}: Spent shows ${eur(s.spent)}, expected ${eur(e.spent)}`);
    assert(s.balance === e.balance, `${where}: Balance shows ${eur(s.balance)}, expected ${eur(e.balance)}`);
    assert(e.balance < 0 ? /over/.test(s.balanceColor) : !/over/.test(s.balanceColor), `${where}: balance colour`);
    assert(s.hasBudget === e.budget > 0, `${where}: budget summary ${s.hasBudget ? 'shown' : 'missing'}`);
    if (e.budget > 0) {
      assert(s.left === e.left, `${where}: Left shows ${eur(s.left)}, expected ${eur(e.left)}`);
      assert(s.over === e.left < 0, `${where}: over-budget state`);
    } else assert(s.spentBig === e.spent, `${where}: "Spent this month" shows ${eur(s.spentBig)}`);
  }
  async function goto(space, m) {
    if (space !== viewSpace) { await tab(space); viewSpace = space; }
    while (viewMonth !== m) {
      const d = m > viewMonth ? 1 : -1;
      await p.click(d > 0 ? '#nextMonth' : '#prevMonth');
      viewMonth = shift(viewMonth, d);
    }
  }
  async function add({ space = viewSpace, kind = 'expense', cat, amount, typed, date = `${viewMonth}-${viewMonth === thisMonth ? today.slice(8) : '15'}`, via = 'fab', note }) {
    await goto(space, date.slice(0, 7));
    if (via === 'fab') { await p.click('#addBtn'); if (kind === 'income') await p.click('.seg [data-kind=income]'); }
    else await p.click(`[data-add=${kind}]`);
    // The app puts the cursor in the amount box right after opening; wait for that before typing elsewhere.
    await p.waitForFunction(() => document.activeElement?.id === 'amount');
    await p.fill('#amount', typed ?? eur(amount));
    await p.locator('[data-chip]', { hasText: cat }).first().click();
    await p.fill('#date', date);
    const n = note || `n${model.tx.length}_${Math.random().toString(36).slice(2, 7)}`;
    await p.fill('#note', n);
    await p.click('#saveTx2');
    await closed().catch(async (e) => {
      await p.screenshot({ path: '/tmp/claude-0/-home-user/0757da7a-2f06-5689-afac-2ee0efb439e8/scratchpad/money-fail.png' });
      const st = await p.evaluate(() => ({ amount: document.querySelector('#amount')?.value, on: [...document.querySelectorAll('#sheet .on')].map((b) => b.textContent), n: window.__budgetStore.data.transactions.length }));
      throw new Error(`could not save ${kind} ${typed ?? eur(amount)} ${cat} ${date}: ${JSON.stringify(st)} toasts=${await p.$$eval('.toast', (ts) => ts.map((t) => t.textContent).join(' | '))}`);
    });
    const t = { space, kind, cat, amount, date, note: n };
    model.tx.push(t);
    return t;
  }
  async function open(t) { await goto(t.space, t.date.slice(0, 7)); await p.locator('.tx', { hasText: t.note }).locator('button').click(); }
  async function setBudget(space, cat, amount) {
    await tab('settings');
    const card = p.locator('.card', { hasText: space === 'house' ? 'House categories' : 'personal categories' });
    await card.locator('.set-list li', { hasText: cat }).first().locator('[data-editcat]').click();
    await p.fill('#catBudget', amount ? eur(amount) : '');
    await p.click('#saveCat2');
    await closed();
    if (amount) model.budgets[`${space}:${cat}`] = amount; else delete model.budgets[`${space}:${cat}`];
    await tab(viewSpace);
  }

  await check('empty month: everything is 0 and no budget is shown', async () => { await verify('empty'); });

  await check('spend 5 € with no budget: Spent 5 €, Balance −5 € in red (not "–")', async () => {
    await add({ cat: 'Food & Drinks', amount: 500 });
    await verify('after 5 €');
    assert((await p.textContent('#balance .val')).replace(/\s/g, '').match(/^[-−]5/), `balance text: ${await p.textContent('#balance .val')}`);
  });

  await check('tapping Income opens the add screen set to income, with income categories', async () => {
    await p.click('[data-add=income]');
    assert(await p.$eval('.seg [data-kind=income]', (b) => b.classList.contains('on')), 'Income not selected');
    const chips = await p.$$eval('[data-chip]', (cs) => cs.map((c) => c.textContent));
    assert(chips.some((c) => c.endsWith('Salary')) && !chips.some((c) => c.endsWith('Groceries')), `chips: ${chips.join(', ')}`);
    const focused = await p.waitForFunction(() => document.activeElement?.id === 'amount', null, { timeout: 1500 }).then(() => true, () => false);
    if (!focused) { await p.click('[data-close]'); await closed(); }
    assert(focused, 'amount field focused, keyboard ready');
    await p.click('[data-close]'); await closed();
  });

  await check('tapping Spent opens the add screen set to expense', async () => {
    await p.click('[data-add=expense]');
    assert(await p.$eval('.seg [data-kind=expense]', (b) => b.classList.contains('on')), 'Expense not selected');
    const chips = await p.$$eval('[data-chip]', (cs) => cs.map((c) => c.textContent));
    assert(chips.some((c) => c.endsWith('Groceries')) && !chips.some((c) => c.endsWith('Salary')));
    await p.click('[data-close]'); await closed();
  });

  await check('salary 1.200,50 added from the Income button: Balance +1.195,50', async () => {
    await add({ via: 'stat', kind: 'income', cat: 'Salary', amount: 120050, typed: '1.200,50' });
    await verify('after salary');
  });

  await check('budget of 100 € on Groceries: Left = budget − all spending', async () => {
    await setBudget('personal', 'Groceries', 10000);
    await verify('budget set');
    await add({ via: 'stat', cat: 'Groceries', amount: 3025 });
    await verify('after groceries');
  });

  await check('going over budget shows "Over budget" in red', async () => {
    await add({ cat: 'Groceries', amount: 8000 });
    await verify('over budget');
    assert(await p.$('.summary-main .big.over'), 'not red');
  });

  await check('cents add up exactly (0,01 + 0,02 + 0,07 = 0,10)', async () => {
    for (const a of [1, 2, 7]) await add({ cat: 'Toiletries', amount: a });
    await verify('cents');
  });

  await check('changing an expense into income moves it between the totals', async () => {
    const t = model.tx.find((x) => x.cat === 'Food & Drinks');
    await open(t);
    await p.click('.seg [data-kind=income]');
    await p.locator('[data-chip]', { hasText: 'Other income' }).click();
    await p.click('#saveTx2'); await closed();
    Object.assign(t, { kind: 'income', cat: 'Other income' });
    await verify('switched to income');
  });

  await check('changing an amount and deleting an entry update the totals', async () => {
    const t = model.tx.find((x) => x.cat === 'Groceries' && x.amount === 8000);
    await open(t);
    await p.fill('#amount', '12,34');
    await p.click('#saveTx2'); await closed();
    t.amount = 1234;
    await verify('amount changed');
    const d = model.tx.find((x) => x.cat === 'Toiletries');
    await open(d);
    await p.click('#delTx'); await closed();
    model.tx.splice(model.tx.indexOf(d), 1);
    await verify('deleted');
  });

  await check('removing the budget switches back to the plain "Spent this month" view', async () => {
    await setBudget('personal', 'Groceries', 0);
    await verify('budget removed');
  });

  await check('other months and the House are separate from this month\'s Personal', async () => {
    await add({ cat: 'Gas', amount: 4999, date: `${shift(thisMonth, -1)}-28` });
    await verify('last month');
    await add({ kind: 'income', cat: 'Other income', amount: 5000, date: `${shift(thisMonth, 1)}-02` });
    await verify('next month, income only');
    await goto('house', thisMonth);
    await verify('house empty');
    await add({ space: 'house', cat: 'Groceries', amount: 6420 });
    await add({ space: 'house', kind: 'income', via: 'stat', cat: 'Contributions', amount: 20000 });
    await setBudget('house', 'Groceries', 40000);
    await verify('house');
    await goto('personal', thisMonth);
    await verify('personal unchanged');
  });

  await check('very large and very small numbers display correctly', async () => {
    await add({ kind: 'income', cat: 'Other income', amount: 999999999, typed: '9.999.999,99', date: `${shift(thisMonth, 2)}-10` });
    await add({ cat: 'Saving', amount: 1, date: `${shift(thisMonth, 2)}-11` });
    await verify('large');
  });

  await check('200 random changes (add, edit, switch kind, delete; both spaces; 4 months; budgets on and off) all add up', async () => {
    let seed = 7;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
    const cats = { personal: { expense: ['Car', 'Rent', 'Groceries', 'Gas', 'Barber'], income: ['Salary', 'Other income'] }, house: { expense: ['Groceries', 'Savings', 'Shopping'], income: ['Contributions'] } };
    const months = [shift(thisMonth, -2), shift(thisMonth, -1), thisMonth, shift(thisMonth, 1)];
    for (let i = 0; i < 200; i++) {
      const op = rnd(10);
      const space = rnd(3) ? 'personal' : 'house';
      if (op < 5 || !model.tx.length) {
        const kind = rnd(4) ? 'expense' : 'income';
        const m = months[rnd(4)];
        await add({ space, kind, cat: cats[space][kind][rnd(cats[space][kind].length)], amount: 1 + rnd(50000), date: `${m}-${String(1 + rnd(28)).padStart(2, '0')}`, via: rnd(2) ? 'fab' : 'stat' });
      } else if (op < 7) {
        const t = model.tx[rnd(model.tx.length)];
        await open(t);
        const amount = 1 + rnd(90000);
        await p.fill('#amount', eur(amount));
        await p.click('#saveTx2'); await closed();
        t.amount = amount;
      } else if (op < 8) {
        const t = model.tx[rnd(model.tx.length)];
        await open(t);
        const kind = t.kind === 'income' ? 'expense' : 'income';
        await p.click(`.seg [data-kind=${kind}]`);
        const cat = cats[t.space][kind][0];
        await p.locator('[data-chip]', { hasText: cat }).first().click();
        await p.click('#saveTx2'); await closed();
        Object.assign(t, { kind, cat });
      } else if (op < 9) {
        const t = model.tx[rnd(model.tx.length)];
        await open(t);
        await p.click('#delTx'); await closed();
        model.tx.splice(model.tx.indexOf(t), 1);
      } else {
        const cat = cats[space].expense[rnd(cats[space].expense.length)];
        await setBudget(space, cat, rnd(3) ? 1000 * (1 + rnd(60)) : 0);
      }
      await goto(rnd(2) ? 'personal' : 'house', months[rnd(4)]);
      await verify(`step ${i + 1}`);
    }
  });

  await check('no script errors', async () => { assert(!errors.length, errors.join(' | ')); });
  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
