#!/usr/bin/env python
"""Redact machine-specific identifiers from the evidence artifacts before publishing.

The probe JSON files capture real stdout/stderr from a local Codex run, so they
embed the author's Windows profile directory (which contains the account name and
hostname) and the sandbox temp root. Those are not secrets, but they are personal
environment details with no reason to ship in a public repository.

Replacement targets the MARKER itself rather than a full path, so it works
regardless of how deeply backslashes are escaped inside JSON strings. The
surrounding output -- the actual policy verdicts -- is left byte-for-byte intact,
so the evidence remains verifiable.

Deliberately NOT redacted:
  * `codex-build` -- an ordinary directory name a reader may legitimately reuse.
  * drive letters and generic paths -- carry no personal information.

Usage:
    python sanitize-for-publish.py [root]

Exits non-zero if any known personal marker survives.
"""
import os
import sys

# (marker, replacement). Chosen so they match at any escaping level.
REPLACEMENTS = [
    # Windows profile path segment: contains both account name and hostname.
    ("Administrator.DESKTOP-4A6KNOF", "<user>"),
    # Sandbox temp root used by the probe harness.
    ("360data", "<TEMP_ROOT>"),
]

FORBIDDEN = [marker for marker, _ in REPLACEMENTS]

# This script necessarily contains the markers as literals; skip it.
SELF = "sanitize-for-publish.py"

TEXT_EXT = {".md", ".json", ".py", ".rs", ".ps1", ".cmd", ".patch", ".txt"}


def _walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__")]
        for name in filenames:
            yield os.path.join(dirpath, name), name


def sanitize(root):
    changed = []
    for path, name in _walk(root):
        if name == SELF or os.path.splitext(name)[1].lower() not in TEXT_EXT:
            continue
        try:
            raw = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        new = raw
        for marker, repl in REPLACEMENTS:
            new = new.replace(marker, repl)
        if new != raw:
            open(path, "w", encoding="utf-8", newline="").write(new)
            changed.append(os.path.relpath(path, root))
    return changed


def audit(root):
    hits = {}
    for path, name in _walk(root):
        if name == SELF:
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for marker in FORBIDDEN:
            if marker in text:
                hits.setdefault(os.path.relpath(path, root), set()).add(marker)
    return hits


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    changed = sanitize(root)
    print("sanitized %d file(s)" % len(changed))
    for c in changed:
        print("   ", c)
    hits = audit(root)
    if hits:
        print("\n[FAIL] personal markers still present:")
        for path, markers in sorted(hits.items()):
            print("   %s -> %s" % (path, ", ".join(sorted(markers))))
        return 1
    print("\n[OK] no personal markers remain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
