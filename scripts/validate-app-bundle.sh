#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: validate-app-bundle.sh APP_PATH [options]

Options:
  --version VERSION             Expected CFBundleShortVersionString.
  --build BUILD                 Expected CFBundleVersion.
  --architecture ARCHITECTURE   Expected universal, arm64, or x86_64 executable.
  --team-id TEAM_ID             Expected signing team for distribution builds.
  --distribution               Require Developer ID signing and hardened runtime.
  --notarized                  Require a stapled ticket and Gatekeeper acceptance.
  --require-adb                Require the pinned bundled ADB package.
  --require-no-bundled-tools   Require the standard bundle with no ADB or scrcpy.
USAGE
}

fail() {
  echo "Artifact validation failed: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Missing file: $1"
}

require_directory() {
  [[ -d "$1" ]] || fail "Missing directory: $1"
}

APP_PATH="${1:-}"
[[ -n "$APP_PATH" ]] || {
  usage >&2
  exit 2
}
shift

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPROVED_ENTITLEMENTS="$ROOT/Resources/AndroidFileBrowser.entitlements"

EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_ARCHITECTURE="universal"
EXPECTED_TEAM_ID=""
REQUIRE_DISTRIBUTION=false
REQUIRE_NOTARIZED=false
REQUIRE_ADB=false
REQUIRE_NO_BUNDLED_TOOLS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version needs a value."
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || fail "--build needs a value."
      EXPECTED_BUILD="$2"
      shift 2
      ;;
    --architecture)
      [[ $# -ge 2 ]] || fail "--architecture needs a value."
      EXPECTED_ARCHITECTURE="$2"
      shift 2
      ;;
    --team-id)
      [[ $# -ge 2 ]] || fail "--team-id needs a value."
      EXPECTED_TEAM_ID="$2"
      shift 2
      ;;
    --distribution)
      REQUIRE_DISTRIBUTION=true
      shift
      ;;
    --notarized)
      REQUIRE_DISTRIBUTION=true
      REQUIRE_NOTARIZED=true
      shift
      ;;
    --require-adb)
      REQUIRE_ADB=true
      shift
      ;;
    --require-no-bundled-tools)
      REQUIRE_NO_BUNDLED_TOOLS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

require_directory "$APP_PATH"
require_file "$APPROVED_ENTITLEMENTS"

CONTENTS="$APP_PATH/Contents"
RESOURCES="$CONTENTS/Resources"
LICENSES="$RESOURCES/Licenses"
INFO_PLIST="$CONTENTS/Info.plist"
EXECUTABLE="$CONTENTS/MacOS/AOSP File Manager"

require_directory "$CONTENTS"
require_file "$INFO_PLIST"
require_file "$EXECUTABLE"
[[ -x "$EXECUTABLE" ]] || fail "The main executable is not executable."

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$INFO_PLIST" 2>/dev/null
}

[[ "$(plist_value CFBundleIdentifier)" == "com.ababilinski.android-file-browser" ]] \
  || fail "Unexpected bundle identifier."
[[ "$(plist_value CFBundleExecutable)" == "AOSP File Manager" ]] \
  || fail "Unexpected bundle executable."
[[ "$(plist_value CFBundleName)" == "AOSP File Manager" ]] \
  || fail "Unexpected bundle name."
[[ "$(plist_value CFBundlePackageType)" == "APPL" ]] \
  || fail "Unexpected bundle package type."
[[ "$(plist_value LSMinimumSystemVersion)" == "13.0" ]] \
  || fail "The app must keep macOS 13.0 as its minimum system version."
[[ "$(plist_value LSMultipleInstancesProhibited)" == "true" ]] \
  || fail "The app must prohibit multiple running instances."
[[ "$(plist_value NSMicrophoneUsageDescription)" == "AOSP File Manager records audio from your Mac's microphone when you include it in a screen recording." ]] \
  || fail "The app must include its approved microphone usage description."

