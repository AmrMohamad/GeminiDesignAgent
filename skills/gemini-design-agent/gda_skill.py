#!/usr/bin/env python3
from __future__ import annotations

import sys

# The installed skill bundle has an exact, manifest-verified tree. Prevent
# ordinary Python launches from mutating that tree before importing any local
# runtime module; callers must not need `python -B` or environment flags.
sys.dont_write_bytecode = True

import json

from gda_cli import build_parser, dispatch
from gda_envelope import GDASkillError


def main() -> None:
    parser = build_parser()
    ns = parser.parse_args()

    try:
        result = dispatch(ns)
        print(json.dumps(result, indent=2, ensure_ascii=False))

    except GDASkillError as exc:
        payload = exc.payload if exc.payload is not None else {
            "ok": False,
            "command": "gda_skill",
            "schema_version": "1.0",
            "data": None,
            "diagnostics": [],
            "next_actions": [],
            "error": {
                "code": "GDA_SKILL_ERROR",
                "title": "gda skill wrapper failed",
                "message": str(exc),
                "resolution": "Check GDA_BIN or install the gda binary.",
                "retryable": False,
            },
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        sys.exit(1)

    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "command": "gda_skill",
                    "schema_version": "1.0",
                    "data": None,
                    "diagnostics": [],
                    "next_actions": [],
                    "error": {
                        "code": "GDA_SKILL_ERROR",
                        "title": "gda skill wrapper failed",
                        "message": str(exc),
                        "resolution": "Check wrapper arguments and local file paths.",
                        "retryable": False,
                    },
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
