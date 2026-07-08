# Gemini Design Agent Skill

Use this skill when you need to analyze a UI screenshot, Figma export, app screen, component screenshot, or design mockup and return development-ready layout details.

## Tool

Use `gda_skill.py`, which wraps the Swift CLI binary `gda`.

The wrapper always calls `gda` with `--json`, parses stdout as JSON, and returns the CLI envelope:

```json
{
  "ok": true,
  "command": "analyze",
  "schema_version": "1.0",
  "data": {},
  "diagnostics": [],
  "next_actions": []
}
```

## Authentication

Required:

```bash
gda auth set
```

Optional:

```bash
export GDA_BIN="/absolute/path/to/gda"
```

For CI or temporary debugging only, `GEMINI_API_KEY` can override the Keychain value for a single process.

## Initialize memory

```bash
python gda_skill.py setup \
  --project-dir ./.gda \
  --project-name "My Design Project"

python gda_skill.py init \
  --project-dir ./.gda \
  --project-name "My Design Project"
```

## Preflight

```bash
python gda_skill.py doctor \
  --project-dir ./.gda \
  --image /absolute/path/to/frame.png
```

## Analyze screenshot

```bash
python gda_skill.py analyze \
  --project-dir ./.gda \
  --image /absolute/path/to/frame.png \
  --screen "Home Screen" \
  --request "Extract layout, spacing, colors, typography, components, and code-ready values." \
  --device-pixel-ratio 2 \
  --viewport 390x844 \
  --theme light \
  --state default \
  --locale-direction ltr
```

## Batch analyze

Batch file format: one image path per line, optionally followed by comma or tab and a screen name.

```bash
python gda_skill.py analyze-batch \
  --project-dir ./.gda \
  --batch-file /absolute/path/to/screens.txt \
  --preset components
```

## Compare screenshots

```bash
python gda_skill.py compare \
  --before /absolute/path/to/old.png \
  --after /absolute/path/to/new.png
```

## Search memory

```bash
python gda_skill.py memory-search \
  --project-dir ./.gda \
  --query "primary button spacing and radius" \
  --limit 8
```

## Inspect memory

```bash
python gda_skill.py memory-show \
  --project-dir ./.gda \
  --id mem_123

python gda_skill.py memory-export \
  --project-dir ./.gda
```

## Preview memory injection

```bash
python gda_skill.py memory-preview \
  --project-dir ./.gda \
  --screen "Home Screen" \
  --request "primary button spacing"

python gda_skill.py memory-explain \
  --project-dir ./.gda \
  --run-id run_123

python gda_skill.py memory-conflicts \
  --project-dir ./.gda
```

## Inspect runs

```bash
python gda_skill.py runs-list \
  --project-dir ./.gda

python gda_skill.py runs-show \
  --project-dir ./.gda \
  --id run_123

python gda_skill.py runs-undo \
  --project-dir ./.gda \
  --id run_123 \
  --confirm

python gda_skill.py runs-recover \
  --project-dir ./.gda \
  --id run_123
```

## Clean local artifacts

```bash
python gda_skill.py gc \
  --project-dir ./.gda

python gda_skill.py gc \
  --project-dir ./.gda \
  --max-raw-refs-age-days 30 \
  --expire-low-confidence-older-than-days 60 \
  --min-confidence 0.55 \
  --apply
```

## Export and snapshots

```bash
python gda_skill.py export \
  --project-dir ./.gda \
  --format figma-tokens

python gda_skill.py export \
  --project-dir ./.gda \
  --format tailwind

python gda_skill.py snapshot create \
  --project-dir ./.gda \
  --name "before rebrand"

python gda_skill.py snapshot list \
  --project-dir ./.gda
```

## Agent rules

* Always pass an absolute image path.
* Always pass a clear screen name.
* Do not base64 encode images yourself; let `gda` handle image loading.
* Do not parse stderr. Only parse stdout JSON.
* Check `ok`, `error.code`, `diagnostics`, and `next_actions` before deciding recovery.
* Use `doctor` before long-running analysis in CI or unfamiliar project directories.
* Use `memory-search` before code generation when you need style consistency.
* Use `memory-preview` before `analyze` when you need to inspect prompt memory without spending Gemini quota.
* Use `memory-explain` after a run when you need to explain why memory affected the prompt.
* Use `memory-conflicts` when output looks inconsistent or after a rebrand.
* Use `runs-undo` for wrong-screen recovery instead of manually editing SQLite.
* Use `snapshot create` before a large design-system shift.
* Use the `analysis.elements[*].bboxPx` fields for implementation measurements.
* Use `analysis.elements[*].bboxCss` when `--device-pixel-ratio` is set for Retina/HiDPI screenshots.
* Use `analysis.tokens` and `analysis.components` for reusable design system values.
* Treat Gemini measurements as visual estimates unless confidence is high.
