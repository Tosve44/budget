#!/usr/bin/env bash
# For GitHub's Macs: runs the device tests on an iPhone simulator and appends the output to a log.
# Now and then the app never starts on the simulator after the build (no test runs at all, until
# the step times out). When nothing has started 6 minutes after the build, the simulator is
# wiped and restarted and the tests run again (at most 3 tries).
#
#   mobile/tool/ci-ios-test.sh <simulator id> device-test.log [test file]
set -uo pipefail
SIM="$1"
LOG="$2"
TARGET="${3:-integration_test/app_test.dart}"
RUN="$(mktemp)"
for attempt in 1 2 3; do
  : > "$RUN"
  flutter test "$TARGET" -d "$SIM" --reporter expanded > "$RUN" 2>&1 &
  PID=$!
  tail -f "$RUN" & TAIL=$!
  built=""; stuck=""
  while kill -0 "$PID" 2>/dev/null; do
    sleep "${CHECK_EVERY:-10}"
    if [ -z "$built" ] && grep -q "Xcode build done" "$RUN"; then built="$(date +%s)"; fi
    if [ -n "$built" ] && ! grep -q "^DEVICE " "$RUN" && [ $(( $(date +%s) - built )) -gt "${STUCK_AFTER:-360}" ]; then
      stuck=yes
      echo "The app did not start on the simulator within 6 minutes of the build (try $attempt)."
      pkill -P "$PID" 2>/dev/null; kill "$PID" 2>/dev/null
      break
    fi
  done
  wait "$PID"; rc=$?
  kill "$TAIL" 2>/dev/null
  cat "$RUN" >> "$LOG"
  [ -z "$stuck" ] && exit "$rc"
  echo "Simulator restart after the app did not start (try $attempt)" >> "$LOG"
  xcrun simctl shutdown "$SIM" || true
  xcrun simctl erase "$SIM" || true
  xcrun simctl boot "$SIM" || true
  xcrun simctl bootstatus "$SIM" -b || true
done
echo "The app did not start on the simulator, three times." | tee -a "$LOG"
exit 1
