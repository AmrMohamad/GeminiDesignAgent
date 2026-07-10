# GeminiDesignAgent

`gda` is a SwiftPM command-line tool for analyzing UI screenshots with the Gemini Interactions API and storing reusable design memory in a local `.gda` project.

It is intended for AI agents and developers who need a repeatable screenshot-to-implementation handoff:

```text
local PNG/JPEG screenshot -> Gemini structured JSON -> SQLite memory + JSONL archive
```

## Status

- Release: `0.1.0`, distributed as a source-built Codex skill.
- Gemini API path: stable Interactions API (`/v1/interactions`).
- Screenshot requests set `store: false`. This requests no interaction storage; it does not alter Google's normal API data-processing terms.
- Image input: PNG and JPEG only.
- Persistent auth:
  - macOS: Keychain.
  - Linux: Secret Service through `secret-tool` when available.
  - Windows: Credential Manager.
- Temporary auth override: `--api-key` or `GEMINI_API_KEY`.

## Requirements

- Swift 6.1 or newer.
- Python 3.12 is used in CI; the installer requires Python 3.
- macOS 15, Ubuntu 24.04, and Windows Server 2022 are the release CI targets.
- A Gemini API key for live analysis. Offline builds, tests, recorded evaluation,
  and installer validation do not require a key.

## Install The Codex Skill

On macOS or Linux, clone the repository and run the repository-owned bootstrap:

```bash
git clone --depth 1 https://github.com/AmrMohamad/GeminiDesignAgent.git
cd GeminiDesignAgent
./scripts/install.sh --version v0.1.0
```

After the `v0.1.0` release tag is published, prefer the immutable tagged clone:

```bash
git clone --depth 1 --branch v0.1.0 \
  https://github.com/AmrMohamad/GeminiDesignAgent.git
cd GeminiDesignAgent
./scripts/install.sh --version v0.1.0
```

The Bash bootstrap verifies Git, Python 3, Swift, the repository root, and the
declared product version. It then runs a no-write preflight before delegating to
the deterministic Python installer. It never requests a Gemini API key and does
not modify shell startup files or `PATH`.

Preview the complete installation without building or writing anything:

```bash
./scripts/install.sh --version v0.1.0 --dry-run
```

On Windows, use the same current clone (or the tagged clone after publication)
and invoke the cross-platform Python installer directly:

```powershell
git clone --depth 1 https://github.com/AmrMohamad/GeminiDesignAgent.git
cd GeminiDesignAgent
py scripts/install_skill.py --dry-run
py scripts/install_skill.py
```

The underlying installer can also be invoked directly from any clean source
checkout:

```bash
python3 scripts/install_skill.py --dry-run
python3 scripts/install_skill.py
```

The installer builds `gda` in release mode, stages the exact runtime bundle,
verifies its version/protocol handshake and SHA-256 manifest, then replaces the
installed skill atomically. It uses `$CODEX_HOME` when set and otherwise
installs under `~/.codex/skills/gemini-design-agent`.

Useful development options:

```bash
./scripts/install.sh --codex-home /custom/.codex
./scripts/install.sh --allow-dirty       # local development only
./scripts/install.sh --replace-unmanaged # explicit stale-install replacement
python3 scripts/install_skill.py --codex-home /custom/.codex
python3 scripts/install_skill.py --allow-dirty       # local development only
python3 scripts/install_skill.py --replace-unmanaged # explicit stale-install replacement
```

Final release installations must come from a clean checkout without
`--allow-dirty`. The installer reports a legacy `~/.local/bin/gda` but never
deletes it automatically. Re-run the same installer command to update or repair
a managed installation.

## Build And Test

```bash
swift build
swift test
python3 -m py_compile skills/gemini-design-agent/gda_skill.py skills/gemini-design-agent/gda_*.py
python3 -m unittest discover -s skills/gemini-design-agent/tests -p 'test_*.py'
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/validate_skill.py --json
python3 scripts/evaluate_design_quality.py --mode recorded --corpus public
python3 scripts/build_with_warning_audit.py --configuration release
```

