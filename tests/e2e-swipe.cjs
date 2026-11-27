// Swipe down to close the add screen and other sheets, with real touch events on iPhone sizes.
// Run: python3 -m http.server 8123 & node tests/e2e-swipe.cjs
const { chromium, devices } = require('playwright');
const APP = process.env.APP_URL || 'http://localhost:8123/';
let pass = 0, fail = 0; const results = [];
async function check(name, fn) {
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n').slice(0, 3).join('\n    ')}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }

(async () => {
  const browser = await chromium.launch();
  async function phone(device = 'iPhone 15') {
    const ctx = await browser.newContext({ ...devices[device], locale: 'sl-SI' });
    const p = await ctx.newPage(); p.setDefaultTimeout(8000);
    p.errors = []; p.on('pageerror', (e) => p.errors.push(e.message));
    await p.goto(APP);
    p.cdp = await ctx.newCDPSession(p);
    return { ctx, p };
  }
  // A finger drag from (x, y) by (dx, dy) over `ms` milliseconds.
  async function drag(p, x, y, dx, dy, ms = 250, steps = 12) {
    await p.cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
    for (let i = 1; i <= steps; i++) {
      await p.cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x + dx * i / steps, y: y + dy * i / steps }] });
      await p.waitForTimeout(ms / steps);
    }
    await p.cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await p.waitForTimeout(400);
  }
  const sheetOpen = (p) => p.evaluate(() => document.querySelector('#sheet').open);
  const sheetTop = (p) => p.evaluate(() => { const r = document.querySelector('#sheet').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + 30 }; });
  async function openAdd(p) {
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount');
  }

  for (const device of ['iPhone SE', 'iPhone 15', 'iPhone 15 Pro Max']) {
    await check(`${device}: swiping the add screen down closes it without saving`, async () => {
      const { ctx, p } = await phone(device);
      await openAdd(p);
      await p.fill('#amount', '4,20');
      const t = await sheetTop(p);
      await drag(p, t.x, t.y, 0, 300);
      assert(!(await sheetOpen(p)), 'still open');
      assert(!(await p.textContent('main')).includes('4,20'), 'entry was saved');
      await openAdd(p); // opens normally again, in place
      const r = await p.evaluate(() => ({ tr: document.querySelector('#sheet').style.transform, top: document.querySelector('#sheet').getBoundingClientRect().bottom <= innerHeight + 1 }));
      assert(!r.tr && r.top, 'sheet not back in place: ' + JSON.stringify(r));
      assert(!p.errors.length, p.errors.join(' | '));
      await ctx.close();
    });
  }

  await check('a short slow drag springs back and keeps what you typed', async () => {
    const { ctx, p } = await phone();
    await openAdd(p);
    await p.fill('#amount', '3,10');
    const t = await sheetTop(p);
    await drag(p, t.x, t.y, 0, 50, 600);
    assert(await sheetOpen(p), 'closed on a short drag');
    assert((await p.inputValue('#amount')) === '3,10', 'typed text lost');
    assert(await p.evaluate(() => !document.querySelector('#sheet').style.transform), 'did not spring back');
    await ctx.close();
  });

  await check('a quick flick closes it', async () => {
    const { ctx, p } = await phone();
    await openAdd(p);
    const t = await sheetTop(p);
    await drag(p, t.x, t.y, 0, 90, 0, 3); // 90 px in about 0.15 s (each simulated move takes ~50 ms)
    assert(!(await sheetOpen(p)), 'flick did not close');
    await ctx.close();
  });

  await check('dragging down while the screen is scrolled scrolls it instead of closing', async () => {
    const { ctx, p } = await phone('iPhone SE');
    await openAdd(p);
    const scrolls = await p.evaluate(() => { const s = document.querySelector('#sheet'); s.scrollTop = 120; return s.scrollTop > 0; });
    assert(scrolls, 'add screen does not scroll on iPhone SE (test setup)');
    const t = await sheetTop(p);
    await drag(p, t.x, t.y + 100, 0, 200);
    assert(await sheetOpen(p), 'closed while scrolled');
    await ctx.close();
  });

  await check('swiping the category chips sideways does not close the screen', async () => {
    const { ctx, p } = await phone();
    await openAdd(p);
    const c = await p.locator('[data-chip]').first().boundingBox();
    await drag(p, c.x + c.width / 2 + 150, c.y + c.height / 2, -150, 20);
    assert(await sheetOpen(p), 'closed on a sideways swipe');
    await ctx.close();
  });

  await check('Cancel and tapping outside still close it; the category screen swipes closed too', async () => {
    const { ctx, p } = await phone();
    await openAdd(p);
    await p.click('[data-close]');
    assert(!(await sheetOpen(p)), 'Cancel did not close');
    await p.click('[data-tab=settings]');
    await p.locator('[data-addcat][data-kind=expense]').first().click();
    await p.waitForSelector('#catName');
    const t = await sheetTop(p);
    await drag(p, t.x, t.y, 0, 300);
    assert(!(await sheetOpen(p)), 'category screen did not close');
    assert(!p.errors.length, p.errors.join(' | '));
    await ctx.close();
  });

  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
