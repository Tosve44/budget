// Reads a receipt photo on the phone itself with Tesseract (free, open source, offline).
// Nothing is uploaded anywhere. The text engine (~3-5 MB) is loaded only the first
// time a receipt is read, and then cached for offline use.

import { toCents } from './store.js';

const BASE = new URL('vendor/tesseract/', import.meta.url).href;
let loading;
let worker;
let workerLang;

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error('Could not load the receipt reader.'));
    document.head.appendChild(s);
  });
}

async function getWorker(lang, onProgress) {
  if (!window.Tesseract) {
    loading = loading || loadScript(BASE + 'tesseract.min.js');
    await loading;
  }
  if (worker && workerLang === lang) return worker;
  if (worker) { await worker.terminate(); worker = null; }
  worker = await window.Tesseract.createWorker(lang, 1, {
    workerPath: BASE + 'worker.min.js',
    corePath: BASE,
    langPath: BASE + 'lang',
    logger: (m) => onProgress && m.status === 'recognizing text' && onProgress(m.progress),
  });
  workerLang = lang;
  // Treat the receipt as one block of text lines (other modes split names and prices into columns).
  await worker.setParameters({ tessedit_pageseg_mode: '6' });
  return worker;
}

// Turn a photo into text lines. `lang` is e.g. "eng" or "srp_latn+eng".
// If the first try finds (almost) nothing, the photo may be sideways, upside down or half in
// shadow, so it is tried again those ways and the reading with the most items wins.
export async function readReceiptText(blob, lang = 'eng', onProgress) {
  const w = await getWorker(lang, (p) => onProgress && onProgress(p, attempt));
  const tries = [{}, { rotate: 90 }, { rotate: 270 }, { even: true }, { rotate: 180 }];
  let attempt = 0;
  let best = null;
  for (const t of tries) {
    const { data } = await w.recognize(await prepareForReading(blob, t));
    const n = parseReceipt(data.text).length;
    if (!best || n > best.n) best = { n, text: data.text };
    if (n >= 3 || (n >= 1 && findTotal(data.text))) break;
    attempt++;
  }
  return best.text;
}

// Make the photo easier to read: grey scale, stretch the contrast (faded or grey thermal paper),
// and enlarge small photos. The saved receipt photo is not changed.
// rotate: turn the photo by 90/180/270 degrees first. even: even out uneven light (a shadow
// across the receipt) instead of cutting the receipt out of its background.
export async function prepareForReading(blob, { rotate = 0, even = false } = {}) {
  try {
    const bmp = await createImageBitmap(blob);
    const side = rotate % 180 ? bmp.height : bmp.width;
    const scale = Math.min(2, Math.max(1, 1400 / side));
    const c = document.createElement('canvas');
    c.width = Math.round((rotate % 180 ? bmp.height : bmp.width) * scale);
    c.height = Math.round((rotate % 180 ? bmp.width : bmp.height) * scale);
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.imageSmoothingQuality = 'high';
    ctx.translate(c.width / 2, c.height / 2);
    ctx.rotate((rotate * Math.PI) / 180);
    ctx.drawImage(bmp, (-bmp.width * scale) / 2, (-bmp.height * scale) / 2, bmp.width * scale, bmp.height * scale);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    const img = ctx.getImageData(0, 0, c.width, c.height);
    const px = img.data;
    for (let i = 0; i < px.length; i += 4) px[i] = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) / 1000 | 0;
    if (even) evenOutLight(px, c.width, c.height);
    const hist = new Uint32Array(256);
    for (let i = 0; i < px.length; i += 4) hist[px[i]]++;
    // Ignore the darkest/lightest 1% so the table around the receipt doesn't skew the stretch.
    const n = px.length / 4;
    let lo = 0, hi = 255, acc = 0;
    while (lo < 255 && (acc += hist[lo]) < n * 0.01) lo++;
    acc = 0;
    while (hi > 0 && (acc += hist[hi]) < n * 0.01) hi--;
    const range = Math.max(1, hi - lo);
    for (let i = 0; i < px.length; i += 4) {
      const v = Math.max(0, Math.min(255, ((px[i] - lo) * 255) / range));
      px[i] = px[i + 1] = px[i + 2] = v;
    }
    ctx.putImageData(img, 0, 0);
    const out = even ? straighten(c) : cropToPaper(straighten(c));
    return await new Promise((resolve) => out.toBlob((b) => resolve(b || blob), 'image/png'));
  } catch {
    return blob;
  }
}

