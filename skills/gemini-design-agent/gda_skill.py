#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


class GDASkillError(RuntimeError):
    pass


def find_gda() -> str:
    env_bin = os.environ.get("GDA_BIN")
    if env_bin:
        path = Path(env_bin).expanduser()
        if path.exists():
            return str(path)
        raise GDASkillError(f"GDA_BIN points to a missing file: {path}")

    found = shutil.which("gda")
    if found:
        return found

    raise GDASkillError(
        "Could not find `gda`. Install GeminiDesignAgent or set GDA_BIN=/path/to/gda."
    )


def run_gda(args: list[str], timeout_seconds: int = 180) -> dict[str, Any]:
    binary = find_gda()

    proc = subprocess.run(
        [binary, *args, "--json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout_seconds,
        shell=False,
    )

    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()

    if not stdout:
        raise GDASkillError(
            f"gda returned no JSON. exit={proc.returncode}, stderr={stderr}"
        )

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise GDASkillError(
            f"gda stdout was not valid JSON. exit={proc.returncode}, "
            f"stderr={stderr}, stdout={stdout[:1000]}"
        ) from exc

    if proc.returncode != 0:
        raise GDASkillError(
            json.dumps(
                {
                    "message": "gda command failed",
                    "exit_code": proc.returncode,
                    "stderr": stderr,
                    "payload": payload,
                },
                indent=2,
            )
        )

    return payload


def analyze(
    image: str,
    screen: str,
    request: str,
    project_dir: str = ".gda",
    model: str | None = None,
    timeout_seconds: int = 180,
) -> dict[str, Any]:
    image_path = Path(image).expanduser().resolve()
    if not image_path.exists():
        raise FileNotFoundError(f"Image not found: {image_path}")

    args = [
        "analyze",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--image", str(image_path),
        "--screen", screen,
        "--request", request,
    ]

    if model:
        args.extend(["--model", model])

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_search(
    query: str,
    project_dir: str = ".gda",
    limit: int = 8,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "search",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--query", query,
        "--limit", str(limit),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def init_project(
    project_dir: str = ".gda",
    project_name: str = "Design Project",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "init",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--project-name", project_name,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Python wrapper for Gemini Design Agent CLI."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("--project-dir", default=".gda")
    p_init.add_argument("--project-name", default="Design Project")

    p_analyze = sub.add_parser("analyze")
    p_analyze.add_argument("--image", required=True)
    p_analyze.add_argument("--screen", required=True)
    p_analyze.add_argument("--request", default=(
        "Extract layout, spacing, typography, colors, reusable components, "
        "and development-ready implementation values."
    ))
    p_analyze.add_argument("--project-dir", default=".gda")
    p_analyze.add_argument("--model", default=None)
    p_analyze.add_argument("--timeout-seconds", type=int, default=180)

    p_search = sub.add_parser("memory-search")
    p_search.add_argument("--query", required=True)
    p_search.add_argument("--project-dir", default=".gda")
    p_search.add_argument("--limit", type=int, default=8)

    ns = parser.parse_args()

    try:
        if ns.command == "init":
            result = init_project(
                project_dir=ns.project_dir,
                project_name=ns.project_name,
            )
        elif ns.command == "analyze":
            result = analyze(
                image=ns.image,
                screen=ns.screen,
                request=ns.request,
                project_dir=ns.project_dir,
                model=ns.model,
                timeout_seconds=ns.timeout_seconds,
            )
        elif ns.command == "memory-search":
            result = memory_search(
                query=ns.query,
                project_dir=ns.project_dir,
                limit=ns.limit,
            )
        else:
            raise GDASkillError(f"Unsupported command: {ns.command}")

        print(json.dumps(result, indent=2, ensure_ascii=False))

    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": {
                        "code": "GDA_SKILL_ERROR",
                        "message": str(exc),
                    },
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
