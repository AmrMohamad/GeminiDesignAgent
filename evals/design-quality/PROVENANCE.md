# Design-quality fixture provenance

The `public/` fixtures are original synthetic interface designs created for the
GeminiDesignAgent test suite. They do not reproduce a product, customer screen,
third-party design, trademarked artwork, or private data. Their SVG sources,
rendered PNGs, manifests, and recorded analyses are provided under this
repository's MIT license.

Each fixture directory contains:

- `source.svg`: reviewable source artwork;
- `fixture.png`: the raster input used by live evaluation;
- `manifest.json`: expected geometry, colors, typography, and components;
- `recorded-analysis.json`: deterministic offline evaluator input;
- `SHA256SUMS`: checksums for all four files.

`private/` is reserved for locally owned screenshots and uses the same manifest
schema. It and `results/` must remain ignored by Git and must never be required
by CI. Evaluation reports contain only fixture identifiers, scores, and expected
labels; they intentionally exclude raw model output and filesystem paths.
