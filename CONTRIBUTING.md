# Contributing

## Local Checks

Run Swift tests:

```bash
swift test
```

Run wrapper checks:

```bash
python3 -m py_compile skills/gemini-design-agent/gda_skill.py skills/gemini-design-agent/gda_*.py
python3 -m unittest discover -s skills/gemini-design-agent/tests -p 'test_*.py'
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
