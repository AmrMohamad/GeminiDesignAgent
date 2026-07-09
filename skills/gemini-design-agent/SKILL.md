# Gemini Design Agent Skill

Use this skill when you need to analyze a UI screenshot, Figma export, app screen, component screenshot, or design mockup and return development-ready layout details.

## Tool

Use `gda_skill.py`, which wraps the bundled Swift CLI binary at `bin/gda`.

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
python gda_skill.py ensure-auth
gda auth onboard
```

`ensure-auth` is the agent-facing readiness check. If no platform credential-store key or temporary `GEMINI_API_KEY` override exists, it may open a Terminal window with the guided `gda auth onboard` flow on macOS.

`gda auth onboard` is interactive. It opens Google AI Studio API Keys where supported, asks the user to paste the key, and stores it in the platform credential store: macOS Keychain, Linux Secret Service when `secret-tool` is available, or Windows Credential Manager.

`gda auth set` and `gda auth onboard` require a real TTY. JSON mode and piped stdin are rejected; do not pipe credentials into either command. The CLI disables terminal echo only during entry and restores it before returning.

The wrapper resolves the executable in this order:

1. `GDA_BIN` override
2. `bin/gda` inside this skill
3. `gda` from `PATH`

Optional override:

```bash
export GDA_BIN="/absolute/path/to/gda"
```

For CI or temporary debugging only, `GEMINI_API_KEY` can override the credential-store value for a single process.

Auth-required wrapper commands automatically run `ensure-auth` before contacting Gemini:

* `analyze`
* `analyze-batch`
* `analyze-handoff`

Non-analysis commands such as `capabilities`, `validate-handoff`, `setup`, `doctor`, memory inspection, compare, export, snapshots, and GC do not auto-open Terminal.

To suppress Terminal onboarding in CI or headless runs:

```bash
GDA_DISABLE_AUTH_ONBOARDING=1 python gda_skill.py ensure-auth
```

## Dynamic design-platform handoff

Other design skills should call this skill through a small handoff JSON instead of depending on Figma, Open Design, Sketch, XD, or browser-specific code inside `gda`.

Use this when another skill can produce a local screenshot plus optional platform metadata:

```bash
python gda_skill.py ensure-auth
python gda_skill.py capabilities
python gda_skill.py validate-handoff --handoff-json /absolute/path/to/handoff.json
python gda_skill.py analyze-handoff --handoff-json /absolute/path/to/handoff.json
```

Minimum handoff:

```json
{
  "schema_version": "gda.design_handoff.v1",
  "source": {
    "platform": "figma",
    "mode": "mcp",
    "url": "https://www.figma.com/design/...",
    "file_key": "abc123",
    "node_id": "1:2",
    "node_name": "Home Screen"
  },
  "asset": {
    "image_path": "/absolute/path/to/home.png",
    "scale": 2
  },
  "analysis": {
    "project_dir": "/absolute/path/to/.gda",
    "screen": "Home Screen",
    "preset": "components",
    "viewport": "390x844",
    "theme": "light",
    "state": "default",
    "locale_direction": "ltr"
  },
  "context": {
    "tokens": {},
    "metadata": {},
    "layout_tree": [],
    "interactions": []
  }
}
```

Accepted source platforms are intentionally open-ended. Use `source.platform` values such as `figma`, `open_design`, `local_fig_decoder`, `browser`, `sketch`, `adobe_xd`, or any platform-specific slug. The only hard requirement is a local PNG/JPEG screenshot path that `gda` can read.

Handoff rules for platform skills:

* Keep platform extraction in the source skill. For Figma, use Figma MCP or REST to produce the screenshot and metadata; do not make `gda` call Figma directly.
* Pass absolute paths for exported screenshots and generated handoff JSON.
* Put traceability in `source`: platform, URL, file key, node ID, node name, MCP tool name, or export mode.
* Put design-system hints in `context`: tokens, metadata, layout tree, interactions, assets, unresolved fields.
* Keep screenshots as the visual source of truth. Treat `context` as disambiguation and traceability metadata.
* Run `validate-handoff` before `analyze-handoff` in CI or multi-skill workflows.
* Use `--no-handoff-context` when the metadata is too large or noisy and only the screenshot should drive analysis.

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

## Request Privacy And Lock Recovery

The Swift CLI uses Gemini Interactions v1 with `store: false` for screenshot analysis. This requests no interaction storage; it does not change the provider's ordinary API data-processing terms.

Inspect locks before mutating them:

```bash
python gda_skill.py lock-status --project-dir ./.gda
python gda_skill.py lock-clear --project-dir ./.gda --force
```

`lock-clear` is destructive and requires `--force`. Network errors remain structured: timeout, unavailable network, DNS, connection, rate-limit, and HTTP failures are distinct in the CLI envelope.

## Analyze screenshot

```bash
python gda_skill.py analyze \
  --project-dir ./.gda \
  --image /absolute/path/to/frame.png \
  --screen "Home Screen" \
  --request "Extract layout, spacing, colors, typography, components, and code-ready values." \
  --preset components \
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
