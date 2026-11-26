// Two iPhone-sized browsers (Tosve's phone and Milica's phone) using the real app UI,
// syncing through Supabase. By default it talks to the local test server
// (tests/backend/fake-supabase.cjs); set SUPABASE_URL and SUPABASE_ANON_KEY to test a real project.
// Run: python3 -m http.server 8123 & node tests/e2e-sync.cjs
const { chromium, devices } = require('playwright');
const path = require('path');

const APP = process.env.APP_URL || 'http://localhost:8123/';
const SB_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const SHOTS = process.env.SHOTS || null;
const run = Date.now().toString(36);
let pass = 0, fail = 0;
const results = [];
async function check(name, fn) {
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n')[0]}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }

(async () => {
  const key = process.env.SUPABASE_ANON_KEY || (process.env.USE_BUILT_IN_CONFIG ? '' : (await (await fetch(`${SB_URL}/__test/anon-key`)).json()).key);
  const browser = await chromium.launch();
  async function phone(device) {
    const ctx = await browser.newContext({ ...devices[device], locale: 'sl-SI', timezoneId: 'Europe/Ljubljana' });
    if (!process.env.USE_BUILT_IN_CONFIG) {
      await ctx.addInitScript(([u, k]) => localStorage.setItem('budget.config.override', JSON.stringify({ supabaseUrl: u, supabaseAnonKey: k })), [SB_URL, key]);
    }
    const p = await ctx.newPage();
    p.setDefaultTimeout(15000);
    p.errors = [];
    p.on('pageerror', (e) => p.errors.push(e.message));
    await p.goto(APP);
    return { ctx, p };
  }
  const tab = (p, t) => p.click(`[data-tab=${t}]`);
  const closed = (p) => p.waitForFunction(() => !document.querySelector('#sheet').open);
  const addEntry = async (p, { amount, cat, note, photo }) => {
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount'); // the app focuses it right after opening
    if (photo) {
      await p.setInputFiles('#photoInput', photo);
      await p.waitForFunction(() => /Found|Could not/.test(document.querySelector('#ocrStatus')?.textContent || ''), null, { timeout: 120000 });
    } else {
      await p.fill('#amount', amount);
    }
    if (cat) await p.locator('[data-chip]', { hasText: cat }).first().click();
    if (note) await p.fill('#note', note);
    await p.click('#saveTx2');
    await closed(p);
  };
  const synced = (p) => p.waitForFunction(() => / · synced$/.test(document.querySelector('#who').textContent), null, { timeout: 20000 });
  const syncNow = async (p) => { await tab(p, 'settings'); await p.click('#syncNowBtn'); await synced(p); };

  const A = await phone('iPhone 13');
  const B = await phone('iPhone SE');
  const tosveEmail = `test-tosve-${run}@example.com`;
  const milicaEmail = `test-milica-${run}@example.com`;

  await check('Tosve uses the app before signing in (offline-only mode still works)', async () => {
    await addEntry(A.p, { amount: '55', cat: 'Gas' });
    await tab(A.p, 'house');
    await addEntry(A.p, { amount: '64,20', cat: 'Groceries', note: 'Spar' });
    assert(await A.p.locator('.tx').count() === 1);
  });

  await check('Tosve creates an account and starts the household; an invite code appears', async () => {
    await tab(A.p, 'settings');
    await A.p.fill('#authEmail', tosveEmail);
    await A.p.fill('#authPass', 'secret123');
    await A.p.click('#signUpBtn');
    await A.p.waitForSelector('#createHh');
    await A.p.fill('#dispName', 'Tosve');
    await A.p.click('#createHh');
    await A.p.waitForSelector('#inviteCode');
    const code = (await A.p.textContent('#inviteCode')).trim();
    assert(/^[0-9A-F]{8}$/.test(code), code);
    A.code = code;
    if (SHOTS) await A.p.screenshot({ path: `${SHOTS}/sync-invite.png` });
    await synced(A.p);
  });

  await check('a wrong invite code is refused with a clear message', async () => {
    await tab(B.p, 'settings');
    await B.p.click('[data-user=u_milica]');
    await B.p.fill('#authEmail', milicaEmail);
    await B.p.fill('#authPass', 'secret456');
    await B.p.click('#signUpBtn');
    await B.p.waitForSelector('#joinHh');
    await B.p.fill('#dispName', 'Milica');
    await B.p.fill('#joinCode', 'ZZZZZZZZ');
    await B.p.click('#joinHh');
    await B.p.waitForSelector('.form-error');
    assert((await B.p.textContent('.form-error')).includes('not found'));
  });

  await check('Milica joins with the code and sees the House entries, not Tosve\'s Personal', async () => {
    await B.p.fill('#joinCode', A.code.toLowerCase());
    await B.p.click('#joinHh');
    await B.p.waitForSelector('#syncNowBtn');
    await synced(B.p);
    await tab(B.p, 'house');
    const txt = await B.p.textContent('.tx-list');
    assert(txt.includes('Spar') && txt.includes('Tosve'), 'House entry from Tosve shown with his name');
    await tab(B.p, 'personal');
    assert((await B.p.textContent('main')).includes('No entries yet'), "Tosve's Gas entry is not in Milica's Personal");
    assert((await B.p.textContent('#who')).startsWith('Milica'));
  });

  await check('Milica adds a House entry with a receipt photo; it reaches Tosve with the photo', async () => {
    await tab(B.p, 'house');
    await addEntry(B.p, { photo: path.join(__dirname, 'lidl.jpg'), note: 'Lidl' });
    await synced(B.p);
    await syncNow(A.p);
    await tab(A.p, 'house');
    const row = A.p.locator('.tx', { hasText: 'Lidl' });
    assert(await row.count() === 1, 'Lidl entry arrived');
    assert((await row.textContent()).includes('Milica'));
    await row.locator('button').click();
    await A.p.waitForFunction(() => !document.querySelector('#thumb').hidden && document.querySelector('#thumb').naturalWidth > 0, null, { timeout: 15000 });
    assert(await A.p.locator('.item-row').count() >= 5, 'receipt items came along');
    if (SHOTS) await A.p.screenshot({ path: `${SHOTS}/sync-received.png` });
    await A.p.click('[data-close]');
  });

  await check('price comparison uses both people\'s receipts', async () => {
    await tab(A.p, 'prices');
    assert((await A.p.textContent('main')).includes('Maslo 250g'), "Milica's items show in Tosve's Prices");
  });

  await check('Tosve edits Milica\'s entry; she sees the change', async () => {
    await tab(A.p, 'house');
    await A.p.locator('.tx', { hasText: 'Lidl' }).locator('button').click();
    await A.p.fill('#note', 'Lidl Vič');
    await A.p.click('#saveTx2');
    await closed(A.p);
    await synced(A.p);
    await syncNow(B.p);
    await tab(B.p, 'house');
    assert(await B.p.locator('.tx', { hasText: 'Lidl Vič' }).count() === 1);
  });

  await check('no internet: entries are saved, shown as waiting, and sync when back online', async () => {
    await A.ctx.setOffline(true);
    await tab(A.p, 'house');
    await addEntry(A.p, { amount: '19,99', cat: 'Unexpected expenses', note: 'Offline buy' });
    await A.p.waitForFunction(() => / · offline$/.test(document.querySelector('#who').textContent), null, { timeout: 20000 });
    assert(await A.p.locator('.tx', { hasText: 'Offline buy' }).count() === 1, 'shown while offline');
    await tab(A.p, 'settings');
    assert((await A.p.textContent('#syncCard')).includes('waiting'), 'shows changes waiting');
    await A.ctx.setOffline(false);
    await A.p.evaluate(() => window.dispatchEvent(new Event('online')));
    await synced(A.p);
    await syncNow(B.p);
    await tab(B.p, 'house');
    assert(await B.p.locator('.tx', { hasText: 'Offline buy' }).count() === 1, 'arrived on Milica\'s phone');
  });

  await check('closing and reopening the app keeps you signed in and synced', async () => {
    await A.p.reload();
    await synced(A.p);
    await tab(A.p, 'house');
    assert(await A.p.locator('.tx').count() === 3);
  });

  await check('deleting on one phone removes it on the other', async () => {
    await tab(B.p, 'house');
    await B.p.locator('.tx', { hasText: 'Offline buy' }).locator('button').click();
    await B.p.click('#delTx');
    await closed(B.p);
    await synced(B.p);
    await syncNow(A.p);
    await tab(A.p, 'house');
    assert(await A.p.locator('.tx', { hasText: 'Offline buy' }).count() === 0);
  });

  await check('a new House category and budget sync', async () => {
    await tab(A.p, 'settings');
    await A.p.locator('[data-addcat][data-kind=expense]').last().click();
    await A.p.fill('#catName', 'Garden');
    await A.p.fill('#catBudget', '30');
    await A.p.click('#saveCat2');
    await synced(A.p);
    await syncNow(B.p);
    assert((await B.p.textContent('main')).includes('Garden'));
  });

  await check('sign out and sign back in on the same phone', async () => {
    await tab(B.p, 'settings');
    await B.p.click('#signOutBtn');
    await B.p.click('#confirmYes');
    await B.p.waitForSelector('#authForm');
    await B.p.fill('#authEmail', milicaEmail);
    await B.p.fill('#authPass', 'wrongpass');
    await B.p.click('#signInBtn');
    await B.p.waitForSelector('.form-error');
    assert((await B.p.textContent('.form-error')).includes('Wrong email or password'), 'wrong password message: ' + await B.p.textContent('.form-error'));
    await B.p.fill('#authPass', 'secret456');
    await B.p.click('#signInBtn');
    await B.p.waitForSelector('#syncNowBtn');
    await synced(B.p);
    await tab(B.p, 'house');
    const n = await B.p.locator('.tx').count();
    assert(n === 2, `house entries after sign-in: ${n}: ${await B.p.textContent('main')}`);
  });

  await check('a brand-new phone (reinstall) gets everything back after sign-in', async () => {
    const C = await phone('iPhone 14 Pro Max');
    await tab(C.p, 'settings');
    await C.p.fill('#authEmail', tosveEmail);
    await C.p.fill('#authPass', 'secret123');
    await C.p.click('#signInBtn');
    await C.p.waitForSelector('#syncNowBtn');
    await synced(C.p);
    await tab(C.p, 'personal');
    assert((await C.p.textContent('.tx-list')).includes('Gas'), "Tosve's personal entry");
    await tab(C.p, 'house');
    assert(await C.p.locator('.tx').count() === 2);
    const names = await C.p.evaluate(() => JSON.parse(localStorage['budget.v1']).categories.map((c) => c.spaceId + c.name + c.kind));
    assert(names.length === new Set(names).size, 'no duplicate categories');
    assert(C.p.errors.length === 0, C.p.errors.join(' | '));
    await C.ctx.close();
  });

  await check('screens fit (no sideways scrolling) and no script errors', async () => {
    for (const { p } of [A, B]) {
      for (const t of ['personal', 'house', 'prices', 'settings']) {
        await tab(p, t);
        assert(!(await p.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1)), `overflow on ${t}`);
      }
      assert(p.errors.length === 0, p.errors.join(' | '));
    }
    if (SHOTS) { await tab(B.p, 'settings'); await B.p.screenshot({ path: `${SHOTS}/sync-settings-se.png` }); }
  });

  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
