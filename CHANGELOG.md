# Changelog

## 0.1.0

- Added an authoritative product/protocol contract plus `gda --version` and
  machine-readable `gda version --json` output.
- Made the Codex skill discoverable with valid metadata and added deterministic
  runtime-closure validation.
- Added an atomic, manifest-backed, cross-platform source-build installer with
  compatibility handshakes, restricted-PATH proof, conflict detection, and
  rollback.
- Added a repository-owned macOS/Linux Bash bootstrap with prerequisite,
  checkout-version, and no-write preflight validation for clone-and-run setup.
- Added run telemetry for contract versions, token usage, duration, raw usage,
  conservative dated cost estimates, database migration v2, and `runs stats`.
- Added original public design-quality fixtures, deterministic recorded scoring,
  and a two-pass installed-skill memory-recall smoke.
- Upgraded bundled SQLite to 3.53.3 with verified provenance and a warning-clean
  build policy.
- Added cross-platform install/manifest/quality CI, supply-chain updates,
  security guidance, and public-release secret/history auditing.
- Migrated Gemini requests to stable Interactions v1 with `store: false`, documented interaction statuses, usage fields, and error envelopes.
- Added OpenAPI-anchored request/response fixtures and retry policy coverage.
- Added decode defaults for omitted Gemini confidence fields.
- Replaced POSIX locking with an asynchronous lock-directory mechanism, safe ownership release, inspection, and explicit force-clear recovery.
- Split platform credential storage across macOS Keychain, Linux Secret Service, and Windows Credential Manager; interactive secret input now refuses non-TTY streams and restores echo reliably.
- Limited documented image support to PNG/JPEG.
- Split the Python skill wrapper into focused modules.
- Added README, license, contributing notes, CI, and gated live Gemini smoke test.
