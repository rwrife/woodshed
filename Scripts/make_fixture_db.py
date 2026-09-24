#!/usr/bin/env python3
"""Regenerate the committed schema-v1 fixture database.

The fixture proves that `WoodshedStoreSchema.migrator` can upgrade a real v1-era
database file to the current schema. Run this ONLY when a v2 migration is
added (after which the v1 fixture must already exist and stay unchanged);
never regenerate to match an edited v1 — v1 is frozen.

Usage (repo root, after building fixture-seed, e.g. in the Linux container):
    Scripts/make_fixture_db.py <path-to-package-build-dir>

The helper locates the `fixture-seed` executable built from
Packages/WoodshedStore (Tools/fixture-seed).
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "Packages/WoodshedStore/Tests/WoodshedStoreTests/Fixtures/v1.sqlite"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("scratch_dir", type=Path, help="Directory containing the built fixture-seed binary")
    parser.add_argument("--out", type=Path, default=FIXTURE)
    args = parser.parse_args()

    seed = next(args.scratch_dir.rglob("fixture-seed"), None)
    if seed is None:
        print("fixture-seed binary not found under", args.scratch_dir, file=sys.stderr)
        return 1

    staging = Path(sys.argv[0]).resolve().parent / f".fixture-{FIXTURE.name}"
    staging.unlink(missing_ok=True)
    subprocess.run([str(seed), str(staging)], check=True)

    # Logical content compare (SQLite files embed a change counter in the
    # header, so raw bytes are not stable across regenerations).
    def logical_dump(path: Path) -> str:
        import sqlite3

        connection = sqlite3.connect(path)
        try:
            lines = []
            for row in connection.iterdump():
                lines.append(row)
            return "\n".join(lines)
        finally:
            connection.close()

    if args.out.exists() and logical_dump(args.out) != logical_dump(staging):
        print("Generated fixture differs logically from the committed one — v1 must be frozen!", file=sys.stderr)
        staging.unlink(missing_ok=True)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(staging), str(args.out))
    print(f"Wrote {args.out} ({args.out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