// Divide each pixel by the brightness of the paper around it, so a shadow over part of the
// receipt no longer looks like dark ink. The paper brightness is the brightest value in
// each 32×32 block (text is thin, so blocks always contain some paper), smoothed out.
function evenOutLight(px, w, h) {
  const B = 32, bw = Math.ceil(w / B), bh = Math.ceil(h / B);
  const bg = new Float32Array(bw * bh);
  for (let by = 0; by < bh; by++) {
    for (let bx = 0; bx < bw; bx++) {
      let m = 0;
      for (let y = by * B; y < Math.min(h, by * B + B); y += 2) {
        for (let x = bx * B; x < Math.min(w, bx * B + B); x += 2) { const v = px[(y * w + x) * 4]; if (v > m) m = v; }
      }
      bg[by * bw + bx] = m;
    }
  }
  const sm = new Float32Array(bw * bh);
  for (let by = 0; by < bh; by++) {
    for (let bx = 0; bx < bw; bx++) {
      let s = 0, k = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const yy = by + dy, xx = bx + dx;
        if (yy >= 0 && yy < bh && xx >= 0 && xx < bw) { s += bg[yy * bw + xx]; k++; }
      }
      sm[by * bw + bx] = s / k;
    }
  }
  for (let y = 0; y < h; y++) {
    const fy = Math.min(bh - 1, Math.max(0, y / B - 0.5)), y0 = Math.floor(fy), y1 = Math.min(bh - 1, y0 + 1), ty = fy - y0;
    for (let x = 0; x < w; x++) {
      const fx = Math.min(bw - 1, Math.max(0, x / B - 0.5)), x0 = Math.floor(fx), x1 = Math.min(bw - 1, x0 + 1), tx = fx - x0;
      const b = (sm[y0 * bw + x0] * (1 - tx) + sm[y0 * bw + x1] * tx) * (1 - ty) + (sm[y1 * bw + x0] * (1 - tx) + sm[y1 * bw + x1] * tx) * ty;
      const i = (y * w + x) * 4;
      px[i] = Math.min(255, (px[i] * 255) / Math.max(30, b)) | 0;
    }
  }
}

// Photos are rarely straight, and a tilt of 2-3 degrees makes prices drift onto the next line.
// Try small angles on a shrunken copy and keep the one where text rows line up best
// (the row darkness profile is the most "peaky").
function straighten(src) {
  const small = document.createElement('canvas');
  const k = Math.min(1, 500 / src.width);
  small.width = Math.round(src.width * k);
  small.height = Math.round(src.height * k);
  const sctx = small.getContext('2d', { willReadFrequently: true });
  let best = 0, bestScore = -1;
  for (let a = -6; a <= 6; a += 0.5) {
    sctx.fillStyle = '#fff';
    sctx.fillRect(0, 0, small.width, small.height);
    sctx.save();
    sctx.translate(small.width / 2, small.height / 2);
    sctx.rotate((a * Math.PI) / 180);
    sctx.drawImage(src, -small.width / 2, -small.height / 2, small.width, small.height);
    sctx.restore();
    const d = sctx.getImageData(0, 0, small.width, small.height).data;
    let score = 0, prev = 0;
    for (let y = 0; y < small.height; y++) {
      let dark = 0;
      for (let x = 0; x < small.width; x++) if (d[(y * small.width + x) * 4] < 110) dark++;
      score += (dark - prev) ** 2;
      prev = dark;
    }
    if (score > bestScore) { bestScore = score; best = a; }
  }
  if (best === 0) return src;
  const out = document.createElement('canvas');
  out.width = src.width;
  out.height = src.height;
  const o = out.getContext('2d');
  o.fillStyle = '#000'; // dark corners get cut away by cropToPaper
  o.fillRect(0, 0, out.width, out.height);
  o.translate(out.width / 2, out.height / 2);
  o.rotate((best * Math.PI) / 180);
  o.drawImage(src, -src.width / 2, -src.height / 2);
  return out;
}

