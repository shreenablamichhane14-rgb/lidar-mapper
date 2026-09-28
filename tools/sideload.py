"""Install an IPA on the USB-connected iPhone with Sideloadly, driven from the PC.

Sideloadly has no command line, so this script drives its window with pyautogui
up to the one step a human has to do: typing the Apple ID password and the 2FA
code. The script never sees, stores or types the password.

Steps:
  1. iPhone over USB?  (python -m pymobiledevice3 usbmux list)      else exit 2
  2. IPA exists?                                                      else exit 2
  3. Sideloadly window (launched with cwd = project folder if needed)
  4. IPA icon -> Windows "Open" dialog -> type the path -> Enter
  5. Apple ID field -> select all -> type the email
  6. Start -> Sideloadly asks for the password + 2FA: YOU TYPE THEM
  7. Poll sideloadlydaemon.log and the phone's app list every 10 s (6 min max)

  python tools/sideload.py                      # Desktop/Mapper.ipa, Apple ID from SIDELOAD_APPLE_ID
  python tools/sideload.py --ipa X --apple-id Y
  python tools/sideload.py --dry-run            # plan + window rectangles, no clicks

A screenshot is saved to build_artifacts/sideload-<step>.png before every click.
pyautogui's corner fail-safe is off (the mouse may be parked in a corner);
Ctrl+C in the terminal aborts. Exit codes: 0 installed, 1 install failed or
timed out, 2 precondition failed (libs, phone, IPA, window).
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

try:
    import pyautogui
    import pygetwindow as gw
except ImportError as exc:  # reported by main() with the pip command
    pyautogui = None  # type: ignore[assignment]
    gw = None  # type: ignore[assignment]
    IMPORT_ERROR: ImportError | None = exc
else:
    IMPORT_ERROR = None

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "build_artifacts"
SIDELOADLY_EXE = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))) / "Sideloadly" / "sideloadly.exe"
DEFAULT_IPA = Path.home() / "Desktop" / "Mapper.ipa"


def _apple_id_from_env() -> str:
    """SIDELOAD_APPLE_ID from the environment, else from ~/.env. Kept out of the repo on purpose."""
    value = os.environ.get("SIDELOAD_APPLE_ID", "").strip()
    if value:
        return value
    env_file = Path.home() / ".env"
    try:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            key, sep, val = line.partition("=")
            if sep and key.strip() == "SIDELOAD_APPLE_ID":
                return val.strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


DEFAULT_APPLE_ID = _apple_id_from_env()
BUNDLE_PREFIX = "com.shreehub.mapper"  # Sideloadly appends the free team id

WINDOW_PREFIX = "Sideloadly!"
EXPECTED_TITLE = "Sideloadly! v0.60"
EXPECTED_SIZE = (616, 241)
# Offsets from the window's top-left corner, measured on v0.60 at 100 % DPI (runbook 2026-09-26).
CLICKS: dict[str, tuple[int, int]] = {
    "ipa_icon": (60, 95),
    "apple_id": (350, 128),
    "start": (320, 185),
}
FILE_DIALOG_TITLES = ("open", "öffnen")
AUTH_TITLES = ("apple id", "authentication", "password", "2fa", "two-factor")

LOG_NAME = "sideloadlydaemon.log"
# The daemon writes its log into the cwd it was started from. The GUI is launched from the
# project folder, but an already running daemon keeps its old cwd (the parent folder so far),
# so every plausible location is tailed.
LOG_CANDIDATES = (
    ROOT / LOG_NAME,
    ROOT.parent / LOG_NAME,
    SIDELOADLY_EXE.parent / LOG_NAME,
    Path.home() / LOG_NAME,
)

WINDOW_WAIT = 30    # s for the Sideloadly window after launching it
DIALOG_WAIT = 15    # s for the file dialog to open / close
AUTH_WAIT = 45      # s for the Apple ID password dialog after Start
POLL_EVERY = 10     # s between install checks
POLL_MAX = 6 * 60   # s
GRACE = 30          # s to keep checking the phone after an error/done line before giving up

SW_SHOWNOACTIVATE = 4

# Daemon log lines. Timestamp prefix, per-minute noise, and what a real error looks like
# ("Error: Could not get app list from device ...", seen 2026-09-26).
STAMP_RE = re.compile(r"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ")
NOISE = ("Done tick", "Will tick", "Drain failed?..", "Got timeout, refreshing", "Timeout stop:",
         "Checking installed app", "Nothing to do for device", "Apps [{Udid:")
ERROR_RE = re.compile(r"^(?:Error:|ERROR\b)|\bFailed\b|\bfailed\b")
DONE_RE = re.compile(r"\bDone\b")


class SideloadError(Exception):
    """A step that cannot continue; the message is shown to the user."""


def say(msg: str) -> None:
    print(msg, flush=True)


def elapsed(since: float) -> str:
    return f"{int(time.time() - since):3d}s"


# --- phone -------------------------------------------------------------------

def pmd3(*args: str, timeout: float = 90) -> subprocess.CompletedProcess[str] | None:
    """Run a pymobiledevice3 subcommand; None on timeout."""
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    try:
        return subprocess.run([sys.executable, "-m", "pymobiledevice3", *args], capture_output=True,
                              text=True, encoding="utf-8", errors="replace", env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def usb_phone() -> dict[str, Any] | None:
    """First iPhone usbmuxd sees over the cable, or None."""
    res = pmd3("usbmux", "list", "--usb", timeout=30)
    if res is None:
        say("usbmux list timed out (is 'Apple Mobile Device Service' running?)")
        return None
    if res.returncode != 0:
        say(f"usbmux list failed: {res.stderr.strip()[-300:]}")
        return None
    try:
        devices = json.loads(res.stdout or "[]")
    except json.JSONDecodeError:
        say(f"unexpected usbmux output: {res.stdout[:200]}")
        return None
    return devices[0] if devices else None


def developer_mode() -> bool | None:
    res = pmd3("amfi", "developer-mode-status", timeout=30)
    if res is None or res.returncode != 0:
        return None
    out = res.stdout.strip().lower()
    return True if out == "true" else False if out == "false" else None


def installed_apps() -> dict[str, tuple[str, str, str]] | None:
    """Our bundles on the phone -> (path, sequence, build). All three change on a reinstall.

    None when the phone did not answer (unplugged, or busy mid-install)."""
    res = pmd3("apps", "list")
    if res is None or res.returncode != 0:
        return None
    try:
        apps = json.loads(res.stdout)
    except json.JSONDecodeError:
        return None
    return {b: (str(i.get("Path", "")), str(i.get("SequenceNumber", "")), str(i.get("CFBundleVersion", "")))
            for b, i in apps.items() if b.startswith(BUNDLE_PREFIX) and isinstance(i, dict)}


def fresh_install(before: dict[str, tuple[str, str, str]], after: dict[str, tuple[str, str, str]]) -> str | None:
    for bundle, sig in after.items():
        if before.get(bundle) != sig:
            return bundle
    return None


# --- daemon log --------------------------------------------------------------

@dataclass
class LogTail:
    path: Path
    offset: int = 0

    @classmethod
    def at_end(cls, path: Path) -> LogTail:
        return cls(path, path.stat().st_size if path.exists() else 0)

    def read_new(self) -> list[str]:
        if not self.path.exists():
            return []
        size = self.path.stat().st_size
        if size < self.offset:  # truncated or rotated
            self.offset = 0
        if size == self.offset:
            return []
        with self.path.open("rb") as f:
            f.seek(self.offset)
            chunk = f.read()
            self.offset = f.tell()
        return chunk.decode("utf-8", errors="replace").splitlines()


def classify(raw: str) -> tuple[str, str] | None:
    """(kind, message) for a daemon log line, None for per-minute noise."""
    msg = STAMP_RE.sub("", raw.rstrip())
    if not msg or any(n in msg for n in NOISE):
        return None
    if msg.startswith("Installed apps on"):
        return ("installed", "daemon lists the app on the phone") if BUNDLE_PREFIX in msg else None
    if ERROR_RE.search(msg) and "LastError:" not in msg:
        return "error", msg[:200]
    if DONE_RE.search(msg):
        return "done", msg[:200]
    if msg.startswith("Got ins "):
        return "progress", "install record updated"
    return "progress", msg[:160]


# --- windows -----------------------------------------------------------------

def hwnd(win: Any) -> int:
    return int(win._hWnd)


def visible_hwnds() -> dict[int, Any]:
    return {hwnd(w): w for w in gw.getAllWindows() if w.title.strip()}


def find_sideloadly() -> Any | None:
    # substring match is case-insensitive; a terminal titled "python tools/sideload.py" must not count
    for w in gw.getWindowsWithTitle(WINDOW_PREFIX):
        if w.title.startswith(WINDOW_PREFIX):
            return w
    return None


def launch_sideloadly() -> Any:
    if not SIDELOADLY_EXE.exists():
        raise SideloadError(f"Sideloadly not found at {SIDELOADLY_EXE}")
    say(f"launching {SIDELOADLY_EXE.name} (cwd {ROOT})")
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    subprocess.Popen([str(SIDELOADLY_EXE)], cwd=ROOT, creationflags=flags, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + WINDOW_WAIT
    while time.time() < deadline:
        win = find_sideloadly()
        if win is not None:
            time.sleep(2)  # let it finish drawing / anisette init
            return win
        time.sleep(0.5)
    raise SideloadError(f"no '{WINDOW_PREFIX}' window within {WINDOW_WAIT}s. If it hangs at "
                        "'Initializing Anisette', VC++ 2013 x64 is missing (see the runbook).")


def focus(win: Any, label: str) -> None:
    """Restore + bring to front. Minimized windows ignore SetForegroundWindow; Alt lets us steal focus."""
    user32 = ctypes.windll.user32
    active_title = ""
    for attempt in range(4):
        if win.isMinimized:
            win.restore()
            time.sleep(0.4)
        if attempt:
            pyautogui.press("alt")
        user32.SetForegroundWindow(hwnd(win))
        time.sleep(0.4)
        active = gw.getActiveWindow()
        if active is not None and hwnd(active) == hwnd(win):
            return
        active_title = active.title if active is not None else "<none>"
    raise SideloadError(f"could not bring the {label} window to the front (active window: '{active_title}')")


def click_points(win: Any) -> dict[str, tuple[int, int]]:
    return {name: (win.left + dx, win.top + dy) for name, (dx, dy) in CLICKS.items()}


def check_geometry(win: Any) -> None:
    w, h = win.width, win.height
    ew, eh = EXPECTED_SIZE
    if abs(w - ew) > ew * 0.15 or abs(h - eh) > eh * 0.15:
        raise SideloadError(f"Sideloadly window is {w}x{h}; the click offsets were measured on {ew}x{eh}. "
                            f"Re-measure CLICKS in {Path(__file__).name} before running.")
    if (w, h) != (ew, eh):
        say(f"note: window is {w}x{h} (expected {ew}x{eh}); using the measured offsets anyway")
    if win.title != EXPECTED_TITLE:
        say(f"note: window title is '{win.title}' (offsets measured on '{EXPECTED_TITLE}')")
    sw, sh = pyautogui.size()
    for name, (x, y) in click_points(win).items():
        if not (0 <= x < sw and 0 <= y < sh):
            raise SideloadError(f"click target '{name}' at ({x},{y}) is off screen ({sw}x{sh}); move the window")


def wait_new_window(before: set[int], match: Callable[[str], bool], timeout: float) -> Any | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        fresh = [w for h, w in visible_hwnds().items() if h not in before]
        exact = [w for w in fresh if match(w.title)]
        if exact:
            return exact[0]
        time.sleep(0.3)
    return None


def wait_gone(h: int, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if h not in visible_hwnds():
            return True
        time.sleep(0.3)
    return False


def is_file_dialog(title: str) -> bool:
    t = title.strip().lower()
    # exactly "Open"/"Öffnen", or "Open <something>"; not "OpenAI - Chrome"
    return t in FILE_DIALOG_TITLES or any(t.startswith(p + " ") for p in FILE_DIALOG_TITLES)


def is_auth_dialog(title: str) -> bool:
    t = title.lower()
    return any(k in t for k in AUTH_TITLES) or t.startswith(WINDOW_PREFIX.lower())


def minimize_terminal() -> Any | None:
    """The window this script runs in sits over Sideloadly and blocks foreground changes."""
    active = gw.getActiveWindow()
    if active is None or not active.title.strip():
        return None
    if active.title.startswith(WINDOW_PREFIX) or active.title == "Program Manager":
        return None
    active.minimize()
    time.sleep(0.4)
    return active


def restore_quietly(win: Any) -> None:
    """Un-minimize without stealing focus from Sideloadly's password dialog."""
    ctypes.windll.user32.ShowWindow(hwnd(win), SW_SHOWNOACTIVATE)


