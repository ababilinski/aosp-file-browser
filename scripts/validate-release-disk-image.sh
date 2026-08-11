#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: validate-release-disk-image.sh DISK_IMAGE_PATH [options]

App validation options are passed to scripts/validate-app-bundle.sh.
Use --architecture universal, --architecture arm64, or --architecture x86_64
to validate the matching app executable.

Disk image options:
  --dmg-signed       Require a Developer ID signature on the disk image.
  --dmg-notarized    Require a stapled ticket and Gatekeeper acceptance for
                     the disk image. This also requires --dmg-signed.
  --launch-app       Open the app from the mounted disk image and require it to
                     remain running long enough to catch immediate failures.
USAGE
}

fail() {
  echo "Disk image validation failed: $*" >&2
  exit 1
}

DISK_IMAGE_PATH="${1:-}"
[[ -n "$DISK_IMAGE_PATH" ]] || {
  usage >&2
  exit 2
}
shift

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_VALIDATOR="$ROOT/scripts/validate-app-bundle.sh"
APP_LAUNCH_VERIFIER="$ROOT/scripts/verify-app-launch.sh"
EXPECTED_TEAM_ID=""
REQUIRE_APP_DISTRIBUTION=false
REQUIRE_DMG_SIGNATURE=false
REQUIRE_DMG_NOTARIZATION=false
REQUIRE_APP_LAUNCH=false
APP_VALIDATION_OPTIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg-signed)
      REQUIRE_DMG_SIGNATURE=true
      shift
      ;;
    --dmg-notarized)
      REQUIRE_DMG_SIGNATURE=true
      REQUIRE_DMG_NOTARIZATION=true
      shift
      ;;
    --launch-app)
      REQUIRE_APP_LAUNCH=true
      shift
      ;;
    --team-id)
      [[ $# -ge 2 ]] || fail "--team-id needs a value."
      EXPECTED_TEAM_ID="$2"
      APP_VALIDATION_OPTIONS+=("$1" "$2")
      shift 2
      ;;
    --version|--build|--architecture)
      [[ $# -ge 2 ]] || fail "$1 needs a value."
      APP_VALIDATION_OPTIONS+=("$1" "$2")
      shift 2
      ;;
    --distribution)
      REQUIRE_APP_DISTRIBUTION=true
      APP_VALIDATION_OPTIONS+=("$1")
      shift
      ;;
    --notarized)
      REQUIRE_APP_DISTRIBUTION=true
      APP_VALIDATION_OPTIONS+=("$1")
      shift
      ;;
    --require-adb|--require-no-bundled-tools)
      APP_VALIDATION_OPTIONS+=("$1")
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

if [[ "$REQUIRE_DMG_SIGNATURE" == true && "$REQUIRE_APP_DISTRIBUTION" != true ]]; then
  fail "A signed release disk image must also require a distribution-signed app."
fi

[[ -f "$DISK_IMAGE_PATH" ]] || fail "Missing disk image: $DISK_IMAGE_PATH"
DISK_IMAGE_PATH="$(cd "$(dirname "$DISK_IMAGE_PATH")" && pwd)/$(basename "$DISK_IMAGE_PATH")"

/usr/bin/hdiutil verify "$DISK_IMAGE_PATH" >/dev/null

if [[ "$REQUIRE_DMG_SIGNATURE" == true ]]; then
  /usr/bin/codesign --verify --strict --verbose=2 "$DISK_IMAGE_PATH"
  SIGNING_DETAILS="$(/usr/bin/codesign -dvvv "$DISK_IMAGE_PATH" 2>&1)"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<< "$SIGNING_DETAILS" \
    || fail "The disk image is not signed with a Developer ID Application certificate."
  /usr/bin/grep -q '^Timestamp=' <<< "$SIGNING_DETAILS" \
    || fail "The disk image signature has no secure timestamp."
  if [[ -n "$EXPECTED_TEAM_ID" ]]; then
    /usr/bin/grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<< "$SIGNING_DETAILS" \
      || fail "The disk image is not signed by team $EXPECTED_TEAM_ID."
  fi
fi

if [[ "$REQUIRE_DMG_NOTARIZATION" == true ]]; then
  /usr/bin/xcrun stapler validate "$DISK_IMAGE_PATH"
  if ! GATEKEEPER_OUTPUT="$(
      /usr/sbin/spctl \
        -a \
        -t open \
        --context context:primary-signature \
        -vvv \
        "$DISK_IMAGE_PATH" 2>&1
    )"; then
    echo "$GATEKEEPER_OUTPUT" >&2
    fail "Gatekeeper rejected the disk image."
  fi
  /usr/bin/grep -q 'source=Notarized Developer ID' <<< "$GATEKEEPER_OUTPUT" \
    || fail "Gatekeeper did not report a notarized Developer ID disk image."
fi

MOUNT_POINT="$(/usr/bin/mktemp -d -t asop-release-dmg.XXXXXX)"
ATTACHED=false

cleanup() {
  if [[ "$ATTACHED" == true ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
      || /usr/bin/hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1 \
      || true
  fi
  /bin/rm -rf "$MOUNT_POINT"
}
trap cleanup EXIT

/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$MOUNT_POINT" \
  "$DISK_IMAGE_PATH" >/dev/null
ATTACHED=true

APP_PATH="$MOUNT_POINT/AOSP File Manager.app"
VOLUME_ICON_PATH="$MOUNT_POINT/.VolumeIcon.icns"
[[ -d "$APP_PATH" ]] || fail "The disk image does not contain AOSP File Manager.app."
[[ -L "$MOUNT_POINT/Applications" ]] \
  || fail "The disk image does not contain an Applications shortcut."
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || fail "The Applications shortcut has an unexpected destination."
[[ -f "$VOLUME_ICON_PATH" ]] \
  || fail "The disk image does not contain a custom volume icon."
/usr/bin/cmp -s "$ROOT/Resources/AppIcon.icns" "$VOLUME_ICON_PATH" \
  || fail "The disk image volume icon does not match the app icon."

VOLUME_ICON_TYPE="$(/usr/bin/xcrun GetFileInfo -c "$VOLUME_ICON_PATH")"
[[ "$VOLUME_ICON_TYPE" == '"icnC"' ]] \
  || fail "The disk image volume icon is missing its icon-file type."
VOLUME_ATTRIBUTES="$(/usr/bin/xcrun GetFileInfo -a "$MOUNT_POINT")"
[[ "$VOLUME_ATTRIBUTES" == *C* ]] \
  || fail "The disk image volume is missing its custom-icon attribute."

"$APP_VALIDATOR" "$APP_PATH" "${APP_VALIDATION_OPTIONS[@]}"

if [[ "$REQUIRE_DMG_NOTARIZATION" == true ]]; then
  if ! APP_GATEKEEPER_OUTPUT="$(
      /usr/sbin/spctl -a -t exec -vvv "$APP_PATH" 2>&1
    )"; then
    echo "$APP_GATEKEEPER_OUTPUT" >&2
    fail "Gatekeeper rejected the app inside the disk image."
  fi
  /usr/bin/grep -q 'source=Notarized Developer ID' <<< "$APP_GATEKEEPER_OUTPUT" \
    || fail "Gatekeeper did not report a notarized Developer ID app."
  # Apple notarizes and staples the outer DMG. Gatekeeper above confirms that
  # its ticket covers the nested app; the app does not need a second staple.
fi

if [[ "$REQUIRE_APP_LAUNCH" == true ]]; then
  "$APP_LAUNCH_VERIFIER" "$APP_PATH"
fi

echo "Validated $DISK_IMAGE_PATH"