// Phone photos show the table around the receipt. Dark borders confuse the reader badly,
// so keep only the bright paper area (rows/columns that are mostly light).
function cropToPaper(src) {
  const ctx = src.getContext('2d', { willReadFrequently: true });
  const { width: w, height: h } = src;
  const d = ctx.getImageData(0, 0, w, h).data;
  const light = (x, y) => d[(y * w + x) * 4] > 150;
  const rowOk = (y) => { let n = 0; for (let x = 0; x < w; x += 2) n += light(x, y); return n > w / 2 * 0.45; };
  const colOk = (x, y0, y1) => { let n = 0; for (let y = y0; y < y1; y += 2) n += light(x, y); return n > (y1 - y0) / 2 * 0.6; };
  let top = 0, bottom = h - 1;
  while (top < h && !rowOk(top)) top++;
  while (bottom > top && !rowOk(bottom)) bottom--;
  if (bottom - top < h * 0.2) return src; // no clear paper found: leave as is
  let left = 0, right = w - 1;
  while (left < w && !colOk(left, top, bottom)) left++;
  while (right > left && !colOk(right, top, bottom)) right--;
  if (right - left < w * 0.2) return src;
  const pad = Math.round(Math.min(w, h) * 0.01);
  left += pad; right -= pad; top += pad; bottom -= pad;
  const out = document.createElement('canvas');
  out.width = right - left;
  out.height = bottom - top;
  out.getContext('2d').drawImage(src, left, top, out.width, out.height, 0, 0, out.width, out.height);
  return out;
}

// Words that mark lines which are not products (totals, tax, payment, etc.).
// Includes common English, Slovenian, Serbian/Croatian/Bosnian and German receipt words.
const SKIP = /\b(skupaj|za pla[čc]ilo|ddv|vrnjeno|vra[čc]ilo|zoi|eor|davčna|davcna|blagajnik|total|subtotal|sub-total|sum|summe|ukupno|ukupan|za uplatu|uplata|plaćeno|placeno|povra[ćc]aj|kusur|pdv|vat|tax|mwst|ust|gotovina|cash|kartica|card|visa|mastercard|maestro|change|rabat|popust|discount|osnovica|stopa|iznos|račun|racun|receipt|fiskalni|pib|datum|date|vreme|time|kasir|cashier|bon|tel|www|hvala|thank)\b/i;

// A price at the end of a line: 129.99, 1.299,00, 89,50, optionally followed by a tax letter
// (A, B, C...) or €. Photos often add stray dots or colons around it ("1,29/:C", "2,15.€", "1;28"),
// so a little junk between the price and the end of the line is allowed.
const PRICE_AT_END = /(?<=^|[\s€:])(-?\d{1,3}(?:\.\d{3})+,\d{2}|-?\d+[.,;:] ?\d{2})[\s\W_]*(?:[A-ZĐŠČĆŽ€$]{1,3}|[a-e])?[\s\W_]*$/u;

// Common misreads in product names: "500G" read as "5006", "150g" as "1509", and a small
// "l" (litre) read as "1": "1,5l" as "1,51", "0,75l" as "0,751", "3,5% 1l" as "3,5% 11".
function fixName(name) {
  const upper = name === name.toUpperCase();
  let n = name.replace(/\b(\d*[1-9]0{1,2})[69]\b/g, (_, d) => d + (upper ? 'G' : 'g'));
  if (!upper) n = n.replace(/\b(\d,\d{1,2})1\b/g, '$1l').replace(/(%\s?)11\b/g, (_, pct) => `${pct}1l`).replace(/\b11$/, '1l');
  return n;
}

// "2 x 0,59", "0,856 kg x 1,49", "350 g x 12,99": how many (or how much) and the price of one
// (or of a kilo). Returns null when the line doesn't say.
function readQuantity(text) {
  const m = String(text).match(/^([\d.,]+)\s*(kom|kos|kg|g|pcs|st)?\.?\s*[x×*]\s*([\d.,]+)/i);
  if (!m) return null;
  let qty = Number(m[1].replace(',', '.'));
  const unitWord = (m[2] || '').toLowerCase();
  if (unitWord === 'g') qty /= 1000;
  if (!(qty > 0) || qty > 999 || qty === 1) return null;
  const byWeight = unitWord === 'kg' || unitWord === 'g' || !Number.isInteger(qty);
  const each = toCents(m[3].replace(/[;:]/g, ','));
  return { qty: Math.round(qty * 1000) / 1000, unit: byWeight ? 'kg' : undefined, unitPrice: Number.isFinite(each) && each > 0 ? each : undefined };
}

