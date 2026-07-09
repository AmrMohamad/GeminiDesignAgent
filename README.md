# GeminiDesignAgent

`gda` is a SwiftPM command-line tool for analyzing UI screenshots with the Gemini Interactions API and storing reusable design memory in a local `.gda` project.

It is intended for AI agents and developers who need a repeatable screenshot-to-implementation handoff:

```text
local PNG/JPEG screenshot -> Gemini structured JSON -> SQLite memory + JSONL archive
```

## Status

- Swift package and CLI: production hardening in progress.
- Gemini API path: stable Interactions API (`/v1/interactions`).
- Screenshot requests set `store: false`. This requests no interaction storage; it does not alter Google's normal API data-processing terms.
- Image input: PNG and JPEG only.
- Persistent auth:
  - macOS: Keychain.
  - Linux: Secret Service through `secret-tool` when available.
  - Windows: Credential Manager.
- Temporary auth override: `--api-key` or `GEMINI_API_KEY`.

## Build And Test

```bash
swift build
swift test
python3 -m py_compile skills/gemini-design-agent/gda_skill.py skills/gemini-design-agent/gda_*.py
python3 -m unittest discover -s skills/gemini-design-agent/tests -p 'test_*.py'
```

Local Xcode 27 Beta 2 proof should not mutate global `xcode-select`:

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.2.app/Contents/Developer swift test
```

## Quick Start

```bash
swift run gda setup --project-dir .gda --project-name "Design Project"
swift run gda auth set
swift run gda analyze \
  --project-dir .gda \
  --image /absolute/path/screen.png \
  --screen Home \
  --request "Extract layout, spacing, typography, colors, and reusable components." \
  --json
```

The CLI writes machine-readable JSON with an `ok` flag, command name, data payload, diagnostics, next actions, and structured error details.

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
GDA_LIVE_GEMINI_MODEL=gemini-2.5-flash
```

## Known Limitations

- Linux persistent auth depends on `secret-tool`; env/flag auth is the guaranteed fallback.
- Windows Credential Manager support requires a successful Windows CI run; it cannot be proved from local macOS alone.
- The live Gemini workflow runs only for trusted main-branch pushes, nightly, or manual dispatch. A successful live run is required before tagging a release.
- The Python skill wrapper validates design handoff shape, but Swift remains the source of truth for analysis, memory, runs, snapshots, compare, and GC.