# --- actions -----------------------------------------------------------------

def shot(step: str) -> Path | None:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    path = ARTIFACTS / f"sideload-{step}.png"
    try:
        pyautogui.screenshot(str(path))
    except Exception as exc:  # screen locked, Pillow missing, ...
        say(f"screenshot {path.name} failed: {exc}")
        return None
    return path


def click(name: str, point: tuple[int, int], step: str) -> None:
    shot(step)
    say(f"click {name} at {point}")
    pyautogui.click(*point)


def banner(lines: list[str]) -> None:
    width = max(len(line) for line in lines) + 4
    rule = "=" * width
    say("\n" + rule)
    for line in lines:
        say(f"  {line}")
    say(rule + "\n")


def wait_for_install(tails: list[LogTail], before: dict[str, tuple[str, str, str]]) -> tuple[bool, str]:
    started = time.time()
    deadline = started + POLL_MAX
    grace_until: float | None = None
    last_error = ""
    known = {t.path for t in tails}
    while True:
        for path in LOG_CANDIDATES:  # a daemon started by this run creates a new file
            if path not in known and path.exists():
                say(f"[{elapsed(started)}] new log appeared: {path}")
                tails.append(LogTail(path, 0))
                known.add(path)
        for tail in tails:
            for line in tail.read_new():
                kind = classify(line)
                if kind is None:
                    continue
                what, msg = kind
                say(f"[{elapsed(started)}] log {what}: {msg}")
                if what == "error":
                    last_error = msg
                    grace_until = grace_until or time.time() + GRACE
                elif what == "done":
                    grace_until = grace_until or time.time() + GRACE
        apps = installed_apps()
        if apps is None:
            say(f"[{elapsed(started)}] phone did not answer 'apps list' (busy installing, or unplugged)")
        else:
            bundle = fresh_install(before, apps)
            if bundle:
                return True, bundle
            say(f"[{elapsed(started)}] not on the phone yet")
        now = time.time()
        if grace_until is not None and now >= grace_until:
            if last_error:
                return False, f"Sideloadly logged an error: {last_error}"
            return False, "the daemon logged Done but the app did not appear on the phone"
        if now >= deadline:
            return False, f"no install after {POLL_MAX // 60} min (password/2FA never typed, or Sideloadly failed)"
        time.sleep(POLL_EVERY)


