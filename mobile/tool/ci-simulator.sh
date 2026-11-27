#!/usr/bin/env bash
# For GitHub's Macs: makes an iPhone simulator of the given model and prints its id.
# Downloads the iPhone simulator system first if the Mac has none.
#
#   mobile/tool/ci-simulator.sh iPhone-SE-3rd-generation [iOS-17-5]
#
# The second argument picks the iOS version (newest installed if left out).
set -euo pipefail
TYPE="com.apple.CoreSimulator.SimDeviceType.$1"
WANT="${2:-}"

pick_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
want, dtype = sys.argv[1], sys.argv[2]
rts = [r for r in json.load(sys.stdin)["runtimes"]
       if r.get("isAvailable") and r.get("platform", "iOS") == "iOS" and "iOS" in r["identifier"]
       and want in r["identifier"]
       and (not r.get("supportedDeviceTypes") or any(d["identifier"] == dtype for d in r["supportedDeviceTypes"]))]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rts[-1]["identifier"] if rts else "")
' "$WANT" "$TYPE"
}

RT="$(pick_runtime)"
if [ -z "$RT" ]; then
  echo "No matching iPhone simulator system installed; downloading one." >&2
  if [ -n "$WANT" ]; then
    V="${WANT#iOS-}"; xcodebuild -downloadPlatform iOS -buildVersion "${V//-/.}" >&2 || true
  else
    xcodebuild -downloadPlatform iOS >&2 || true
  fi
  RT="$(pick_runtime)"
fi
[ -n "$RT" ] || { echo "No iPhone simulator system available." >&2; xcrun simctl list runtimes >&2; exit 1; }
echo "Using $1 on $RT" >&2
xcrun simctl create "CI $1" "$TYPE" "$RT"
