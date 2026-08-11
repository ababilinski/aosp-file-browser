# Third-Party Notices

AOSP File Manager is licensed under the GNU General Public License version 3. This file identifies separate software that is compiled into the app or can be used with optional features.

## Included in the application

### MTPKit 0.1.4

- Copyright: © 2026 Ricky Chuang
- License: MIT
- Source: https://github.com/5j54d93/MTPKit/tree/0.1.4
- Upstream revision: `7ad0c0f3a0a6443408f2b3721a58594a1641d242`
- Vendored source: [`Vendor/MTPKit`](Vendor/MTPKit)
- Use: USB File Transfer Mode

The complete license is in [`ThirdPartyLicenses/MTPKit-LICENSE.txt`](ThirdPartyLicenses/MTPKit-LICENSE.txt).

## Tools used by optional features

The default app bundle does not include ADB or scrcpy. AOSP File Manager can find compatible installations already on the Mac. With the user's approval, it can also download the official scrcpy 4.1 macOS archive directly into Application Support. The archive checksum is verified before extraction. See [`TOOLS.md`](TOOLS.md) for details and manual installation choices.

### Android Debug Bridge (ADB)

- Project: Android Open Source Project, Android SDK Platform-Tools
- License: ADB source is principally Apache License 2.0; Google’s SDK terms apply to Google’s downloadable Platform-Tools package
- Source: https://android.googlesource.com/platform/packages/modules/adb/
- Official download: https://developer.android.com/tools/releases/platform-tools
- Use: USB and Wi-Fi debugging, file operations, app tools, screenshots, and recording

The Apache License 2.0 is in [`ThirdPartyLicenses/Apache-2.0.txt`](ThirdPartyLicenses/Apache-2.0.txt).

The complete matching Platform-Tools 37.0.0 notice is in [`ThirdPartyLicenses/Android-SDK-Platform-Tools-37.0.0-NOTICE.txt`](ThirdPartyLicenses/Android-SDK-Platform-Tools-37.0.0-NOTICE.txt).

The managed scrcpy 4.1 archive contains the same universal, Google-signed ADB 37.0.0 executable recorded in [`ThirdPartyLicenses/Android-SDK-Platform-Tools-37.0.0.md`](ThirdPartyLicenses/Android-SDK-Platform-Tools-37.0.0.md). It is downloaded from Genymobile's official release rather than mirrored by this project.

The package script can separately include the pinned Platform-Tools 37.0.0 ADB build only when its executable, `NOTICE.txt`, and `source.properties` match the recorded SHA-256 hashes. A bundled build carries those files and a tool manifest inside the app. Anyone distributing that build must also comply with the terms accepted when Platform-Tools was downloaded. A generic Apache license file is not a replacement for the package’s complete notice.

### scrcpy

- Copyright: © 2018 Genymobile; © 2018–2026 Romain Vimont
- License: Apache License 2.0
- Source and official releases: https://github.com/Genymobile/scrcpy
- macOS installation guide: https://github.com/Genymobile/scrcpy/blob/master/doc/macos.md
- Use: Phone Control

The scrcpy 4.1 license and attribution are in [`ThirdPartyLicenses/scrcpy-4.1-LICENSE.txt`](ThirdPartyLicenses/scrcpy-4.1-LICENSE.txt).

The app-managed setup downloads one of these pinned official archives:

- Apple silicon: `scrcpy-macos-aarch64-v4.1.tar.gz`, SHA-256 `20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3`
- Intel: `scrcpy-macos-x86_64-v4.1.tar.gz`, SHA-256 `ee2a7223bc8dbdc4f482db1134bcf441178dafb833492b71ca4c22090c58ce72`

Distributors must not copy an arbitrary Homebrew `scrcpy` executable into a release. Homebrew builds can depend on FFmpeg, SDL, libusb, and other files that remain outside the app bundle. Anyone distributing a portable or custom scrcpy build is responsible for including the licenses, notices, dependent libraries, and source or relinking materials required by that exact build.

## Software supplied by macOS or the phone

Apple frameworks and standard macOS tools are supplied by macOS and are not redistributed by this project. Android shell utilities such as `pm`, `screencap`, and `screenrecord` are supplied by the connected phone.

## Trademarks

Android is a trademark of Google LLC. ADB, scrcpy, MTPKit, Google, and other names belong to their respective owners and are used only to identify compatibility. AOSP File Manager is not affiliated with or endorsed by those projects or owners.

## Android robot

*The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the* [*Creative Commons*](https://creativecommons.org/licenses/by/3.0/) *3.0 Attribution License.*
