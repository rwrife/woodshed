#!/usr/bin/env python3
"""Select an installed Xcode only when its measured versions match the pins."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Mapping


class PinError(ValueError):
    pass


REQUIRED_TYPES = {
    "xcode_version": str,
    "xcode_build": str,
    "iphoneos_sdk": str,
    "minimum_sdk_major": int,
    "deployment_target": str,
    "swift_language_mode": str,
    "bundle_identifier": str,
}


def load_pins(path: Path) -> dict:
    try:
        pins = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PinError(f"Cannot read valid toolchain pins from {path}: {error}") from error
    for key, expected_type in REQUIRED_TYPES.items():
        if key not in pins:
            raise PinError(f"Missing required pin: {key}")
        if type(pins[key]) is not expected_type:
            raise PinError(f"Pin {key} must be {expected_type.__name__}")
    try:
        sdk_major = int(pins["iphoneos_sdk"].split(".", 1)[0])
    except ValueError as error:
        raise PinError("iphoneos_sdk must begin with a numeric major version") from error
    if sdk_major < pins["minimum_sdk_major"]:
        raise PinError(
            f"Pinned iPhoneOS SDK {pins['iphoneos_sdk']} is below minimum "
            f"major {pins['minimum_sdk_major']}"
        )
    return pins


def select_xcode(pins: Mapping, installations: Mapping[Path, tuple[str, str, str]]) -> Path:
    wanted = (pins["xcode_version"], pins["xcode_build"], pins["iphoneos_sdk"])
    matches = sorted(path for path, measured in installations.items() if measured == wanted)
    if not matches:
        observed = ", ".join(
            f"{path}: Xcode {values[0]} ({values[1]}), iPhoneOS {values[2]}"
            for path, values in sorted(installations.items(), key=lambda item: str(item[0]))
        ) or "none"
        raise PinError(f"No installed Xcode matches {wanted}; observed: {observed}")
    return matches[0]


def command_output(command: list[str], developer_dir: Path) -> str:
    environment = dict(os.environ, DEVELOPER_DIR=str(developer_dir))
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
    ).stdout.strip()


def inspect_installation(app: Path) -> tuple[str, str, str]:
    developer_dir = app / "Contents" / "Developer"
    version_output = command_output(["xcodebuild", "-version"], developer_dir)
    version_match = re.search(r"^Xcode ([^\s]+)$", version_output, re.MULTILINE)
    build_match = re.search(r"^Build version ([^\s]+)$", version_output, re.MULTILINE)
    if not version_match or not build_match:
        raise PinError(f"Unexpected xcodebuild -version output for {app}: {version_output!r}")
    sdk = command_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], developer_dir)
    return version_match.group(1), build_match.group(1), sdk


def installed_xcodes(applications: Path) -> dict[Path, tuple[str, str, str]]:
    installations = {}
    for app in sorted(applications.glob("Xcode*.app")):
        try:
            installations[app] = inspect_installation(app)
        except (OSError, subprocess.CalledProcessError, PinError) as error:
            print(f"Ignoring unreadable Xcode candidate {app}: {error}", file=sys.stderr)
    return installations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", type=Path, default=Path("toolchain.json"))
    parser.add_argument("--applications", type=Path, default=Path("/Applications"))
    args = parser.parse_args()
    try:
        pins = load_pins(args.toolchain)
        installations = installed_xcodes(args.applications)
        for path, values in installations.items():
            print(
                f"Observed {path}: Xcode {values[0]} build {values[1]}, "
                f"iPhoneOS SDK {values[2]}",
                file=sys.stderr,
            )
        selected = select_xcode(pins, installations)
    except PinError as error:
        print(error, file=sys.stderr)
        return 1
    print(selected / "Contents" / "Developer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
