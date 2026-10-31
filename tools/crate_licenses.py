#!/usr/bin/env python3
"""License list of the Rust crates a build links (B6, D9: no GPL in what we ship), from `cargo metadata`.

    python3 tools/crate_licenses.py core/gd [--features ncnn] [--out NOTICE-crates.md]

Prints crates grouped by license and flags any GPL, LGPL, AGPL or unknown license. Only crates the build
actually links count: normal dependencies of the package for Linux x86_64, not dev or build-only ones.
"""
import argparse
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

COPYLEFT = ("GPL", "LGPL", "AGPL", "EUPL", "CDDL")
# file-level copyleft: fine to link and ship as long as those crates' own sources stay available (they are
# published crates); godot-rust is MPL-2.0, the app already ships it with Ayagami
WEAK = ("MPL",)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("crate", type=Path)
    ap.add_argument("--features", default="")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    cmd = ["cargo", "metadata", "--format-version", "1", "--filter-platform", "x86_64-unknown-linux-gnu",
           "--manifest-path", str(a.crate / "Cargo.toml")]
    if a.features:
        cmd += ["--features", a.features]
    meta = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    # walk normal (linked) dependencies from the root only
    seen, todo = set(), [meta["resolve"]["root"]]
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            if any(k["kind"] is None for k in dep["dep_kinds"]):
                todo.append(dep["pkg"])
    by_license = defaultdict(list)
    for pid in seen:
        p = packages[pid]
        if p["source"] is None:  # our own crates
            continue
        by_license[p.get("license") or "UNKNOWN"].append(f"{p['name']} {p['version']}")
    lines = [f"# Rust crates in {a.crate} ({sum(map(len, by_license.values()))})", ""]
    flagged = []
    for lic in sorted(by_license):
        names = sorted(by_license[lic])
        lines.append(f"## {lic} ({len(names)})")
        lines.append(", ".join(names))
        lines.append("")
        # a crate offered under "X OR Y" is fine when one of the choices is permissive
        choices = [c.strip() for c in lic.replace("(", "").replace(")", "").split(" OR ")]
        if lic == "UNKNOWN" or all(any(w in c for w in COPYLEFT) for c in choices):
            flagged.append((lic, names))
    weak = [f"{lic}: {', '.join(sorted(by_license[lic]))}" for lic in sorted(by_license) if any(w in lic for w in WEAK)]
    if weak:
        lines += ["File-level copyleft (their sources are the published crates, unchanged):", *weak, ""]
    text = "\n".join(lines)
    if a.out:
        a.out.write_text(text)
    print(text)
    for lic, names in flagged:
        print(f"CHECK: {lic}: {', '.join(names)}", file=sys.stderr)
    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