if [[ -n "$EXPECTED_VERSION" ]]; then
  [[ "$(plist_value CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]] \
    || fail "Expected version $EXPECTED_VERSION."
fi
if [[ -n "$EXPECTED_BUILD" ]]; then
  [[ "$(plist_value CFBundleVersion)" == "$EXPECTED_BUILD" ]] \
    || fail "Expected build $EXPECTED_BUILD."
fi

ARCHITECTURES="$(/usr/bin/lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
case "$EXPECTED_ARCHITECTURE" in
  universal)
    REQUIRED_ARCHITECTURES=(arm64 x86_64)
    ;;
  arm64)
    REQUIRED_ARCHITECTURES=(arm64)
    ;;
  x86_64)
    REQUIRED_ARCHITECTURES=(x86_64)
    ;;
  *)
    fail "Expected architecture must be universal, arm64, or x86_64."
    ;;
esac
for required_architecture in "${REQUIRED_ARCHITECTURES[@]}"; do
  [[ " $ARCHITECTURES " == *" $required_architecture "* ]] \
    || fail "Missing $required_architecture executable slice; found: ${ARCHITECTURES:-none}."
done
[[ "$(wc -w <<< "$ARCHITECTURES" | tr -d ' ')" -eq "${#REQUIRED_ARCHITECTURES[@]}" ]] \
  || fail "Unexpected executable slices; found: ${ARCHITECTURES:-none}."

MINIMUM_OS_VALUES="$(/usr/bin/xcrun vtool -show-build "$EXECUTABLE" | /usr/bin/awk '$1 == "minos" { print $2 }')"
[[ "$(printf '%s\n' "$MINIMUM_OS_VALUES" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')" -eq "${#REQUIRED_ARCHITECTURES[@]}" ]] \
  || fail "Expected one minimum-OS record for each architecture."
while IFS= read -r minimum_os; do
  [[ -z "$minimum_os" || "$minimum_os" == "13.0" ]] \
    || fail "Executable slice has minimum macOS $minimum_os instead of 13.0."
done <<< "$MINIMUM_OS_VALUES"

require_file "$RESOURCES/AppIcon.icns"
require_directory "$RESOURCES/MTPKit_MTPKit.bundle"
if [[ -f "$RESOURCES/MTPKit_MTPKit.bundle/Contents/Info.plist" ]]; then
  MTPKIT_INFO_PLIST="$RESOURCES/MTPKit_MTPKit.bundle/Contents/Info.plist"
elif [[ -f "$RESOURCES/MTPKit_MTPKit.bundle/Info.plist" ]]; then
  MTPKIT_INFO_PLIST="$RESOURCES/MTPKit_MTPKit.bundle/Info.plist"
else
  fail "MTPKit_MTPKit.bundle has no Info.plist."
fi
/usr/bin/plutil -lint "$MTPKIT_INFO_PLIST" >/dev/null
require_file "$LICENSES/Android-File-Browser-GPL-3.0.txt"
require_file "$LICENSES/THIRD_PARTY_NOTICES.md"
require_file "$LICENSES/TOOLS.md"
require_file "$LICENSES/ThirdPartyLicenses/managed-tools.json"
require_file "$LICENSES/ThirdPartyLicenses/Android-SDK-Platform-Tools-37.0.0-NOTICE.txt"
require_file "$LICENSES/Vendor/MTPKit/Package.swift"
require_file "$LICENSES/Vendor/MTPKit/LICENSE"
require_file "$LICENSES/Vendor/MTPKit/README.md"
require_file "$LICENSES/Vendor/MTPKit/UPSTREAM.md"
require_directory "$LICENSES/Vendor/MTPKit/Sources"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ENTITLEMENTS_FILE="$(/usr/bin/mktemp -t asop-entitlements.XXXXXX)"
trap '/bin/rm -f "$ENTITLEMENTS_FILE"' EXIT
/usr/bin/codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_FILE" 2>/dev/null \
  || fail "Could not read the app entitlements."
/usr/bin/plutil -lint "$ENTITLEMENTS_FILE" >/dev/null

USB_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.usb' "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
[[ "$USB_ENTITLEMENT" == "true" || "$USB_ENTITLEMENT" == "1" ]] \
  || fail "The USB entitlement is missing."

AUDIO_INPUT_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
[[ "$AUDIO_INPUT_ENTITLEMENT" == "true" || "$AUDIO_INPUT_ENTITLEMENT" == "1" ]] \
  || fail "The audio input entitlement is missing."

GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
[[ "$GET_TASK_ALLOW" != "true" && "$GET_TASK_ALLOW" != "1" ]] \
  || fail "Distribution artifacts must not contain get-task-allow."

