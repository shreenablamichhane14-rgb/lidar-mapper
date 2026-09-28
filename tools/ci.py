"""Drive the GitHub Actions iOS build from the PC.

There is no Mac here, so every compile happens on the macos runner. This tool
finds the run for the current commit, waits for it, pulls the build log and
prints the compiler errors in a compact file:line form, and downloads the IPA
when the build succeeded.

  python tools/ci.py            # watch the run for HEAD, print errors or download the IPA
  python tools/ci.py --sha X    # a specific commit
  python tools/ci.py --run ID   # a specific run id
  python tools/ci.py --trigger  # workflow_dispatch on main, then watch
  python tools/ci.py --errors-only   # print errors and exit non-zero, never download

Exit codes: 0 build succeeded, 1 build failed (errors printed), 2 could not find or reach the run.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "build_artifacts"
DESKTOP_IPA = Path.home() / "Desktop" / "Mapper.ipa"
WORKFLOW = "ios-build"

ERROR_RE = re.compile(r"^(?P<file>/[^:]+\.swift):(?P<line>\d+):(?P<col>\d+): error: (?P<msg>.*)$")
NOTE_RE = re.compile(r"^(?P<file>/[^:]+\.swift):(?P<line>\d+):(?P<col>\d+): note: (?P<msg>.*)$")
OTHER_ERROR_RE = re.compile(r"error: (?P<msg>.*)$")


def gh(*args: str, check: bool = True) -> str:
    res = subprocess.run(["gh", *args], capture_output=True, text=True, cwd=ROOT)
    if check and res.returncode != 0:
        sys.exit(f"gh {' '.join(args)} failed: {res.stderr.strip()[-500:]}")
    return res.stdout


def head_sha() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=ROOT).stdout.strip()


def find_run(sha: str, tries: int = 12) -> dict | None:
    """The run for a commit can take ~10 s to appear after the push."""
    for _ in range(tries):
        out = gh("run", "list", "--workflow", WORKFLOW, "--commit", sha, "--json",
                 "databaseId,status,conclusion,headSha,createdAt", "--limit", "5")
        runs = json.loads(out or "[]")
        if runs:
            runs.sort(key=lambda r: r["createdAt"], reverse=True)
            return runs[0]
        time.sleep(5)
    return None


def wait_for(run_id: int, poll: float = 15) -> dict:
    started = time.time()
    last = ""
    while True:
        out = gh("run", "view", str(run_id), "--json", "status,conclusion,jobs")
        info = json.loads(out)
        step = ""
        for job in info.get("jobs", []):
            for s in job.get("steps", []):
                if s.get("status") == "in_progress":
                    step = s.get("name", "")
        line = f"{info['status']} {step}".strip()
        if line != last:
            print(f"[{int(time.time() - started):4d}s] {line}", flush=True)
            last = line
        if info["status"] == "completed":
            return info
        time.sleep(poll)


def download(run_id: int, name: str, dest: Path) -> Path | None:
    dest.mkdir(parents=True, exist_ok=True)
    res = subprocess.run(["gh", "run", "download", str(run_id), "-n", name, "-D", str(dest)],
                         capture_output=True, text=True, cwd=ROOT)
    if res.returncode != 0:
        print(f"could not download artifact {name}: {res.stderr.strip()[-300:]}")
        return None
    return dest


def summarize_errors(log: Path) -> list[str]:
    seen: set[str] = set()
    lines: list[str] = []
    text = log.read_text(encoding="utf-8", errors="replace").splitlines()
    for i, raw in enumerate(text):
        m = ERROR_RE.match(raw.strip())
        if m:
            rel = m["file"].split("/ios/", 1)[-1]
            key = f"{rel}:{m['line']}:{m['col']}: {m['msg']}"
            if key in seen:
                continue
            seen.add(key)
            lines.append(key)
            # the compiler prints the source line and a caret after the error; keep them for context
            for extra in text[i + 1:i + 3]:
                if extra.strip() and not ERROR_RE.match(extra.strip()) and not NOTE_RE.match(extra.strip()):
                    lines.append("    " + extra.rstrip())
            continue
        m = NOTE_RE.match(raw.strip())
        if m and lines and not lines[-1].startswith("    note"):
            rel = m["file"].split("/ios/", 1)[-1]
            lines.append(f"    note {rel}:{m['line']}: {m['msg']}")
    if not lines:
        for raw in text:
            m = OTHER_ERROR_RE.search(raw)
            if m and "error:" in raw and raw.strip() not in seen:
                seen.add(raw.strip())
                lines.append(raw.strip())
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sha")
    ap.add_argument("--run", type=int)
    ap.add_argument("--trigger", action="store_true")
    ap.add_argument("--errors-only", action="store_true")
    ap.add_argument("--no-wait", action="store_true")
    args = ap.parse_args()

    if args.trigger:
        gh("workflow", "run", WORKFLOW, "--ref", "main")
        print("triggered workflow_dispatch; waiting for the run to appear")
        time.sleep(8)

    run_id = args.run
    if run_id is None:
        sha = args.sha or head_sha()
        run = find_run(sha)
        if run is None:
            # a dispatch run has the same head sha but may not be listed by --commit
            out = gh("run", "list", "--workflow", WORKFLOW, "--json", "databaseId,status,conclusion,headSha,createdAt", "--limit", "5")
            runs = [r for r in json.loads(out or "[]") if r["headSha"] == sha]
            if not runs:
                print(f"no {WORKFLOW} run found for {sha[:8]} (did the push touch ios/ ?)")
                return 2
            run = sorted(runs, key=lambda r: r["createdAt"], reverse=True)[0]
        run_id = run["databaseId"]
        print(f"run {run_id} for {sha[:8]}: {run['status']} {run.get('conclusion') or ''}")

    if args.no_wait:
        return 0
    info = wait_for(run_id)
    conclusion = info.get("conclusion")
    dest = ARTIFACTS / str(run_id)
    log_dir = download(run_id, "build-log", dest)
    log = (log_dir / "build.log") if log_dir else None

    if conclusion == "success":
        print("BUILD SUCCEEDED")
        if args.errors_only:
            return 0
        ipa_dir = download(run_id, "Mapper-ipa", dest)
        if ipa_dir:
            ipa = ipa_dir / "Mapper.ipa"
            shutil.copy(ipa, DESKTOP_IPA)
            print(f"IPA: {ipa} ({ipa.stat().st_size // 1024} KB) -> {DESKTOP_IPA}")
        return 0

    print(f"BUILD {str(conclusion).upper()} (run {run_id})")
    if log and log.exists():
        errors = summarize_errors(log)
        print(f"--- {len([e for e in errors if not e.startswith(' ')])} error(s) from {log} ---")
        print("\n".join(errors) if errors else "(no 'error:' lines found; open the log)")
        if not errors:
            tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-40:]
            print("\n".join(tail))
    else:
        print("no build log artifact; the failure happened before xcodebuild (xcodegen? yaml?)")
        print(gh("run", "view", str(run_id), "--log-failed", check=False)[-3000:])
    return 1


if __name__ == "__main__":
    sys.exit(main())
