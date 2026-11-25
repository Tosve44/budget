#!/usr/bin/env bash
# Starts an Android emulator on GitHub's Linux machines and waits until it has booted.
#   tool/ci-android-emulator.sh <api level> <device profile, e.g. pixel_8 or "7.6in Foldable">
# Uses Google's newest command-line tools, which know the newest phone profiles (Pixel 8, 9, Fold).
set -euo pipefail
API="$1"; PROFILE="$2"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
IMAGE="system-images;android-$API;google_apis;x86_64"
T=/tmp/clt/cmdline-tools/bin
if [ ! -x "$T/avdmanager" ]; then
  for build in 13114758 12700392 12266719 11076708; do
    curl -fsSLo /tmp/clt.zip "https://dl.google.com/android/repository/commandlinetools-linux-${build}_latest.zip" && break
  done
  rm -rf /tmp/clt && unzip -q /tmp/clt.zip -d /tmp/clt
fi
yes | "$T/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null || true
"$T/sdkmanager" --sdk_root="$SDK" --install emulator platform-tools "$IMAGE" >/dev/null
if ! echo no | "$T/avdmanager" create avd --force -n test -k "$IMAGE" -d "$PROFILE"; then
  echo "Unknown phone profile '$PROFILE'. Known profiles:"; "$T/avdmanager" list device -c; exit 1
fi
CFG="$HOME/.android/avd/test.avd/config.ini"
sed -i '/^hw.ramSize/d;/^disk.dataPartition.size/d;/^hw.keyboard/d' "$CFG"
printf 'hw.ramSize=4096\ndisk.dataPartition.size=6000M\nhw.keyboard=no\n' >> "$CFG"
nohup "$SDK/emulator/emulator" -avd test -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim -no-snapshot \
  -camera-back none -camera-front none > /tmp/emulator.log 2>&1 &
ADB="$SDK/platform-tools/adb"
"$ADB" wait-for-device
for i in $(seq 1 200); do
  [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && { echo "Booted after $((i * 3)) s"; exit 0; }
  sleep 3
done
echo "The emulator did not finish booting in 10 minutes."; tail -50 /tmp/emulator.log; exit 1
