#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
readonly PYTHON_INSTALLER="$SCRIPT_DIR/install_skill.py"

requested_version=""
codex_home=""
dry_run=false
replace_unmanaged=false
allow_dirty=false

usage() {
    cat <<'EOF'
Install GeminiDesignAgent from a cloned source checkout.

Usage:
  ./scripts/install.sh [options]

Options:
  --version VERSION       Require this checkout to declare VERSION (for example, v0.1.0).
  --codex-home PATH       Install under PATH instead of $CODEX_HOME or ~/.codex.
  --dry-run               Validate the checkout and environment without building or installing.
  --replace-unmanaged     Replace an unmanaged or locally modified existing skill installation.
  --allow-dirty           Permit an uncommitted source checkout (development only).
  -h, --help              Show this help.

Current install (before the v0.1.0 release tag is published):
  git clone --depth 1 https://github.com/AmrMohamad/GeminiDesignAgent.git
  cd GeminiDesignAgent
  ./scripts/install.sh --version v0.1.0

Published release install (after the tag exists):
  git clone --depth 1 --branch v0.1.0 \
    https://github.com/AmrMohamad/GeminiDesignAgent.git
EOF
}

fail() {
    printf 'GeminiDesignAgent installer: %s\n' "$1" >&2
    exit "${2:-1}"
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        fail "$option requires a value." 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            require_value "$1" "${2:-}"
            requested_version="$2"
            shift 2
            ;;
        --version=*)
            requested_version="${1#*=}"
            require_value "--version" "$requested_version"
            shift
            ;;
        --codex-home)
            require_value "$1" "${2:-}"
            codex_home="$2"
            shift 2
            ;;
        --codex-home=*)
            codex_home="${1#*=}"
            require_value "--codex-home" "$codex_home"
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --replace-unmanaged)
            replace_unmanaged=true
            shift
            ;;
        --allow-dirty)
            allow_dirty=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1" 2
            ;;
    esac
done

case "$(uname -s 2>/dev/null || true)" in
    Darwin|Linux)
        ;;
    *)
        fail "this Bash bootstrap supports macOS and Linux. On Windows, run 'py scripts/install_skill.py'."
        ;;
esac

command -v git >/dev/null 2>&1 || fail "git is required. Install Git and retry."
command -v swift >/dev/null 2>&1 || fail "Swift 6.1 or newer is required. Install Swift and retry."

python_command=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && \
        "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' >/dev/null 2>&1; then
        python_command="$candidate"
        break
    fi
done
[[ -n "$python_command" ]] || fail "Python 3 is required. Install Python 3 and retry."

[[ -f "$REPO_ROOT/Package.swift" ]] || fail "Package.swift is missing; run this script from a complete GeminiDesignAgent clone."
[[ -f "$PYTHON_INSTALLER" ]] || fail "scripts/install_skill.py is missing from this checkout."

git_root="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" || \
    fail "the source directory is not a Git checkout; clone GeminiDesignAgent before installing."
resolved_git_root="$(cd -- "$git_root" >/dev/null 2>&1 && pwd -P)"
resolved_repo_root="$(cd -- "$REPO_ROOT" >/dev/null 2>&1 && pwd -P)"
[[ "$resolved_git_root" == "$resolved_repo_root" ]] || \
    fail "the installer is not running from the GeminiDesignAgent repository root."

source_version="$({ PYTHONDONTWRITEBYTECODE=1 "$python_command" - "$REPO_ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
contracts = {
    "scripts/install_skill.py": r'^PRODUCT_VERSION\s*=\s*"([^"]+)"\s*$',
    "skills/gemini-design-agent/gda_constants.py": r'^PRODUCT_VERSION\s*=\s*"([^"]+)"\s*$',
    "Sources/GeminiDesignAgentCore/Utilities/GDAContract.swift":
        r'^\s*public static let productVersion\s*=\s*"([^"]+)"\s*$',
}
versions = {}
for relative, pattern in contracts.items():
    source = (root / relative).read_text(encoding="utf-8")
    match = re.search(pattern, source, re.MULTILINE)
    if match is None:
        raise SystemExit(f"could not read the product version from {relative}")
    versions[relative] = match.group(1)
if len(set(versions.values())) != 1:
    raise SystemExit(f"product version declarations disagree: {versions}")
print(next(iter(versions.values())))
PY
} 2>/dev/null)" || fail "could not determine the product version declared by this checkout."

if [[ -n "$requested_version" ]]; then
    normalized_version="${requested_version#v}"
    [[ "$normalized_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
        fail "invalid version '$requested_version'; expected a semantic version such as v0.1.0." 2
    [[ "$normalized_version" == "$source_version" ]] || \
        fail "requested version $requested_version does not match checkout version v$source_version. Clone the matching release tag."
fi

resolved_codex_home="$({ PYTHONDONTWRITEBYTECODE=1 "$python_command" - "${codex_home:-${CODEX_HOME:-$HOME/.codex}}" <<'PY'
import sys
from pathlib import Path

print(Path(sys.argv[1]).expanduser().resolve())
PY
} 2>/dev/null)" || fail "could not resolve the Codex home directory."

installer_arguments=(--codex-home "$resolved_codex_home")
if [[ "$replace_unmanaged" == true ]]; then
    installer_arguments+=(--replace-unmanaged)
fi
if [[ "$allow_dirty" == true ]]; then
    installer_arguments+=(--allow-dirty)
fi

printf 'GeminiDesignAgent v%s source checkout verified.\n' "$source_version"
printf 'Running installation preflight for %s ...\n' "$resolved_codex_home"
PYTHONDONTWRITEBYTECODE=1 "$python_command" "$PYTHON_INSTALLER" \
    --dry-run "${installer_arguments[@]}"

if [[ "$dry_run" == true ]]; then
    printf 'Dry run complete; no build or installation was performed.\n'
    exit 0
fi

printf 'Building and installing the managed Codex skill ...\n'
PYTHONDONTWRITEBYTECODE=1 "$python_command" "$PYTHON_INSTALLER" \
    "${installer_arguments[@]}"

readonly GDA_BINARY="$resolved_codex_home/skills/gemini-design-agent/bin/gda"
printf '\nGeminiDesignAgent v%s installed successfully.\n' "$source_version"
printf 'Binary: %s\n' "$GDA_BINARY"
printf '\nNext steps:\n'
printf '  "%s" auth onboard\n' "$GDA_BINARY"
printf '  "%s" setup --project-dir .gda --project-name "My App" --json\n' "$GDA_BINARY"
