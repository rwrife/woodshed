#!/usr/bin/env python3
"""Boot one selected simulator with bounded commands and durable logs."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence


class SimulatorBootError(RuntimeError):
    def __init__(self, message: str, *, timed_out: bool = False) -> None:
        super().__init__(message)
        self.timed_out = timed_out


Runner = Callable[..., subprocess.CompletedProcess[str]]


def _text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def run_logged(
    command: Sequence[str],
    timeout: int,
    log_path: Path,
    *,
    runner: Runner = subprocess.run,
) -> None:
    with log_path.open("a", encoding="utf-8") as log:
        log.write(f"$ {' '.join(command)}\n")
        log.flush()
        try:
            result = runner(
                list(command),
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            log.write(_text(error.output))
            message = f"{' '.join(command)} timed out after {timeout}s"
            log.write(f"{message}\n")
            raise SimulatorBootError(message, timed_out=True) from error
        log.write(_text(result.stdout))
        if result.returncode != 0:
            message = f"{' '.join(command)} exited {result.returncode}"
            log.write(f"{message}\n")
            raise SimulatorBootError(message)


def device_state(payload: dict, udid: str) -> str:
    for devices in payload.get("devices", {}).values():
        for device in devices:
            if device.get("udid") == udid:
                if device.get("isAvailable") is not True:
                    raise SimulatorBootError(f"Selected simulator {udid} is not available")
                return str(device.get("state", "unknown"))
    raise SimulatorBootError(f"Selected simulator {udid} is missing from the device list")


def _shutdown_best_effort(
    udid: str,
    log_path: Path,
    *,
    timeout: int,
    runner: Runner,
) -> None:
    """Best-effort `simctl shutdown` to clear a wedged boot attempt.

    Failures and timeouts here are logged and tolerated: the following boot
    retry either succeeds or reports its own bounded error.
    """
    with log_path.open("a", encoding="utf-8") as log:
        log.write(f"$ xcrun simctl shutdown {udid} (best-effort)\n")
        log.flush()
        try:
            runner(
                ["xcrun", "simctl", "shutdown", udid],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
            log.write("shutdown accepted\n")
        except subprocess.TimeoutExpired:
            log.write(f"xcrun simctl shutdown {udid} timed out after {timeout}s; ignoring\n")


def boot_selected_simulator(
    udid: str,
    devices: dict,
    log_path: Path,
    *,
    boot_timeout: int = 120,
    bootstatus_timeout: int = 180,
    runner: Runner = subprocess.run,
) -> None:
    state = device_state(devices, udid)
    log_path.write_text(f"Selected {udid}; initial state is {state}\n", encoding="utf-8")

    def attempt_boot() -> None:
        if state == "Booted":
            with log_path.open("a", encoding="utf-8") as log:
                log.write("Simulator is already Booted; skipping simctl boot.\n")
        else:
            run_logged(
                ["xcrun", "simctl", "boot", udid],
                boot_timeout,
                log_path,
                runner=runner,
            )
        run_logged(
            ["xcrun", "simctl", "bootstatus", udid, "-b"],
            bootstatus_timeout,
            log_path,
            runner=runner,
        )

    try:
        attempt_boot()
    except SimulatorBootError as error:
        # Hosted runners sometimes hand out a simulator whose CoreSimulator
        # boot wedges until the timeout (seat-weave PR #8/#9 measured this
        # class of stall). One bounded shutdown + re-attempt absorbs it;
        # a second timeout, or any non-timeout error, is fatal.
        if not error.timed_out:
            raise
        with log_path.open("a", encoding="utf-8") as log:
            log.write("Boot stalled; shutting down and retrying boot once.\n")
        _shutdown_best_effort(udid, log_path, timeout=30, runner=runner)
        try:
            attempt_boot()
        except SimulatorBootError as retry_error:
            if not retry_error.timed_out:
                raise
            raise SimulatorBootError(
                f"{error} (retry after shutdown also timed out: {retry_error})"
            ) from retry_error


def capture_command(command: list[str], output: Path, timeout: int) -> int:
    output.write_text("", encoding="utf-8")
    try:
        run_logged(command, timeout, output)
    except SimulatorBootError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)

    boot_parser = subparsers.add_parser("boot")
    boot_parser.add_argument("--udid", required=True)
    boot_parser.add_argument("--devices-json", type=Path, required=True)
    boot_parser.add_argument("--log", type=Path, required=True)
    boot_parser.add_argument("--boot-timeout", type=int, default=120)
    boot_parser.add_argument("--bootstatus-timeout", type=int, default=180)

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--output", type=Path, required=True)
    capture_parser.add_argument("--timeout", type=int, default=15)
    capture_parser.add_argument("command", nargs=argparse.REMAINDER)

    args = parser.parse_args()
    if args.action == "capture":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command:
            parser.error("capture requires a command after --")
        return capture_command(command, args.output, args.timeout)

    try:
        payload = json.loads(args.devices_json.read_text(encoding="utf-8"))
        boot_selected_simulator(
            args.udid,
            payload,
            args.log,
            boot_timeout=args.boot_timeout,
            bootstatus_timeout=args.bootstatus_timeout,
        )
    except (OSError, json.JSONDecodeError, SimulatorBootError) as error:
        print(f"Simulator boot failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