Local Xcode 27 Beta 2 proof should not mutate global `xcode-select`:

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.2.app/Contents/Developer swift test
```

## Quick Start

```bash
GDA="${CODEX_HOME:-$HOME/.codex}/skills/gemini-design-agent/bin/gda"
"$GDA" --version
"$GDA" version --json
"$GDA" auth onboard
"$GDA" setup --project-dir .gda --project-name "Design Project" --json
"$GDA" doctor --project-dir .gda --image /absolute/path/screen.png --json
"$GDA" analyze \
  --project-dir .gda \
  --image /absolute/path/screen.png \
  --screen Home \
  --request "Extract layout, spacing, typography, colors, and reusable components." \
  --json
```

The CLI writes machine-readable JSON with an `ok` flag, command name, data payload, diagnostics, next actions, and structured error details.

Inspect versioned usage, latency, and conservative cost estimates with:

```bash
"$GDA" runs stats --project-dir .gda --since-days 30 --json
```

The Python wrapper at
`$CODEX_HOME/skills/gemini-design-agent/gda_skill.py` is the portable
agent-facing entry point on every supported platform. The installer does not
modify the user's `PATH`.

Cost values are labeled upper-bound estimates based on a dated pricing contract;
they are not invoices or exact charges. Unknown models remain usable and are
reported as unpriced.

## Auth

Credential lookup order is:

1. `--api-key`
2. `GEMINI_API_KEY`
3. platform credential store

Use `GEMINI_API_KEY` only for CI or temporary debugging. The key is never written to `.gda`, SQLite, JSONL records, prompt artifacts, or wrapper diagnostics.

`gda auth set` and `gda auth onboard` require an interactive terminal. JSON mode and piped stdin are rejected rather than treating arbitrary input as a credential.

## Image Support

PNG and JPEG only screenshots are supported in this release. WebP may be detected for diagnostics, but it is rejected until dimension parsing and request handling are implemented. GIF is not accepted.

Inline Gemini requests are capped before network upload when the image payload is too large.

## Lock Recovery

Normal commands serialize project writes with directory locks. Inspect without changing state:

```bash
swift run gda lock status --project-dir .gda --json
```

If a crashed process left a lock behind, review it first, then clear only with an explicit force flag:

```bash
swift run gda lock clear --project-dir .gda --force --json
```

The clear operation atomically quarantines the old lock path before deletion, so it cannot remove a replacement lock acquired after inspection. `gda doctor` reports valid locks as warnings and malformed lock metadata as failures.

## Network Behavior

The Gemini client distinguishes timeout, unavailable network, DNS, and connection/TLS failures. It retries transient transport failures, HTTP 429, and 5xx responses. `Retry-After` is honored up to 60 seconds; larger server delays are returned as a rate-limit error instead of sleeping indefinitely.

## Live Gemini Smoke Test

Live tests are opt-in:

```bash
GDA_LIVE_GEMINI_TESTS=1 GEMINI_API_KEY=... swift test --filter GeminiLiveSmokeTests
```

Optionally override the model:

```bash
GDA_LIVE_GEMINI_MODEL=gemini-3.5-flash
```

To prove the installed wrapper, persistence, and second-run memory recall:

```bash
python3 scripts/smoke_installed_skill.py \
  --skill-dir "${CODEX_HOME:-$HOME/.codex}/skills/gemini-design-agent"
```

This command consumes Gemini quota and requires configured authentication.

## Known Limitations

- Linux persistent auth depends on `secret-tool`; env/flag auth is the guaranteed fallback.
- Windows Credential Manager support requires a successful Windows CI run; it cannot be proved from local macOS alone.
- The live Gemini workflow runs only for trusted main-branch pushes, nightly, or manual dispatch. A successful live run is required before tagging a release.
- Release artifacts are source-only. The project does not publish unsigned prebuilt binaries.
- The Python skill wrapper validates design handoff shape, but Swift remains the source of truth for analysis, memory, runs, snapshots, compare, and GC.
