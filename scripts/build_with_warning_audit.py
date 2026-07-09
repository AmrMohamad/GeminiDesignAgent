#!/usr/bin/env python3
"""Run a Swift build and fail on any unsuppressed compiler warning."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys


def warning_lines(output: str) -> list[str]:
    return [line for line in output.splitlines() if "warning:" in line.lower()]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--target")
    args = parser.parse_args()

    command = ["swift", "build", "-c", args.configuration]
    if args.target:
        command.extend(["--target", args.target])

    completed = subprocess.run(
        command,
        cwd=os.getcwd(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    sys.stdout.write(completed.stdout)
    if completed.returncode != 0:
        return completed.returncode

    warnings = warning_lines(completed.stdout)
    if warnings:
        print(f"warning audit failed: {len(warnings)} unsuppressed warning(s)", file=sys.stderr)
        for line in warnings[:20]:
            print(line, file=sys.stderr)
        if len(warnings) > 20:
            print(f"... {len(warnings) - 20} additional warning(s)", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