python3 - "$APPROVED_ENTITLEMENTS" "$ENTITLEMENTS_FILE" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as approved_file:
    approved = plistlib.load(approved_file)
with open(sys.argv[2], "rb") as signed_file:
    signed = plistlib.load(signed_file)

if signed != approved:
    missing = sorted(set(approved) - set(signed))
    unexpected = sorted(set(signed) - set(approved))
    changed = sorted(
        key for key in set(approved) & set(signed) if approved[key] != signed[key]
    )
    print("The signed entitlements do not match the approved entitlement file.", file=sys.stderr)
    if missing:
        print(f"Missing: {', '.join(missing)}", file=sys.stderr)
    if unexpected:
        print(f"Unexpected: {', '.join(unexpected)}", file=sys.stderr)
    if changed:
        print(f"Changed: {', '.join(changed)}", file=sys.stderr)
    raise SystemExit(1)
PY

validate_distribution_signature() {
  local target="$1"
  local signing_details

  signing_details="$(/usr/bin/codesign -dvvv "$target" 2>&1)"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<< "$signing_details" \
    || fail "$target is not signed with a Developer ID Application certificate."
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$signing_details" \
    || fail "$target does not have hardened runtime enabled."
  /usr/bin/grep -q '^Timestamp=' <<< "$signing_details" \
    || fail "$target has no secure timestamp."
  if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    /usr/bin/grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<< "$signing_details" \
      || fail "$target is not signed by team $EXPECTED_TEAM_ID."
  fi
}

MACH_O_COUNT=0
while IFS= read -r candidate; do
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    MACH_O_COUNT=$((MACH_O_COUNT + 1))
    /usr/bin/codesign --verify --strict --verbose=2 "$candidate"
    if [[ "$REQUIRE_DISTRIBUTION" == true ]]; then
      validate_distribution_signature "$candidate"
    fi
  fi
done < <(/usr/bin/find "$CONTENTS" -type f -print)
[[ "$MACH_O_COUNT" -ge 1 ]] || fail "The app bundle contains no Mach-O executable."

ADB_PATH="$RESOURCES/Tools/platform-tools/adb"
if [[ -f "$ADB_PATH" ]]; then
  [[ -x "$ADB_PATH" ]] || fail "Bundled ADB is not executable."
  /usr/bin/codesign --verify --strict --verbose=2 "$ADB_PATH"
  require_file "$LICENSES/Android-SDK-Platform-Tools/NOTICE.txt"
  require_file "$LICENSES/Android-SDK-Platform-Tools/source.properties"
  require_file "$LICENSES/Android-SDK-Platform-Tools/BUNDLED-TOOL-MANIFEST.txt"
elif [[ "$REQUIRE_ADB" == true ]]; then
  fail "The required bundled ADB package is missing."
fi

if [[ "$REQUIRE_NO_BUNDLED_TOOLS" == true ]]; then
  for bundled_tool in \
    "$ADB_PATH" \
    "$RESOURCES/Tools/adb" \
    "$RESOURCES/Tools/scrcpy" \
    "$RESOURCES/Tools/scrcpy-server"; do
    [[ ! -e "$bundled_tool" ]] || fail "Standard artifacts must not bundle $bundled_tool."
  done
fi

if [[ "$REQUIRE_DISTRIBUTION" == true ]]; then
  validate_distribution_signature "$APP_PATH"
fi

if [[ "$REQUIRE_NOTARIZED" == true ]]; then
  /usr/bin/xcrun stapler validate "$APP_PATH"
  if ! GATEKEEPER_OUTPUT="$(/usr/sbin/spctl -a -t exec -vvv "$APP_PATH" 2>&1)"; then
    echo "$GATEKEEPER_OUTPUT" >&2
    fail "Gatekeeper rejected the app."
  fi
  /usr/bin/grep -q 'source=Notarized Developer ID' <<< "$GATEKEEPER_OUTPUT" \
    || fail "Gatekeeper did not report a notarized Developer ID app."
fi

echo "Validated $APP_PATH"
echo "Version: $(plist_value CFBundleShortVersionString) ($(plist_value CFBundleVersion))"
echo "Architectures: $ARCHITECTURES"
