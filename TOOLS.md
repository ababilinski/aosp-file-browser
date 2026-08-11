# ADB and scrcpy

AOSP File Manager can use tools already installed on your Mac. If one is missing, open **Settings → Tools**, choose **Managed Copy** for that tool, then choose **Download**. The app never downloads or updates tools in the background.

File Transfer Mode does not need ADB or scrcpy. Debugging features use ADB. Phone Control also uses scrcpy.

## Install ADB

In **Settings → Tools**, set the ADB source to **Managed Copy**, then choose **Download**. This stores the official scrcpy 4.1 macOS package in Application Support. That package includes ADB 37.0.0 and the matching Phone Control files. It does not need Homebrew, Terminal, or an administrator password.

The app downloads directly from the [official scrcpy 4.1 release](https://github.com/Genymobile/scrcpy/releases/tag/v4.1) and verifies its architecture-specific SHA-256 checksum before extracting anything.

You can also install ADB yourself:

Use either of these official paths:

1. Install Android SDK Platform-Tools through Android Studio’s SDK Manager.
2. Download Platform-Tools for Mac from [Android Developers](https://developer.android.com/tools/releases/platform-tools).

Homebrew also provides Google’s Platform-Tools package:

```sh
brew install --cask android-platform-tools
```

Google requires you to accept the Android SDK License Agreement before using its download. Keep Platform-Tools updated as a complete package; do not copy only `adb` out of a release and redistribute it without the matching notices.

## Install scrcpy

In **Settings → Tools**, set the scrcpy source to **Managed Copy**, then choose **Download**. This sets up scrcpy with its matching server and ADB. You can also install it yourself:

Follow the [official scrcpy macOS guide](https://github.com/Genymobile/scrcpy/blob/master/doc/macos.md), or install it with Homebrew:

```sh
brew install scrcpy
```

The Homebrew installation uses ADB from your system. Official standalone builds and their published SHA-256 checksums are available from the [scrcpy releases page](https://github.com/Genymobile/scrcpy/releases).

## Choose a tool in the app

Open **Settings → Tools**.

- **Automatic** prefers a verified app-managed copy, then checks Android Studio and Unity SDK locations, Homebrew, your `PATH`, and a bundled copy when a distributor has provided one correctly.
- **Managed Copy** uses the verified copy downloaded by AOSP File Manager. If it is not present, choose **Download** beside the tool.
- **Choose…** selects a specific executable.
- **Bundled Copy** appears only when a distributor supplied that tool inside the app.

The status beneath each picker shows the executable the app is using.

## Distribution notes

The standard package script does not copy arbitrary ADB or scrcpy binaries from the build machine. It can include only the pinned Platform-Tools 37.0.0 ADB build with matching hashes and notices. The user-approved managed setup remains outside the app bundle in Application Support. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Create the standard local bundle:

```sh
./scripts/package-app.sh
```

Include the pinned ADB build from a complete Platform-Tools directory:

```sh
ADB_PLATFORM_TOOLS_DIR="$HOME/Library/Android/sdk/platform-tools" ./scripts/package-app.sh
```

The script applies an ad-hoc signature for local testing. Set `CODE_SIGN_IDENTITY` to a Developer ID Application identity for a release build. Notarization is still a separate release step.
