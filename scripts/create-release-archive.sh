#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: create-release-archive.sh APP_PATH OUTPUT_DIRECTORY VERSION [validation options]

The validation options are passed to scripts/validate-app-bundle.sh before and
after the app is archived. The script creates a ZIP and matching .sha256 file.
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
VALIDATOR="$ROOT/scripts/validate-app-bundle.sh"
RELEASE_ARTIFACT_SUFFIX="${RELEASE_ARTIFACT_SUFFIX:-}"
if [[ -n "$RELEASE_ARTIFACT_SUFFIX" && ! "$RELEASE_ARTIFACT_SUFFIX" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "RELEASE_ARTIFACT_SUFFIX may contain only letters, numbers, and hyphens." >&2
  exit 2
fi
SUFFIX="${RELEASE_ARTIFACT_SUFFIX:+-$RELEASE_ARTIFACT_SUFFIX}"
ARCHIVE_NAME="AOSP-File-Manager-$VERSION-macOS$SUFFIX.zip"
CHECKSUM_NAME="$ARCHIVE_NAME.sha256"

mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
ARCHIVE_PATH="$OUTPUT_DIRECTORY/$ARCHIVE_NAME"
CHECKSUM_PATH="$OUTPUT_DIRECTORY/$CHECKSUM_NAME"
TEMPORARY_DIRECTORY="$(/usr/bin/mktemp -d -t asop-release-archive.XXXXXX)"

cleanup() {
  /bin/rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

"$VALIDATOR" "$APP_PATH" "$@"

/bin/rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
/usr/bin/unzip -tq "$ARCHIVE_PATH" >/dev/null

(
  cd "$OUTPUT_DIRECTORY"
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" >"$CHECKSUM_NAME"
  /usr/bin/shasum -a 256 -c "$CHECKSUM_NAME"
)

/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$TEMPORARY_DIRECTORY"
EXTRACTED_APP="$TEMPORARY_DIRECTORY/$(basename "$APP_PATH")"
"$VALIDATOR" "$EXTRACTED_APP" "$@"

echo "Created $ARCHIVE_PATH"
echo "Created $CHECKSUM_PATH"
