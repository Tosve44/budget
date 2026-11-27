#!/usr/bin/env bash
# Runs the device tests on the Android emulator that is already started (GitHub Actions).
#   tool/ci-android-test.sh <font scale> <dark: yes/no> <log file> <test apk> [test file]
# The test app is built once by another job (so 13 jobs do not all download the same build tools).
set -uo pipefail
FONT="${1:-1.0}"; DARK="${2:-no}"; LOG="${3:-device-test.log}"; APK="${4:-app-debug.apk}"; TARGET="${5:-integration_test/app_test.dart}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
export PATH="$SDK/platform-tools:$SDK/emulator:$PATH"
command -v adb >/dev/null || { echo "adb not found in $SDK/platform-tools"; exit 1; }
adb wait-for-device
# Same settings a person could pick in the phone's settings.
adb shell settings put system font_scale "$FONT"
adb shell cmd uimode night "$DARK"
for a in window_animation_scale transition_animation_scale animator_duration_scale; do adb shell settings put global "$a" 0 || true; done
adb shell input keyevent 82 || true
prop() { adb -s emulator-5554 shell "$@" </dev/null 2>/dev/null | tr -d '\r' | tail -1; }
echo "Emulator: $(prop getprop ro.product.model) | Android $(prop getprop ro.build.version.release) (API $(prop getprop ro.build.version.sdk)) | $(prop wm size) | $(prop wm density) | font x$FONT | dark $DARK" | tee "$LOG"
flutter drive --driver=test_driver/integration_test.dart --target="$TARGET" \
  --use-application-binary="$APK" -d emulator-5554 2>&1 | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
