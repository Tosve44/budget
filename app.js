import { Store, LIMITS, categoryIcon, ICON_CHOICES, toCents, monthKey, todayKey, shiftMonth, uid, normalizeItem, pricePerUnit, cleanItem, storeTrend, sameStore } from './store.js';
import { putPhoto, getPhoto, deletePhoto, compressImage } from './photos.js';
import { readReceiptText, parseReceipt, findTotal, findStore } from './receipt.js';
import { startCloud, loadPhoto } from './cloud.js';

const store = new Store();
window.__budgetStore = store; // lets the automated tests simulate sync events
const state = { tab: 'personal', month: monthKey(), filterCat: null };
let sync = null; // set when the app is connected to Supabase (see cloud.js)

const $ = (sel, root = document) => root.querySelector(sel);
const view = $('#view');
const sheet = $('#sheet');

const CURRENCIES = ['EUR', 'RSD', 'BAM', 'USD', 'CHF', 'GBP'];
const RECEIPT_LANGS = [['slv+eng', 'Slovenian'], ['eng', 'English'], ['srp_latn+eng', 'Serbian (Latin)'], ['srp+eng', 'Serbian (Cyrillic)']];

function pctChange(now, before) {
  if (!before) return null;
  return Math.round(((now - before) / before) * 1000) / 10;
}
function changeBadge(p) {
  if (p === null) return '<span class="badge new">new</span>';
  if (p === 0) return '<span class="badge same">same</span>';
  return `<span class="badge ${p > 0 ? 'up' : 'down'}">${p > 0 ? '▲ +' : '▼ '}${p}%</span>`;
}

// ---------- formatting ----------
// The category's icon, hidden from screen readers (the name is read instead).
const ico = (cat) => `<span class="cat-ico" aria-hidden="true">${esc(categoryIcon(cat))}</span>`;
function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function money(cents, { sign = false } = {}) {
  const cur = store.data.settings.currency || 'EUR';
  let s;
  try {
    s = new Intl.NumberFormat(undefined, { style: 'currency', currency: cur, minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 }).format(cents / 100);
  } catch { s = `${(cents / 100).toFixed(2)} ${cur}`; }
  return sign && cents > 0 ? `+${s}` : s;
}
function centsToInput(cents) { return cents ? (cents / 100).toString() : ''; }
function monthLabel(month) {
  const [y, m] = month.split('-').map(Number);
  const s = new Date(y, m - 1, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  return s.charAt(0).toUpperCase() + s.slice(1);
}
function dayLabel(date) {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
}
function toast(msg) {
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 1800);
}

// ---------- light / dark look (per phone, not synced) ----------
function theme() {
  try { const t = localStorage.getItem('budget.theme'); return t === 'light' || t === 'dark' ? t : 'system'; } catch { return 'system'; }
}
function setTheme(t) {
  try { if (t === 'system') localStorage.removeItem('budget.theme'); else localStorage.setItem('budget.theme', t); } catch {}
  if (t === 'system') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = t;
  applyThemeColor();
}
// The colour of the iPhone status bar area follows the chosen look.
function applyThemeColor() {
  const t = theme();
  document.querySelectorAll('meta[name=theme-color]').forEach((m) => {
    if (!m.dataset.media) m.dataset.media = m.getAttribute('media') || '';
    if (t === 'system') m.setAttribute('media', m.dataset.media);
    else m.setAttribute('media', m.dataset.media.includes(t) ? 'all' : 'not all');
  });
}
applyThemeColor();

// ---------- current space ----------
function currentSpace() {
  return state.tab === 'house' ? store.houseSpace() : store.personalSpace();
}

// ---------- rendering ----------
function render() {
  document.querySelectorAll('.tabbar button').forEach((b) => b.classList.toggle('active', b.dataset.tab === state.tab));
  $('#who').textContent = store.currentUser.name + syncBadge();
  const isSettings = state.tab === 'settings' || state.tab === 'prices';
  $('#monthBar').classList.toggle('hidden', isSettings);
  $('#addBtn').classList.toggle('hidden', isSettings);
  $('#monthLabel').textContent = monthLabel(state.month);
  if (state.tab === 'prices') { $('#title').textContent = 'Prices'; renderPrices(); }
  else if (isSettings) { $('#title').textContent = 'Settings'; renderSettings(); }
  else { $('#title').textContent = state.tab === 'house' ? 'House' : 'Personal'; renderSpace(currentSpace()); }
}

