from __future__ import annotations

PRODUCT_VERSION = "0.1.0"
SKILL_PROTOCOL_VERSION = "1"
GEMINI_API_VERSION = "v1"
PROMPT_SCHEMA_VERSION = "1.1"
ANALYSIS_SCHEMA_VERSION = "1.0"
DATABASE_SCHEMA_VERSION = 3
INSTALL_MANIFEST_NAME = ".gda-install-manifest.json"
RUNTIME_PYTHON_FILES = (
    "gda_skill.py",
    "gda_auth.py",
    "gda_cli.py",
    "gda_commands.py",
    "gda_constants.py",
    "gda_envelope.py",
    "gda_handoff.py",
    "gda_runner.py",
)

DEFAULT_ANALYSIS_REQUEST = (
    "Extract layout, spacing, typography, colors, reusable components, "
    "and development-ready implementation values."
)

HANDOFF_SCHEMA_VERSION = "gda.design_handoff.v1"
AUTH_ONBOARDING_URL = "https://aistudio.google.com/app/apikey"
AUTH_ONBOARDING_COOLDOWN_SECONDS = 300