def install(win: Any, ipa: Path, apple_id: str) -> tuple[bool, str]:
    points = click_points(win)
    before = installed_apps()
    if before is None:
        raise SideloadError("phone did not answer 'apps list'; unlock it and check the cable")
    say(f"installed before: {', '.join(before) if before else 'none'}")
    tails = [LogTail.at_end(p) for p in LOG_CANDIDATES if p.exists()]
    say("tailing: " + (", ".join(str(t.path) for t in tails) if tails else "no daemon log yet"))

    terminal = minimize_terminal()
    auth: Any | None = None
    try:
        focus(win, "Sideloadly")
        main_hwnd = hwnd(win)
        leftovers = [w.title for h, w in visible_hwnds().items()
                     if h != main_hwnd and (is_file_dialog(w.title) or is_auth_dialog(w.title))]
        if leftovers:
            say(f"warning: dialogs already open, close them if they belong to Sideloadly: {leftovers}")

        # 4. IPA
        before_windows = set(visible_hwnds())
        click("IPA icon", points["ipa_icon"], "01-ipa-icon")
        dialog = wait_new_window(before_windows, is_file_dialog, DIALOG_WAIT)
        if dialog is None:
            shot("error-no-file-dialog")
            raise SideloadError("the file dialog did not open (see build_artifacts/sideload-error-no-file-dialog.png)")
        say(f"file dialog '{dialog.title}' at ({dialog.left},{dialog.top}) {dialog.width}x{dialog.height}")
        focus(dialog, "file dialog")
        shot("02-file-dialog")
        pyautogui.hotkey("ctrl", "a")
        pyautogui.write(str(ipa), interval=0.01)
        pyautogui.press("enter")
        if not wait_gone(hwnd(dialog), DIALOG_WAIT):
            shot("error-file-dialog-open")
            raise SideloadError("the file dialog did not accept the path (see build_artifacts/sideload-error-file-dialog-open.png)")
        time.sleep(1.5)  # Sideloadly reads the IPA

        # 5. Apple ID
        focus(win, "Sideloadly")
        click("Apple ID field", points["apple_id"], "03-apple-id")
        pyautogui.hotkey("ctrl", "a")
        pyautogui.write(apple_id, interval=0.01)

        # 6. Start
        before_windows = set(visible_hwnds())  # includes the main window, so it can never count as the dialog
        click("Start", points["start"], "04-start")
        auth = wait_new_window(before_windows, is_auth_dialog, AUTH_WAIT)
        shot("05-after-start")
        if auth is not None:
            say(f"password dialog: '{auth.title}'")
        else:
            say(f"no separate password window within {AUTH_WAIT}s; it may be inside the main window")
    finally:
        if terminal is not None:
            restore_quietly(terminal)
    if auth is not None:
        try:
            focus(auth, "password dialog")
        except SideloadError as exc:
            say(str(exc))

    banner([
        "ACTION NEEDED: type the Apple ID password in the Sideloadly window,",
        f"then the 2FA code from the phone.   Apple ID: {apple_id}",
        "This script never sees the password. It now watches the phone and",
        f"the daemon log every {POLL_EVERY} s for up to {POLL_MAX // 60} min.",
    ])
    try:
        import winsound
        winsound.MessageBeep(winsound.MB_ICONASTERISK)
    except Exception:
        pass
    ok, detail = wait_for_install(tails, before)
    shot("06-result")
    return ok, detail


