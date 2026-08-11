# Repository scripts

Run these commands from the repository root. Release policy, signing setup, and
the normal publishing flow are documented in [`RELEASING.md`](../RELEASING.md).

## Common commands

```sh
# Build the universal app bundle with an ad-hoc signature.
./scripts/package-app.sh

# Validate the packaged app.
./scripts/validate-app-bundle.sh \
  ".build/release/AOSP File Manager.app" \
  --require-no-bundled-tools

# Create and validate a local DMG and checksum.
./scripts/create-release-disk-image.sh \
  ".build/release/AOSP File Manager.app" \
  dist \
  "$(cat VERSION)" \
  --require-no-bundled-tools
```

`package-app.sh` reads `VERSION` by default and builds for the supported
macOS 13 deployment target. Its main overrides are
`APP_VERSION`, `APP_BUILD`, `MIN_MACOS_VERSION`, `CODE_SIGN_IDENTITY`, and the
optional `ADB_PLATFORM_TOOLS_DIR`.

## Script index

| Script | Purpose |
| --- | --- |
| `package-app.sh` | Builds the arm64/x86_64 app bundle, copies resources and licenses, and signs it. |
| `validate-app-bundle.sh` | Checks bundle structure, versions, architectures, entitlements, signatures, notarization, and bundled-tool policy. |
| `verify-app-launch.sh` | Opens an app bundle and confirms that it remains running long enough to catch an immediate failure. |
| `create-release-disk-image.sh` | Creates the branded read-only DMG and matching SHA-256 file, validating the app and DMG along the way. |
| `validate-release-disk-image.sh` | Mounts and inspects a DMG; it can also require signing, notarization, and a successful app launch. |
| `create-release-archive.sh` | Creates and revalidates an optional ZIP archive and checksum. The public release currently uses the DMG. |
| `check-notary-submission-readiness.sh` | Runs Apple's local notarization preflight and narrowly handles its known internal XProtect error. |
| `release_metadata.py` | Validates release labels, generates release-PR version/changelog updates, and checks version transitions. |
| `validate-third-party-metadata.py` | Confirms pinned tool metadata, notices, licenses, and website attribution remain consistent. |
| `audit-third-party-upstream.py` | Checks the network for newer scrcpy and Android Platform-Tools releases. |

Shell validators with options support `--help`. Python command details are
available with `python3 scripts/<name>.py --help`.

## Script tests

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/validate-third-party-metadata.py
```

GitHub Actions runs these helpers as part of pull-request and release
validation. Local signing and notarization commands still require the
credentials and environment described in [`RELEASING.md`](../RELEASING.md).
