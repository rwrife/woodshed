"""Fail closed on the repository's iPhone-only, registered-bundle release contract."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT / 'Woodshed.xcodeproj/project.pbxproj').read_text()
pin = json.loads((ROOT / 'toolchain.json').read_text())
assert pin['bundle_identifier'] == 'com.infinityball.woodshed'
assert pin['targeted_device_family'] == '1'
assert pin['xcode_version'] == '26.0.1' and pin['xcode_build'] == '17A400'
assert pin['iphoneos_sdk'] == '26.0'
assert re.findall(r'TARGETED_DEVICE_FAMILY\s*=\s*([^;]+);', project) == ['1'] * 4
assert re.findall(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);', project) == [
    'com.infinityball.woodshed', 'com.infinityball.woodshed',
    'com.infinityball.woodshed.uitests', 'com.infinityball.woodshed.uitests',
]
assert project.count('ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;') == 2
assert project.count('Assets.xcassets in Resources') >= 2
icon = ROOT / 'App/Assets.xcassets/AppIcon.appiconset'
images = json.loads((icon / 'Contents.json').read_text())['images']
assert any(i.get('filename') == 'AppIcon.png' and i.get('platform') == 'ios' for i in images)
assert (icon / 'AppIcon.png').stat().st_size > 0
print('Release project contract: PASS (exact pin, iPhone-only, registered bundle, icon)')
