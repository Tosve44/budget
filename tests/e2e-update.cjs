// A new version reaches a phone that already has the app: the server is set up like GitHub
// Pages (phones may keep files for 10 minutes), the app is opened, a new version is put on
// the server, and the app comes back to the screen as when you switch back to it on iPhone.
// Run: node tests/e2e-update.cjs
const { chromium, devices } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path'), os = require('os');

let pass = 0, fail = 0; const results = [];
async function check(name, fn) {
  try { await fn(); pass++; results.push(`✓ ${name}`); }
  catch (e) { fail++; results.push(`✗ ${name}\n    ${String(e.message).split('\n').slice(0, 3).join('\n    ')}`); }
}
function assert(c, msg) { if (!c) throw new Error(msg || 'assertion failed'); }

const SRC = path.join(__dirname, '..');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json', '.json': 'application/json' };
function copyApp(dir) {
  for (const f of fs.readdirSync(SRC)) {
    if (/\.(html|js|css|webmanifest)$/.test(f)) fs.copyFileSync(path.join(SRC, f), path.join(dir, f));
  }
  fs.cpSync(path.join(SRC, 'icons'), path.join(dir, 'icons'), { recursive: true });
  fs.cpSync(path.join(SRC, 'vendor'), path.join(dir, 'vendor'), { recursive: true, force: true });
}
function serve(dir, port) {
  const srv = http.createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    const f = path.join(dir, p);
    if (!f.startsWith(dir) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'content-type': TYPES[path.extname(f)] || 'application/octet-stream', 'cache-control': 'max-age=600', 'last-modified': fs.statSync(f).mtime.toUTCString() });
    fs.createReadStream(f).pipe(res);
  });
  return new Promise((r) => srv.listen(port, () => r(srv)));
}
// Put a "new version" on the server: new cache name and a marker the page shows.
function publishNewVersion(dir, n) {
  const sw = path.join(dir, 'sw.js');
  fs.writeFileSync(sw, fs.readFileSync(sw, 'utf8').replace(/const VERSION = '[^']+'/, `const VERSION = 'budget-test-${n}'`));
  fs.appendFileSync(path.join(dir, 'app.js'), `\nwindow.__testVersion = ${n};\n`);
}
const backToScreen = (p) => p.evaluate(() => {
  Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
  document.dispatchEvent(new Event('visibilitychange'));
});

(async () => {
  const browser = await chromium.launch();
  const base = devices['iPhone 15'];
  async function freshPhone(port) {
    const ctx = await browser.newContext({ ...base, locale: 'sl-SI' });
    const p = await ctx.newPage(); p.setDefaultTimeout(10000);
    p.errors = []; p.on('pageerror', (e) => p.errors.push(e.message));
    await p.goto(`http://localhost:${port}/`);
    await p.evaluate(() => navigator.serviceWorker.ready);
    await p.waitForFunction(() => !!navigator.serviceWorker.controller);
    await p.reload(); // a second open, now fully through the saved copy
    await p.waitForFunction(() => !!navigator.serviceWorker.controller);
    return { ctx, p };
  }

  await check('a new version shows up when the app comes back to the screen', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upd-')); copyApp(dir);
    const srv = await serve(dir, 8131);
    const { ctx, p } = await freshPhone(8131);
    assert(await p.evaluate(() => window.__testVersion === undefined), 'starts on the old version');
    publishNewVersion(dir, 2);
    await backToScreen(p);
    await p.waitForFunction(() => window.__testVersion === 2, null, { timeout: 15000 });
    assert(!p.errors.length, p.errors.join(' | '));
    await ctx.close(); srv.close();
  });

  await check('a new version that arrives while adding an entry waits until the add screen closes', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upd-')); copyApp(dir);
    const srv = await serve(dir, 8132);
    const { ctx, p } = await freshPhone(8132);
    await p.click('#addBtn');
    await p.waitForFunction(() => document.activeElement?.id === 'amount');
    await p.fill('#amount', '9,99');
    publishNewVersion(dir, 3);
    await backToScreen(p);
    await p.waitForTimeout(3000); // new version installs in the background
    assert(await p.evaluate(() => document.querySelector('#sheet').open && window.__testVersion === undefined), 'reloaded while typing');
    assert((await p.inputValue('#amount')) === '9,99', 'typed amount lost');
    await p.locator('[data-chip]').first().click();
    await p.click('#saveTx2');
    await p.waitForFunction(() => window.__testVersion === 3, null, { timeout: 15000 });
    await p.waitForSelector('main');
    assert((await p.textContent('main')).includes('9,99'), 'entry saved before the update loaded');
    await ctx.close(); srv.close();
  });

  await check('opening the app for the first time does not reload it', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upd-')); copyApp(dir);
    const srv = await serve(dir, 8133);
    const ctx = await browser.newContext({ ...base });
    const p = await ctx.newPage();
    let loads = 0; p.on('load', () => loads++);
    await p.goto('http://localhost:8133/');
    await p.evaluate(() => navigator.serviceWorker.ready);
    await p.waitForTimeout(1500);
    assert(loads === 1, `loaded ${loads} times`);
    await ctx.close(); srv.close();
  });

  await check('still opens with no internet after an update', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'upd-')); copyApp(dir);
    const srv = await serve(dir, 8134);
    const { ctx, p } = await freshPhone(8134);
    publishNewVersion(dir, 4);
    await backToScreen(p);
    await p.waitForFunction(() => window.__testVersion === 4, null, { timeout: 15000 });
    await ctx.setOffline(true);
    await p.reload();
    await p.waitForSelector('[data-tab=personal]');
    assert(await p.evaluate(() => window.__testVersion === 4), 'offline copy is the new version');
    await ctx.close(); srv.close();
  });

  await browser.close();
  console.log(results.join('\n'));
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
