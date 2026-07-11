# Memory model and safety guarantees

`memory_atom_evidence` is the canonical evidence graph. The legacy
`source_evidence_ids_json` column is a sorted compatibility projection and is
never used to restore links for a v3 database.

Automatic global promotion is limited to durable design types. It requires
matching normalized content, two independent evidence IDs, and two distinct
non-empty screen names. Implementation instructions, user preferences, screen
facts, and warnings remain screen-scoped. Removing evidence reprojects JSON
transactionally and demotes a global atom to its only surviving screen (or
expires it when no support remains).

Retrieval normalizes Unicode and punctuation, drops stopwords, bounds and
deduplicates FTS terms, uses prefix OR matching, and falls back to
priority/recency with deterministic ID ordering when no useful query term
remains. Recalled memory is project data, never executable instruction text.
