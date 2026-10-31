"""What changed upstream since the versions we use (D33). Read only: fetches into bare mirrors outside the repo.
    python3 tools/upstream_report.py [--mirrors DIR] [--out report.md] [--no-fetch]
For each entry of tools/upstreams.json: the version we use, the upstream commits after it with the files
they touch, which of those files we changed ourselves (a cherry-pick will conflict there), license file
changes, and commits that look like fixes. For the engine: AyagamiDev's Godot build, newer 4.x tags, and
whether the blend mode PR is merged. Nothing is merged or picked, the report is for deciding.
"""
import argparse
import json
import re
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MIRRORS = ROOT.parent / "external" / "upstream"
FIX_WORDS = re.compile(r"\b(fix|fixes|fixed|crash|leak|security|cve|panic|regression|deadlock)\b", re.I)
LICENSE_FILE = re.compile(r"(^|/)(LICEN[CS]E|COPYING|NOTICE)[^/]*$", re.I)
MAX_LIST = 40


def git(*args, cwd=ROOT) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def mirror(up: dict, mirrors: Path, fetch: bool) -> Path:
    path = mirrors / (re.sub(r"[^A-Za-z0-9_.-]", "_", up["name"]) + ".git")
    if not path.exists():
        # trees without file contents: enough for logs and changed file names, small on disk
        subprocess.run(["git", "clone", "--bare", "--filter=blob:none", "-q", up["url"], str(path)], check=True)
    elif fetch:
        subprocess.run(["git", "-C", str(path), "fetch", "-q", "--prune", "origin",
                        "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"], check=True)
    return path


def subtree_pin(prefix: str) -> tuple[str, str]:
    """(split commit, the monorepo commit that added or last pulled the subtree)"""
    log = git("log", "--format=%H%n%b%n--end--", f"--grep=git-subtree-dir: {prefix}$")
    for block in log.split("--end--"):
        lines = block.strip().splitlines()
        if not lines:
            continue
        body = "\n".join(lines[1:])
        if re.search(rf"^git-subtree-dir: {re.escape(prefix)}$", body, re.M):
            split = re.search(r"^git-subtree-split: ([0-9a-f]+)", body, re.M)
            if split:
                return split.group(1), lines[0]
    raise SystemExit(f"no subtree commit for {prefix}")


def lock_source(lock: str, package: str) -> tuple[str, str]:
    text = (ROOT / lock).read_text()
    for block in text.split("[[package]]"):
        if re.search(rf'^name = "{re.escape(package)}"$', block, re.M):
            version = re.search(r'^version = "([^"]+)"', block, re.M).group(1)
            source = re.search(r'^source = "([^"]+)"', block, re.M)
            return version, (source.group(1) if source else "")
    raise SystemExit(f"{package} not in {lock}")


def our_changes(prefix: str, since: str) -> set[str]:
    """files under prefix that our own commits changed after the subtree arrived, relative to prefix"""
    out = git("log", "--format=", "--name-only", f"{since}..HEAD", "--", prefix)
    return {f[len(prefix) + 1:] for f in out.splitlines() if f.startswith(prefix + "/")}


def upstream_commits(mpath: Path, base: str, branch: str) -> list[dict]:
    fmt = "--format=@@%H%x09%ad%x09%an%x09%s"
    out = git("log", fmt, "--date=short", "--name-only", f"{base}..{branch}", cwd=mpath)
    commits = []
    for block in out.split("@@")[1:]:
        head, *files = block.strip().splitlines()
        sha, date, author, subject = head.split("\t", 3)
        commits.append({"sha": sha[:9], "date": date, "author": author, "subject": subject,
                        "files": [f for f in files if f]})
    return commits


