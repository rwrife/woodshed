import json
import tempfile
import unittest
from pathlib import Path

from Scripts.select_xcode import PinError, load_pins, select_xcode


VALID = {
    "xcode_version": "26.0.1",
    "xcode_build": "17A400",
    "iphoneos_sdk": "26.0",
    "minimum_sdk_major": 26,
    "deployment_target": "26.0",
    "swift_language_mode": "6",
    "bundle_identifier": "com.infinityball.woodshed",
}


class PinTests(unittest.TestCase):
    def write_pins(self, value):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "toolchain.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        self.addCleanup(directory.cleanup)
        return path

    def test_rejects_missing_pin(self):
        pins = dict(VALID)
        del pins["xcode_build"]
        with self.assertRaisesRegex(PinError, "xcode_build"):
            load_pins(self.write_pins(pins))

    def test_rejects_bad_pin_type(self):
        pins = dict(VALID, minimum_sdk_major="26")
        with self.assertRaisesRegex(PinError, "minimum_sdk_major"):
            load_pins(self.write_pins(pins))

    def test_rejects_sdk_below_supported_major(self):
        pins = dict(VALID, iphoneos_sdk="25.4")
        with self.assertRaisesRegex(PinError, "below minimum"):
            load_pins(self.write_pins(pins))

    def test_selects_only_exact_actual_versions(self):
        installations = {
            Path("/Applications/Xcode_26.0.app"): ("26.0", "17A300", "26.0"),
            Path("/Applications/Xcode_26.0.1.app"): ("26.0.1", "17A400", "26.0"),
        }
        selected = select_xcode(VALID, installations)
        self.assertEqual(selected, Path("/Applications/Xcode_26.0.1.app"))

    def test_multiple_exact_installations_choose_deterministically(self):
        installations = {
            Path("/Applications/Xcode_26.0.app"): ("26.0.1", "17A400", "26.0"),
            Path("/Applications/Xcode.app"): ("26.0.1", "17A400", "26.0"),
        }
        self.assertEqual(select_xcode(VALID, installations), Path("/Applications/Xcode.app"))

    def test_rejects_matching_name_with_wrong_actual_build(self):
        installations = {
            Path("/Applications/Xcode_26.0.1.app"): ("26.0.1", "17A401", "26.0")
        }
        with self.assertRaisesRegex(PinError, "No installed Xcode"):
            select_xcode(VALID, installations)


if __name__ == "__main__":
    unittest.main()
