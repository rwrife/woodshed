import unittest
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

from Scripts.select_simulator import (
    DestinationError,
    enumerate_available_devices,
    select_destination,
)


class DestinationTests(unittest.TestCase):
    def test_selects_available_iphone_on_exact_runtime(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {
                        "name": "iPhone 17 Pro",
                        "udid": "PHONE-26",
                        "isAvailable": True,
                    },
                    {
                        "name": "iPad Pro",
                        "udid": "PAD-26",
                        "isAvailable": True,
                    },
                ]
            }
        }
        self.assertEqual(select_destination(devices, "26.0"), "PHONE-26")

    def test_rejects_unavailable_iphone(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "NOPE", "isAvailable": False}
                ]
            }
        }
        with self.assertRaisesRegex(DestinationError, "available iPhone"):
            select_destination(devices, "26.0")

    def test_rejects_unsupported_sdk_runtime(self):
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-25-5": [
                    {"name": "iPhone 16", "udid": "OLD", "isAvailable": True}
                ]
            }
        }
        with self.assertRaisesRegex(DestinationError, "iOS 26.0"):
            select_destination(devices, "26.0")


class EnumerationTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("WOODSHED_SIMCTL_TIMEOUT_SECONDS", None)

    def test_timeout_then_succeeds_on_retry(self):
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            if len(calls) == 1:
                raise subprocess.TimeoutExpired(command, 5)
            return subprocess.CompletedProcess(command, 0, '{"devices": {}}')

        output = enumerate_available_devices(runner=runner, timeout=5)
        self.assertEqual(json.loads(output), {"devices": {}})
        self.assertEqual(len(calls), 2)

    def test_repeated_timeouts_are_not_swallowed(self):
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            raise subprocess.TimeoutExpired(command, 5)

        with self.assertRaises(subprocess.TimeoutExpired):
            enumerate_available_devices(runner=runner, timeout=5)
        self.assertEqual(len(calls), 2)

    def test_nonzero_exit_is_not_retried(self):
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            raise subprocess.CalledProcessError(1, command)

        with self.assertRaises(subprocess.CalledProcessError):
            enumerate_available_devices(runner=runner, timeout=5)
        self.assertEqual(len(calls), 1)

    def test_cli_recovers_and_flushes_devices_json_after_stall(self):
        """Subprocess-level regression for the wedged-enumeration path.

        A fake xcrun times out on the first enumeration and succeeds on the
        second. The caught TimeoutExpired keeps the devices-JSON handle's
        frame alive, so without an explicit flush in main() the output file
        can end up 0 bytes and crash the boot phase with empty JSON. An
        in-process test cannot catch this: only a real CLI run finalizes the
        interpreter the same way CI does.
        """
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            counter = Path(tmp) / "count"
            counter.write_text("0")
            devices_json = {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                        {"name": "iPhone 17 Pro", "udid": "PHONE-26", "isAvailable": True}
                    ]
                }
            }
            fake = bin_dir / "xcrun"
            fake.write_text(
                "#!/bin/sh\n"
                f'count=$(cat "{counter}")\n'
                f'echo $((count + 1)) > "{counter}"\n'
                "if [ \"$count\" = \"0\" ]; then sleep 5; exit 0; fi\n"
                f"printf '%s' '{json.dumps(devices_json)}'\n"
            )
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            out_path = Path(tmp) / "devices.json"
            env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
            env["WOODSHED_SIMCTL_TIMEOUT_SECONDS"] = "1"
            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve().parents[1] / "select_simulator.py"),
                    "--sdk", "26.0",
                    "--devices-json-out", str(out_path),
                ],
                capture_output=True,
                text=True,
                env=env,
                timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "PHONE-26")
            self.assertEqual(
                json.loads(out_path.read_text()), devices_json,
                "devices JSON must be flushed before interpreter exit",
            )


if __name__ == "__main__":
    unittest.main()
