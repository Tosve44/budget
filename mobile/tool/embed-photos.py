#!/usr/bin/env python3
"""Puts the web app's sample receipt photos (tests/*.jpg) into integration_test/receipt_photos.dart,
so the tests on real emulators and simulators can read them with the phone's own text reader.
Run from mobile/:  python3 tool/embed-photos.py"""
import base64, glob, os
out = ['// Made by tool/embed-photos.py from ../tests/*.jpg. Do not edit.', '', 'const receiptPhotos = <String, String>{']
for p in sorted(glob.glob('../tests/*.jpg')):
    b = base64.b64encode(open(p, 'rb').read()).decode()
    out.append(f"  '{os.path.basename(p)}':")
    for i in range(0, len(b), 120):
        out.append(f"      '{b[i:i+120]}'")
    out[-1] += ','
out.append('};')
open('integration_test/receipt_photos.dart', 'w').write('\n'.join(out) + '\n')
