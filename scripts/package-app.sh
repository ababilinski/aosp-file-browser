#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ASOP File Browser"
VERSION_FILE="$ROOT/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "Missing version file: $VERSION_FILE" >&2
  exit 1
fi

TRACKED_APP_VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
if [[ ! "$TRACKED_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain a three-part version such as 0.3.0." >&2
  exit 1
fi

APP_VERSION="${APP_VERSION:-$TRACKED_APP_VERSION}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "APP_VERSION must be a three-part version such as 0.3.0." >&2
  exit 1
fi
APP_BUILD="${APP_BUILD:-2}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"
ADB_PLATFORM_TOOLS_DIR="${ADB_PLATFORM_TOOLS_DIR:-}"
ADB_PINNED_REVISION="37.0.0"
ADB_PINNED_SHA256="9fdf861259dc807937b13afdd5f053c7fda9f3b7726933fe0e0f45130ecb8dc7"
ADB_NOTICE_PINNED_SHA256="f74735e1636534c2165b51815c4de870a2a06c24d8fe3e8c91149c841b81d33e"
ADB_SOURCE_PROPERTIES_PINNED_SHA256="fbd87c8567afbc6dc78e140097fcde234f4a61fa7065e85081d43e442ccd3d24"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP_ARCHITECTURE="${APP_ARCHITECTURE:-universal}"

case "$APP_ARCHITECTURE" in
  universal)
    SWIFT_ARCHITECTURES=(--arch arm64 --arch x86_64)
    REQUIRED_ARCHITECTURES=(arm64 x86_64)
    DEFAULT_BUNDLE_DIRECTORY="$ROOT/.build/release"
    ;;
  arm64)
    SWIFT_ARCHITECTURES=(--arch arm64)
    REQUIRED_ARCHITECTURES=(arm64)
    DEFAULT_BUNDLE_DIRECTORY="$ROOT/.build/release-arm64"
    ;;
  x86_64)
    SWIFT_ARCHITECTURES=(--arch x86_64)
    REQUIRED_ARCHITECTURES=(x86_64)
    DEFAULT_BUNDLE_DIRECTORY="$ROOT/.build/release-x86_64"
    ;;
  *)
    echo "APP_ARCHITECTURE must be universal, arm64, or x86_64." >&2
    exit 2
    ;;
esac

BUNDLE="${APP_BUNDLE_OUTPUT_PATH:-$DEFAULT_BUNDLE_DIRECTORY/$APP_NAME.app}"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
TOOLS="$RESOURCES/Tools"
LICENSES="$RESOURCES/Licenses"
ENTITLEMENTS="$ROOT/Resources/AndroidFileBrowser.entitlements"
APP_ICON="$ROOT/Resources/AppIcon.icns"

cd "$ROOT"
swift build -c release "${SWIFT_ARCHITECTURES[@]}"

BUILD_OUTPUT="$(swift build --show-bin-path -c release "${SWIFT_ARCHITECTURES[@]}")"
APP_BINARY="$BUILD_OUTPUT/AndroidFileBrowser"
[[ -x "$APP_BINARY" ]] || {
  echo "Missing release executable: $APP_BINARY" >&2
  exit 1
}

APP_ARCHS="$(/usr/bin/lipo -archs "$APP_BINARY" 2>/dev/null || true)"
for required_arch in "${REQUIRED_ARCHITECTURES[@]}"; do
  if [[ " $APP_ARCHS " != *" $required_arch "* ]]; then
    echo "Packaged app must support $required_arch; found: ${APP_ARCHS:-unknown}" >&2
    exit 1
  fi
done
if [[ "$(wc -w <<< "$APP_ARCHS" | tr -d ' ')" -ne "${#REQUIRED_ARCHITECTURES[@]}" ]]; then
  echo "Packaged app has unexpected architectures: ${APP_ARCHS:-unknown}" >&2
  exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$TOOLS/platform-tools" "$LICENSES"
cp "$APP_BINARY" "$MACOS/$APP_NAME"

if [[ ! -f "$APP_ICON" ]]; then
  echo "Missing app icon: $APP_ICON" >&2
  exit 1
fi
cp "$APP_ICON" "$RESOURCES/AppIcon.icns"

MTPKIT_BUNDLE=""
for candidate in \
  "$BUILD_OUTPUT/MTPKit_MTPKit.bundle" \
  "$ROOT/.build/apple/Products/Release/MTPKit_MTPKit.bundle" \
  "$ROOT/.build/release/MTPKit_MTPKit.bundle"; do
  if [[ -d "$candidate" ]]; then
    MTPKIT_BUNDLE="$candidate"
    break
  fi
done

if [[ -z "$MTPKIT_BUNDLE" ]]; then
  echo "Missing MTPKit_MTPKit.bundle from the release build." >&2
  exit 1
fi
cp -R "$MTPKIT_BUNDLE" "$RESOURCES/MTPKit_MTPKit.bundle"

cp "$ROOT/LICENSE" "$LICENSES/Android-File-Browser-GPL-3.0.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$LICENSES/THIRD_PARTY_NOTICES.md"
cp "$ROOT/TOOLS.md" "$LICENSES/TOOLS.md"
PROJECT_ADB_NOTICE="$ROOT/ThirdPartyLicenses/Android-SDK-Platform-Tools-37.0.0-NOTICE.txt"
if [[ ! -f "$PROJECT_ADB_NOTICE" ]] || [[ "$(/usr/bin/shasum -a 256 "$PROJECT_ADB_NOTICE" | awk '{print $1}')" != "$ADB_NOTICE_PINNED_SHA256" ]]; then
  echo "The packaged Platform-Tools 37.0.0 NOTICE is missing or does not match its pinned SHA-256." >&2
  exit 1
