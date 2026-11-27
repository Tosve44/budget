#!/usr/bin/env python3
"""Makes 26 weekly Slovenian grocery receipts (photos) for testing price tracking.

One shopping trip every Saturday for 6 months (2026-05-30 .. 2026-11-21), 20 items,
mostly at Mercator, sometimes at Lidl, Hofer, Spar or Tuš. Prices change over time:
some rise, some stay the same, some drop, and store brands at Lidl/Hofer are cheaper.
Bananas, tomatoes, apples and chicken are sold by weight ("0,856 kg x 1,49"), and
yogurt sometimes twice ("2 x 0,59"), as on real receipts.

Writes receipts/week-NN.jpg and expected.json (what each receipt says).
Run: python3 tests/price-history/make-receipts.py
"""
import datetime as dt
import json
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'receipts')
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'

WEEKS = 26
FIRST = dt.date(2026, 5, 30)  # a Saturday


def lerp(a, b, w, start=0, end=WEEKS - 1):
    """Price moving from a to b between week start and end (in whole cents)."""
    if w <= start:
        return a
    if w >= end:
        return b
    return round(a + (b - a) * (w - start) / (end - start))


def step(*pairs):
    """Price that jumps: step((0, 149), (12, 179)) = 1,49 until week 11, then 1,79."""
    def f(w):
        p = pairs[0][1]
        for start, price in pairs:
            if w >= start:
                p = price
        return p
    return f


# key: (Mercator/Spar/Tuš name, price per unit or per kg by week, how: 'pc' | 'kg' | 'multi',
#       how often bought (every n weeks), trend for the report)
ITEMS = {
    'milk':     ('ALPSKO MLEKO 3,5% 1L', lambda w: 119, 'pc', 1, 'stable'),
    'bread':    ('KRUH BELI 500G', step((0, 149), (12, 179)), 'pc', 1, 'up'),
    'butter':   ('MASLO ZELENE DOLINE 250G', lambda w: lerp(249, 319, w), 'pc', 2, 'up'),
    'eggs':     ('JAJCA M 10 KOM', step((0, 289), (8, 309), (18, 329)), 'pc', 2, 'up'),
    'coffee':   ('KAVA BARCAFFE 400G', lambda w: lerp(549, 699, w), 'pc', 3, 'up'),
    'choco':    ('ČOKOLADA MILKA 100G', step((0, 129), (10, 149), (20, 159)), 'pc', 2, 'up'),
    'olive':    ('OLJČNO OLJE 0,75L', lambda w: lerp(899, 1049, w), 'pc', 4, 'up'),
    'sunoil':   ('SONČNIČNO OLJE 1L', lambda w: lerp(229, 179, w), 'pc', 3, 'down'),
    'sugar':    ('SLADKOR 1KG', step((0, 109), (9, 99), (17, 89)), 'pc', 4, 'down'),
    'pasta':    ('TESTENINE BARILLA 500G', lambda w: 119 if w == 10 else 169, 'pc', 2, 'stable, one sale week'),
    'rice':     ('RIŽ BASMATI 1KG', lambda w: 299, 'pc', 4, 'stable'),
    'yogurt':   ('JOGURT NAVADNI 180G', step((0, 59), (14, 69)), 'multi', 1, 'up'),
    'cheese':   ('SIR GAVDA 400G', lambda w: lerp(499, 549, w), 'pc', 3, 'up'),
    'chicken':  ('PIŠČANČJE PRSI', lambda w: lerp(999, 1149, w), 'kg', 2, 'up (per kg)'),
    'banana':   ('BANANE', lambda w: lerp(149, 129, w), 'kg', 1, 'down (per kg)'),
    'tomato':   ('PARADIŽNIK', lambda w: lerp(199, 349, w, 8, 25), 'kg', 2, 'up in autumn (per kg)'),
    'apples':   ('JABOLKA ZLATI DELIŠES', lambda w: 179, 'kg', 2, 'stable (per kg)'),
    'cola':     ('COCA-COLA 1,5L', lambda w: 189, 'pc', 2, 'stable'),
    'tp':       ('TOALETNI PAPIR 10/1', step((0, 399), (13, 449)), 'pc', 4, 'up'),
    'water':    ('RADENSKA 1,5L', step((0, 99), (16, 109)), 'pc', 2, 'up'),
}