function renderSpace(space) {
  const sum = store.monthSummary(space.id, state.month);
  const left = sum.budget - sum.spent;
  const cats = store.categories(space.id);
  const expenseCats = cats.filter((c) => c.kind === 'expense');
  const incomeCats = cats.filter((c) => c.kind === 'income');
  const pct = sum.budget ? Math.min(100, (sum.spent / sum.budget) * 100) : 0;
  const barClass = sum.budget && sum.spent > sum.budget ? 'over' : pct > 85 ? 'warn' : '';

  const summary = sum.budget
    ? `<div class="summary-main">
        <div><div class="sub">${left >= 0 ? 'Left this month' : 'Over budget'}</div>
        <div class="big ${left < 0 ? 'over' : ''}">${money(Math.abs(left))}</div></div>
        <div class="sub">${Math.round((sum.spent / sum.budget) * 100)}% of ${money(sum.budget)}</div>
      </div>
      <div class="bar ${barClass}"><i style="width:${pct}%"></i></div>`
    : `<div class="sub">Spent this month</div><div class="big">${money(sum.spent)}</div>
       <p class="note">No monthly budget set yet. Add one per category in Settings.</p>`;
  const balance = sum.income - sum.spent;

  const catRow = (c) => {
    const spent = sum.byCategory.get(c.id) || 0;
    const p = c.budget ? Math.min(100, (spent / c.budget) * 100) : 0;
    const cls = c.budget && spent > c.budget ? 'over' : p > 85 ? 'warn' : '';
    const right = c.kind === 'expense' && c.budget
      ? `${money(spent)} <small>/ ${money(c.budget)}</small>`
      : money(spent);
    return `<li class="cat-row ${state.filterCat === c.id ? 'selected' : ''}"><button data-cat="${esc(c.id)}">
      <div class="cat-top"><span class="cat-name">${ico(c)}${esc(c.name)}</span><span class="cat-amt">${right}</span></div>
      ${c.kind === 'expense' && c.budget ? `<div class="bar ${cls}"><i style="width:${p}%"></i></div>` : ''}
    </button></li>`;
  };

  // Only show categories that have a budget or activity this month, to keep the list short.
  const activeExpense = expenseCats.filter((c) => c.budget || sum.byCategory.has(c.id));
  const activeIncome = incomeCats.filter((c) => sum.byCategory.has(c.id));

  let txs = store.transactions(space.id, state.month);
  const filterCat = state.filterCat && store.category(state.filterCat);
  if (filterCat) txs = txs.filter((t) => t.categoryId === filterCat.id);

  const showWho = space.type === 'house';
  const txRows = txs.map((t) => {
    const c = store.category(t.categoryId);
    const meta = [dayLabel(t.date), t.store, t.items?.length ? `🧾 ${t.items.length} items` : (t.receiptId ? '🧾' : null), t.note, showWho ? store.user(t.createdBy)?.name : null].filter(Boolean).map(esc).join(' · ');
    return `<li class="tx"><button data-tx="${esc(t.id)}">
      <div class="tx-main"><div class="tx-cat">${c ? ico(c) : ''}${esc(c ? c.name : 'Deleted category')}</div><div class="tx-meta">${meta}</div></div>
      <div class="tx-amt ${t.kind === 'income' ? 'income' : ''}">${t.kind === 'income' ? '+' : '−'}${money(t.amount)}</div>
    </button></li>`;
  }).join('');

  view.innerHTML = `
    <section class="card">${summary}
      <div class="stats">
        <button class="stat" data-add="income" aria-label="Income ${money(sum.income)}. Add income"><div class="label">Income ＋</div><div class="val income">${money(sum.income)}</div></button>
        <button class="stat" data-add="expense" aria-label="Spent ${money(sum.spent)}. Add expense"><div class="label">Spent ＋</div><div class="val">${money(sum.spent)}</div></button>
        <div class="stat" id="balance"><div class="label">Balance</div><div class="val ${balance < 0 ? 'over' : balance > 0 ? 'income' : ''}">${money(balance, { sign: true })}</div></div>
      </div>
    </section>
    <section class="card"><h2>Spending by category</h2>
      ${activeExpense.length ? `<ul class="cat-list">${activeExpense.map(catRow).join('')}</ul>` : '<p class="empty-note">Nothing spent yet this month.</p>'}
    </section>
    ${activeIncome.length ? `<section class="card"><h2>Income</h2><ul class="cat-list">${activeIncome.map(catRow).join('')}</ul></section>` : ''}
    <section class="card"><h2>${filterCat ? 'Entries' : 'All entries'}</h2>
      ${filterCat ? `<button class="filter-chip" id="clearFilter">${ico(filterCat)}${esc(filterCat.name)} ✕</button>` : ''}
      ${txRows ? `<ul class="tx-list">${txRows}</ul>` : '<p class="empty-note">No entries yet. Tap + to add one.</p>'}
    </section>`;

  view.querySelectorAll('[data-add]').forEach((b) => b.addEventListener('click', () => openTxSheet(null, { kind: b.dataset.add })));
  view.querySelectorAll('[data-cat]').forEach((b) => b.addEventListener('click', () => {
    state.filterCat = state.filterCat === b.dataset.cat ? null : b.dataset.cat;
    render();
  }));
  view.querySelectorAll('[data-tx]').forEach((b) => b.addEventListener('click', () => {
    openTxSheet(store.data.transactions.find((t) => t.id === b.dataset.tx));
  }));
  $('#clearFilter')?.addEventListener('click', () => { state.filterCat = null; render(); });
}

function syncBadge() {
  if (!sync?.connected) return '';
  if (sync.status.state === 'syncing') return ' · syncing…';
  if (sync.status.state === 'error') return ' · offline';
  if (sync.pendingCount()) return ' · saving…';
  return ' · synced';
}

