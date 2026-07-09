# Security Policy

## Supported Versions

The `0.1.x` release line receives security fixes while it is the latest public
minor release.

## Reporting A Vulnerability

Use GitHub's private vulnerability reporting for this repository. Do not open a
public issue containing credentials, private screenshots, local project data,
or an unredacted `.gda` directory.

Include the affected version, platform, reproduction steps, and the smallest
redacted diagnostic needed to understand the problem. You should receive an
initial acknowledgement within three business days and a remediation status
within seven business days.

## Credential Response

If a Gemini API key may have been exposed, revoke it in Google AI Studio before
continuing investigation. Then remove or replace the local credential with:

```bash
GDA="${CODEX_HOME:-$HOME/.codex}/skills/gemini-design-agent/bin/gda"
"$GDA" auth remove
"$GDA" auth onboard
```

Never attach Keychain exports, environment dumps, shell history, process lists,
or GitHub Actions secret values to a report.

## Local Data

Each project directory can contain screenshots paths, prompts, raw model
responses, structured analysis, SQLite memory, and JSONL evidence. Sanitize or
delete that data before sharing a reproduction. The default project directory
is `.gda`, but callers may choose any absolute path.
