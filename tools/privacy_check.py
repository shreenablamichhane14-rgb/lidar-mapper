"""Block personal data from reaching the public repository.

Scans text files and commit metadata (author/committer emails, messages) for
patterns listed in `.privacy-patterns` at the repo root. That file is
gitignored on purpose: the patterns themselves are the personal data.

Pattern file format: one Python regular expression per line, matched
case-insensitively; blank lines and lines starting with # are ignored.
A line starting with `email-allow:` lists a regex of commit emails that are
allowed (everything else in commit metadata is rejected).

  python tools/privacy_check.py                # scan the working tree (tracked + untracked, not ignored)
  python tools/privacy_check.py --staged       # scan what is staged
  python tools/privacy_check.py --pre-push     # git pre-push hook mode (reads refs on stdin)
  python tools/privacy_check.py --range A..B   # scan commits in a range

Exit code 0 clean, 1 personal data found, 2 configuration error.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATTERN_FILE = ROOT / ".privacy-patterns"
ZERO = "0" * 40
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic", ".ipa", ".zip", ".usdz", ".pdf", ".ttf", ".otf"}


def git(*args: str) -> str:
    res = subprocess.run(["git", *args], capture_output=True, text=True, cwd=ROOT, encoding="utf-8", errors="replace")
    if res.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {res.stderr.strip()}")
    return res.stdout


def load_patterns() -> tuple[list[re.Pattern[str]], list[re.Pattern[str]]]:
    if not PATTERN_FILE.exists():
        print(f"privacy check: {PATTERN_FILE.name} missing; create it (one regex per line)", file=sys.stderr)
        sys.exit(2)
    deny: list[re.Pattern[str]] = []
    allow: list[re.Pattern[str]] = []
    for raw in PATTERN_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        is_allow = line.startswith("email-allow:")
        source = line.split(":", 1)[1].strip() if is_allow else line
        try:
            compiled = re.compile(source, re.IGNORECASE)
        except re.error as exc:
            print(f"privacy check: bad pattern on a line of {PATTERN_FILE.name}: {exc}", file=sys.stderr)
            sys.exit(2)
        (allow if is_allow else deny).append(compiled)
    return deny, allow


def scan_text(name: str, text: str, deny: list[re.Pattern[str]]) -> list[str]:
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        for pattern in deny:
            if pattern.search(line):
                # never echo the matched text itself; point at the location and the rule index
                hits.append(f"{name}:{number}: matches private pattern #{deny.index(pattern) + 1}")
    return hits


def scan_tree(paths: list[str], reader, deny) -> list[str]:
    hits: list[str] = []
    for path in paths:
        if Path(path).suffix.lower() in BINARY_SUFFIXES or path == PATTERN_FILE.name:
            continue
        text = reader(path)
        if text is None or "\x00" in text[:4096]:
            continue
        hits += scan_text(path, text, deny)
    return hits


def scan_commits(rev_range: str, deny, allow) -> list[str]:
    hits: list[str] = []
    out = git("log", "--format=%H%x1f%ae%x1f%ce%x1f%B%x1e", rev_range)
    for record in filter(None, (r.strip() for r in out.split("\x1e"))):
        sha, author, committer, message = (record.split("\x1f") + ["", "", "", ""])[:4]
        for label, email in (("author", author), ("committer", committer)):
            if allow and not any(p.search(email) for p in allow):
                hits.append(f"commit {sha[:8]}: {label} email is not an allowed public address")
        hits += scan_text(f"commit {sha[:8]} message", message, deny)
        files = git("diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha).split()

        def reader(path: str, sha: str = sha) -> str | None:
            try:
                return git("show", f"{sha}:{path}")
            except RuntimeError:
                return None  # deleted in this commit

        hits += [f"commit {sha[:8]} {h}" for h in scan_tree(files, reader, deny)]
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--staged", action="store_true")
    ap.add_argument("--pre-push", action="store_true")
    ap.add_argument("--range")
    args, _ = ap.parse_known_args()
    deny, allow = load_patterns()
    hits: list[str] = []

    if args.pre_push:
        for line in sys.stdin.read().splitlines():
            parts = line.split()
            if len(parts) != 4:
                continue
            _local_ref, local_sha, _remote_ref, remote_sha = parts
            if local_sha == ZERO:
                continue  # branch deletion
            rev_range = local_sha if remote_sha == ZERO else f"{remote_sha}..{local_sha}"
            if remote_sha == ZERO:
                # new branch: only commits not already on any remote branch
                rev_range = f"{local_sha} --not --remotes"
                out = git("log", "--format=%H", local_sha, "--not", "--remotes").split()
                hits += sum((scan_commits(f"{sha}^!", deny, allow) for sha in out), [])
                continue
            hits += scan_commits(rev_range, deny, allow)
    elif args.range:
        hits += scan_commits(args.range, deny, allow)
    elif args.staged:
        files = git("diff", "--cached", "--name-only", "--diff-filter=ACMR").split("\n")

        def staged_reader(path: str) -> str | None:
            try:
                return git("show", f":{path}")
            except RuntimeError:
                return None

        hits += scan_tree([f for f in files if f], staged_reader, deny)
    else:
        files = git("ls-files", "--cached", "--others", "--exclude-standard").split("\n")

        def disk_reader(path: str) -> str | None:
            try:
                return (ROOT / path).read_text(encoding="utf-8", errors="replace")
            except OSError:
                return None

        hits += scan_tree([f for f in files if f], disk_reader, deny)

    if hits:
        print("privacy check FAILED: personal data would be published", file=sys.stderr)
        for h in hits[:200]:
            print("  " + h, file=sys.stderr)
        return 1
    print("privacy check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
