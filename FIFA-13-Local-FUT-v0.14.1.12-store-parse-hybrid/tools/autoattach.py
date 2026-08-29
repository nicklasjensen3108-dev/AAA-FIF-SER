#!/usr/bin/env python3
"""Wait for FIFA 13's Blaze login, pair the matching CardsDLL, then launch Frida.

This replaces the old nested PowerShell autoattach helper. Keeping the entire
post-launch compatibility step in Python avoids Windows PowerShell 5.1 process/
stack quirks seen on other PCs while retaining the same safety rule: never let
FUT load with a CardsDLL from a different runtime build.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

try:
    import frida
except Exception as exc:  # pragma: no cover - user machine diagnostic
    raise SystemExit(f"Frida is not importable by {sys.executable}: {exc}")

CARDS = {
    "1298564": (
        "CL1298564",
        "35BDAC6BB2F37F4E3F674C5BB979BCB607FEB11CD09105631796D566590FFC06",
    ),
    "1217703": (
        "CL1217703",
        "7D8A7EEAAAFEDF41EA407D497042C79E168D391D6AF5A2F692F870372284E089",
    ),
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()


def find_fifa_pid() -> int | None:
    try:
        for proc in frida.get_local_device().enumerate_processes():
            if proc.name.lower() == "fifa13.exe":
                return int(proc.pid)
    except Exception:
        return None
    return None


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, value: dict) -> None:
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2), encoding="utf-8")
    os.replace(temp, path)


def bridge_runtime_build(bridge_log: Path) -> str | None:
    if not bridge_log.is_file():
        return None
    text = bridge_log.read_text(encoding="utf-8", errors="replace")
    marker = "FIFA 13 redirect request:"
    found: str | None = None
    for line in text.splitlines():
        if marker not in line or "version=" not in line:
            continue
        value = line.split("version=", 1)[1].split(",", 1)[0].strip()
        if value.isdigit():
            found = value
    return found


def safe_candidate_files(root: Path, cards_path: Path, runtime: str) -> list[Path]:
    candidates: list[Path] = []
    seen: set[str] = set()

    def add(path: Path) -> None:
        try:
            key = str(path.resolve()).lower()
        except Exception:
            key = str(path).lower()
        if key in seen or path == cards_path or not path.is_file():
            return
        seen.add(key)
        candidates.append(path)

    required = root / "required"
    add(required / f"CardsDLLzf.cl{runtime}.dll")
    add(required / "CardsDLLzf.dll")

    backup_dir = root / "backups" / "game-files"
    if backup_dir.is_dir():
        for path in sorted(backup_dir.glob("*.dll"), key=lambda p: p.stat().st_mtime, reverse=True):
            add(path)

    # Old releases are commonly unpacked beside the new one. Search only for
    # CardsDLL-named DLLs and cap the walk so Downloads never becomes a giant
    # recursive crawl. os.walk(..., followlinks=False) avoids symlink loops.
    roots: list[Path] = []
    for p in [root.parent, root.parent.parent, Path.home() / "Downloads", Path.home() / "Desktop"]:
        try:
            if p.is_dir() and p not in roots:
                roots.append(p)
        except Exception:
            pass

    scanned = 0
    for search_root in roots:
        for current, dirs, files in os.walk(search_root, topdown=True, followlinks=False):
            # Do not recurse into system/development caches that cannot contain
            # a useful retail CardsDLL and make first-run scans unnecessarily slow.
            dirs[:] = [d for d in dirs if d.lower() not in {
                ".git", "node_modules", ".venv", "__pycache__", "windowsapps",
            }]
            for name in files:
                if not name.lower().startswith("cardsdllzf") or not name.lower().endswith(".dll"):
                    continue
                add(Path(current) / name)
                scanned += 1
                if scanned >= 300:
                    return candidates
    return candidates


def pair_cardsdll(root: Path, settings_path: Path, runtime: str) -> tuple[dict, Path]:
    if runtime not in CARDS:
        raise RuntimeError(
            f"Unsupported FIFA 13 runtime build {runtime}. No fifa13.exe hash allow-list is used, "
            "but no CardsDLL profile has been measured for this runtime."
        )
    label, wanted = CARDS[runtime]
    settings = read_json(settings_path)
    game_dir = str(settings.get("gameDirectory") or "").strip()
    if not game_dir:
        raise RuntimeError("local.settings.json does not contain the FIFA 13 Game directory.")

    cards_path = Path(game_dir) / "dlc" / "dlc_CardsDLL" / "dlc" / "CardsDLLzf.dll"
    if not cards_path.is_file():
        raise RuntimeError(f"CardsDLL not found: {cards_path}")

    current = sha256(cards_path)
    print(f"FIFA runtime build: {runtime}", flush=True)
    if current != wanted:
        print(f"CardsDLL/runtime mismatch detected. FIFA {runtime} requires {label}.", flush=True)
        matched: Path | None = None
        for candidate in safe_candidate_files(root, cards_path, runtime):
            try:
                if sha256(candidate) == wanted:
                    matched = candidate
                    break
            except Exception:
                continue
        if matched is None:
            raise RuntimeError(
                f"FIFA reports runtime build {runtime}, but the installed CardsDLL is for another build.\n"
                f"Required CardsDLL: {label}\nRequired SHA-256: {wanted}\n"
                f"Installed SHA-256: {current}\n\n"
                "The launcher did NOT let FUT load, so the game has not been crashed by the mismatch.\n"
                "It searched required/, this release's backups, nearby/older releases, Downloads and Desktop\n"
                "for a previously backed-up matching CardsDLL but did not find one.\n\n"
                f"Run IMPORT_MATCHED_CARDSDLL.cmd and select a legally obtained {label} CardsDLLzf.dll,\n"
                "or repair/restore your own FIFA 13 installation, then restart RUN_LOCAL_FUT13.cmd."
            )

        backup_dir = root / "backups" / "game-files"
        backup_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup = backup_dir / f"CardsDLLzf.pre-runtime-swap.{current[:12]}.{stamp}.dll"
        shutil.copy2(cards_path, backup)
        shutil.copy2(matched, cards_path)
        verify = sha256(cards_path)
        if verify != wanted:
            raise RuntimeError("Runtime-matched CardsDLL swap failed SHA-256 verification.")
        print(f"Runtime-matched CardsDLL installed from: {matched}", flush=True)
        current = verify

    print(f"CardsDLL pairing confirmed: FIFA {runtime} + {label}", flush=True)
    settings["gameVersion"] = f"runtime-{runtime}"
    settings["gameRuntimeVersion"] = runtime
    settings["cardsDllSha256"] = current
    write_json(settings_path, settings)
    return settings, cards_path


def record_tracer(runtime_path: Path, pid: int) -> None:
    if not runtime_path.is_file():
        return
    try:
        runtime = read_json(runtime_path)
        processes = list(runtime.get("processes") or [])
        processes.append({"name": "tracer", "pid": pid, "startedUtc": None})
        runtime["processes"] = processes
        write_json(runtime_path, runtime)
    except Exception as exc:
        print(f"Warning: tracer PID could not be added to runtime manifest: {exc}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--log-directory", required=True)
    ap.add_argument("--runtime-path", required=True)
    ap.add_argument("--session-id", required=True)
    ap.add_argument("--seconds", type=int, default=3600)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--settle", type=int, default=6)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    logs = Path(args.log_directory).resolve()
    runtime_path = Path(args.runtime_path).resolve()
    settings_path = root / "local.settings.json"
    tracer = root / "tools" / "trace_fifa13_futgate.py"
    bridge_log = logs / f"bridge-{args.session_id}.out.log"
    if not settings_path.is_file():
        raise RuntimeError(f"Missing settings: {settings_path}")
    if not tracer.is_file():
        raise RuntimeError(f"Tracer script not found: {tracer}")

    settings = read_json(settings_path)
    frida_packages = str(settings.get("fridaSitePackages") or "").strip()
    if frida_packages:
        path = Path(frida_packages)
        if not path.is_absolute():
            path = root / path
        if path.is_dir():
            current = os.environ.get("PYTHONPATH", "")
            os.environ["PYTHONPATH"] = str(path) + (os.pathsep + current if current else "")

    deadline = time.monotonic() + max(60, args.timeout)
    print("Waiting for fifa13.exe...", flush=True)
    pid: int | None = None
    while time.monotonic() < deadline:
        pid = find_fifa_pid()
        if pid:
            break
        time.sleep(1)
    if not pid:
        raise RuntimeError("fifa13.exe is not starting")
    print(f"fifa13.exe PID {pid}", flush=True)

    # Give slower PCs a fresh full window after the game itself appears. The old
    # helper spent the same deadline waiting for both process birth and Blaze,
    # which could leave only seconds for loginPersona on a slow EA App launch.
    deadline = time.monotonic() + max(120, args.timeout)
    print("Waiting for the Blaze session (loginPersona)...", flush=True)
    runtime: str | None = None
    while time.monotonic() < deadline:
        if not find_fifa_pid():
            raise RuntimeError("fifa13.exe closed before the Blaze session was established")
        if bridge_log.is_file():
            text = bridge_log.read_text(encoding="utf-8", errors="replace")
            if "loginPersona" in text:
                runtime = bridge_runtime_build(bridge_log)
                if runtime:
                    break
        time.sleep(1)
    if not runtime:
        raise RuntimeError("no loginPersona/runtime build -- was the local bridge started for this launch?")
    print("Session established.", flush=True)

    pair_cardsdll(root, settings_path, runtime)
    time.sleep(max(0, args.settle))

    logs.mkdir(parents=True, exist_ok=True)
    tracer_out = logs / f"tracer-{args.session_id}.out.log"
    tracer_err = logs / f"tracer-{args.session_id}.err.log"
    native = root / "artifacts" / f"fifa13-native-{args.session_id}.jsonl"
    native.parent.mkdir(parents=True, exist_ok=True)

    print("Attaching the tracer...", flush=True)
    creationflags = 0
    if os.name == "nt":
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    env = os.environ.copy()
    with tracer_out.open("wb") as out, tracer_err.open("wb") as err:
        proc = subprocess.Popen(
            [sys.executable, str(tracer), "--seconds", str(args.seconds), "--cards-build", runtime, "--log", str(native)],
            cwd=str(root), stdout=out, stderr=err, env=env, creationflags=creationflags,
        )

    time.sleep(4)
    code = proc.poll()
    if code is not None:
        detail = ""
        try:
            detail = tracer_err.read_text(encoding="utf-8", errors="replace").strip()
        except Exception:
            pass
        raise RuntimeError(
            f"The tracer exited immediately (code {code})."
            + (f"\nTracer stderr:\n{detail}" if detail else f" See {tracer_err}")
        )

    record_tracer(runtime_path, proc.pid)
    print(f"Tracer running, detached (PID {proc.pid}).", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:
        print(str(exc), file=sys.stderr, flush=True)
        print("Python autoattach traceback:", file=sys.stderr, flush=True)
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(1)
