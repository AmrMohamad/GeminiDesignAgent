# Bundled SQLite

This target vendors the official SQLite amalgamation so `gda` has the same
FTS5 and JSON behavior on every supported platform.

- Version: 3.53.3
- Retrieved: 2026-07-10
- Archive: `sqlite-amalgamation-3530300.zip`
- Source: https://www.sqlite.org/2026/sqlite-amalgamation-3530300.zip
- Archive SHA3-256: `d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9`
- Official `sqlite3-amalgamation.c` SHA3-256: `28e484abdaa43630e34040ef6ed92be973a1ad54107803d8af5145b889c23ed7`

Compile-time configuration is owned by `Package.swift`:

- `SQLITE_ENABLE_FTS5`
- `SQLITE_ENABLE_JSON1`
- `SQLITE_THREADSAFE=1`

The Xcode 27 Clang toolchain reports `-Wambiguous-macro` and
`-Wshorten-64-to-32` throughout the generated amalgamation. The small
project-owned `sqlite3.c` wrapper suppresses exactly those categories while it
includes the excluded, byte-identical `sqlite3-amalgamation.c`. This avoids
SwiftPM unsafe flags, which would make the library product unsuitable as a
dependency. Do not patch `sqlite3-amalgamation.c` or `sqlite3.h` manually and
do not extend the suppressions to other project sources.

When updating SQLite, download a new official amalgamation, verify both hashes,
replace `sqlite3-amalgamation.c` and `sqlite3.h` mechanically, update this file, then run the
full storage, lock, migration, debug-build, and release-build verification.