fi
cp -R "$ROOT/ThirdPartyLicenses" "$LICENSES/ThirdPartyLicenses"
mkdir -p "$LICENSES/Vendor"
MTPKIT_SOURCE_LICENSES="$LICENSES/Vendor/MTPKit"
mkdir -p "$MTPKIT_SOURCE_LICENSES"
for source_file in Package.swift LICENSE README.md UPSTREAM.md; do
  cp "$ROOT/Vendor/MTPKit/$source_file" "$MTPKIT_SOURCE_LICENSES/$source_file"
done
cp -R "$ROOT/Vendor/MTPKit/Sources" "$MTPKIT_SOURCE_LICENSES/Sources"

# Platform-Tools may be added only from a complete package whose matching
# NOTICE.txt and source.properties are available. Arbitrary PATH binaries are
# deliberately not copied into release bundles.
if [[ -n "$ADB_PLATFORM_TOOLS_DIR" ]]; then
  for required in adb NOTICE.txt source.properties; do
    if [[ ! -f "$ADB_PLATFORM_TOOLS_DIR/$required" ]]; then
      echo "ADB_PLATFORM_TOOLS_DIR is missing $required" >&2
      exit 1
    fi
  done

  ADB_ARCHS="$(/usr/bin/lipo -archs "$ADB_PLATFORM_TOOLS_DIR/adb" 2>/dev/null || true)"
  for required_arch in arm64 x86_64; do
    if [[ " $ADB_ARCHS " != *" $required_arch "* ]]; then
      echo "Bundled adb must support $required_arch; found: ${ADB_ARCHS:-unknown}" >&2
      exit 1
    fi
  done

  ADB_REVISION="$(sed -n 's/^Pkg.Revision=//p' "$ADB_PLATFORM_TOOLS_DIR/source.properties" | head -1)"
  ADB_SHA256="$(/usr/bin/shasum -a 256 "$ADB_PLATFORM_TOOLS_DIR/adb" | awk '{print $1}')"
  ADB_NOTICE_SHA256="$(/usr/bin/shasum -a 256 "$ADB_PLATFORM_TOOLS_DIR/NOTICE.txt" | awk '{print $1}')"
  ADB_SOURCE_PROPERTIES_SHA256="$(/usr/bin/shasum -a 256 "$ADB_PLATFORM_TOOLS_DIR/source.properties" | awk '{print $1}')"

  if [[ "$ADB_REVISION" != "$ADB_PINNED_REVISION" ]]; then
    echo "Platform-Tools revision must be $ADB_PINNED_REVISION; found: ${ADB_REVISION:-unknown}" >&2
    exit 1
  fi
  if [[ "$ADB_SHA256" != "$ADB_PINNED_SHA256" ]]; then
    echo "adb SHA-256 does not match the pinned Platform-Tools $ADB_PINNED_REVISION build." >&2
    exit 1
  fi
  if [[ "$ADB_NOTICE_SHA256" != "$ADB_NOTICE_PINNED_SHA256" ]]; then
    echo "NOTICE.txt SHA-256 does not match the pinned Platform-Tools $ADB_PINNED_REVISION package." >&2
    exit 1
  fi
  if [[ "$ADB_SOURCE_PROPERTIES_SHA256" != "$ADB_SOURCE_PROPERTIES_PINNED_SHA256" ]]; then
    echo "source.properties SHA-256 does not match the pinned Platform-Tools $ADB_PINNED_REVISION package." >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict "$ADB_PLATFORM_TOOLS_DIR/adb"

  cp "$ADB_PLATFORM_TOOLS_DIR/adb" "$TOOLS/platform-tools/adb"
  chmod +x "$TOOLS/platform-tools/adb"
  mkdir -p "$LICENSES/Android-SDK-Platform-Tools"
  cp "$ADB_PLATFORM_TOOLS_DIR/NOTICE.txt" "$LICENSES/Android-SDK-Platform-Tools/NOTICE.txt"
  cp "$ADB_PLATFORM_TOOLS_DIR/source.properties" "$LICENSES/Android-SDK-Platform-Tools/source.properties"
  cat > "$LICENSES/Android-SDK-Platform-Tools/BUNDLED-TOOL-MANIFEST.txt" <<MANIFEST
Component: Android SDK Platform-Tools adb
Revision: $ADB_REVISION
adb SHA-256: $ADB_SHA256
NOTICE.txt SHA-256: $ADB_NOTICE_SHA256
source.properties SHA-256: $ADB_SOURCE_PROPERTIES_SHA256
Official download: https://developer.android.com/tools/releases/platform-tools
MANIFEST
else
  echo "ADB is not bundled. The app will use a compatible install on the Mac."
fi

echo "scrcpy is not bundled. The app can install verified phone tools in Application Support; see TOOLS.md."

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.ababilinski.android-file-browser</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS_VERSION</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Adrian Babilinski</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>ASOP File Browser records audio from your Mac's microphone when you include it in a screen recording.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE" >/dev/null
  echo "Applied an ad-hoc signature for local testing."
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$BUNDLE" >/dev/null
  echo "Signed with $CODE_SIGN_IDENTITY. Notarization is a separate release step."
fi

echo "Built $BUNDLE"