// The receipt's grand total ("SKUPAJ", "ZA PLAČILO", "TOTAL"...), which already includes discounts.
const TOTAL_WORDS = /\b(skupaj|za pla[čc]ilo|total|ukupno|za uplatu|summe)\b/i;
export function findTotal(text) {
  let total = null;
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.replace(/\s+/g, ' ').trim();
    if (!TOTAL_WORDS.test(line) || /\b(ddv|pdv|vat|osnova)\b/i.test(line)) continue;
    const m = line.match(PRICE_AT_END);
    if (m) {
      const c = toCents(m[1].replace(/[;:]/g, ',').replace(/ /g, ''));
      if (c > 0) total = Math.max(total || 0, c);
    }
  }
  return total;
}

export function parseReceipt(text) {
  const items = [];
  const at = new Map(); // item -> its line
  const lines = String(text).split(/\r?\n/).map((l) => l.replace(/\s+/g, ' ').trim()).filter(Boolean);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (SKIP.test(line)) continue;
    const m = line.match(PRICE_AT_END);
    if (!m) continue;
    // Drop a currency sign before the price (OCR often reads € as "e" or "E").
    let name = line.slice(0, m.index).replace(/(\s+(€|EUR|e|E))+\s*$/u, '').replace(/€\s*$/u, '').trim();
    const price = toCents(m[1].replace(/[;:]/g, ',').replace(/ /g, ''));
    if (!Number.isFinite(price) || price <= 0) continue;
    // Quantity lines like "2 x 1,29" or "0,750 kg x 199,99": the product name is usually on the line above.
    const qtyOnly = /^[\d.,]+\s*(kom|kg|g|l|pcs|st)?\s*[x×*]\s*[\d.,]+/i.test(name);
    if (!qtyOnly && !/\p{L}{2,}/u.test(name)) continue; // e.g. a date and time "25.11.2026 10:15"
    let amount = null;
    if (qtyOnly) {
      const above = lines[i - 1] && !PRICE_AT_END.test(lines[i - 1]) && !SKIP.test(lines[i - 1]) ? lines[i - 1] : null;
      if (above && /\p{L}{2,}/u.test(above)) { amount = readQuantity(name); name = above; }
      else continue;
    }
    name = name.replace(/[|_~*#"]+/g, ' ').replace(/\s+/g, ' ').replace(/^[\d.,\s]+(?=\p{L})/u, '').trim();
    if (name.length < 2) continue;
    const item = { name: fixName(name), price };
    if (amount) addQuantity(item, amount);
    items.push(item);
    at.set(item, i);
  }
  // Other layouts put the quantity on its own line, without the line total: below the product
  // ("Paradižnik 1,15" then "0,620 kg x 1,85 EUR/kg", Lidl) or above it ("2 x 0,89" then
  // "JOGURT 1,78", Mercator). Use it when the numbers agree with that product's line total.
  const byLine = new Map(items.map((it) => [at.get(it), it]));
  for (let i = 0; i < lines.length; i++) {
    if (byLine.has(i) || SKIP.test(lines[i])) continue;
    const amount = readQuantity(lines[i]);
    if (!amount || !amount.unitPrice) continue;
    for (const j of [i - 1, i + 1]) {
      const it = byLine.get(j);
      if (it && !it.qty && Math.abs(Math.round(amount.qty * amount.unitPrice) - it.price) <= 1) { addQuantity(it, amount); break; }
    }
  }
  return items;
}

function addQuantity(item, amount) {
  item.qty = amount.qty;
  if (amount.unit) item.unit = amount.unit;
  // The printed price of one (or of a kilo) is exact; dividing the line total is off by a cent
  // sometimes. Kept even when the numbers disagree: then one of them is misread, and the line is
  // left out of the price history until the total is fixed (see pricePerUnit in store.js).
  if (amount.unitPrice) item.unitPrice = amount.unitPrice;
}
