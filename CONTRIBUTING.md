# Contributing

## Local Release Gate

Run the complete offline gate from a clean checkout:

```bash
swift test
python3 scripts/build_with_warning_audit.py --configuration release
python3 -m py_compile skills/gemini-design-agent/gda_skill.py skills/gemini-design-agent/gda_*.py
python3 -m unittest discover -s skills/gemini-design-agent/tests -p 'test_*.py'
python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/validate_skill.py --json
python3 scripts/evaluate_design_quality.py --mode recorded --corpus public
python3 scripts/install_skill.py --dry-run --codex-home /tmp/gda-codex-home
python3 scripts/audit_public_release.py
git diff --check
```

Run the Xcode 27 Beta 2 proof without changing global `xcode-select`:

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.2.app/Contents/Developer swift test
```

## Live Gemini Tests

Live tests are skipped by default. Opt in only when you intend to spend Gemini API quota:

```bash
GDA_LIVE_GEMINI_TESTS=1 GEMINI_API_KEY=... swift test --filter GeminiLiveSmokeTests
```

The trusted GitHub workflow runs this focused test only on main-branch pushes, nightly, and manual dispatch. It never runs for pull requests. A release commit needs a successful trusted live workflow before it is tagged.

Live installed-skill and quality tests intentionally consume Gemini quota. Do
not run them casually, retry a low quality score, or expose a repository secret
to pull-request code.

## Design-Quality Evaluation

Public fixtures must be original, license-safe, checksummed, and include source
artwork, a PNG, a manifest, and a recorded analysis. Recorded mode runs on every
change without network access. Live mode uses a fresh temporary `.gda` project
per fixture and is reserved for trusted workflows.

Private fixtures belong under `evals/design-quality/private/`; never commit
their screenshots or raw outputs. Reports must remain redacted and path-free.

## SQLite Provenance And Warnings

`CSQLite/README.md` records the official amalgamation URL, version, hashes,
features, and compile policy. Upgrade only from an official SQLite archive,
verify the documented hashes, and never hand-edit the generated amalgamation.

Fix every project-owned warning. If an upstream generated SQLite warning cannot
be eliminated by upgrading, suppress only that exact category inside the
`CSQLite` wrapper. Blanket warning suppression is not allowed. The warning-audit
script must pass with no uncontrolled `warning:` line.

## Lock And Auth Safety

Use `gda lock status` before `gda lock clear --force`; force clearing intentionally requires an explicit mutation flag. `auth set` and `auth onboard` only read secrets from a TTY and always restore terminal echo after entry. Do not pipe API keys into either command.

## Network Contracts

Keep Interactions request/response fixtures aligned with `https://ai.google.dev/static/api/interactions-v1.openapi.json`. Do not add SDK-only fields such as `output_text` or `usage_metadata` to REST fixtures. Network tests must inject waits; they must not sleep in real time.

## Secrets

Do not log, archive, or commit API keys. Credential resolution belongs at the CLI boundary:

1. `--api-key`
2. `GEMINI_API_KEY`
3. platform credential store

Never persist secrets in `.gda`, SQLite, JSONL, prompt artifacts, wrapper diagnostics, or docs examples.
