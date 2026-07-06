# Gemini Design Agent Skill

Use this skill when you need to analyze a UI screenshot, Figma export, app screen, component screenshot, or design mockup and return development-ready layout details.

## Tool

Use `gda_skill.py`, which wraps the Swift CLI binary `gda`.

The wrapper always calls `gda` with `--json`, parses stdout as JSON, and returns machine-readable results.

## Environment

Required:

```bash
export GEMINI_API_KEY="..."
```

Optional:

```bash
export GDA_BIN="/absolute/path/to/gda"
```

## Initialize memory

```bash
python gda_skill.py init \
  --project-dir ./.gda \
  --project-name "My Design Project"
```

## Analyze screenshot

```bash
python gda_skill.py analyze \
  --project-dir ./.gda \
  --image /absolute/path/to/frame.png \
  --screen "Home Screen" \
  --request "Extract layout, spacing, colors, typography, components, and code-ready values."
```

## Search memory

```bash
python gda_skill.py memory-search \
  --project-dir ./.gda \
  --query "primary button spacing and radius" \
  --limit 8
```

## Agent rules

* Always pass an absolute image path.
* Always pass a clear screen name.
* Do not base64 encode images yourself; let `gda` handle image loading.
* Do not parse stderr. Only parse stdout JSON.
* Use `memory-search` before code generation when you need style consistency.
* Use the `analysis.elements[*].bboxPx` fields for implementation measurements.
* Use `analysis.tokens` and `analysis.components` for reusable design system values.
* Treat Gemini measurements as visual estimates unless confidence is high.
