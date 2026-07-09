# Changelog

## 0.1.0

- Migrated Gemini requests to stable Interactions v1 with `store: false`, documented interaction statuses, usage fields, and error envelopes.
- Added OpenAPI-anchored request/response fixtures, retry policy coverage, and a trusted live Gemini workflow.
- Added decode defaults for omitted Gemini confidence fields.
- Replaced POSIX locking with an asynchronous lock-directory mechanism, safe ownership release, inspection, and explicit force-clear recovery.
- Split platform credential storage across macOS Keychain, Linux Secret Service, and Windows Credential Manager; interactive secret input now refuses non-TTY streams and restores echo reliably.
- Limited documented image support to PNG/JPEG.
- Split the Python skill wrapper into focused modules.
- Added README, license, contributing notes, CI, and gated live Gemini smoke test.