# --- entry -------------------------------------------------------------------

def preflight(ipa: Path, dry_run: bool) -> None:
    phone = usb_phone()
    if phone is None:
        msg = ("no iPhone over USB. Plug the cable in, unlock the phone, tap Trust; then check "
               "'python -m pymobiledevice3 usbmux list' and 'sc query \"Apple Mobile Device Service\"'.")
        if not dry_run:
            raise SideloadError(msg)
        say(f"phone: {msg}")
    else:
        say(f"phone: {phone.get('DeviceName')} ({phone.get('ProductType')}, iOS {phone.get('ProductVersion')}, "
            f"udid {phone.get('Identifier')})")
        dev = developer_mode()
        if dev is False:
            say("note: Developer Mode is OFF; the app installs but will not launch until it is on "
                "(Settings > Privacy & Security > Developer Mode)")
        elif dev is None:
            say("note: could not read Developer Mode status")
    if not ipa.is_file():
        msg = f"IPA not found: {ipa} (run 'python tools/ci.py' to download the latest build)"
        if not dry_run:
            raise SideloadError(msg)
        say(f"ipa: {msg}")
    else:
        say(f"ipa: {ipa} ({ipa.stat().st_size // 1024} KB)")


def dry_run_report(win: Any, ipa: Path, apple_id: str) -> None:
    active = gw.getActiveWindow()
    say("\n--- dry run: detected windows ---")
    say(f"Sideloadly: '{win.title}' at ({win.left},{win.top}) {win.width}x{win.height} "
        f"minimized={win.isMinimized} active={win.isActive}")
    if active is not None:
        say(f"active (would be minimized): '{active.title}' at ({active.left},{active.top}) {active.width}x{active.height}")
    others = [w for h, w in visible_hwnds().items() if h != hwnd(win) and (is_file_dialog(w.title) or is_auth_dialog(w.title))]
    for w in others:
        say(f"dialog-like window already open: '{w.title}' at ({w.left},{w.top}) {w.width}x{w.height}")
    say("\n--- dry run: planned actions (nothing clicked) ---")
    points = click_points(win)
    say(f"1. minimize the active window, restore+focus Sideloadly (hwnd {hwnd(win)})")
    say(f"2. screenshot, click IPA icon at {points['ipa_icon']}, wait for a new 'Open'/'Öffnen' window")
    say(f"3. screenshot, ctrl+a, type '{ipa}', enter, wait for the dialog to close")
    say(f"4. screenshot, click Apple ID field at {points['apple_id']}, ctrl+a, type '{apple_id}'")
    say(f"5. screenshot, click Start at {points['start']}, wait up to {AUTH_WAIT}s for the password dialog")
    say("6. restore the terminal (no focus), beep, print the ACTION NEEDED banner")
    say(f"7. poll every {POLL_EVERY}s for {POLL_MAX // 60} min: daemon log lines + 'apps list' for a new {BUNDLE_PREFIX}*")
    say("\n--- dry run: daemon log candidates ---")
    for p in LOG_CANDIDATES:
        say(f"{'exists' if p.exists() else 'absent'}  {p}" + (f"  ({p.stat().st_size // 1024} KB)" if p.exists() else ""))
    apps = installed_apps()
    say("\n--- dry run: app snapshot ---")
    if apps is None:
        say("phone did not answer 'apps list'")
    elif not apps:
        say(f"no {BUNDLE_PREFIX}* on the phone (first install)")
    else:
        for b, (path, seq, build) in apps.items():
            say(f"{b}  build {build}  seq {seq}  {path}")
    p = shot("dry-run")
    say(f"\nscreenshot test: {p if p else 'failed'}")


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # window titles are not cp1252-safe
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ipa", type=Path, default=DEFAULT_IPA, help=f"IPA to install (default {DEFAULT_IPA})")
    ap.add_argument("--apple-id", default=DEFAULT_APPLE_ID, help="Apple ID email (default: SIDELOAD_APPLE_ID in the environment or ~/.env)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan and window rectangles, click nothing")
    args = ap.parse_args()

    if sys.platform != "win32":
        say("this script drives Sideloadly on Windows only")
        return 2
    if IMPORT_ERROR is not None:
        say(f"missing GUI automation library: {IMPORT_ERROR}")
        say(f"install with:  {sys.executable} -m pip install pyautogui pygetwindow pillow")
        return 2
    if not args.apple_id:
        say("no Apple ID: pass --apple-id or add SIDELOAD_APPLE_ID=<email> to ~/.env")
        return 2
    pyautogui.FAILSAFE = False  # the mouse may be parked in a corner
    pyautogui.PAUSE = 0.3

    ipa = args.ipa.expanduser().resolve()
    try:
        preflight(ipa, args.dry_run)
        win = find_sideloadly()
        if win is None:
            win = launch_sideloadly()
        else:
            say(f"Sideloadly already running: '{win.title}'")
        if args.dry_run:
            dry_run_report(win, ipa, args.apple_id)
            check_geometry(win)  # after the report, so a resized window still gets its rectangle printed
            say("geometry OK")
            return 0
        check_geometry(win)
        ok, detail = install(win, ipa, args.apple_id)
    except SideloadError as exc:
        say(f"FAILED: {exc}")
        return 2
    except KeyboardInterrupt:
        say("aborted")
        return 130

    if ok:
        say(f"INSTALLED: {detail} is on the phone (screenshots in {ARTIFACTS})")
        return 0
    say(f"NOT INSTALLED: {detail}")
    say(f"check Sideloadly's log pane and {ARTIFACTS}/sideload-*.png")
    return 1


if __name__ == "__main__":
    sys.exit(main())
