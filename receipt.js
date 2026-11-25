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
export async function readReceiptText(blob, lang = 'eng', onProgress) {
  const w = await getWorker(lang, onProgress);
  const { data } = await w.recognize(await prepareForReading(blob));
  return data.text;
}

// Make the photo easier to read: grey scale, stretch the contrast (faded or grey thermal paper),
// and enlarge small photos. The saved receipt photo is not changed.
export async function prepareForReading(blob) {
  try {
    const bmp = await createImageBitmap(blob);
    const scale = Math.min(2, Math.max(1, 1400 / bmp.width));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * scale);
    c.height = Math.round(bmp.height * scale);
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(bmp, 0, 0, c.width, c.height);
    const img = ctx.getImageData(0, 0, c.width, c.height);
    const px = img.data;
    const hist = new Uint32Array(256);
    for (let i = 0; i < px.length; i += 4) {
      const g = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) / 1000 | 0;
      px[i] = g;
      hist[g]++;
    }
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
    const out = cropToPaper(straighten(c));
    return await new Promise((resolve) => out.toBlob((b) => resolve(b || blob), 'image/png'));
  } catch {
    return blob;
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

// Common misreads in product names: "500G" read as "5006", "150g" as "1509".
function fixName(name) {
  const upper = name === name.toUpperCase();
  return name.replace(/\b(\d*[1-9]0{1,2})[69]\b/g, (_, n) => n + (upper ? 'G' : 'g'));
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
    if (qtyOnly) {
      const above = lines[i - 1] && !PRICE_AT_END.test(lines[i - 1]) && !SKIP.test(lines[i - 1]) ? lines[i - 1] : null;
      if (above && /\p{L}{2,}/u.test(above)) name = above;
      else continue;
    }
    name = name.replace(/[|_~*#"]+/g, ' ').replace(/\s+/g, ' ').replace(/^[\d.,\s]+(?=\p{L})/u, '').trim();
    if (name.length < 2) continue;
    items.push({ name: fixName(name), price });
  }
  return items;
}
