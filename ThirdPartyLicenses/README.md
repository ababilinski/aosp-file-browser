# License files

- `MTPKit-LICENSE.txt` accompanies MTPKit 0.1.4, which is compiled into AOSP File Manager.
- `Apache-2.0.txt` is the license used by the open-source ADB code.
- `Android-SDK-Platform-Tools-37.0.0-NOTICE.txt` is the complete matching notice from Google’s Platform-Tools 37.0.0 package.
- `scrcpy-4.1-LICENSE.txt` is the exact license published for scrcpy 4.1.
- `Android-SDK-Platform-Tools-37.0.0.md` records the exact ADB build accepted by the package script.
- `managed-tools.json` is the canonical record of the managed scrcpy and ADB versions, official sources, archive names, checksums, notice files, and website copyright.

These files do not by themselves authorize redistribution of every prebuilt tool package.

The matching MTPKit source and its upstream revision record are in [`../Vendor/MTPKit`](../Vendor/MTPKit).

The repository copy of the Platform-Tools notice has SHA-256 `f74735e1636534c2165b51815c4de870a2a06c24d8fe3e8c91149c841b81d33e`. If a release includes the complete Google Platform-Tools package, also include its unmodified `source.properties`. If a release includes scrcpy, include the notices, libraries, and any source or relinking materials required by that exact scrcpy build and its dependencies.

## Keeping the record current

Run `python3 scripts/validate-third-party-metadata.py` before changing a managed tool or notice. It checks the manifest against the app, packaging script, tests, public documentation, license files, website attribution, and copyright.

The scheduled third-party audit compares the pinned releases with the official scrcpy release API and Google’s Android SDK repository each week. If a stable version or published checksum changes, the workflow opens or updates a GitHub issue for review. It does not update binaries, checksums, or legal files automatically.
