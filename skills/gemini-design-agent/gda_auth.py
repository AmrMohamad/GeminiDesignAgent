from __future__ import annotations

import json
import math
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from gda_constants import AUTH_ONBOARDING_COOLDOWN_SECONDS
from gda_envelope import GDASkillError, skill_error_payload
from gda_runner import find_gda


def env_flag(name: str) -> bool:
    value = os.environ.get(name)
    return value is not None and value.strip().lower() not in ("", "0", "false", "no", "off")


def auth_onboarding_dir() -> Path:
    uid = getattr(os, "getuid", lambda: "user")()
    return Path(tempfile.gettempdir()) / f"gda-auth-onboarding-{uid}"


def auth_onboarding_marker_path() -> Path:
    return auth_onboarding_dir() / "pending.json"


def read_auth_onboarding_marker() -> dict[str, Any] | None:
    marker = auth_onboarding_marker_path()
    if not marker.exists():
        return None
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        marker.unlink(missing_ok=True)
        return None
    expires_at = data.get("expires_at_epoch")
    if not isinstance(expires_at, (int, float)) or not math.isfinite(float(expires_at)):
        marker.unlink(missing_ok=True)
        return None
    now = time.time()
    if float(expires_at) < now or float(expires_at) > now + AUTH_ONBOARDING_COOLDOWN_SECONDS + 1:
        marker.unlink(missing_ok=True)
        return None
    return data


def reserve_auth_onboarding_marker(marker_data: dict[str, Any], force: bool) -> None:
    marker = auth_onboarding_marker_path()
    marker.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if force:
        marker.unlink(missing_ok=True)
    try:
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as error:
        raise GDASkillError("auth onboarding was already started recently") from error
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(marker_data, output, indent=2, sort_keys=True)


def replace_auth_onboarding_marker(marker_data: dict[str, Any]) -> None:
    marker = auth_onboarding_marker_path()
    temporary = marker.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(marker_data, indent=2, sort_keys=True), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(marker)


def auth_onboarding_is_disabled() -> tuple[bool, str | None]:
    if env_flag("GDA_DISABLE_AUTH_ONBOARDING"):
        return True, "GDA_DISABLE_AUTH_ONBOARDING is set"
    if env_flag("GDA_HEADLESS"):
        return True, "GDA_HEADLESS is set"
    if env_flag("CI") or env_flag("GITHUB_ACTIONS"):
        return True, "CI/headless environment detected"
    if os.environ.get("SSH_TTY") or os.environ.get("SSH_CONNECTION"):
        return True, "SSH session detected"
    if sys.platform != "darwin":
        return True, "auto Terminal onboarding is only supported on macOS"
    return False, None


def auth_unavailable_payload(reason: str) -> dict[str, Any]:
    return skill_error_payload(
        command="auth.ensure",
        code="AUTH_ONBOARDING_UNAVAILABLE",
        title="Gemini auth onboarding cannot be opened automatically",
        message=reason,
        resolution="Run `gda auth onboard` in Terminal, or set GEMINI_API_KEY only as a temporary CI/debugging override.",
        retryable=False,
        diagnostics=[{"kind": "auth_onboarding", "reason": reason}],
        next_actions=[
            {"label": "Start auth onboarding", "command": "gda auth onboard"},
            {"label": "Check auth status", "command": "python gda_skill.py ensure-auth"},
        ],
    )

def write_auth_onboarding_launcher(gda_binary: str) -> Path:
    launch_dir = auth_onboarding_dir()
    launch_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    launcher = launch_dir / "gda-auth-onboard.command"
    quoted_binary = shlex.quote(gda_binary)
    launcher.write_text(
        "\n".join([
            "#!/bin/zsh",
            "clear",
            "echo 'Gemini Design Agent auth onboarding'",
            "echo ''",
            "echo 'Your browser will open for Google sign-in.'",
            "echo 'Complete sign-in there; GDA will finish automatically.'",
            "echo ''",
            f"{quoted_binary} auth onboard",
            "status=$?",
            "echo ''",
            "if [ $status -eq 0 ]; then",
            "  echo 'Done. Return to Codex and rerun the design analysis.'",
            "else",
            f"  echo 'Auth onboarding did not complete. Retry with: {quoted_binary} auth onboard'",
            "fi",
            "echo ''",
            "read -r '?Press Return to close this window...'",
            "exit $status",
            "",
        ]),
        encoding="utf-8",
    )
    launcher.chmod(0o700)
    return launcher


