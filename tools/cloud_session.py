"""Start a Claude Code cloud session for a task brief, without opening a window.

`claude --cloud "<prompt>"` refuses to run unless it has an interactive
terminal. This wrapper gives it one (a Windows pseudo console via pywinpty),
waits for the "Created cloud session" line, and prints the session id and URL.

  python tools/cloud_session.py docs/tasks/geometry.md --branch feat/geometry
  python tools/cloud_session.py docs/tasks/x.md --branch feat/x --dry-run

The brief must already be pushed to GitHub (the session reads it from the repo).
Sessions are appended to build_artifacts/cloud_sessions.jsonl (gitignored).
Exit codes: 0 created, 1 claude did not report a session, 2 bad arguments.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "build_artifacts" / "cloud_sessions.jsonl"
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[=>]")
SESSION_RE = re.compile(r"(session_[A-Za-z0-9]+)")
URL_RE = re.compile(r"https://claude\.ai/code/session_[A-Za-z0-9]+")
TIMEOUT = 120.0


def build_prompt(brief: str, branch: str) -> str:
    # single line, no double quotes: it is passed on a Windows command line
    return (f"Read {brief} in this repository and carry out that task exactly. "
            f"Work only on branch {branch}. Never push to main.")


def run(prompt: str) -> tuple[str | None, str | None, str]:
    try:
        from winpty import PtyProcess
    except ImportError:
        sys.exit(f"pywinpty missing: {sys.executable} -m pip install pywinpty")
    proc = PtyProcess.spawn(f'claude --cloud "{prompt}"', cwd=str(ROOT), dimensions=(40, 200))
    out = ""
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        try:
            chunk = proc.read(4096)
        except EOFError:
            break
        if chunk:
            out += chunk
            clean = ANSI.sub("", out)
            if URL_RE.search(clean) and ("Resume with" in clean or "teleport" in clean):
                break
        elif not proc.isalive():
            break
        else:
            time.sleep(0.2)
    if proc.isalive():
        proc.terminate(force=True)
    clean = ANSI.sub("", out)
    url = URL_RE.search(clean)
    sid = SESSION_RE.search(url.group(0)) if url else SESSION_RE.search(clean)
    return (sid.group(1) if sid else None), (url.group(0) if url else None), clean


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("brief", help="path of the task brief inside the repo, e.g. docs/tasks/geometry.md")
    ap.add_argument("--branch", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if not (ROOT / args.brief).is_file():
        print(f"brief not found: {args.brief}")
        return 2
    prompt = build_prompt(args.brief.replace("\\", "/"), args.branch)
    if args.dry_run:
        print(f'claude --cloud "{prompt}"')
        return 0
    sid, url, text = run(prompt)
    if not sid:
        print("no session reported; claude printed:")
        print("\n".join(line for line in text.splitlines() if line.strip())[-2000:])
        return 1
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with LEDGER.open("a", encoding="utf-8") as f:
        f.write(json.dumps({"time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                            "brief": args.brief, "branch": args.branch, "session": sid, "url": url}) + "\n")
    print(f"session {sid}")
    print(f"url {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
