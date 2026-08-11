# Release process

Pull requests cannot merge until the **Release readiness** check passes. That
check builds one universal app containing native `arm64` code for Apple silicon
and `x86_64` code for Intel Macs. The DMG has an Applications shortcut and the
app's icon as its mounted-volume icon. CI verifies its checksum, mounts it
read-only, validates both architectures, and opens the same universal app on
Apple silicon and Intel runners.

Pull-request builds are ad-hoc signed and never receive Apple credentials.

## Choose the release impact

Every change pull request should have one release label:

| Label | Use it for |
| --- | --- |
| `release:major` | A breaking change that needs a new major version |
| `release:minor` | A new feature that remains compatible |
| `release:patch` | A compatible fix or small improvement |
| `release:none` | Documentation, tests, or maintenance with no release note |

After a labeled pull request merges, automation updates a pull request named
**Release X.Y.Z**. It bumps [VERSION](VERSION), adds the merged pull requests
to a dated section of [CHANGELOG.md](CHANGELOG.md), and uses the highest
release impact waiting on `main`.

Review the generated version and notes like any other change. Merging that
release pull request starts the signed release workflow. Do not edit a release
tag by hand to work around a failed build.

For a newly created repository with no release tags, the manual workflow may
publish version 1.0.0 only when `main` contains exactly one root commit. Every
later release follows the normal version-transition checks.

GitHub may block Actions from opening the draft pull request unless
**Settings → Actions → General → Allow GitHub Actions to create and approve
pull requests** is enabled. GitHub combines creation and approval in this one
setting; this project's workflow creates a draft and never approves it. If the
setting remains off, the workflow still updates `release/next` and provides a
link for opening the pull request by hand.

## Configure the release environment

Create a GitHub environment named `release` under **Settings → Environments**.
Restrict it to protected branches and require a reviewer before a job can use
its secrets. A solo maintainer can be the reviewer with self-review allowed;
enable **Prevent self-review** only after adding a second trusted maintainer.
Disable administrator bypass when that option is available.

Store the following as environment secrets, not repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting that `.p12` |
| `APP_STORE_CONNECT_API_KEY_P8_BASE64` | Base64-encoded Team API `.p8` key |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect Team API issuer UUID |

The App Store Connect key must be a Team API key. Individual keys cannot be
used by `notarytool`. Use a dedicated Team key with the least access that works
for notarization, and revoke it immediately if it is lost or exposed.

### Export the signing identity

The `.p12` must contain both the Developer ID Application certificate and its
paired private key:

1. Open **Keychain Access → My Certificates**.
2. Expand **Developer ID Application: Adrian Babilinski (2XPCVTQ4HN)** and
   confirm that a private key appears beneath it.
3. Select the certificate and private key together, then choose
   **File → Export Items**.
4. Save a `.p12` and protect it with a strong, unique password.

Protect local copies so only your macOS account can read them:

```sh
chmod 600 DeveloperIDApplication.p12 AuthKey_XXXXXXXXXX.p8
```

Upload the files directly through standard input so their contents never appear
in a command argument, clipboard, or terminal output:

```sh
base64 -i DeveloperIDApplication.p12 |
  gh secret set --env release DEVELOPER_ID_CERTIFICATE_P12_BASE64
base64 -i AuthKey_XXXXXXXXXX.p8 |
  gh secret set --env release APP_STORE_CONNECT_API_KEY_P8_BASE64
read -rs CERTIFICATE_PASSWORD
printf '%s' "$CERTIFICATE_PASSWORD" |
  gh secret set --env release DEVELOPER_ID_CERTIFICATE_PASSWORD
unset CERTIFICATE_PASSWORD
```

Add the key ID and issuer ID through `gh secret set --env release` or the
GitHub settings page. Base64 is only an encoding; GitHub's encrypted environment
secret is what protects the value. Never commit a `.p12`, `.p8`, password file,
or encoded credential. Keep an encrypted offline backup of the `.p12`, and do
not leave its password in a plaintext file after setup.

The release job follows GitHub's documented temporary-keychain process on an
ephemeral GitHub-hosted macOS runner. Apple's `security import` command receives
the `.p12` password only during that isolated job. The imported key is
non-extractable, is limited to Apple code-signing tools, and is deleted in an
unconditional cleanup step. If the signing private key must never leave Apple,
use Apple's cloud-managed signing from Xcode instead of this command-line CI
workflow.

## Publish a release

The normal path is to review and merge the automated **Release X.Y.Z** pull
request. Its merge runs the same checked, signed, and notarized release process
described below.

### Manual fallback

Use the manual workflow only when release automation cannot prepare the pull
request:

1. Open **Actions → Publish release → Run workflow**.
2. Choose `main`.
3. Enter the version from [VERSION](VERSION).
4. Enter the full commit SHA for the `main` snapshot to release. From a current
   checkout, use `git rev-parse origin/main`. Use
   `git rev-list --count <commit>` for its build number.
5. Choose whether the release is a prerelease.

The workflow rejects a commit that is not on `main`, does not contain the
requested [VERSION](VERSION), lacks one unambiguous first-parent transition to
that version after the previous release tag, or has the wrong history-derived
build number. The automated release path uses the current validated `main`
snapshot. This also lets a failed release include a later pipeline-only fix
without changing the app version or bypassing its original version transition.

The workflow builds and tests one universal candidate before it can access
release credentials, including opening the app and requiring it to remain
running. A protected job then imports the temporary signing identity, signs the
exact tested candidate, and runs Apple's local notarization-readiness check.
If that check returns only its exact internal XProtect error, the workflow
retries three times before deferring to Apple's notary service; every other
local finding remains blocking. The job creates and signs one read-only DMG,
submits it to Apple, requires an Accepted result and an issue-free notarization
log, staples its ticket, checks Gatekeeper, and removes the credentials. The ZIP
used to pass the tested app between jobs is private and never published.
Separate jobs with no Apple credentials open the same universal build on Apple
silicon (`arm64`) and Intel (`x86_64`) Macs. The publishing job verifies its
digest again, creates a provenance attestation, and publishes the universal DMG
and its checksum.

Each DMG is an outer distribution that Apple notarizes and staples. Validation
also mounts it read-only and asks Gatekeeper to assess the contained app, but
the app does not need a second physical ticket stapled inside the signed DMG.

If any build, test, signature, notarization, archive, asset-integrity, or
Gatekeeper check fails, no public GitHub release is published. A failed draft
and its tag are removed automatically.

## Local artifact checks

Create and validate an ad-hoc signed candidate:

```sh
APP_VERSION=0.3.0 APP_BUILD=3 ./scripts/package-app.sh
./scripts/create-release-disk-image.sh \
  ".build/release/ASOP File Browser.app" \
  dist \
  0.3.0 \
  --version 0.3.0 \
  --build 3 \
  --require-no-bundled-tools
```

The default package is universal. Validation requires both `arm64` and
`x86_64` slices before the app can be distributed.
