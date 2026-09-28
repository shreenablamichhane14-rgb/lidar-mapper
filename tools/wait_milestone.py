"""Wait, without using any AI tokens, until the cloud lead reaches a milestone or stalls.

Polls GitHub every few minutes with `git ls-remote` and `gh` (both free) and exits
exactly once, printing one line, when either:
  MILESTONE  the integration branch head changed docs/STATUS.md and its latest
             ios-build run on that head is green (a build is ready for the phone)
  STALLED    no branch in the repository has moved for --stall-minutes and no CI
             run is queued or in progress (the lead finished, hit a usage limit,
             or is stuck)
  FAILED     the integration head's CI run failed and nothing was pushed for
             --fail-minutes afterwards (the lead may have given up on a fix)

  python tools/wait_milestone.py                   # defaults: poll 5 min, stall 75 min
  python tools/wait_milestone.py --since <sha>     # ignore milestones at or before this integration commit
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "shreenablamichhane14-rgb/lidar-mapper"


def run(*cmd: str) -> str:
    res = subprocess.run(list(cmd), capture_output=True, text=True, cwd=ROOT)
    return res.stdout if res.returncode == 0 else ""


def heads() -> dict[str, str]:
    out = run("git", "ls-remote", "--heads", "origin")
    pairs = (line.split("\t") for line in out.splitlines() if "\t" in line)
    return {ref.replace("refs/heads/", ""): sha for sha, ref in pairs}


def latest_run(sha: str) -> dict | None:
    out = run("gh", "run", "list", "--repo", REPO, "--workflow", "ios-build", "--commit", sha,
              "--json", "databaseId,status,conclusion", "--limit", "1")
    try:
        runs = json.loads(out or "[]")
    except json.JSONDecodeError:
        return None
    return runs[0] if runs else None


def active_runs() -> int:
    total = 0
    for status in ("in_progress", "queued"):
        out = run("gh", "run", "list", "--repo", REPO, "--status", status, "--json", "databaseId", "--limit", "20")
        try:
            total += len(json.loads(out or "[]"))
        except json.JSONDecodeError:
            pass
    return total


def touched_status(sha: str) -> bool:
    out = run("gh", "api", f"repos/{REPO}/commits/{sha}", "--jq", "[.files[].filename] | join(\" \")")
    return "docs/STATUS.md" in out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--poll-minutes", type=float, default=5)
    ap.add_argument("--stall-minutes", type=float, default=75)
    ap.add_argument("--fail-minutes", type=float, default=45)
    ap.add_argument("--since", default="", help="integration sha already handled")
    args = ap.parse_args()

    last = heads()
    last_change = time.time()
    fail_seen_at: float | None = None
    handled = args.since
    while True:
        time.sleep(args.poll_minutes * 60)
        now_heads = heads()
        if not now_heads:
            continue  # network blip
        if now_heads != last:
            last, last_change, fail_seen_at = now_heads, time.time(), None
        head = now_heads.get("integration", "")
        if head and not head.startswith(handled or "~"):
            run_info = latest_run(head)
            if run_info and run_info.get("status") == "completed":
                if run_info.get("conclusion") == "success" and touched_status(head):
                    print(f"MILESTONE integration={head[:8]} run={run_info['databaseId']}")
                    return 0
                if run_info.get("conclusion") == "failure":
                    fail_seen_at = fail_seen_at or time.time()
                    if time.time() - fail_seen_at > args.fail_minutes * 60:
                        print(f"FAILED integration={head[:8]} run={run_info['databaseId']}")
                        return 0
        idle = time.time() - last_change
        if idle > args.stall_minutes * 60 and active_runs() == 0:
            branch_list = " ".join(f"{b}={s[:8]}" for b, s in sorted(now_heads.items()) if b not in ("main", "dev"))
            print(f"STALLED no pushes for {int(idle // 60)} min; {branch_list}")
            return 0


if __name__ == "__main__":
    sys.exit(main())
