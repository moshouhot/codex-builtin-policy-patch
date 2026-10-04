#!/usr/bin/env python
"""Normalize Codex SQL migration files to CRLF before building a patched binary.

Why this is required
--------------------
sqlx embeds each migration's SQL text and computes a checksum from the file's
RAW BYTES. That checksum is written into the database's `_sqlx_migrations`
table when the migration is applied, and verified on every later open.

OpenAI publishes `codex-rs/state/*_migrations/*.sql` with CRLF line endings, so
the official binary records CRLF-based checksums. A source checkout with
`core.autocrlf=true` (the Windows default) rewrites those files to LF, changing
every checksum.

The result is a patched binary that cannot open ANY database the official binary
created -- and the official binary cannot open the ones it creates. The failure
surfaces as:

    Error: failed to initialize sqlite state runtime under <CODEX_HOME>: ...

which in Codex Desktop appears as a blocking "Organization settings could not
be loaded" dialog, because the app-server process exits during startup.

Usage
-----
    python fix-migrations-crlf.py [state_dir]

`state_dir` defaults to `codex-rs/state` relative to the current directory.
Exits non-zero if any file is still not CRLF after conversion.
"""
import os
import sys

MIGRATION_DIRS = (
    "migrations",
    "logs_migrations",
    "goals_migrations",
    "memory_migrations",
    "queue_migrations",
    "thread_history_migrations",
)


def normalize(state_dir):
    converted = 0
    total = 0
    for name in MIGRATION_DIRS:
        d = os.path.join(state_dir, name)
        if not os.path.isdir(d):
            continue
        for entry in sorted(os.listdir(d)):
            if not entry.endswith(".sql"):
                continue
            path = os.path.join(d, entry)
            raw = open(path, "rb").read()
            total += 1
            # Normalize to LF first so repeated runs are idempotent.
            normalized = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            if normalized != raw:
                open(path, "wb").write(normalized)
                converted += 1
    return total, converted


def verify(state_dir):
    bad = []
    for name in MIGRATION_DIRS:
        d = os.path.join(state_dir, name)
        if not os.path.isdir(d):
            continue
        for entry in sorted(os.listdir(d)):
            if not entry.endswith(".sql"):
                continue
            raw = open(os.path.join(d, entry), "rb").read()
            # A pure-CRLF file has no lone LF.
            if raw.replace(b"\r\n", b"").count(b"\n"):
                bad.append(os.path.join(name, entry))
    return bad


def main():
    state_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join("codex-rs", "state")
    if not os.path.isdir(state_dir):
        print("[FAIL] state dir not found: %s" % state_dir)
        return 1
    total, converted = normalize(state_dir)
    bad = verify(state_dir)
    print("[OK] migrations: %d files, %d converted to CRLF" % (total, converted))
    if bad:
        print("[FAIL] still not pure CRLF (%d):" % len(bad))
        for b in bad[:20]:
            print("   ", b)
        return 1
    print("[OK] all %d migration files are pure CRLF" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
