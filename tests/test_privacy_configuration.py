import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENTS = ROOT / "DynamicIsland" / "DynamicIsland.entitlements"
PROJECT = ROOT / "Orbit.xcodeproj" / "project.pbxproj"
RELEASE_SCRIPT = ROOT / "scripts" / "sign_local_release.sh"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class PrivacyConfigurationTests(unittest.TestCase):
    def test_camera_capture_is_explicitly_entitled(self):
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertTrue(entitlements.get("com.apple.security.device.camera"))

    def test_notes_sync_is_authorized_for_apple_events(self):
        project = PROJECT.read_text()
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertNotIn("AUTOMATION_APPLE_EVENTS = NO;", project)
        self.assertIn(
            "com.apple.Notes",
            entitlements["com.apple.security.temporary-exception.apple-events"],
        )

    def test_automation_usage_text_names_notes(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count(
                'INFOPLIST_KEY_NSAppleEventsUsageDescription = "Orbit uses AppleScripts to control Spotify, Apple Music, and Notes.";'
            ),
        )

    def test_full_access_reminder_api_has_matching_usage_text(self):
        project = PROJECT.read_text()

        self.assertEqual(
            2,
            project.count("INFOPLIST_KEY_NSRemindersFullAccessUsageDescription ="),
        )

    def test_local_release_signing_preserves_required_entitlements(self):
        workflow = RELEASE_SCRIPT.read_text()

        self.assertIn('ENTITLEMENTS_PATH="$SCRIPT_ROOT/DynamicIsland/DynamicIsland.entitlements"', workflow)
        self.assertIn('--entitlements "$ENTITLEMENTS_PATH"', workflow)
        self.assertIn(
            'codesign -d --entitlements :- "$APP_PATH" > "$FINAL_ENTITLEMENTS_PATH"',
            workflow,
        )
        self.assertIn('com.apple.security.device.camera com.apple.security.automation.apple-events', workflow)
        self.assertIn('codesign --verify --deep --strict', workflow)
        self.assertIn('[[ "$SIGNING_IDENTITY" != "-" ]]', workflow)

    def test_ci_checks_the_privacy_configuration(self):
        workflow = CI_WORKFLOW.read_text()

        self.assertIn("python3 -m unittest tests.test_privacy_configuration", workflow)


if __name__ == "__main__":
    unittest.main()
