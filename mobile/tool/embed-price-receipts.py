#!/usr/bin/env python3
"""Puts the six months of test receipts (../tests/price-history: expected.json and receipts/*.jpg,
made by make-receipts.py) into integration_test/, for the price tracking test:
  price_receipts.dart  what each receipt says (date, items, total, text)
  price_photos.dart    the photos, read by the phone's own text reader on emulators/simulators
Run from mobile/:  python3 tool/embed-price-receipts.py"""
import base64, json, os

src = '../tests/price-history'
data = json.load(open(f'{src}/expected.json'))
receipts = [{k: r[k] for k in ('week', 'date', 'store', 'total', 'discount', 'file', 'text')} |
            {'items': [{k: i[k] for k in ('name', 'price', 'qty', 'unit', 'unitPrice')} for i in r['items']]}
            for r in data['receipts']]
body = json.dumps({'trends': data['trends'], 'receipts': receipts}, ensure_ascii=False)
with open('integration_test/price_receipts.dart', 'w') as f:
    f.write('// Made by tool/embed-price-receipts.py from ../tests/price-history/expected.json. Do not edit.\n\n')
    f.write("const priceReceiptsJson = r'''\n" + body.replace("'''", "") + "\n''';\n")
out = ['// Made by tool/embed-price-receipts.py from ../tests/price-history/receipts/*.jpg. Do not edit.', '',
       'const pricePhotos = <String, String>{']
for r in receipts:
    b = base64.b64encode(open(f"{src}/receipts/{r['file']}", 'rb').read()).decode()
    out.append(f"  '{r['file']}':")
    for i in range(0, len(b), 120):
        out.append(f"      '{b[i:i + 120]}'")
    out[-1] += ','
out.append('};')
open('integration_test/price_photos.dart', 'w').write('\n'.join(out) + '\n')
print(f'{len(receipts)} receipts embedded')
