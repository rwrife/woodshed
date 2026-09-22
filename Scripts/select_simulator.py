#!/usr/bin/env python3
"""Choose an explicit available iPhone simulator UDID for the pinned SDK."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

DEFAULT_TIMEOUT_SECONDS = 30


class DestinationError(ValueError):
    pass


def configured_timeout() -> int:
    """Timeout for simctl enumeration; tests override via env (seconds)."""
    raw = os.environ.get("WOODSHED_SIMCTL_TIMEOUT_SECONDS", "")
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_TIMEOUT_SECONDS


def select_destination(payload: dict, sdk_version: str) -> str:
    runtime = f"com.apple.CoreSimulator.SimRuntime.iOS-{sdk_version.replace('.', '-')}"
    candidates = [
        device
        for device in payload.get("devices", {}).get(runtime, [])
        if device.get("isAvailable") is True
        and str(device.get("name", "")).startswith("iPhone")
        and device.get("udid")
    ]
    if not candidates:
        raise DestinationError(f"No available iPhone simulator found for iOS {sdk_version}")
    candidates.sort(key=lambda device: (device["name"], device["udid"]), reverse=True)
    return str(candidates[0]["udid"])


def enumerate_available_devices(
    *,
    runner=subprocess.run,
    timeout: int | None = None,
    attempts: int = 2,
) -> str:
    """Run `simctl list devices available --json` with a bounded retry.

    Hosted runners intermittently hand out a wedged CoreSimulator daemon and
    the enumeration subprocess stalls until it times out (seat-weave PR #8/#9
    measured this class of stall; a single retry on TimeoutExpired absorbs
    it). A nonzero exit is a real environment error and is NOT retried.
    """
    if timeout is None:
        timeout = configured_timeout()
    command = ["xcrun", "simctl", "list", "devices", "available", "--json"]
    last_error: subprocess.TimeoutExpired | None = None
    for attempt in range(1, max(1, attempts) + 1):
        try:
            result = runner(
                command,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
                timeout=timeout,
            )
            return str(result.stdout)
        except subprocess.TimeoutExpired as error:
            last_error = error
            if attempt < max(1, attempts):
                print(
                    f"Simulator enumeration timed out after {timeout}s; "
                    "retrying once.",
                    file=sys.stderr,
                )
    assert last_error is not None
    raise last_error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--devices-json-out", type=argparse.FileType("w", encoding="utf-8"))
    args = parser.parse_args()
    try:
        output = enumerate_available_devices()
        if args.devices_json_out:
            args.devices_json_out.write(output)
            # Flush now: a caught TimeoutExpired keeps this handle's frame
            # alive, so interpreter-exit finalization alone can leave the
            # file empty and crash the next phase with empty JSON.
            args.devices_json_out.flush()
        udid = select_destination(json.loads(output), args.sdk)
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
        DestinationError,
    ) as error:
        print(error, file=sys.stderr)
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
