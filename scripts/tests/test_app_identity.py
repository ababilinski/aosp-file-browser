import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class AppIdentityTests(unittest.TestCase):
    def test_release_identity_matches_app_store_connect(self):
        identity = (ROOT / "scripts" / "app-identity.sh").read_text(encoding="utf-8")

        self.assertRegex(identity, r'(?m)^AOSP_APP_NAME="AOSP File Manager"$')
        self.assertRegex(
            identity,
            r'(?m)^AOSP_BUNDLE_ID="com\.ababilinski\.aospfilebrowser"$',
        )

    def test_packaging_does_not_restore_the_old_bundle_identifier(self):
        packaging = (ROOT / "scripts" / "package-app.sh").read_text(encoding="utf-8")
        validation = (ROOT / "scripts" / "validate-app-bundle.sh").read_text(encoding="utf-8")

        self.assertNotIn("com.ababilinski.android-file-browser", packaging)
        self.assertNotIn("com.ababilinski.android-file-browser", validation)
        self.assertIn("<string>$BUNDLE_ID</string>", packaging)
        self.assertIn('"$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID"', validation)


if __name__ == "__main__":
    unittest.main()
