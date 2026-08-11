# App metadata bridge

`AppMetadataBridge.java` reads installed-app labels and icons from each APK's
own resources. AOSP File Manager runs the compiled helper temporarily through
an existing debugging connection. It is not installed on the device.

The checked-in payload is generated from this source. To rebuild it, run
`./scripts/build-app-metadata-bridge.sh` from the repository root with an
Android SDK and Java installed.
