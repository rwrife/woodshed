import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from Scripts.boot_simulator import SimulatorBootError, boot_selected_simulator, run_logged


def devices(state="Shutdown"):
    return {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {
                    "name": "iPhone 17 Pro",
                    "udid": "PHONE-26",
                    "isAvailable": True,
                    "state": state,
                }
            ]
        }
    }


class FakeRunner:
    def __init__(self, results):
        self.results = iter(results)
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        result = next(self.results)
        if isinstance(result, BaseException):
            raise result
        return result


class BootTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.log_path = Path(directory.name) / "simulator-boot.log"

    def completed(self, returncode=0, output="ok\n"):
        return subprocess.CompletedProcess([], returncode, output)

    def test_already_booted_skips_boot_and_waits_for_readiness(self):
        runner = FakeRunner([self.completed()])

        boot_selected_simulator(
            "PHONE-26", devices("Booted"), self.log_path, runner=runner
        )

        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(runner.calls[0][0][2:4], ["bootstatus", "PHONE-26"])
        self.assertIn("already Booted", self.log_path.read_text())

    def test_boot_timeout_retries_once_after_shutdown_then_fails(self):
        first = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "boot", "PHONE-26"], 120, output="partial boot\n"
        )
        second = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "boot", "PHONE-26"], 120, output="partial retry\n"
        )
        runner = FakeRunner([first, self.completed(), second])

        with self.assertRaisesRegex(
            SimulatorBootError, "timed out after 120.*retry after shutdown"
        ):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        log = self.log_path.read_text()
        self.assertIn("partial boot", log)
        self.assertIn("retrying boot once", log)

    def test_bootstatus_timeout_recovers_on_single_retry(self):
        stalled = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "bootstatus", "PHONE-26", "-b"], 180, output=""
        )
        runner = FakeRunner(
            [
                self.completed(output="boot requested\n"),
                stalled,
                self.completed(output="shutdown ok\n"),
                self.completed(output="boot requested again\n"),
                self.completed(output="booted\n"),
            ]
        )

        boot_selected_simulator("PHONE-26", devices(), self.log_path, runner=runner)

        verbs = [call[0][2:4] for call in runner.calls]
        self.assertEqual(
            verbs,
            [
                ["boot", "PHONE-26"],
                ["bootstatus", "PHONE-26"],
                ["shutdown", "PHONE-26"],
                ["boot", "PHONE-26"],
                ["bootstatus", "PHONE-26"],
            ],
        )

    def test_boot_shutdown_failure_is_tolerated_before_retry(self):
        first = subprocess.TimeoutExpired(
            ["xcrun", "simctl", "bootstatus", "PHONE-26", "-b"], 180, output=""
        )
        runner = FakeRunner(
            [
                self.completed(output="boot requested\n"),
                first,
                self.completed(returncode=2, output="shutdown failed\n"),
                self.completed(output="boot requested again\n"),
                self.completed(output="booted\n"),
            ]
        )

        boot_selected_simulator("PHONE-26", devices(), self.log_path, runner=runner)

        self.assertEqual(len(runner.calls), 5)

    def test_boot_nonzero_exit_is_not_ignored(self):
        runner = FakeRunner([self.completed(returncode=9, output="boot failed\n")])

        with self.assertRaisesRegex(SimulatorBootError, "exited 9"):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        self.assertIn("boot failed", self.log_path.read_text())

    def test_bootstatus_nonzero_exit_is_not_ignored(self):
        runner = FakeRunner(
            [self.completed(output="boot requested\n"), self.completed(7, "not ready\n")]
        )

        with self.assertRaisesRegex(SimulatorBootError, "bootstatus.*exited 7"):
            boot_selected_simulator(
                "PHONE-26", devices(), self.log_path, runner=runner
            )

        self.assertIn("not ready", self.log_path.read_text())


class RealSubprocessTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.log_path = Path(directory.name) / "command.log"

    def test_real_subprocess_is_terminated_at_timeout(self):
        command = [
            sys.executable,
            "-c",
            "import time; print('started', flush=True); time.sleep(10)",
        ]

        with self.assertRaisesRegex(SimulatorBootError, "timed out"):
            run_logged(command, 0.05, self.log_path)

        log = self.log_path.read_text()
        self.assertIn("started", log)
        self.assertIn("timed out", log)

    def test_real_subprocess_nonzero_exit_is_reported(self):
        command = [sys.executable, "-c", "print('failed'); raise SystemExit(6)"]

        with self.assertRaisesRegex(SimulatorBootError, "exited 6"):
            run_logged(command, 5, self.log_path)

        self.assertIn("failed", self.log_path.read_text())


if __name__ == "__main__":
    unittest.main()
