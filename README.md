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
- A Gemini API key or GDA-owned Google OAuth desktop client for live analysis. Offline builds, tests, recorded evaluation,
  and installer validation do not require either credential.

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
# Development/release-owner provisioning; end users still run only `gda auth onboard`:
python3 scripts/install_skill.py --oauth-client-secrets /secure/path/desktop-client.json
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

GDA supports Code Assist OAuth using the published Gemini CLI desktop identity,
public Gemini API OAuth using an imported installed-app client, and existing
Gemini API keys. It never reads Gemini CLI credential files or launches Gemini
CLI. Without `--account`, Code Assist may route across Google profiles that the
user explicitly signed into; `--account <profile-id>` pins one profile. Routing
honors observed provider quota and does not create accounts or projects to evade
limits. See [Google's rate-limit documentation](https://ai.google.dev/gemini-api/docs/rate-limits), [Google API Terms](https://developers.google.com/terms/), and the [Gemini CLI FAQ](https://geminicli.com/docs/faq/).

Credential lookup order is:

1. Explicit `--api-key` or `--account <profile-id>` (mutually exclusive)
2. `GEMINI_API_KEY`
3. The persistent `code-assist`, `public-oauth`, or `api-key` mode

Use `GEMINI_API_KEY` only for CI or temporary debugging. Credentials, imported
client configuration, OAuth responses, and full account emails are never
written to `.gda`, SQLite, JSONL records, diagnostics, or command arguments.

In an OAuth-ready installation, normal onboarding opens the system browser and
completes when the loopback callback returns. GDA validates provisioning before
printing that the browser is opening. No OAuth JSON path, authorization code,
or account label is requested from the end user:

```bash
gda auth onboard
gda auth login --mode code-assist
gda auth login --mode public-oauth
gda auth accounts list
gda auth accounts use <profile-id>
gda auth mode set code-assist
gda auth usage --account <profile-id> --json
gda auth credit-policy set never
```

Use `gda auth onboard --api-key` only when an API key is preferred. Development
builds must provision GDA's own desktop OAuth client once before browser login;
managed release builds should do this before distribution:

```bash
gda auth oauth-client import --client-secrets /absolute/path/desktop-client.json
gda auth oauth-client status
```

The validated public OAuth client configuration is remembered in the platform
secure credential store. `gda auth login --mode public-oauth --client-secrets
...` imports the client and opens sign-in; later public OAuth accounts omit the
client path. Code Assist login does not require an imported client.

Only `installed` public OAuth client JSON is accepted. GDA fixes the Google
authorization, token, revocation, and user-info endpoints; uses PKCE S256,
256-bit state, a five-minute one-shot `127.0.0.1` loopback callback, and
backend-specific scopes. Tokens and identity
metadata remain only in macOS Keychain, Linux Secret Service, or Windows
Credential Manager. `auth accounts remove` revokes remotely before deleting
the local profile; use `--local-only` only as a recovery option.

The observed usage ledger at `~/.geminidesignagent/usage-v1.json` is locked,
atomically updated, and mode `0600` on POSIX. It shows local observed requests,
tokens, errors, and provider cooldowns—not remaining quota.

API-key pool commands remain available for migration and manual selection:

```bash
gda auth pool add --label personal-project
gda auth pool add --label work-project
gda auth pool promote <entry-id>
gda auth status --json
```

The first-priority key is used until the user manually selects another one;
quota errors never cause project/key rotation. A model fallback chain is also
explicit and always stays in the selected account:

```bash
gda auth model-policy set --preferred gemini-3.5-flash --fallback gemini-3.5-pro
gda analyze --account <profile-id> --fallback-model gemini-3.5-pro
```

Fallback occurs only after a provider-proven model-scoped terminal quota error
or model unavailability. Project-wide quota, unknown 429s, RPM/TPM, billing,
authentication, invalid requests, and safety failures never trigger a fallback.

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

## Stable agent surface

For normal agent use, rely on `gda setup`, `gda doctor`, `gda analyze`, `gda memory search`, and `gda memory show`. Pool, lock, export, snapshot, compact, GC, and reset commands remain supported as advanced operator tools.

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
- Live tests are developer diagnostics only. Offline CI and release auditing are the documented release proof; no live-provider workflow is required for tagging.
- Release artifacts are source-only. The project does not publish unsigned prebuilt binaries.
- The Python skill wrapper validates design handoff shape, but Swift remains the source of truth for analysis, memory, runs, snapshots, compare, and GC.
