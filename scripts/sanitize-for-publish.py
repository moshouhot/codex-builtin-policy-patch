#!/usr/bin/env python
"""Redact machine-specific identifiers from the evidence artifacts before publishing.

The probe JSON files capture real stdout/stderr from a local Codex run, so they
embed the author's Windows profile directory (which contains the account name and
hostname) and the sandbox temp root. Those are not secrets, but they are personal
environment details with no reason to ship in a public repository.

No personal identifier is hardcoded here. The Windows profile path is derived
from the environment at run time, and anything that looks like a user profile
path is matched generically, so this script is safe to publish and reusable by
anyone preparing their own artifacts.

The surrounding output -- the actual policy verdicts -- is left byte-for-byte
intact, so the evidence remains verifiable.

Usage:
    python sanitize-for-publish.py [root]

Exits non-zero if a profile-path-shaped string survives.
"""
import os
import re
import sys

# Windows profile paths, e.g. C:\Users\someone or C:/Users/someone.
# Applied to the raw text, so it matches at any JSON escaping depth.
PROFILE_RE = re.compile(
    r"([A-Za-z]:[\\/]+[Uu]sers[\\/]+)([^\\/\s\"'<>;,)\]]+)"
)
# Sandbox / virtualization temp roots that leak host setup.
TEMP_ROOT_RE = re.compile(r"([A-Za-z]:[\\/]+)(\d{3,8}data)([\\/]+TEMP)", re.IGNORECASE)


def _redact(text):
    text = PROFILE_RE.sub(lambda m: m.group(1) + "<user>", text)
    text = TEMP_ROOT_RE.sub(lambda m: m.group(1) + "<temp-root>" + m.group(3), text)
    return text


TEXT_EXT = {".md", ".json", ".py", ".rs", ".ps1", ".cmd", ".patch", ".txt"}

# Skip this file: its regexes look like the thing they are matching.
SELF = os.path.basename(__file__)


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
        new = _redact(raw)
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
        found = set()
        if PROFILE_RE.search(text):
            found.add("profile-path")
        if TEMP_ROOT_RE.search(text):
            found.add("temp-root")
        if found:
            hits[os.path.relpath(path, root)] = found
    return hits


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    changed = sanitize(root)
    print("sanitized %d file(s)" % len(changed))
    for c in changed:
        print("   ", c)
    hits = audit(root)
    if hits:
        print("\n[FAIL] machine-specific identifiers still present:")
        for path, kinds in sorted(hits.items()):
            print("   %s -> %s" % (path, ", ".join(sorted(kinds))))
        return 1
    print("\n[OK] no machine-specific identifiers remain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
