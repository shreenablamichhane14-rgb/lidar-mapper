"""Read the iPhone Mapper app's troubleshooting log from the PC.

Three ways in:
  usb     pull Documents/Logs out of the app container (cable, house_arrest)
  wifi    follow the app's wireless debug server (Settings > Wireless debug on
          the phone; IP and token are shown in the ladybug Debug screen)
  syslog  live unified-log lines from the app (cable), no app setting needed

Examples:
  python tools/phone_log.py usb
  python tools/phone_log.py wifi 192.168.1.42 k7m2q9xa
  python tools/phone_log.py wifi 192.168.1.42 k7m2q9xa --status
  python tools/phone_log.py syslog
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BUNDLE_PREFIX = "com.shreehub.mapper"
PORT = 8765
OUT_DIR = Path(__file__).resolve().parent.parent / "logs" / "phone"


def pmd3(*args: str, capture: bool = True) -> subprocess.CompletedProcess:
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    return subprocess.run([sys.executable, "-m", "pymobiledevice3", *args],
                          capture_output=capture, text=True, env=env)


def find_bundle() -> str:
    """Sideloadly appends the team id, so look the real bundle id up."""
    res = pmd3("apps", "list")
    if res.returncode != 0:
        sys.exit(f"phone not reachable over USB: {res.stderr.strip()[-300:]}")
    try:
        ids = list(json.loads(res.stdout).keys())
    except json.JSONDecodeError:
        ids = [w.strip('",:{} ') for w in res.stdout.split() if BUNDLE_PREFIX in w]
    matches = [i for i in ids if i.startswith(BUNDLE_PREFIX)]
    if not matches:
        sys.exit("Mapper app not installed on the connected phone")
    return matches[0]


def cmd_usb(args: argparse.Namespace) -> None:
    bundle = find_bundle()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    res = pmd3("apps", "pull", bundle, "/Documents/Logs", str(OUT_DIR))
    if res.returncode != 0:
        sys.exit(f"pull failed: {res.stderr.strip()[-500:]}")
    files = sorted(OUT_DIR.rglob("mapper-*.log"))
    if not files:
        sys.exit("no log files yet (open the app once on the phone)")
    print(f"pulled {len(files)} file(s) into {OUT_DIR}")
    latest = files[-1]
    lines = latest.read_text(encoding="utf-8", errors="replace").splitlines()
    print(f"--- last {args.lines} lines of {latest.name} ---")
    print("\n".join(lines[-args.lines:]))


def get(ip: str, token: str, path: str, timeout: float = 5) -> bytes:
    sep = "&" if "?" in path else "?"
    url = f"http://{ip}:{PORT}{path}{sep}t={token}"
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


def cmd_wifi(args: argparse.Namespace) -> None:
    try:
        if args.status:
            print(get(args.ip, args.token, "/status").decode())
            return
        if args.file:
            print(get(args.ip, args.token, f"/log/{args.file}").decode())
            return
        print(get(args.ip, args.token, "/status").decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode(errors='replace')}")
    except OSError as e:
        sys.exit(f"cannot reach {args.ip}:{PORT} ({e}). Same Wi-Fi? App open with Wireless debug on?")

    print("--- following live log (Ctrl+C to stop) ---")
    last = 0
    misses = 0
    while True:
        try:
            data = json.loads(get(args.ip, args.token, f"/tail?after={last}"))
            for line in data["lines"]:
                print(line, flush=True)
            last = data["last"]
            misses = 0
        except (OSError, ValueError) as e:
            misses += 1
            if misses == 3:
                print(f"[phone not answering: {e}; app backgrounded or Wi-Fi changed, retrying]", flush=True)
        time.sleep(1)


def cmd_syslog(_: argparse.Namespace) -> None:
    print("--- app lines from the phone's system log (Ctrl+C to stop) ---")
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    proc = subprocess.Popen([sys.executable, "-m", "pymobiledevice3", "syslog", "live"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace", env=env)
    assert proc.stdout
    try:
        for line in proc.stdout:
            if "Mapper" in line or "com.shreehub.mapper" in line:
                print(line.rstrip(), flush=True)
    except KeyboardInterrupt:
        proc.terminate()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("usb", help="pull saved logs over the cable")
    u.add_argument("--lines", type=int, default=80)
    u.set_defaults(func=cmd_usb)
    w = sub.add_parser("wifi", help="follow the live log over Wi-Fi")
    w.add_argument("ip")
    w.add_argument("token")
    w.add_argument("--status", action="store_true", help="print the status snapshot and exit")
    w.add_argument("--file", help="print one saved log file, e.g. mapper-2026-09-28.log")
    w.set_defaults(func=cmd_wifi)
    s = sub.add_parser("syslog", help="live system log lines from the app over the cable")
    s.set_defaults(func=cmd_syslog)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
