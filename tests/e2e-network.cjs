// Bad internet and two phones changing the same things, with the real app screens.
// Uses the local test server (tests/backend/fake-supabase.cjs).
// Run: python3 -m http.server 8123 & node tests/e2e-network.cjs
const { chromium, devices } = require('playwright');

const APP = process.env.APP_URL || 'http://localhost:8123/';
const SB_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const run = Date.now().toString(36);
let pass = 0, fail = 0;
const results = [];
async function check(name, fn) {
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n').slice(0, 2).join('\n    ')}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const key = (await (await fetch(`${SB_URL}/__test/anon-key`)).json()).key;
  const browser = await chromium.launch();
  async function phone(device) {
    const ctx = await browser.newContext({ ...devices[device], locale: 'sl-SI', timezoneId: 'Europe/Ljubljana' });
    await ctx.addInitScript(([u, k]) => localStorage.setItem('budget.config.override', JSON.stringify({ supabaseUrl: u, supabaseAnonKey: k })), [SB_URL, key]);
    const p = await ctx.newPage();
    p.setDefaultTimeout(15000);
    p.errors = [];
    p.on('pageerror', (e) => p.errors.push(e.message));
    await p.goto(APP);
    return { ctx, p };
  }
  const tab = (p, t) => p.click(`[data-tab=${t}]`);
  const closed = (p) => p.waitForFunction(() => !document.querySelector('#sheet').open);
  const who = (p) => p.textContent('#who');
  const synced = (p, timeout = 30000) => p.waitForFunction(() => / · synced$/.test(document.querySelector('#who').textContent), null, { timeout });
  const syncNow = async (p) => { await p.evaluate(() => window.dispatchEvent(new Event('online'))); await synced(p); };
  const store = (p) => p.evaluate(() => window.__budgetStore.data);
  const house = async (p) => { const d = await store(p); const h = d.spaces.find((s) => s.type === 'house'); return { d, h, txs: d.transactions.filter((t) => t.spaceId === h.id), cats: d.categories.filter((c) => c.spaceId === h.id) }; };
  const addEntry = async (p, { amount, cat = 'Groceries', note }) => {
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount'); // the app focuses it right after opening
    await p.fill('#amount', amount);
    await p.locator('[data-chip]', { hasText: cat }).first().click();
    if (note) await p.fill('#note', note);
    await p.click('#saveTx2');
    await closed(p);
  };
  const editNote = async (p, from, to) => {
    await tab(p, 'house');
    await p.locator('.tx', { hasText: from }).first().locator('button').click();
    await p.fill('#note', to);
    await p.click('#saveTx2');
    await closed(p);
  };

  const A = await phone('iPhone 13');
  const B = await phone('iPhone SE');

  // Pair the two phones.
  await tab(A.p, 'settings');
  await A.p.fill('#authEmail', `test-net-a-${run}@example.com`);
  await A.p.fill('#authPass', 'secret123');
  await A.p.click('#signUpBtn');
  await A.p.fill('#dispName', 'Tosve');
  await A.p.click('#createHh');
  const code = (await A.p.textContent('#inviteCode')).trim();
  await tab(B.p, 'settings');
  await B.p.click('[data-user=u_milica]');
  await B.p.fill('#authEmail', `test-net-b-${run}@example.com`);
  await B.p.fill('#authPass', 'secret456');
  await B.p.click('#signUpBtn');
  await B.p.fill('#dispName', 'Milica');
  await B.p.fill('#joinCode', code);
  await B.p.click('#joinHh');
  await synced(B.p);
  await tab(A.p, 'house'); await tab(B.p, 'house');

  await check('slow mobile internet (3G): the app opens and an entry syncs', async () => {
    const { ctx, p } = await phone('iPhone 13');
    const cdp = await ctx.newCDPSession(p);
    await cdp.send('Network.enable');
    await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 400, downloadThroughput: 400 * 1024 / 8, uploadThroughput: 400 * 1024 / 8 });
    const t0 = Date.now();
    await p.goto(APP + '?slow');
    await p.waitForSelector('.tabbar');
    const tOpen = Date.now() - t0;
    await tab(p, 'settings');
    await p.fill('#authEmail', `test-net-a-${run}@example.com`);
    await p.fill('#authPass', 'secret123');
    await p.click('#signInBtn');
    await p.waitForSelector('#syncNowBtn', { timeout: 60000 });
    await synced(p, 60000);
    const tSignIn = Date.now() - t0;
    await tab(p, 'house');
    await addEntry(p, { amount: '3,10', note: 'slow 3G' });
    await synced(p, 60000);
    await ctx.close();
    await syncNow(B.p);
    assert((await house(B.p)).txs.some((t) => t.note === 'slow 3G'), 'arrived on the other phone');
    results.push(`    (first open on 3G ${(tOpen / 1000).toFixed(1)} s, signed in and synced after ${(tSignIn / 1000).toFixed(1)} s)`);
    assert(tOpen < 15000, `took ${tOpen} ms to open`);
  });

  await check('a request that never answers (bad Wi-Fi) does not leave the app stuck on "syncing" forever', async () => {
    let hang = true;
    const held = [];
    await A.ctx.route(`${SB_URL}/rest/**`, (route) => { if (hang) held.push(route); else route.continue(); });
    await addEntry(A.p, { amount: '1', note: 'during hang' });
    // The app should give up on the stuck request, say it is offline, and try again later.
    await A.p.waitForFunction(() => / · offline$/.test(document.querySelector('#who').textContent), null, { timeout: 60000 });
    hang = false;
    await A.ctx.unroute(`${SB_URL}/rest/**`);
    held.forEach((r) => r.abort().catch(() => {}));
    await syncNow(A.p);
    await syncNow(B.p);
    assert((await house(B.p)).txs.some((t) => t.note === 'during hang'), 'entry arrived after the network came back');
  });

  await check('flaky internet (a third of requests fail): nothing is lost and nothing doubles', async () => {
    let flaky = true;
    for (const X of [A, B]) {
      await X.ctx.route(`${SB_URL}/**`, (route) => (flaky && Math.random() < 0.33 ? route.abort('connectionreset') : route.continue()));
    }
    for (let i = 0; i < 8; i++) {
      await addEntry(A.p, { amount: String(10 + i), note: `flakyA${i}` });
      await addEntry(B.p, { amount: String(20 + i), note: `flakyB${i}` });
      await A.p.evaluate(() => window.dispatchEvent(new Event('online')));
      await B.p.evaluate(() => window.dispatchEvent(new Event('online')));
    }
    await sleep(3000);
    flaky = false;
    for (const X of [A, B]) await X.ctx.unroute(`${SB_URL}/**`);
    await syncNow(A.p); await syncNow(B.p); await syncNow(A.p);
    for (const X of [A, B]) {
      const notes = (await house(X.p)).txs.map((t) => t.note).filter((n) => n.startsWith('flaky'));
      assert(notes.length === 16 && new Set(notes).size === 16, `${notes.length} flaky entries (${new Set(notes).size} different) on one phone`);
    }
  });

  await check('both phones offline edit the same entry: the later edit wins on both phones', async () => {
    await addEntry(A.p, { amount: '5', note: 'conflict' });
    await synced(A.p); await syncNow(B.p);
    await A.ctx.setOffline(true); await B.ctx.setOffline(true);
    await editNote(A.p, 'conflict', 'conflict A');
    await sleep(50);
    await editNote(B.p, 'conflict', 'conflict B (later)');
    await A.ctx.setOffline(false); await B.ctx.setOffline(false);
    await syncNow(A.p); await syncNow(B.p); await syncNow(A.p);
    for (const X of [A, B]) {
      const notes = (await house(X.p)).txs.map((t) => t.note).filter((n) => n.startsWith('conflict'));
      assert(notes.length === 1 && notes[0] === 'conflict B (later)', JSON.stringify(notes));
    }
  });

  await check('one phone deletes an entry while the other edits it offline: both phones end up the same', async () => {
    await addEntry(A.p, { amount: '6', note: 'del-vs-edit' });
    await synced(A.p); await syncNow(B.p);
    await A.ctx.setOffline(true); await B.ctx.setOffline(true);
    await editNote(B.p, 'del-vs-edit', 'del-vs-edit edited');
    await sleep(50);
    await tab(A.p, 'house');
    await A.p.locator('.tx', { hasText: 'del-vs-edit' }).locator('button').click();
    await A.p.click('#delTx');
    await closed(A.p);
    await A.ctx.setOffline(false); await B.ctx.setOffline(false);
    await syncNow(B.p); await syncNow(A.p); await syncNow(B.p);
    const a = (await house(A.p)).txs.filter((t) => t.note.startsWith('del-vs-edit')).length;
    const b = (await house(B.p)).txs.filter((t) => t.note.startsWith('del-vs-edit')).length;
    assert(a === b && a === 0, `Tosve's phone has ${a}, Milica's has ${b} (the later delete should win)`);
  });

  await check('both phones add a House category with the same name while offline: it ends up as one', async () => {
    await A.ctx.setOffline(true); await B.ctx.setOffline(true);
    for (const X of [A, B]) {
      await tab(X.p, 'settings');
      await X.p.locator('[data-addcat][data-kind=expense]').last().click();
      await X.p.fill('#catName', 'Pets');
      await X.p.click('#saveCat2');
      await closed(X.p);
      await tab(X.p, 'house');
      await addEntry(X.p, { amount: '7', cat: 'Pets', note: `pets-${X === A ? 'A' : 'B'}` });
    }
    await A.ctx.setOffline(false); await B.ctx.setOffline(false);
    await syncNow(A.p); await syncNow(B.p); await syncNow(A.p); await syncNow(B.p);
    for (const X of [A, B]) {
      const h = await house(X.p);
      const pets = h.cats.filter((c) => c.name === 'Pets' && !c.archived);
      assert(pets.length === 1, `${pets.length} "Pets" categories`);
      const entries = h.txs.filter((t) => t.note.startsWith('pets-'));
      assert(entries.length === 2 && entries.every((t) => t.categoryId === pets[0].id), 'both entries under the one category');
    }
  });

  await check('a category hidden on one phone while the other adds to it: the entry is kept on both', async () => {
    await A.ctx.setOffline(true); await B.ctx.setOffline(true);
    await tab(A.p, 'settings');
    await A.p.locator('.set-list li', { hasText: 'Travel' }).last().locator('[data-editcat]').click();
    await A.p.click('#archCat');
    await closed(A.p);
    await tab(B.p, 'house');
    await addEntry(B.p, { amount: '80', cat: 'Travel', note: 'train' });
    await A.ctx.setOffline(false); await B.ctx.setOffline(false);
    await syncNow(A.p); await syncNow(B.p); await syncNow(A.p);
    for (const X of [A, B]) assert((await house(X.p)).txs.some((t) => t.note === 'train'), 'entry lost');
    await tab(A.p, 'house');
    assert((await A.p.textContent('main')).includes('train'), 'entry shown on the phone that hid the category');
  });

  await check('the phone clock being wrong (an hour behind) does not lose changes', async () => {
    await B.p.evaluate(() => { const real = Date.now; const off = -3600e3; Date.now = () => real() + off; const R = Date; window.Date = class extends R { constructor(...a) { if (a.length) super(...a); else super(real() + off); } static now() { return real() + off; } }; });
    await tab(B.p, 'house');
    await addEntry(B.p, { amount: '2', note: 'clock behind' });
    await synced(B.p); await syncNow(A.p);
    assert((await house(A.p)).txs.some((t) => t.note === 'clock behind'), 'entry from the phone with a wrong clock did not arrive');
  });

  await check('no script errors on either phone', async () => {
    for (const X of [A, B]) assert(X.p.errors.length === 0, X.p.errors.join(' | '));
  });

  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