def launch_auth_onboarding_terminal(force: bool = False) -> dict[str, Any]:
    marker = read_auth_onboarding_marker()
    if marker and not force:
        raise GDASkillError(
            "auth onboarding was already started recently",
            payload=skill_error_payload(
                command="auth.ensure",
                code="AUTH_ONBOARDING_ALREADY_STARTED",
                title="Gemini auth onboarding is already in progress",
                message="A Terminal onboarding window was opened recently. Finish that flow, then rerun the analysis.",
                resolution="Complete the Terminal prompt, or rerun ensure-auth with --force to reopen it.",
                retryable=True,
                diagnostics=[{"kind": "auth_onboarding", "marker": marker}],
                next_actions=[
                    {"label": "Check auth status", "command": "python gda_skill.py ensure-auth"},
                    {"label": "Reopen onboarding", "command": "python gda_skill.py ensure-auth --force"},
                ],
            ),
        )

    disabled, reason = auth_onboarding_is_disabled()
    if disabled:
        raise GDASkillError("auth onboarding cannot be opened", payload=auth_unavailable_payload(reason or "onboarding is disabled"))

    gda_binary = find_gda()
    launcher = write_auth_onboarding_launcher(gda_binary)
    started_at = time.time()
    marker_data = {
        "started_at_epoch": started_at,
        "expires_at_epoch": started_at + AUTH_ONBOARDING_COOLDOWN_SECONDS,
        "launcher_path": str(launcher),
        "gda_bin": gda_binary,
    }
    try:
        reserve_auth_onboarding_marker(marker_data, force=force)
    except GDASkillError:
        marker = read_auth_onboarding_marker()
        raise GDASkillError(
            "auth onboarding was already started recently",
            payload=skill_error_payload(
                command="auth.ensure",
                code="AUTH_ONBOARDING_ALREADY_STARTED",
                title="Gemini auth onboarding is already in progress",
                message="A concurrent process already opened or is opening Terminal onboarding.",
                resolution="Complete that flow, then rerun the analysis.",
                retryable=True,
                diagnostics=[{"kind": "auth_onboarding", "marker": marker or {}}],
            ),
        )
    proc = subprocess.run(
        ["open", "-a", "Terminal", str(launcher)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        shell=False,
        timeout=30,
    )
    if proc.returncode != 0:
        auth_onboarding_marker_path().unlink(missing_ok=True)
        raise GDASkillError(
            "failed to open Terminal for auth onboarding",
            payload=skill_error_payload(
                command="auth.ensure",
                code="AUTH_ONBOARDING_LAUNCH_FAILED",
                title="Could not open Terminal for Gemini auth onboarding",
                message=proc.stderr.strip() or "The macOS `open` command failed.",
                resolution="Run `gda auth onboard` manually in Terminal.",
                retryable=True,
                diagnostics=[{
                    "kind": "process",
                    "exit_code": proc.returncode,
                    "stderr": proc.stderr.strip(),
                    "launcher_path": str(launcher),
                    "gda_bin": gda_binary,
                }],
                next_actions=[{"label": "Start auth onboarding", "command": "gda auth onboard"}],
            ),
        )

    replace_auth_onboarding_marker(marker_data)
    raise GDASkillError(
        "auth onboarding started",
        payload=skill_error_payload(
            command="auth.ensure",
            code="AUTH_ONBOARDING_STARTED",
            title="Gemini auth onboarding started",
            message="A Terminal window was opened and GDA will open Google sign-in in your browser.",
            resolution="Complete Google sign-in in the browser, then rerun the original design analysis.",
            retryable=True,
            diagnostics=[{"kind": "auth_onboarding", **marker_data}],
            next_actions=[
                {"label": "Check auth status", "command": "python gda_skill.py ensure-auth"},
                {"label": "Rerun original analysis", "command": "Rerun the previous gemini-design-agent command after auth is configured"},
            ],
        ),
    )
