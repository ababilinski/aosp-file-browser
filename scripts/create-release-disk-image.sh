#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: create-release-disk-image.sh APP_PATH OUTPUT_DIRECTORY VERSION [validation options]

The validation options are passed to scripts/validate-app-bundle.sh before the
disk image is created and to scripts/validate-release-disk-image.sh afterward.
The script creates a read-only DMG with an Applications shortcut, a branded
volume icon, and a matching .sha256 file.
USAGE
}

APP_PATH="${1:-}"
OUTPUT_DIRECTORY="${2:-}"
VERSION="${3:-}"
if [[ -z "$APP_PATH" || -z "$OUTPUT_DIRECTORY" || -z "$VERSION" ]]; then
  usage >&2
  exit 2
fi
shift 3

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must contain three numeric components, such as 1.2.3." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_VALIDATOR="$ROOT/scripts/validate-app-bundle.sh"
DMG_VALIDATOR="$ROOT/scripts/validate-release-disk-image.sh"
VOLUME_ICON="$ROOT/Resources/AppIcon.icns"
RELEASE_ARTIFACT_SUFFIX="${RELEASE_ARTIFACT_SUFFIX:-}"
if [[ -n "$RELEASE_ARTIFACT_SUFFIX" && ! "$RELEASE_ARTIFACT_SUFFIX" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "RELEASE_ARTIFACT_SUFFIX may contain only letters, numbers, and hyphens." >&2
  exit 2
fi
SUFFIX="${RELEASE_ARTIFACT_SUFFIX:+-$RELEASE_ARTIFACT_SUFFIX}"
DISK_IMAGE_NAME="AOSP-File-Manager-$VERSION-macOS$SUFFIX.dmg"
CHECKSUM_NAME="$DISK_IMAGE_NAME.sha256"

mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
DISK_IMAGE_PATH="$OUTPUT_DIRECTORY/$DISK_IMAGE_NAME"
CHECKSUM_PATH="$OUTPUT_DIRECTORY/$CHECKSUM_NAME"
TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d -t asop-release-image.XXXXXX)"
STAGING_DIRECTORY="$TEMPORARY_DIRECTORY/staging"
MOUNT_POINT="$TEMPORARY_DIRECTORY/mount"
WRITABLE_DISK_IMAGE="$TEMPORARY_DIRECTORY/AOSP-File-Manager-writable.dmg"
ATTACHED=false

cleanup() {
  if [[ "$ATTACHED" == true ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
      || /usr/bin/hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1 \
      || true
  fi
  /bin/rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

"$APP_VALIDATOR" "$APP_PATH" "$@"
if [[ ! -f "$VOLUME_ICON" ]]; then
  echo "Missing disk image volume icon: $VOLUME_ICON" >&2
  exit 1
fi

/bin/mkdir -p "$STAGING_DIRECTORY" "$MOUNT_POINT"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIRECTORY/AOSP File Manager.app"
/bin/ln -s /Applications "$STAGING_DIRECTORY/Applications"
/usr/bin/ditto "$VOLUME_ICON" "$STAGING_DIRECTORY/.VolumeIcon.icns"

/bin/rm -f "$DISK_IMAGE_PATH" "$CHECKSUM_PATH"

# hdiutil can briefly report "Resource busy" on otherwise idle hosted macOS
# runners. Remove any partial image and retry only that transient failure;
# other errors still fail immediately with their original output and status.
create_writable_disk_image() {
  local attempt output status
  for attempt in 1 2 3; do
    /bin/rm -f "$WRITABLE_DISK_IMAGE"
    if output="$(/usr/bin/hdiutil create \
      -ov \
      -fs HFS+ \
      -format UDRW \
      -volname "AOSP File Manager" \
      -srcfolder "$STAGING_DIRECTORY" \
      "$WRITABLE_DISK_IMAGE" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi

    printf '%s\n' "$output" >&2
    if [[ "$output" != *"Resource busy"* || "$attempt" -eq 3 ]]; then
      return "$status"
    fi

    echo "hdiutil was temporarily busy; retrying disk image creation ($attempt/3)." >&2
    /bin/sleep "$((attempt * 2))"
  done
}

create_writable_disk_image

/usr/bin/hdiutil attach \
  -readwrite \
  -nobrowse \
  -noautoopen \
  -mountpoint "$MOUNT_POINT" \
  "$WRITABLE_DISK_IMAGE" >/dev/null
ATTACHED=true

# Finder recognizes a custom volume icon only when the root volume has the
# custom-icon bit and .VolumeIcon.icns has the classic icon-file type.
/usr/bin/xcrun SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns"
/usr/bin/xcrun SetFile -a C "$MOUNT_POINT"
/bin/sync

/usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
ATTACHED=false

/usr/bin/hdiutil convert \
  "$WRITABLE_DISK_IMAGE" \
  -format UDZO \
  -o "$DISK_IMAGE_PATH" >/dev/null

"$DMG_VALIDATOR" "$DISK_IMAGE_PATH" "$@"

(
  cd "$OUTPUT_DIRECTORY"
  /usr/bin/shasum -a 256 "$DISK_IMAGE_NAME" >"$CHECKSUM_NAME"
  /usr/bin/shasum -a 256 -c "$CHECKSUM_NAME"
)

echo "Created $DISK_IMAGE_PATH"
echo "Created $CHECKSUM_PATH"
