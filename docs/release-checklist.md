# Release checklist

1. Work from a clean, reviewed release commit and confirm `GDAContract.productVersion`.
2. Run `python3 scripts/package_release.py --version 0.1.0 --output dist/`.
   This command reruns Swift tests, the warning-clean release build, Python
   compilation and tests, skill validation, recorded single-screen and
   sequential evaluations, a temporary managed install, the public audit, and
   diff hygiene before creating the archive.
3. Preserve the generated ZIP and `SHA256SUMS` as release artifacts.
4. Confirm the exact release commit is green on macOS, Ubuntu, and Windows.
5. Record one deliberate, opt-in live Gemini smoke or explicitly state that it was not run.
6. Tag only the exact commit that passed every gate.
