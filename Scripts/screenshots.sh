#!/usr/bin/env bash
# Regenerates the Love Letter marketing / App Store screenshots on mock data.
#
# Builds the DEBUG app + the LoveLetterScreenshots UI tests, runs them on the Mac, an iPhone and
# an iPad simulator in light and dark mode, and writes the images to:
#
#   <output>/<mac|iphone|ipad>/<light|dark>/NN-name.png
#
# Usage:
#   Scripts/screenshots.sh [--platforms mac,iphone,ipad] [--appearances light,dark]
#                          [--output DIR] [--iphone "iPhone 17 Pro Max"] [--ipad "iPad Pro 13-inch (M5)"]
#                          [--mac-window 1440x900] [--skip-build]
#
# Defaults produce App Store sizes: iPhone 6.9" (1320x2868), iPad 13" (2064x2752) and a
# 1440x900pt Mac window (2880x1800 on a Retina display).
#
# The shot list lives in LoveLetterScreenshots/ScreenshotTests.swift; add screens there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORMS="mac,iphone,ipad"
APPEARANCES="light,dark"
OUTPUT="$ROOT/build/Screenshots"
IPHONE="iPhone 17 Pro Max"
IPAD="iPad Pro 13-inch (M5)"
MAC_WINDOW="1440x900"
OS_VERSION="27.0"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platforms)   PLATFORMS="$2"; shift 2 ;;
    --appearances) APPEARANCES="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    --iphone)      IPHONE="$2"; shift 2 ;;
    --ipad)        IPAD="$2"; shift 2 ;;
    --mac-window)  MAC_WINDOW="$2"; shift 2 ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    -h|--help)     sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

WORK="$ROOT/build/screenshots-work"
DERIVED="$WORK/DerivedData"
mkdir -p "$WORK" "$OUTPUT"
FAILED=()

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# XCTest method filter for the requested appearances.
only_testing() {
  local target="$1" args=() a
  IFS=',' read -ra list <<< "$APPEARANCES"
  for a in "${list[@]}"; do
    case "$a" in
      light) args+=("-only-testing:$target/ScreenshotTests/testLightAppearance") ;;
      dark)  args+=("-only-testing:$target/ScreenshotTests/testDarkAppearance") ;;
      *) echo "Unknown appearance: $a" >&2; exit 2 ;;
    esac
  done
  printf '%s\n' "${args[@]}"
}

# UDID of an available simulator named $1 on iOS $OS_VERSION.
simulator_udid() {
  xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name, os_version = sys.argv[1], sys.argv[2].replace(".", "-")
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if runtime.endswith("iOS-" + os_version):
        for d in devices:
            if d["name"] == name:
                print(d["udid"]); sys.exit(0)
sys.exit(1)' "$1" "$OS_VERSION"
}

# Clean status bar: 9:41, full battery and signal, no carrier. A full timestamp also pins the
# date iPad shows next to the time.
prepare_simulator() {
  local udid="$1"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # simctl only accepts this exact ISO form (milliseconds + offset). The host's offset *on that
  # date* (DST differs) keeps the simulator's clock at 9:41.
  local day="2026-01-13T09:41:00" offset
  offset="$(date -j -f "%Y-%m-%dT%H:%M:%S" "$day" +%z | sed -E 's/(..)$/:\1/')"
  xcrun simctl status_bar "$udid" override --time "$day.000$offset" \
    --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" \
    --batteryState charged --batteryLevel 100
}

# Runs the screenshot tests for one scheme/destination and exports the attachments.
run() {
  local label="$1" scheme="$2" target="$3" destination="$4"
  local result="$WORK/$label.xcresult"
  rm -rf "$result"

  if [[ $SKIP_BUILD -eq 0 ]]; then
    log "$label: building"
    if ! xcodebuild build-for-testing -project "$ROOT/LoveLetter.xcodeproj" -scheme "$scheme" \
        -destination "$destination" -derivedDataPath "$DERIVED" -quiet; then
      echo "$label: build failed" >&2
      FAILED+=("$label"); return
    fi
  fi

  log "$label: capturing ($APPEARANCES)"
  local tests=()
  while IFS= read -r line; do tests+=("$line"); done < <(only_testing "$target")
  # Failures are expected to be partial (one shot's query broke); keep going and report at the end.
  # TEST_RUNNER_-prefixed variables reach the UI test runner (without the prefix).
  if ! TEST_RUNNER_LL_WINDOW_SIZE="$MAC_WINDOW" \
      xcodebuild test-without-building -project "$ROOT/LoveLetter.xcodeproj" -scheme "$scheme" \
      -destination "$destination" -derivedDataPath "$DERIVED" -resultBundlePath "$result" \
      "${tests[@]}" -quiet; then
    FAILED+=("$label")
  fi

  log "$label: exporting"
  # Replace this run's folders wholesale so a renamed or removed shot doesn't linger.
  local a
  IFS=',' read -ra list <<< "$APPEARANCES"
  for a in "${list[@]}"; do rm -rf "${OUTPUT:?}/$label/$a"; done
  local export_dir="$WORK/$label-attachments"
  rm -rf "$export_dir"
  xcrun xcresulttool export attachments --path "$result" --output-path "$export_dir" >/dev/null
  /usr/bin/python3 - "$export_dir" "$OUTPUT" <<'PY'
import json, os, shutil, sys
export_dir, output = sys.argv[1], sys.argv[2]
with open(os.path.join(export_dir, "manifest.json")) as f:
    manifest = json.load(f)
count = 0
for test in manifest:
    for att in test.get("attachments", []):
        # suggestedHumanReadableName is "<attachment name>_<index>_<uuid>.png"
        name = att.get("suggestedHumanReadableName", "")
        parts = name.split("_")
        if len(parts) < 3 or parts[0] not in ("mac", "iphone", "ipad"):
            continue
        platform, appearance, shot = parts[0], parts[1], parts[2]
        dest_dir = os.path.join(output, platform, appearance)
        os.makedirs(dest_dir, exist_ok=True)
        shutil.copyfile(os.path.join(export_dir, att["exportedFileName"]),
                        os.path.join(dest_dir, shot + ".png"))
        count += 1
print(f"  {count} screenshots")
PY
}

IFS=',' read -ra platforms <<< "$PLATFORMS"
for platform in "${platforms[@]}"; do
  case "$platform" in
    mac)
      run mac LoveLetterScreenshots_macOS LoveLetterScreenshots_macOS "platform=macOS,arch=$(uname -m)" ;;
    iphone|ipad)
      device="$IPHONE"; [[ "$platform" == ipad ]] && device="$IPAD"
      if ! udid="$(simulator_udid "$device")"; then
        echo "No available \"$device\" simulator on iOS $OS_VERSION (see: xcrun simctl list devices)" >&2
        FAILED+=("$platform"); continue
      fi
      prepare_simulator "$udid"
      run "$platform" LoveLetterScreenshots_iOS LoveLetterScreenshots_iOS "id=$udid" ;;
    *) echo "Unknown platform: $platform" >&2; exit 2 ;;
  esac
done

log "Screenshots in $OUTPUT"
find "$OUTPUT" -name '*.png' | sed "s|^$OUTPUT/||" | sort | awk -F/ '{print "  " $0}'
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Some shots failed on: ${FAILED[*]} — see the .xcresult bundles in $WORK" >&2
  exit 1
fi