# Store brands at Lidl and Hofer: other names and lower prices. Items not listed here
# are branded and print the same name everywhere.
OWN = {
    'Lidl': {
        'milk': ('Mleko Pilos 3,5% 1l', lambda w: 99),
        'butter': ('Maslo Pilos 250g', lambda w: lerp(219, 279, w)),
        'sugar': ('Sladkor bel 1kg', lambda w: 85),
        'sunoil': ('Sončnično olje Vita D\'or 1l', lambda w: lerp(199, 159, w)),
        'tp': ('Toal. papir Floralys 10/1', lambda w: 329),
        'pasta': ('Testenine Combino 500g', lambda w: 89),
    },
    'Hofer': {
        'milk': ('MLEKO MILSANI 3,5% 1L', lambda w: 99),
        'butter': ('MASLO MILSANI 250G', lambda w: lerp(219, 279, w)),
        'sugar': ('SLADKOR 1KG BELI', lambda w: 85),
        'tp': ('TOAL. PAPIR KOKETT 10/1', lambda w: 339),
    },
}
STORE_OFFSET = {'Mercator': 0, 'Spar': 10, 'Tus': -5, 'Lidl': -10, 'Hofer': -10}

SCHEDULE = {3: 'Lidl', 9: 'Lidl', 15: 'Lidl', 21: 'Lidl', 6: 'Hofer', 18: 'Hofer', 12: 'Spar', 24: 'Spar', 7: 'Tus', 20: 'Tus'}

HEADERS = {
    'Mercator': ['MERCATOR d.o.o.', 'Hipermarket Šiška', 'Dunajska cesta 107, Ljubljana', 'ID za DDV: SI45884595'],
    'Spar': ['SPAR SLOVENIJA d.o.o.', 'INTERSPAR Vič', 'Tržaška cesta 33, Ljubljana', 'ID za DDV: SI32562985'],
    'Tus': ['ENGROTUS d.o.o.', 'Supermarket Tuš Bežigrad', 'Linhartova 11, Ljubljana', 'ID za DDV: SI54888492'],
    'Lidl': ['LIDL Slovenija d.o.o. k.d.', 'Trgovina Ljubljana Rudnik', 'Jurčkova cesta 225', 'ID za DDV: SI59314923'],
    'Hofer': ['HOFER trgovina d.o.o.', 'PE Ljubljana Moste', 'Zaloška cesta 151', 'ID za DDV: SI72278854'],
}


def eur(c):
    s = f'{abs(c) // 100},{abs(c) % 100:02d}'
    return ('-' if c < 0 else '') + s


def build():
    rnd = random.Random(2026)
    receipts = []
    for w in range(WEEKS):
        date = FIRST + dt.timedelta(days=7 * w)
        store = SCHEDULE.get(w, 'Mercator')
        lines = []
        for key, (name, price, how, every, _trend) in ITEMS.items():
            # Staples every week, the rest every few weeks (shifted so receipts differ).
            if (w + len(key)) % every:
                continue
            if store in OWN and key in OWN[store]:
                name, price = OWN[store][key]
                unit = price(w)
            else:
                unit = price(w) + (STORE_OFFSET[store] if price(w) > 150 else 0)
            if store == 'Lidl':
                name = name.capitalize()  # Lidl prints names in mixed case
            if how == 'kg':
                kg = rnd.randint(450, 1350) / 1000
                total = round(kg * unit)
                lines.append({'key': key, 'name': name, 'qty': kg, 'unit': 'kg', 'unitPrice': unit, 'price': total})
            elif how == 'multi' and w % 3 == 0:
                lines.append({'key': key, 'name': name, 'qty': 2, 'unit': 'pc', 'unitPrice': unit, 'price': 2 * unit})
            else:
                lines.append({'key': key, 'name': name, 'qty': 1, 'unit': 'pc', 'unitPrice': unit, 'price': unit})
        rnd.shuffle(lines)
        discount = -30 if w in (5, 17) else 0
        total = sum(l['price'] for l in lines) + discount
        receipts.append({'week': w, 'date': date.isoformat(), 'store': store, 'items': lines,
                         'discount': discount, 'total': total, 'file': f'week-{w:02d}.jpg'})
    return receipts


