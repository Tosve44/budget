// iPhone Duo (Apple's foldable, 2026): the cover screen and the unfolded inner screen, upright
// and sideways, and switching between them while the app is open.
// Sizes from Apple's tech specs (support.apple.com/en-us/148588):
//   cover 5.4" 1398×2034 px at 460 ppi, inner 7.6" 1878×2670 px at 430 ppi.
// Playwright has no iPhone Duo profile yet, so screen sizes in points are worked out here:
// cover at 3× (466×678); the inner screen is tried at 3× (626×890) and, in case Apple uses a
// smaller scale for it, at 2.5× (751×1068) too.
// Run: python3 -m http.server 8123 & node tests/e2e-duo.cjs
const { chromium, devices } = require('playwright');

const APP = process.env.APP_URL || 'http://localhost:8123/';
const SB_URL = process.env.SUPABASE_URL || 'http://localhost:54321';
const SHOTS = process.env.SHOTS || null;
let pass = 0, fail = 0;
const results = [];
async function check(name, fn) {
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n').slice(0, 3).join('\n    ')}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }

const SCREENS = {
  'cover upright': { width: 466, height: 678, scale: 3 },
  'cover sideways': { width: 678, height: 466, scale: 3 },
  'unfolded upright': { width: 626, height: 890, scale: 3 },
  'unfolded sideways': { width: 890, height: 626, scale: 3 },
  'unfolded upright (2.5×)': { width: 751, height: 1068, scale: 2.5 },
  'unfolded sideways (2.5×)': { width: 1068, height: 751, scale: 2.5 },
};

(async () => {
  const key = (await (await fetch(`${SB_URL}/__test/anon-key`)).json()).key;
  const browser = await chromium.launch();
  const base = devices['iPhone 15 Pro Max']; // same browser (Safari) and touch behaviour
  async function phone(screen, extra = {}) {
    const s = SCREENS[screen];
    const ctx = await browser.newContext({ ...base, viewport: { width: s.width, height: s.height }, screen: { width: s.width, height: s.height }, deviceScaleFactor: s.scale, locale: 'sl-SI', timezoneId: 'Europe/Ljubljana', ...extra });
    await ctx.addInitScript(([u, k]) => localStorage.setItem('budget.config.override', JSON.stringify({ supabaseUrl: u, supabaseAnonKey: k })), [SB_URL, key]);
    const p = await ctx.newPage();
    p.setDefaultTimeout(8000);
    p.errors = [];
    p.on('pageerror', (e) => p.errors.push(e.message));
    await p.goto(APP);
    return { ctx, p };
  }
  const tab = (p, t) => p.click(`[data-tab=${t}]`);
  const closed = (p) => p.waitForFunction(() => !document.querySelector('#sheet').open);
  const resize = async (p, screen) => { const s = SCREENS[screen]; await p.setViewportSize({ width: s.width, height: s.height }); await p.waitForTimeout(150); };
  // Everything that must be on screen and usable: no sideways scrolling, tab bar at the bottom
  // edge, + button inside the screen, nothing cut off, the add screen fits.
  async function layoutProblems(p, where) {
    const probs = [];
    for (const t of ['personal', 'house', 'prices', 'settings']) {
      await tab(p, t);
      const r = await p.evaluate(() => {
        const vw = innerWidth, vh = innerHeight;
        const bar = document.querySelector('.tabbar').getBoundingClientRect();
        const fab = document.querySelector('#addBtn');
        const f = fab.getBoundingClientRect();
        const clipped = [...document.querySelectorAll('button, .tx-cat, .cat-name, .stat .val, h1, .big')].filter((e) => e.offsetParent && e.scrollWidth > e.clientWidth + 2 && getComputedStyle(e).textOverflow !== 'ellipsis').map((e) => (e.id || e.textContent).trim().slice(0, 16));
        return {
          sideways: document.documentElement.scrollWidth > vw + 1,
          barOk: Math.abs(bar.bottom - vh) < 2 && bar.width >= vw - 1,
          fabOk: fab.classList.contains('hidden') || (f.right <= vw && f.bottom <= bar.top && f.left >= 0),
          clipped,
        };
      });
      if (r.sideways) probs.push(`${t}: scrolls sideways`);
      if (!r.barOk) probs.push(`${t}: tab bar not along the bottom`);
      if (!r.fabOk) probs.push(`${t}: + button off screen or under the tab bar`);
      if (r.clipped.length) probs.push(`${t}: cut off ${r.clipped.slice(0, 3).join(', ')}`);
    }
    await tab(p, 'house');
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount');
    const s = await p.evaluate(() => { const d = document.querySelector('#sheet'); const r = d.getBoundingClientRect(); return { sideways: d.scrollWidth > d.clientWidth + 1, inside: r.top >= 0 && r.bottom <= innerHeight + 1 && r.left >= 0 && r.right <= innerWidth + 1 }; });
    if (s.sideways) probs.push('add screen scrolls sideways');
    if (!s.inside) probs.push('add screen runs off the screen');
    await p.locator('#saveTx2').scrollIntoViewIfNeeded();
    if (!(await p.locator('#saveTx2').isVisible())) probs.push('Save not reachable');
    await p.click('[data-close]'); await closed(p);
    if (SHOTS) { await tab(p, 'personal'); await p.screenshot({ path: `${SHOTS}/duo-${where.replace(/\W+/g, '-')}.png` }); }
    return probs;
  }

  for (const screen of Object.keys(SCREENS)) {
    await check(`iPhone Duo ${screen}: every tab and the add screen fit and work`, async () => {
      const { ctx, p } = await phone(screen);
      await p.click('#addBtn');
      await p.waitForFunction(() => document.activeElement?.id === 'amount');
      await p.fill('#amount', '12,50');
      await p.locator('[data-chip]', { hasText: 'Groceries' }).first().click();
      await p.fill('#note', 'duo');
      await p.click('#saveTx2'); await closed(p);
      assert((await p.textContent('main')).includes('duo'), 'entry shown');
      const probs = await layoutProblems(p, screen);
      assert(!p.errors.length, p.errors.join(' | '));
      await ctx.close();
      assert(!probs.length, probs.join('; '));
    });
  }

  await check('unfolding and folding while adding an entry keeps what you typed and the layout adapts', async () => {
    const { ctx, p } = await phone('cover upright');
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount');
    await p.fill('#amount', '7,40');
    await p.locator('[data-chip]', { hasText: 'Gas' }).first().click();
    await p.fill('#note', 'mid-unfold');
    await resize(p, 'unfolded upright');
    assert(await p.evaluate(() => document.querySelector('#sheet').open), 'add screen closed on unfolding');
    assert((await p.inputValue('#amount')) === '7,40' && (await p.inputValue('#note')) === 'mid-unfold', 'typed text lost');
    assert(await p.$eval('[data-chip].on', (b) => b.textContent.includes('Gas')), 'chosen category lost');
    await resize(p, 'unfolded sideways');
    await resize(p, 'cover sideways');
    await resize(p, 'cover upright');
    await p.click('#saveTx2'); await closed(p);
    assert((await p.textContent('main')).includes('mid-unfold'), 'entry saved after folding back');
    const probs = [];
    for (const s of ['unfolded upright', 'unfolded sideways', 'cover sideways', 'cover upright']) {
      await resize(p, s);
      probs.push(...(await layoutProblems(p, `switch-${s}`)).map((x) => `${s}: ${x}`));
    }
    assert(!p.errors.length, p.errors.join(' | '));
    await ctx.close();
    assert(!probs.length, probs.join('; '));
  });

  await check('folding with the category screen or icon picker open keeps it usable', async () => {
    const { ctx, p } = await phone('unfolded upright');
    await tab(p, 'settings');
    await p.locator('[data-addcat][data-kind=expense]').first().click();
    await p.fill('#catName', 'Fold test');
    await p.click('[data-icon="🐶"]');
    await resize(p, 'cover upright');
    const r = await p.evaluate(() => ({ name: document.querySelector('#catName').value, chosen: document.querySelector('[data-icon].on')?.dataset.icon, sideways: document.querySelector('#sheet').scrollWidth > document.querySelector('#sheet').clientWidth + 1 }));
    assert(r.name === 'Fold test' && r.chosen === '🐶' && !r.sideways, JSON.stringify(r));
    await p.click('#saveCat2'); await closed(p);
    assert((await p.locator('.set-list li', { hasText: 'Fold test' }).textContent()).includes('🐶'));
    await ctx.close();
  });

  await check('large text and dark mode on the cover screen', async () => {
    const { ctx, p } = await phone('cover upright', { colorScheme: 'dark' });
    await p.addStyleTag({ content: 'html { font-size: 24px !important; }' });
    const probs = await layoutProblems(p, 'cover-bigtext-dark');
    await ctx.close();
    assert(!probs.length, probs.join('; '));
  });

  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