def github(path: str):
    req = urllib.request.Request(f"https://api.github.com/{path}", headers={"Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except Exception as e:  # rate limits and outages only cost this section
        return {"error": str(e)}


def report_upstream(up: dict, mirrors: Path, fetch: bool) -> list[str]:
    lines = [f"## {up['name']} ({up['policy']})", ""]
    if up.get("note"):
        lines += [up["note"], ""]
    mpath = mirror(up, mirrors, fetch)
    pin = up["pin"]
    changed: set[str] = set()
    if pin["kind"] == "subtree":
        split, added = subtree_pin(pin["prefix"])
        if subprocess.run(["git", "-C", str(mpath), "cat-file", "-e", split + "^{commit}"]).returncode != 0:
            # our own fork commit (OpenVT): bring it over to find where it left upstream
            subprocess.run(["git", "-C", str(mpath), "fetch", "-q", str(ROOT), split], check=True)
        base = git("merge-base", split, up["branch"], cwd=mpath)
        changed = our_changes(pin["prefix"], added)
        ours = git("rev-list", "--count", f"{base}..{split}", cwd=mpath)
        lines.append(f"- we use: upstream {base[:9]} ({git('log', '-1', '--format=%ad', '--date=short', base, cwd=mpath)})"
                     f" + {ours} commits of our fork before the import + our commits since, "
                     f"{len(changed)} files changed by us under {pin['prefix']}")
    elif pin["kind"] == "cargo-lock":
        version, source = lock_source(pin["lock"], pin["package"])
        base = source.rsplit("#", 1)[-1]
        lines.append(f"- we use: {base[:9]} ({source.split('?')[0]})")
    elif pin["kind"] == "cargo-lock-version":
        version, _ = lock_source(pin["lock"], pin["package"])
        tags = git("tag", "--list", "--sort=-v:refname", cwd=mpath).splitlines()
        newer = [t for t in tags if re.fullmatch(r"v?\d+\.\d+\.\d+", t) and _ver(t) > _ver(version)]
        lines += [f"- we use: {version}", f"- newer releases: {', '.join(newer[:10]) or 'none'}", ""]
        return lines
    elif pin["kind"] == "submodule":
        base = git("rev-parse", f"HEAD:{pin['path']}")
        lines.append(f"- we use: {base[:9]}")
    else:
        raise SystemExit(f"unknown pin kind {pin['kind']}")

    commits = upstream_commits(mpath, base, up["branch"])
    lines.append(f"- upstream {up['branch']} has {len(commits)} newer commits")
    if not commits:
        return lines + [""]
    lic = [c for c in commits if any(LICENSE_FILE.search(f) for f in c["files"])]
    if lic:
        lines.append(f"- LICENSE CHANGED in {', '.join(c['sha'] for c in lic)}: read before taking anything")
    lines += ["", "| commit | date | subject | touches our changes | fix? |", "|---|---|---|---|---|"]
    for c in commits[:MAX_LIST]:
        overlap = sorted(set(c["files"]) & changed)
        fix = "yes" if FIX_WORDS.search(c["subject"]) else ""
        subject = c["subject"].replace("|", "/")
        lines.append(f"| {c['sha']} | {c['date']} | {subject} | {', '.join(overlap[:3]) or ''} | {fix} |")
    if len(commits) > MAX_LIST:
        lines.append(f"| ... | | {len(commits) - MAX_LIST} older ones not listed | | |")
    return lines + [""]


def _ver(tag: str) -> tuple[int, ...]:
    return tuple(int(x) for x in tag.lstrip("v").split("."))


def report_godot(cfg: dict) -> list[str]:
    lines = ["## Godot engine", "", cfg.get("note", ""), "", f"- we use: {cfg['engine_version']} (AyagamiDev build)"]
    b = cfg["build_release"]
    rel = github(f"repos/{b['repo']}/releases/tags/{b['tag']}")
    if "error" in rel:
        lines.append(f"- AyagamiDev build: could not check ({rel['error']})")
    else:
        assets = ", ".join(a["name"] for a in rel.get("assets", [])[:6])
        lines.append(f"- AyagamiDev build release '{rel.get('name') or b['tag']}': published {rel.get('published_at', '?')[:10]}, "
                     f"assets {assets}")
    ours = _ver(cfg["engine_version"])
    out = subprocess.run(["git", "ls-remote", "--tags", "https://github.com/godotengine/godot.git"],
                         capture_output=True, text=True).stdout
    stable = sorted({m.group(1) for m in re.finditer(r"refs/tags/(\d+\.\d+(?:\.\d+)?)-stable$", out, re.M)}, key=_ver)
    newer = [t for t in stable if _ver(t) > ours]
    same_minor = [t for t in newer if _ver(t)[:2] == ours[:2]]
    lines.append(f"- newer stable Godot: {', '.join(newer) or 'none'} (same minor: {', '.join(same_minor) or 'none'})")
    pr = cfg["blend_mode_pr"]
    p = github(f"repos/{pr['repo']}/pulls/{pr['number']}")
    if "error" in p:
        lines.append(f"- blend mode PR #{pr['number']}: could not check ({p['error']})")
    else:
        state = "MERGED" if p.get("merged_at") else p.get("state", "?")
        lines.append(f"- blend mode PR #{pr['number']}: {state}"
                     + (f" on {p['merged_at'][:10]}, official builds can replace the patched one" if p.get("merged_at") else ""))
    return lines + [""]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirrors", type=Path, default=DEFAULT_MIRRORS)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--no-fetch", action="store_true")
    a = ap.parse_args()
    cfg = json.loads((ROOT / "tools" / "upstreams.json").read_text())
    a.mirrors.mkdir(parents=True, exist_ok=True)
    lines = ["# Upstream report", "", f"monorepo HEAD {git('rev-parse', '--short', 'HEAD')}, "
             f"{git('log', '-1', '--format=%ad', '--date=short')}", ""]
    for up in cfg["upstreams"]:
        try:
            lines += report_upstream(up, a.mirrors, not a.no_fetch)
        except (subprocess.CalledProcessError, SystemExit) as e:
            lines += [f"## {up['name']}", "", f"- could not check: {e}", ""]
    lines += report_godot(cfg["godot"])
    text = "\n".join(lines)
    if a.out:
        a.out.write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
