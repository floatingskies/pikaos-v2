#!/usr/bin/env python3
"""Walk the dependency closure the ISO will install and list what has to come
from Debian.

Two inputs matter and mixing them up is what made this bug take so long:

* the v2 repository index, which says what our own rebuilt packages depend on,
  including transitively (pika-kde-desktop -> pika-baseos -> pika-baseos-minimal
  -> a package sid does not have). Only walking the closure finds that.
* dep-shims.tsv, which is applied before dpkg-buildpackage, so the index already
  reflects it.

Prints one external dependency per line, for the caller to check against apt.
"""
import os
import re
import sys

FIELD = re.compile(r"^(Depends|Pre-Depends):(.*)$", re.M | re.S)
NAME = re.compile(r"^([A-Za-z0-9][A-Za-z0-9+.-]*)((?::[A-Za-z0-9]+)*)")
ENTRY = re.compile(
    r"^([A-Za-z0-9][A-Za-z0-9+.-]*(?::[A-Za-z0-9]+)?(?:\s*\([^)]*\))?"
    r"(?:\s*\|\s*[A-Za-z0-9][A-Za-z0-9+.-]*(?::[A-Za-z0-9]+)?)*)\s+(?=[A-Za-z0-9])"
)


def load_shims(path):
    shims = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 2:
                shims[parts[0].strip()] = parts[1].strip()
    return shims


def split_deps(text):
    """Yield dependency names from one field, repairing missing commas."""
    out = []
    for chunk in text.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        while True:
            m = ENTRY.match(chunk)
            if not m:
                break
            out.append(m.group(1))
            chunk = chunk[m.end():].strip()
        if chunk:
            out.append(chunk)
    names = []
    for dep in out:
        m = NAME.match(dep)
        if m:
            names.append(m.group(1))
    return names


def load_index(path):
    """package -> set of dependency names, from a repo Packages file."""
    index = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        content = fh.read()
    for stanza in content.split("\n\n"):
        m = re.search(r"^Package: (.+)$", stanza, re.M)
        if not m:
            continue
        deps = set()
        for fm in FIELD.finditer(stanza):
            deps.update(split_deps(fm.group(2)))
        index[m.group(1).strip()] = deps
    return index


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: dep-closure.py <Packages> <dep-shims.tsv> <recipe-list>")
    packages_file, shims_file, recipe_file = sys.argv[1:4]

    shims = load_shims(shims_file)
    index = load_index(packages_file)

    with open(recipe_file, encoding="utf-8") as fh:
        recipe = [line.strip() for line in fh if line.strip()]

    missing_from_pool = [p for p in recipe if p not in index]

    seen, external = set(), set()
    queue = [p for p in recipe if p in index]
    while queue:
        pkg = queue.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        for dep in index.get(pkg, ()):
            if dep.startswith("$") or dep.startswith("<"):
                continue
            if dep in shims:
                action = shims[dep]
                # A renamed dependency may still need something from sid.
                if action != "-" and action not in index:
                    external.add(action)
                continue
            if dep in index:
                queue.append(dep)
            else:
                external.add(dep)

    if missing_from_pool:
        print("recipe names that are not in the v2 repository index:")
        for name in sorted(missing_from_pool):
            print("  " + name, file=sys.stderr)

    for name in sorted(external):
        print(name)


if __name__ == "__main__":
    main()