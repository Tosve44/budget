# Budget phone app (iPhone + Android)

One Flutter app for both phones. It does the same as the web app (https://tosve44.github.io/budget/)
and works on the same data: Personal and House spaces, sharing the House space with a partner via an
invite code, receipt photos read on the phone for grocery price tracking, light/dark/automatic look.

- `lib/core/` the rules, ported from the web app's `store.js`, `receipt.js` and `sync.js`
  (money typing, receipt reading, price history, sync with the same free Supabase project).
- `lib/ui/` the screens. `lib/platform/` the camera and the phone's own text reader
  (Apple Vision in `ios/Runner/AppDelegate.swift`, Google ML Kit in `android/.../MainActivity.kt`;
  both free and offline).

## Tests

| What | Command (from `mobile/`) |
|---|---|
| Same answers as the web app on thousands of inputs | `flutter test test/golden_test.dart` |
| Every screen flow on 8 phone sizes x 2 text sizes | `flutter test test/screens_test.dart` |
| Sync: two phones, the web app, a flaky network | `bash tool/start-test-backend.sh ..` then `SUPABASE_TEST_URL=http://localhost:54321 WEB_APP_DIR=.. NODE_MODULES_DIR=/tmp/budget-test-backend/node_modules flutter test test/sync_test.dart` |
| On a real emulator / simulator (also reads real receipt photos) | `flutter test integration_test/app_test.dart -d <device>` |

`node tool/make-golden.mjs ..` regenerates `test/fixtures` from the web app's code.
GitHub Actions (`.github/workflows/mobile.yml`) runs all of it, on 13 Android emulators and
6 iPhone/iPad simulators, and builds an APK and an unsigned IPA.

## Installing for testing (free)

- Android: download `app-release.apk` from the latest "Phone app" run's artifacts and open it on the phone.
- iPhone: download `Budget-unsigned.ipa` and install it with Sideloadly or AltStore using a free
  Apple ID (it has to be re-installed every 7 days; a paid developer account removes that limit).
