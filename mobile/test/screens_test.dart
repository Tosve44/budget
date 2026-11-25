// The screen flows (integration_test/flows.dart) on many screen sizes and text sizes, on the
// computer. A layout that does not fit (text cut off, "overflowed" boxes) fails the test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/flows.dart';

// Logical sizes of real phones (width x height in points / dp).
const screens = <String, Size>{
  'iPhone SE': Size(320, 568),
  'iPhone 13 mini': Size(375, 812),
  'iPhone 16 Pro Max': Size(440, 956),
  'Galaxy Z Flip (open)': Size(360, 880),
  'Galaxy Z Flip cover screen': Size(320, 330),
  'Galaxy Z Fold (open)': Size(673, 841),
  'small Android': Size(320, 640),
  'Pixel tablet (landscape)': Size(1280, 800),
};

void main() {
  for (final s in screens.entries) {
    for (final textScale in [1.0, 1.6]) {
      group('${s.key}, text x$textScale', () {
        for (final f in flows.entries) {
          testWidgets(f.key, (tester) async {
            tester.view.physicalSize = s.value * 2;
            tester.view.devicePixelRatio = 2;
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            addTearDown(tester.view.reset);
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            await f.value(tester);
          });
        }
      });
    }
  }
}