def draw(r, rnd):
    font = ImageFont.truetype(FONT, 26)
    w_paper = 640
    rows = []
    rows += [(h, None) for h in HEADERS[r['store']]]
    d = dt.date.fromisoformat(r['date'])
    rows.append((f'Račun št.: {r["week"] + 1:02d}-{rnd.randint(1000, 9999)}-{rnd.randint(10, 99)}', None))
    rows.append((f'{d.day:02d}.{d.month:02d}.{d.year} {rnd.randint(8, 19):02d}:{rnd.randint(0, 59):02d}', None))
    rows.append(('-' * 36, None))
    tax = 'C'
    for i, it in enumerate(r['items']):
        if it['qty'] == 1:
            rows.append((it['name'], f'{eur(it["price"])} {tax}'))
        else:
            rows.append((it['name'], None))
            q = f'{it["qty"]:.3f}'.replace('.', ',') + ' kg' if it['unit'] == 'kg' else f'{it["qty"]} x'
            rows.append((f'  {q} x {eur(it["unitPrice"])}' if it['unit'] == 'kg' else f'  {q} {eur(it["unitPrice"])}',
                         f'{eur(it["price"])} {tax}'))
        if r['discount'] and i == 1:
            rows.append(('Popust', eur(r['discount'])))
    rows.append(('-' * 36, None))
    rows.append(('SKUPAJ EUR', eur(r['total'])))
    rows.append(('Plačilna kartica', eur(r['total'])))
    vat = round(r['total'] * 9.5 / 109.5)
    rows.append(('DDV 9,5%', eur(vat)))
    rows.append((f'ZOI: {rnd.getrandbits(40):010x}', None))
    rows.append((f'EOR: {rnd.getrandbits(16):04x}-{rnd.getrandbits(16):04x}-{rnd.getrandbits(16):04x}', None))
    rows.append(('Hvala za nakup!', None))

    lh = 37
    h_paper = 40 + lh * len(rows) + 30
    paper = Image.new('RGB', (w_paper, h_paper), (250, 249, 244))
    pd = ImageDraw.Draw(paper)
    for _ in range(900):  # thermal paper speckles
        x, y = rnd.randrange(w_paper), rnd.randrange(h_paper)
        g = rnd.randint(200, 235)
        pd.point((x, y), fill=(g, g, g))
    y = 30
    for left, right in rows:
        pd.text((24, y), left, font=font, fill=(30, 30, 30))
        if right:
            tw = pd.textlength(right, font=font)
            pd.text((w_paper - 24 - tw, y), right, font=font, fill=(30, 30, 30))
        y += lh
    paper = paper.filter(ImageFilter.GaussianBlur(0.6))
    # The same receipt as text (what a perfect reader would give), for tests without photos.
    r['text'] = '\n'.join(f'{left:<30} {right:>10}' if right else left for left, right in rows)
    # Lay it on a table, slightly turned, like a phone photo.
    bg = Image.new('RGB', (w_paper + 140, h_paper + 140), (rnd.randint(60, 80), rnd.randint(55, 70), rnd.randint(50, 64)))
    angle = rnd.uniform(-1.8, 1.8)
    rot = paper.rotate(angle, expand=True, fillcolor=bg.getpixel((0, 0)), resample=Image.BICUBIC)
    bg.paste(rot, ((bg.width - rot.width) // 2, (bg.height - rot.height) // 2))
    return bg


def main():
    os.makedirs(OUT, exist_ok=True)
    receipts = build()
    rnd = random.Random(7)
    for r in receipts:
        draw(r, rnd).save(os.path.join(OUT, r['file']), quality=82)
    trends = {k: v[4] for k, v in ITEMS.items()}
    with open(os.path.join(HERE, 'expected.json'), 'w') as f:
        json.dump({'trends': trends, 'receipts': receipts}, f, ensure_ascii=False, indent=1)
    n = sum(len(r['items']) for r in receipts)
    print(f'{len(receipts)} receipts, {n} item lines, {receipts[0]["date"]} .. {receipts[-1]["date"]}')


if __name__ == '__main__':
    main()
