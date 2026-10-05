"""Assert bundle, device family and build number from the actual signed archive."""
import json
import plistlib
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit('usage: check_release_archive.py <archived-app-Info.plist> <build-number>')
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
pin = json.loads((Path(__file__).resolve().parents[1] / 'toolchain.json').read_text())
assert info.get('CFBundleIdentifier') == pin['bundle_identifier'], 'wrong archived bundle identifier'
assert info.get('UIDeviceFamily') == [1], 'archive includes a non-iPhone device family'
assert str(info.get('CFBundleVersion')) == sys.argv[2], 'archive build number does not match run'
print('Archived app bundle identifier, UIDeviceFamily=[1], build number: PASS')