function timeAgo(iso) {
  if (!iso) return 'never';
  const s = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  return new Date(iso).toLocaleString(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

// The "Share with your partner" card in Settings: sign in, then create or join a household.
function syncCardHtml() {
  const whoCard = `<section class="card"><h2>Who is using this phone</h2>
      <div class="users">${store.data.users.map((u) => `<button data-user="${esc(u.id)}" class="${u.id === store.currentUser.id ? 'on' : ''}">${esc(u.name)}</button>`).join('')}</div>
      <p class="note">${sync ? 'Pick your name before you sign in below.' : 'Data is saved only on this phone. Syncing between phones is not set up in this version.'}</p>
    </section>`;
  if (sync && !sync.connected) return whoCard + syncCardInner();
  if (!sync) return whoCard;
  return syncCardInner();
}

function syncCardInner() {
  if (!sync) {
    return `<section class="card"><h2>Who is using this phone</h2>
      <div class="users">${store.data.users.map((u) => `<button data-user="${esc(u.id)}" class="${u.id === store.currentUser.id ? 'on' : ''}">${esc(u.name)}</button>`).join('')}</div>
      <p class="note">Data is saved only on this phone. Syncing between phones is not set up in this version.</p>
    </section>`;
  }
  const st = state.syncUi || (state.syncUi = { step: 'signin' });
  if (sync.connected) {
    const partners = store.data.users.length;
    return `<section class="card" id="syncCard"><h2>Sharing with your partner</h2>
      <p style="margin:0 0 6px"><b>Signed in as ${esc(store.currentUser.name)}</b></p>
      <p class="note" style="margin:0 0 10px" id="syncLine">${sync.status.state === 'error' ? `Not synced: ${esc(sync.status.error || '')}` : `Last synced ${timeAgo(sync.status.lastSyncAt)}`}${sync.pendingCount() ? ` · ${sync.pendingCount()} change(s) waiting` : ''}</p>
      ${partners < 2 && store.data.settings.inviteCode ? `<div class="invite"><span>Invite code for your partner</span><b id="inviteCode">${esc(store.data.settings.inviteCode)}</b></div>
        <p class="note">Your partner opens the app, creates an account, taps “Join with a code” and enters this code.</p>` : `<p class="note">${esc(store.data.users.filter((u) => u.id !== store.currentUser.id).map((u) => u.name).join(', '))} sees the House space. Your Personal space is only on your phone and your account.</p>`}
      <button class="secondary" id="syncNowBtn">Sync now</button>
      <button class="secondary" id="signOutBtn">Sign out</button>
    </section>`;
  }
  const err = st.error ? `<p class="form-error" role="alert">${esc(st.error)}</p>` : '';
  const busy = st.busy ? 'disabled' : '';
  if (st.step === 'household') {
    return `<section class="card" id="syncCard"><h2>Sharing with your partner</h2>
      <p class="note" style="margin:0 0 10px">Signed in. Now start a household, or join your partner's with their code.</p>
      <label class="field"><span>Your name</span><input id="dispName" maxlength="40" value="${esc(st.name || store.currentUser.name || '')}" autocomplete="nickname"></label>
      ${err}
      <button class="primary" id="createHh" ${busy}>Start a new household</button>
      <p class="note" style="text-align:center;margin:10px 0">or</p>
      <label class="field"><span>Partner's invite code</span><input id="joinCode" placeholder="e.g. 4F7A21C9" autocapitalize="characters" autocomplete="off" value="${esc(st.code || '')}"></label>
      <button class="secondary" id="joinHh" ${busy}>Join with a code</button>
      <button class="secondary" id="signOutBtn">Sign out</button>
      <p class="note">Entries already on this phone are moved into your account.</p>
    </section>`;
  }
  return `<section class="card" id="syncCard"><h2>Sharing with your partner</h2>
    <p class="note" style="margin:0 0 10px">Sign in so the House space is shared between both phones. Your Personal space stays private to you.</p>
    <form id="authForm">
      <label class="field"><span>Email</span><input id="authEmail" type="email" autocomplete="email" inputmode="email" value="${esc(st.email || '')}" required></label>
      <label class="field"><span>Password (at least 6 characters)</span><input id="authPass" type="password" autocomplete="current-password" required minlength="6"></label>
      ${err}${st.info ? `<p class="note" role="status">${esc(st.info)}</p>` : ''}
      <button class="primary" id="signInBtn" type="submit" ${busy}>Sign in</button>
      <button class="secondary" id="signUpBtn" type="button" ${busy}>Create account</button>
    </form>
  </section>`;
}

function bindSyncCard() {
  if (!sync) return;
  const st = state.syncUi;
  const act = async (fn) => {
    st.busy = true; st.error = null; st.info = null; render();
    try { await fn(); } catch (e) { st.error = e.message || String(e); }
    st.busy = false; render();
  };
  $('#authForm')?.addEventListener('submit', (e) => {
    e.preventDefault();
    st.email = $('#authEmail').value.trim();
    const pass = $('#authPass').value;
    act(async () => {
      const r = await sync.signIn(st.email, pass);
      st.step = r.connected ? 'signin' : 'household';
    });
  });
  $('#signUpBtn')?.addEventListener('click', () => {
    st.email = $('#authEmail').value.trim();
    const pass = $('#authPass').value;
    if (!st.email || pass.length < 6) { st.error = 'Enter your email and a password of at least 6 characters.'; render(); return; }
    act(async () => {
      const r = await sync.signUp(st.email, pass);
      if (r.needsConfirmation) st.info = 'Account created. Open the confirmation email, then come back and sign in.';
      else st.step = 'household';
    });
  });
  $('#createHh')?.addEventListener('click', () => {
    st.name = $('#dispName').value.trim();
    if (!st.name) { st.error = 'Enter your name.'; render(); return; }
    act(async () => { await sync.createHousehold(st.name); st.step = 'signin'; toast('Household created'); });
  });
  $('#joinHh')?.addEventListener('click', () => {
    st.name = $('#dispName').value.trim();
    st.code = $('#joinCode').value.trim();
    if (!st.name || !st.code) { st.error = 'Enter your name and the invite code.'; render(); return; }
    act(async () => { await sync.joinHousehold(st.code, st.name); st.step = 'signin'; toast('Joined the household'); });
  });
  $('#syncNowBtn')?.addEventListener('click', () => act(() => sync.syncNow()));
  $('#signOutBtn')?.addEventListener('click', () => openConfirmSheet('Sign out?', 'Your entries stay on this phone, but stop syncing until you sign in again.', 'Sign out', () => act(async () => { await sync.signOut(); st.step = 'signin'; })));
}

function renderSettings() {
  const me = store.currentUser;
  const catSection = (space, title) => {
    const all = store.categories(space.id, { includeArchived: true });
    const group = (kind, label) => {
      const list = all.filter((c) => c.kind === kind);
      return `<h2 style="margin-top:14px">${label}</h2><ul class="set-list">${list.map((c, i) => `
        <li class="${c.archived ? 'archived' : ''}">
          <span class="name">${ico(c)}${esc(c.name)}<small>${c.archived ? 'Hidden' : kind === 'expense' ? (c.budget ? `Budget ${money(c.budget)} / month` : 'No budget') : 'Income'}</small></span>
          <span class="actions">
            <button class="mini" data-move="${esc(c.id)}" data-dir="-1" aria-label="Move up" ${i === 0 ? 'disabled' : ''}>↑</button>
            <button class="mini" data-move="${esc(c.id)}" data-dir="1" aria-label="Move down" ${i === list.length - 1 ? 'disabled' : ''}>↓</button>
            <button class="mini" data-editcat="${esc(c.id)}">Edit</button>
          </span>
        </li>`).join('')}</ul>
        <button class="secondary" data-addcat="${esc(space.id)}" data-kind="${kind}">Add ${kind} category</button>`;
    };
    return `<section class="card"><h2>${title}</h2>${group('expense', 'Expenses')}${group('income', 'Income')}</section>`;
  };

  view.innerHTML = `
    ${syncCardHtml()}
    <section class="card"><h2>Appearance</h2>
      <div class="seg theme-seg" role="radiogroup" aria-label="Appearance">${[['system', 'Automatic'], ['light', 'Light'], ['dark', 'Dark']].map(([v, l]) => `<button type="button" role="radio" aria-checked="${theme() === v}" data-theme-choice="${v}" class="${theme() === v ? 'on' : ''}">${l}</button>`).join('')}</div>
      <p class="note">Automatic follows the phone's light or dark setting. This choice is kept on this phone only.</p>
    </section>
    <section class="card"><h2>Currency</h2>
      <label class="field"><select id="currency" aria-label="Currency">${CURRENCIES.map((c) => `<option ${c === store.data.settings.currency ? 'selected' : ''}>${c}</option>`).join('')}</select></label>
    </section>
    <section class="card"><h2>Receipt language</h2>
      <label class="field"><select id="ocrLang" aria-label="Receipt language">${RECEIPT_LANGS.map(([v, l]) => `<option value="${v}" ${v === (store.data.settings.receiptLang || 'slv+eng') ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
      <p class="note">Receipts are read on this phone. When you are signed in, the photo is also saved to your account, so House receipts are visible to both of you.</p>
    </section>
    ${catSection(store.personalSpace(), `${esc(me.name)}'s personal categories`)}
    ${catSection(store.houseSpace(), 'House categories')}
    <section class="card"><h2>Backup</h2>
      <button class="secondary" id="exportBtn">Download backup file</button>
      <label class="secondary" style="display:block;text-align:center">Restore from backup file<input type="file" id="importFile" accept="application/json,.json" hidden></label>
      <button class="secondary danger" id="resetBtn">Erase everything</button>
    </section>`;

  view.querySelectorAll('[data-user]').forEach((b) => b.addEventListener('click', () => {
    store.setSetting('currentUserId', b.dataset.user);
    toast(`Switched to ${store.currentUser.name}`);
  }));
  bindSyncCard();
  view.querySelectorAll('[data-theme-choice]').forEach((b) => b.addEventListener('click', () => { setTheme(b.dataset.themeChoice); render(); }));
  $('#currency').addEventListener('change', (e) => {
    store.setSetting('currency', e.target.value);
    if (sync?.connected) sync.setCurrency(e.target.value).catch((err) => toast(err.message));
  });
  $('#ocrLang').addEventListener('change', (e) => store.setSetting('receiptLang', e.target.value));
  view.querySelectorAll('[data-move]').forEach((b) => b.addEventListener('click', () => store.moveCategory(b.dataset.move, Number(b.dataset.dir))));
  view.querySelectorAll('[data-editcat]').forEach((b) => b.addEventListener('click', () => openCategorySheet({ cat: store.category(b.dataset.editcat) })));
  view.querySelectorAll('[data-addcat]').forEach((b) => b.addEventListener('click', () => openCategorySheet({ spaceId: b.dataset.addcat, kind: b.dataset.kind })));
  $('#exportBtn').addEventListener('click', exportBackup);
  $('#importFile').addEventListener('change', importBackup);
  $('#resetBtn').addEventListener('click', () => openConfirmSheet('Erase everything?',
    sync?.connected ? 'This signs you out and erases the data on this phone. Your data in your account stays, and comes back when you sign in again.' : 'All entries and category changes on this phone will be deleted. Download a backup first if you want to keep them.',
    'Erase', async () => { if (sync?.connected) await sync.signOut(); store.reset(); toast('Erased'); }));
}

// ---------- sheets ----------
function openSheet(html, bind) {
  sheet.innerHTML = `<div class="sheet-inner">${html}</div>`;
  bind(sheet);
  sheet.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => sheet.close()));
  if (!sheet.open) sheet.showModal();
}
sheet.addEventListener('click', (e) => { if (e.target === sheet) sheet.close(); });

function openTxSheet(tx, preset = {}) {
  const space = tx ? store.space(tx.spaceId) : currentSpace();
  let kind = tx ? tx.kind : (preset.kind || 'expense');
  let categoryId = tx ? tx.categoryId : null;
  let items = tx?.items ? tx.items.map((it) => ({ ...it })) : [];
  let receiptId = tx?.receiptId || null;
  let newPhoto = null; // { id, blob } not yet saved
  let photoUrl = null;
  const defaultDate = tx ? tx.date : (state.month === monthKey() ? todayKey() : `${state.month}-01`);

  const chipsHtml = () => store.categories(space.id).filter((c) => c.kind === kind)
    .map((c) => `<button type="button" class="chip ${c.id === categoryId ? 'on' : ''}" data-chip="${esc(c.id)}">${ico(c)}${esc(c.name)}</button>`).join('');

  openSheet(`
    <div class="sheet-head"><button class="link-btn" data-close>Cancel</button>
      <h3>${tx ? 'Edit entry' : `Add to ${esc(space.type === 'house' ? 'House' : 'Personal')}`}</h3>
      <button class="link-btn" id="saveTx">Save</button></div>
    <div class="seg"><button type="button" data-kind="expense">Expense</button><button type="button" data-kind="income">Income</button></div>
    <input class="amount-input" id="amount" aria-label="Amount" inputmode="decimal" placeholder="0" autocomplete="off" value="${tx ? centsToInput(tx.amount) : ''}">
    <div class="chips" id="chips"></div>
    <div id="newCatBox" class="new-cat" hidden></div>
    <div class="row2">
      <label class="field"><span>Date</span><input type="date" id="date" value="${defaultDate}"></label>
      <label class="field"><span>Note</span><input id="note" maxlength="${LIMITS.note}" placeholder="Optional" value="${tx ? esc(tx.note) : ''}"></label>
    </div>
    <div id="receiptBox" class="receipt-box">
      <label class="field shop-field"><span>Shop</span><input id="shop" list="shopNames" maxlength="${LIMITS.store}" placeholder="Read from the receipt, or type it" value="${tx ? esc(tx.store || '') : ''}" autocomplete="off"></label>
      <div class="receipt-top">
        <label class="secondary receipt-btn">📷 <span id="photoLabel">Add receipt photo</span><input type="file" id="photoInput" accept="image/*" hidden></label>
        <img id="thumb" class="thumb" alt="Receipt" hidden>
      </div>
      <p class="note" id="ocrStatus" hidden></p>
      <div id="itemsWrap"></div>
    </div>
    <datalist id="shopNames">${[...new Set(['Mercator', 'Spar', 'Lidl', 'Hofer', 'Tuš', 'Eurospin', 'Jager', ...store.data.transactions.map((t) => t.store).filter(Boolean)])].map((n) => `<option value="${esc(n)}">`).join('')}</datalist>
    <datalist id="itemNames">${[...store.itemHistory().values()].map((g) => `<option value="${esc(g.name)}">`).join('')}</datalist>
    <button class="primary" id="saveTx2">Save</button>
    ${tx ? '<button class="secondary danger" id="delTx">Delete entry</button>' : ''}
  `, (root) => {
    const chips = $('#chips', root);
    const paint = () => {
      root.querySelectorAll('[data-kind]').forEach((b) => b.classList.toggle('on', b.dataset.kind === kind));
      chips.innerHTML = `${chipsHtml()}<button type="button" class="chip chip-new" id="newCatChip">+ New category</button>`;
      chips.querySelectorAll('[data-chip]').forEach((b) => b.addEventListener('click', () => { categoryId = b.dataset.chip; paint(); }));
      $('#newCatChip', chips).addEventListener('click', openNewCat);
      $('#receiptBox', root).hidden = kind !== 'expense';
    };
    // A new category made right here, without leaving the entry (what was typed stays). It is
    // picked for this entry straight away.
    const newCatBox = $('#newCatBox', root);
    const closeNewCat = () => { newCatBox.hidden = true; newCatBox.innerHTML = ''; };
    function openNewCat() {
      let icon = '';
      newCatBox.innerHTML = `
        <label class="field"><span>New ${kind === 'income' ? 'income' : 'expense'} category</span>
          <input id="newCatName" maxlength="${LIMITS.categoryName}" placeholder="e.g. Pets" autocomplete="off"></label>
        <div class="field"><span id="newIconLabel">Icon</span>
          <div class="icon-grid" role="radiogroup" aria-labelledby="newIconLabel">
            <button type="button" role="radio" class="icon-auto" data-newicon="" aria-label="Automatic icon for the name"><span id="newAutoIcon"></span><small>Auto</small></button>
            ${ICON_CHOICES.map((e) => `<button type="button" role="radio" data-newicon="${e}" aria-label="${e}">${e}</button>`).join('')}
          </div>
        </div>
        <div class="new-cat-actions">
          <button type="button" class="secondary" id="newCatCancel">Cancel</button>
          <button type="button" class="primary" id="newCatAdd">Add category</button>
        </div>`;
      newCatBox.hidden = false;
      const name = $('#newCatName', newCatBox);
      const paintIcons = () => {
        $('#newAutoIcon', newCatBox).textContent = categoryIcon(name.value);
        newCatBox.querySelectorAll('[data-newicon]').forEach((b) => {
          const on = b.dataset.newicon === icon;
          b.classList.toggle('on', on);
          b.setAttribute('aria-checked', String(on));
        });
      };
      newCatBox.querySelectorAll('[data-newicon]').forEach((b) => b.addEventListener('click', () => { icon = b.dataset.newicon; paintIcons(); }));
      name.addEventListener('input', paintIcons);
      paintIcons();
      const add = () => {
        const n = name.value.trim();
        if (!n) { toast('Enter a name'); name.focus(); return; }
        const same = store.categories(space.id, { includeArchived: true }).find((c) => c.kind === kind && c.name.trim().toLocaleLowerCase() === n.toLocaleLowerCase());
        // A name that is already there (maybe hidden) is used instead of making a second one.
        const c = same || store.addCategory({ spaceId: space.id, name: n, kind, icon });
        if (same?.archived) store.updateCategory(same.id, { archived: false });
        categoryId = c.id;
        closeNewCat();
        paint();
        toast(same ? `"${same.name}" picked` : `Category "${c.name}" added`);
      };
      name.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } });
      $('#newCatAdd', newCatBox).addEventListener('click', add);
      $('#newCatCancel', newCatBox).addEventListener('click', closeNewCat);
      name.focus();
    }
    root.querySelectorAll('[data-kind]').forEach((b) => b.addEventListener('click', () => {
      if (kind !== b.dataset.kind) { kind = b.dataset.kind; categoryId = null; closeNewCat(); paint(); }
    }));
    paint();

    // ----- receipt items, compared with the last time each item was bought -----
    const itemsWrap = $('#itemsWrap', root);
    const cmpHtml = (it) => {
      if (!it.name || !it.price) return '';
      const shop = $('#shop', root).value.trim();
      const prev = store.previousPrice(it.name, $('#date', root).value || todayKey(), tx?.id, shop);
      const elsewhere = prev?.store && shop && !sameStore(prev.store, shop) ? ` at ${esc(prev.store)}` : '';
      const per = it.unit === 'kg' ? '/kg' : '';
      const each = pricePerUnit(it);
      const amount = it.unit === 'kg' ? `${String(it.qty).replace('.', ',')} kg ×` : `${it.qty} ×`;
      if (it.qty && each === null) {
        // Quantity × price of one ≠ line total: something is misread. Show it so it can be fixed.
        return `<small class="item-qty">⚠️ ${amount} ${money(it.unitPrice)}${per} is not ${money(it.price)}. Check this price; until it adds up, this line is left out of the price history.</small>`;
      }
      const qty = it.qty ? `<small class="item-qty">${amount} ${money(each)}${per}</small>` : '';
      return `${qty}${changeBadge(prev ? pctChange(each, prev.price) : null)}${prev ? `<small>was ${money(prev.price)}${prev.unit === 'kg' ? '/kg' : ''}${elsewhere} on ${esc(dayLabel(prev.date))}</small>` : ''}`;
    };
    const itemsTotal = () => items.reduce((s, it) => s + (it.price || 0), 0);
    const paintItems = () => {
      const rows = items.map((it, i) => `<li class="item-row">
          <input class="item-name" aria-label="Item name" maxlength="${LIMITS.itemName}" data-i="${i}" data-f="name" value="${esc(it.name)}" placeholder="Item" list="itemNames" autocomplete="off">
          <input class="item-price" aria-label="Item price" data-i="${i}" data-f="price" value="${centsToInput(it.price)}" placeholder="0" inputmode="decimal" autocomplete="off">
          <button type="button" class="mini" data-rm="${i}" aria-label="Remove item">✕</button>
          <div class="item-cmp" data-cmp="${i}">${cmpHtml(it)}</div>
        </li>`).join('');
      itemsWrap.innerHTML = `
        ${items.length ? `<h4 class="items-head">Items on the bill <span id="itemsTotal">${money(itemsTotal())}</span></h4><ul class="items">${rows}</ul>` : ''}
        <div class="items-actions">
          <button type="button" class="mini" id="addItem">+ Add item</button>
          ${items.length ? '<button type="button" class="mini" id="useTotal">Use items total as amount</button>' : ''}
        </div>`;
      // Update the data while typing, but never re-draw the list (that would drop the keyboard focus).
      itemsWrap.querySelectorAll('input[data-i]').forEach((inp) => {
        const i = Number(inp.dataset.i);
        inp.addEventListener('input', () => {
          if (inp.dataset.f === 'name') items[i].name = inp.value.trim();
          else {
            const c = toCents(inp.value);
            items[i].price = Number.isFinite(c) ? c : 0;
          }
          // Update the comparison while typing, so nothing jumps around when the field loses focus.
          $(`[data-cmp="${i}"]`, itemsWrap).innerHTML = cmpHtml(items[i]);
          $('#itemsTotal', itemsWrap).textContent = money(itemsTotal());
        });
      });
      itemsWrap.querySelectorAll('[data-rm]').forEach((b) => b.addEventListener('click', () => { items.splice(Number(b.dataset.rm), 1); paintItems(); }));
      $('#addItem', itemsWrap).addEventListener('click', () => {
        items.push({ name: '', price: 0 });
        paintItems();
        itemsWrap.querySelector(`input[data-i="${items.length - 1}"]`)?.focus();
      });
      $('#useTotal', itemsWrap)?.addEventListener('click', () => { $('#amount', root).value = centsToInput(itemsTotal()); });
    };
    paintItems();
    $('#date', root).addEventListener('change', paintItems);
    $('#shop', root).addEventListener('change', paintItems);

    const thumb = $('#thumb', root);
    const showThumb = (blob) => {
      if (photoUrl) URL.revokeObjectURL(photoUrl);
      photoUrl = URL.createObjectURL(blob);
      thumb.src = photoUrl;
      thumb.hidden = false;
      $('#photoLabel', root).textContent = 'Replace photo';
    };
    if (receiptId) loadPhoto(sync, receiptId).then((b) => b && showThumb(b)).catch(() => {});
    thumb.addEventListener('click', () => photoUrl && window.open(photoUrl, '_blank'));

    const status = $('#ocrStatus', root);
    $('#photoInput', root).addEventListener('change', async (e) => {
      const file = e.target.files[0];
      e.target.value = '';
      if (!file) return;
      // The full-size original is used for reading; a smaller copy is saved.
      const blob = await compressImage(file);
      newPhoto = { id: uid('photo'), blob };
      showThumb(blob);
      if (!categoryId) {
        const g = store.categories(space.id).find((c) => c.kind === 'expense' && c.name === 'Groceries');
        if (g) { categoryId = g.id; paint(); }
      }
      status.hidden = false;
      status.textContent = 'Reading the receipt on your phone… (first time takes longer)';
      try {
        const text = await readReceiptText(file, store.data.settings.receiptLang || 'slv+eng', (p, attempt) => {
          status.textContent = attempt ? `Hard to read, trying another way (${attempt + 1})… ${Math.round(p * 100)}%` : `Reading the receipt… ${Math.round(p * 100)}%`;
        });
        console.debug('Receipt text:', text);
        const found = parseReceipt(text);
        const shop = findStore(text);
        if (shop && !$('#shop', root).value.trim()) $('#shop', root).value = shop;
        if (found.length) {
          items = found;
          // Prefer the printed total (it includes discounts); otherwise add up the items.
          const printed = findTotal(text);
          const sum = found.reduce((s, it) => s + it.price, 0);
          const total = printed || sum;
          // A misread digit (5 as 9, 1 as 7) would show up later as a fake price jump, so say
          // when the items don't add up to the printed total.
          status.textContent = printed && printed !== sum
            ? `Found ${found.length} items. They add up to ${money(sum)}, but the receipt total is ${money(printed)}: a price may be misread (or there is a discount). Check the prices, then save.`
            : `Found ${found.length} items. Check names and prices, then save.`;
          status.classList.toggle('warn', !!printed && printed !== sum);
          if (!$('#amount', root).value) $('#amount', root).value = centsToInput(total);
        } else {
          status.textContent = 'Could not find item lines. You can add items by hand.';
        }
      } catch (err) {
        console.warn(err);
        status.textContent = 'Could not read the receipt. The photo is kept, and you can add items by hand.';
      }
      paintItems();
    });

    let saving = false;
    const save = async () => {
      if (saving) return; // a double tap must not save the entry twice
      const amount = toCents($('#amount', root).value);
      const date = $('#date', root).value;
      if (!(amount > 0)) { toast('Enter an amount'); return; }
      if (amount >= LIMITS.amount) { toast('That amount is too large. Check the amount.'); return; }
      if (!categoryId) { toast('Pick a category'); return; }
      if (!date) { toast('Pick a date'); return; }
      saving = true;
      const cleanItems = kind === 'expense' ? items.filter((it) => it.name && it.price > 0).map((it) => cleanItem({ name: it.name, price: it.price, qty: it.qty, unit: it.unit, unitPrice: it.unitPrice })) : [];
      if (newPhoto) {
        try {
          await putPhoto(newPhoto.id, newPhoto.blob);
          if (receiptId) deletePhoto(receiptId).catch(() => {});
          receiptId = newPhoto.id;
        } catch { toast('Could not save the photo'); }
      }
      const payload = { spaceId: space.id, categoryId, kind, amount, date, note: $('#note', root).value.trim() };
      if (kind === 'expense') { payload.items = cleanItems; payload.receiptId = receiptId; payload.store = $('#shop', root).value.trim(); }
      else if (tx?.store) payload.store = '';
      let msg = tx ? 'Saved' : 'Added';
      if (tx && !store.updateTransaction(tx.id, payload)) {
        // The other phone deleted this entry while it was open here: keep this person's edit.
        store.addTransaction(payload);
        msg = 'This entry was deleted on the other phone, so it was saved again as a new entry.';
      } else if (!tx) store.addTransaction(payload);
      state.month = date.slice(0, 7);
      sheet.close();
      render();
      if (!store.saveFailed) toast(msg);
    };
    $('#saveTx', root).addEventListener('click', save);
    $('#saveTx2', root).addEventListener('click', save);
    $('#delTx', root)?.addEventListener('click', () => {
      if (tx.receiptId) deletePhoto(tx.receiptId).catch(() => {});
      store.deleteTransaction(tx.id); sheet.close(); toast('Deleted');
    });
    if (!tx) setTimeout(() => $('#amount', root).focus(), 50);
  });
}

function renderPrices() {
  const all = [...store.itemHistory().values()];
  // Shops seen on receipts. Prices differ from shop to shop, so each % is worked out between
  // purchases at the same shop; the chips show one shop only.
  const shops = [...new Map(all.flatMap((g) => g.entries).filter((e) => e.store).map((e) => [normalizeItem(e.store), e.store])).values()].sort((a, b) => a.localeCompare(b));
  if (state.priceStore && !shops.some((s) => sameStore(s, state.priceStore))) state.priceStore = null;
  const pick = state.priceStore;
  const q = normalizeItem(state.priceQuery || '');
  const shown = all
    .map((g) => ({ ...g, entries: pick ? g.entries.filter((e) => sameStore(e.store, pick)) : g.entries }))
    .filter((g) => g.entries.length && (!q || g.key.includes(q)))
    .sort((a, b) => b.entries.at(-1).date.localeCompare(a.entries.at(-1).date));

  const spark = (entries) => {
    if (entries.length < 2) return '';
    const vals = entries.map((e) => e.price);
    const min = Math.min(...vals), max = Math.max(...vals), w = 56, h = 24;
    const pts = vals.map((v, i) => `${(i / (vals.length - 1)) * w},${max === min ? h / 2 : h - ((v - min) / (max - min)) * (h - 4) - 2}`).join(' ');
    return `<svg class="spark" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}" aria-hidden="true"><polyline points="${pts}" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/></svg>`;
  };
  const kg = (e) => (e.unit === 'kg' ? '/kg' : '');

  const rows = shown.map((g) => {
    const tr = storeTrend(g.entries); // at the shop of the newest purchase
    const last = tr.last, prev = tr.entries.at(-2);
    const open = state.openItem === g.key;
    return `<li class="price-row"><button data-item="${esc(g.key)}">
        <div class="price-main"><div class="tx-cat">${esc(g.name)}</div>
          <div class="tx-meta">${tr.store ? `${esc(tr.store)} · ` : ''}${tr.entries.length}× · ${esc(dayLabel(last.date))}${prev ? ` · before ${money(prev.price)}${kg(prev)}` : ''}</div></div>
        ${spark(tr.entries)}
        <div class="price-right"><div class="tx-amt">${money(last.price)}${last.unit === 'kg' ? '<small>/kg</small>' : ''}</div>${g.entries.length > 1 ? changeBadge(tr.change) : ''}</div>
      </button>
      ${open ? `<ul class="price-hist">${g.entries.slice().reverse().map((e) => `<li><span>${esc(dayLabel(e.date))}${e.store ? ` · ${esc(e.store)}` : ''}</span><span>${money(e.price)}${kg(e)}</span></li>`).join('')}</ul>` : ''}
    </li>`;
  }).join('');

  view.innerHTML = `
    <section class="card"><h2>Grocery prices over time</h2>
      <p class="note" style="margin:0 0 10px">Every item from your receipts, newest first. The % is the change since the first time you bought it at the same shop, per piece or per kg. Tap an item for its history.</p>
      <label class="field"><input id="priceSearch" type="search" aria-label="Search items" placeholder="Search items" value="${esc(state.priceQuery || '')}"></label>
      ${shops.length ? `<div class="chips shop-chips" role="group" aria-label="Shop">
        <button type="button" class="chip${pick ? '' : ' on'}" data-shop="" aria-pressed="${!pick}">All shops</button>
        ${shops.map((s) => `<button type="button" class="chip${pick && sameStore(s, pick) ? ' on' : ''}" data-shop="${esc(s)}" aria-pressed="${!!pick && sameStore(s, pick)}">${esc(s)}</button>`).join('')}
      </div>` : ''}
      ${rows ? `<ul class="tx-list">${rows}</ul>` : '<p class="empty-note">No items yet. Add a receipt photo to an expense and the items will show up here.</p>'}
    </section>`;
  const search = $('#priceSearch');
  search.addEventListener('input', () => {
    state.priceQuery = search.value;
    renderPrices();
    const s2 = $('#priceSearch'); s2.focus(); s2.setSelectionRange(s2.value.length, s2.value.length);
  });
  view.querySelectorAll('[data-shop]').forEach((b) => b.addEventListener('click', () => {
    state.priceStore = b.dataset.shop || null;
    renderPrices();
  }));
  view.querySelectorAll('[data-item]').forEach((b) => b.addEventListener('click', () => {
    state.openItem = state.openItem === b.dataset.item ? null : b.dataset.item;
    renderPrices();
  }));
}

function openCategorySheet({ cat, spaceId, kind }) {
  const isNew = !cat;
  const k = cat ? cat.kind : kind;
  openSheet(`
    <div class="sheet-head"><button class="link-btn" data-close>Cancel</button>
      <h3>${isNew ? 'New category' : 'Edit category'}</h3><button class="link-btn" id="saveCat">Save</button></div>
    <label class="field"><span>Name</span><input id="catName" maxlength="${LIMITS.categoryName}" value="${cat ? esc(cat.name) : ''}" placeholder="e.g. Pets"></label>
    <div class="field"><span id="iconLabel">Icon</span>
      <div class="icon-grid" role="radiogroup" aria-labelledby="iconLabel">
        <button type="button" role="radio" class="icon-auto" data-icon="" aria-label="Automatic icon for the name"><span id="autoIcon"></span><small>Auto</small></button>
        ${ICON_CHOICES.map((e) => `<button type="button" role="radio" data-icon="${e}" aria-label="${e}">${e}</button>`).join('')}
      </div>
    </div>
    ${k === 'expense' ? `<label class="field"><span>Monthly budget (leave empty for none)</span><input id="catBudget" inputmode="decimal" value="${cat ? centsToInput(cat.budget) : ''}" placeholder="0"></label>` : ''}
    <button class="primary" id="saveCat2">Save</button>
    ${cat ? `<button class="secondary" id="archCat">${cat.archived ? 'Show again' : 'Hide category'}</button>
      <p class="note">Hiding keeps past entries but removes the category from lists and the add screen.</p>` : ''}
  `, (root) => {
    let icon = cat?.icon || '';
    const paintIcons = () => {
      $('#autoIcon', root).textContent = categoryIcon($('#catName', root).value);
      root.querySelectorAll('[data-icon]').forEach((b) => {
        const on = b.dataset.icon === icon;
        b.classList.toggle('on', on);
        b.setAttribute('aria-checked', String(on));
      });
    };
    root.querySelectorAll('[data-icon]').forEach((b) => b.addEventListener('click', () => { icon = b.dataset.icon; paintIcons(); }));
    $('#catName', root).addEventListener('input', paintIcons);
    paintIcons();
    const save = () => {
      const name = $('#catName', root).value.trim();
      if (!name) { toast('Enter a name'); return; }
      const sid = cat ? cat.spaceId : spaceId;
      if (store.categories(sid).some((c) => c.kind === k && c.id !== cat?.id && c.name.trim().toLocaleLowerCase() === name.toLocaleLowerCase())) { toast('A category with this name already exists'); return; }
      const budgetRaw = $('#catBudget', root)?.value ?? '';
      const budget = budgetRaw.trim() ? toCents(budgetRaw) : 0;
      if (Number.isNaN(budget) || budget < 0) { toast('Budget must be a number'); return; }
      if (budget >= LIMITS.amount) { toast('That budget is too large'); return; }
      if (isNew) store.addCategory({ spaceId, name, kind: k, budget, icon }); else store.updateCategory(cat.id, { name, budget, icon });
      sheet.close();
    };
    $('#saveCat', root).addEventListener('click', save);
    $('#saveCat2', root).addEventListener('click', save);
    $('#archCat', root)?.addEventListener('click', () => { store.updateCategory(cat.id, { archived: !cat.archived }); sheet.close(); });
    if (isNew) setTimeout(() => $('#catName', root).focus(), 50);
  });
}

function openConfirmSheet(title, body, actionLabel, onConfirm) {
  openSheet(`<div class="sheet-head"><h3>${esc(title)}</h3></div><p>${esc(body)}</p>
    <button class="primary" id="confirmYes" style="background:var(--over)">${esc(actionLabel)}</button>
    <button class="secondary" data-close>Cancel</button>`, (root) => {
    $('#confirmYes', root).addEventListener('click', () => { sheet.close(); onConfirm(); });
  });
}

// ---------- backup ----------
function exportBackup() {
  const blob = new Blob([store.exportJSON()], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `budget-backup-${todayKey()}.json`;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
function importBackup(e) {
  const file = e.target.files[0];
  if (!file) return;
  file.text().then((text) => {
    try { store.importJSON(text); toast('Backup restored'); }
    catch (err) { toast(err.message || 'Could not read that file'); }
  });
  e.target.value = '';
}

// ---------- wiring ----------
document.querySelectorAll('.tabbar button').forEach((b) => b.addEventListener('click', () => {
  state.tab = b.dataset.tab;
  state.filterCat = null;
  render();
  window.scrollTo(0, 0);
}));
$('#prevMonth').addEventListener('click', () => { state.month = shiftMonth(state.month, -1); state.filterCat = null; render(); });
$('#nextMonth').addEventListener('click', () => { state.month = shiftMonth(state.month, 1); state.filterCat = null; render(); });
$('#addBtn').addEventListener('click', () => openTxSheet(null));
store.subscribe(render);
store.subscribe(() => {
  if (store.saveFailed) storageWarning();
});
let storageWarned = 0;
function storageWarning() {
  if (Date.now() - storageWarned < 5000) return;
  storageWarned = Date.now();
  const el = document.createElement('div');
  el.className = 'toast toast-alert';
  el.setAttribute('role', 'alert');
  el.textContent = sync?.connected
    ? 'Phone storage is full. Your changes are kept in your account, but free up space on the phone.'
    : 'Phone storage is full, so this change could not be saved. Free up space, or download a backup in Settings.';
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 8000);
}
render();

startCloud(store).then(async (s) => {
  if (!s) return;
  sync = s;
  sync.onStatus(() => { $('#who').textContent = store.currentUser.name + syncBadge(); if (state.tab === 'settings' && !state.syncUi?.busy) render(); });
  render();
  try {
    const r = await sync.resume();
    if (!r.connected && r.needsHousehold) { state.syncUi = { step: 'household' }; render(); }
  } catch (e) { console.warn('sync', e); }
}).catch((e) => console.warn('sync not started', e));

if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}
