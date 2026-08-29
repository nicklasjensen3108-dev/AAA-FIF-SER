from __future__ import annotations

import argparse
import json
import re
import shutil
import tempfile
import zipfile
from collections import Counter
from datetime import datetime, timezone, timedelta
from pathlib import Path

IMPORTANT_NATIVE = {
    'http-request', 'http-request-body-chunk', 'connect', 'cards-event',
    'cardsdll-call', 'cards-config', 'screen-event', 'apt-parse', 'movie-load',
    'resource-open', 'exception', 'squad-null-contained', 'cards-transport',
    'cards-load-gate', 'archive', 'cards-archives', 'fut2-member', 'as-branch',
    'chem-native', 'chem-raw', 'chem-raw-hook', 'chem-raw-hook-failed', 'store-native',
    'store-crash-guard-ready', 'store-crash-guard', 'config-string-override', 'config-int-override',
    'chem-native-refresh', 'chem-refresh-hook',
}


def parse_start(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc) - timedelta(hours=4)
    value = value.strip()
    if value.endswith('Z'):
        value = value[:-1] + '+00:00'
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def compact(value, limit=900):
    if isinstance(value, (dict, list)):
        text = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    else:
        text = str(value)
    text = text.replace('\r', ' ').replace('\n', ' ')
    return text if len(text) <= limit else text[:limit] + '...[truncated]'


def add_file(zf: zipfile.ZipFile, root: Path, path: Path, arc_prefix: str = 'raw'):
    try:
        rel = path.relative_to(root)
        arc = Path(arc_prefix) / rel
    except ValueError:
        arc = Path(arc_prefix) / path.name
    zf.write(path, arc.as_posix())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', type=Path, required=True)
    ap.add_argument('--session', required=True)
    ap.add_argument('--start-utc')
    args = ap.parse_args()

    root = args.root.resolve()
    session = args.session
    start = parse_start(args.start_utc)
    cutoff = start - timedelta(seconds=10)
    reports = root / 'reports'
    reports.mkdir(parents=True, exist_ok=True)
    out_zip = reports / f'fut13-trace-{session}.zip'

    files: list[Path] = []
    for folder in (root / 'logs', root / 'server', root / 'artifacts'):
        if not folder.exists():
            continue
        for p in folder.glob('*'):
            if not p.is_file():
                continue
            include = session in p.name
            if p.name in {'trace-markers.log', 'crash-backtrace.jsonl', 'game-debug.log'}:
                try:
                    include = datetime.fromtimestamp(p.stat().st_mtime, timezone.utc) >= cutoff
                except OSError:
                    pass
            if include:
                files.append(p)

    # Runtime/config context makes a trace reproducible without bundling game files.
    for rel in [
        'runtime/trace-session.json', 'runtime/processes.json', 'local.settings.json',
        'server/config/futcfg.xml', 'server/config/futBoot.xml',
        'server/config/dimecfg.xml', 'server/config/storecfg.xml',
        'server/config/storepackdescriptions.en_us.xml',
    ]:
        p = root / rel
        if p.is_file():
            files.append(p)

    files = list(dict.fromkeys(files))

    summary: list[str] = []
    summary.append('FIFA 13 LOCAL FUT - REVERSE ENGINEERING TRACE')
    summary.append('=' * 58)
    summary.append(f'Session: {session}')
    summary.append(f'Start UTC: {start.isoformat()}')
    summary.append('')

    # User markers
    marker_file = root / 'logs' / 'trace-markers.log'
    markers = []
    if marker_file.is_file():
        for line in marker_file.read_text(encoding='utf-8', errors='replace').splitlines():
            if session in line:
                markers.append(line)
    summary.append('MARKERS')
    summary.append('-' * 58)
    summary.extend(markers[-100:] or ['(none)'])
    summary.append('')

    # Blaze RPC sequence from the bridge.
    bridge_logs = [p for p in files if p.name.startswith('bridge-') and session in p.name and p.name.endswith('.out.log')]
    blaze_calls = []
    for p in bridge_logs:
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            if '<- req:' in line or 'FIFA 13 redirect request:' in line:
                blaze_calls.append(line)
    summary.append('BLAZE RPC SEQUENCE')
    summary.append('-' * 58)
    summary.extend(blaze_calls[-500:] or ['(no Blaze calls captured)'])
    summary.append('')

    # RS4 route sequence + unknown routes.
    rs4_logs = [p for p in files if p.name.startswith('fut13-rs4-') and session in p.name]
    calls, unknown = [], []
    for p in rs4_logs:
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            if re.search(r'\] (200|404)  ', line):
                calls.append(line)
                if '] 404  ' in line:
                    unknown.append(line)
            elif 'REQBODY ' in line or 'REQHDR ' in line:
                calls.append(line)
    summary.append('RS4 HTTP SEQUENCE')
    summary.append('-' * 58)
    summary.extend(calls[-500:] or ['(no RS4 calls captured)'])
    summary.append('')
    summary.append('UNKNOWN / UNIMPLEMENTED RS4 ROUTES')
    summary.append('-' * 58)
    summary.extend(unknown[-200:] or ['(none captured)'])
    summary.append('')

    # DIME/config requests.
    dime_logs = [p for p in files if p.name.startswith('fut13-dime-') and session in p.name]
    dime_calls = []
    for p in dime_logs:
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            if '] 200  ' in line or '] 404  ' in line or '] ERR  ' in line:
                dime_calls.append(line)
    summary.append('DIME / CONFIG SEQUENCE')
    summary.append('-' * 58)
    summary.extend(dime_calls[-250:] or ['(no DIME calls captured)'])
    summary.append('')

    # EASW is FIFA's native pre-RS4 session layer. v0.13.17 exposes the
    # donor's complete 19501..19507 surface so we can see whether fifa13.exe
    # actually establishes EASW-Session/EASW-Token before CardsDLL enters Store.
    easw_logs = [p for p in files if p.name.startswith('fut13-easw-') and session in p.name]
    easw_calls = []
    for p in easw_logs:
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            if '] REQ ' in line or '] HDR ' in line or '] RESP ' in line or '] ERR ' in line:
                easw_calls.append(line)
    summary.append('EASW HTTP SEQUENCE')
    summary.append('-' * 58)
    summary.extend(easw_calls[-400:] or ['(no EASW calls captured)'])
    summary.append('')

    # POW is a separate FIFA web service from RS4. v0.13.17 starts the four
    # donor-parity endpoints on 19512..19515 and keeps every request in the
    # report so Store bootstrap can be compared without native Store hooks.
    pow_logs = [p for p in files if p.name.startswith('fut13-pow-') and session in p.name]
    pow_calls = []
    for p in pow_logs:
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            if 'REQUEST ' in line or 'RESPONSE ' in line or 'ERROR ' in line:
                pow_calls.append(line)
    summary.append('POW HTTP SEQUENCE')
    summary.append('-' * 58)
    summary.extend(pow_calls[-300:] or ['(no POW calls captured)'])
    summary.append('')

    # Native Frida JSONL.
    native = root / 'artifacts' / f'fifa13-native-{session}.jsonl'
    counts = Counter()
    native_lines = []
    crashes = []
    if native.is_file():
        for line in native.read_text(encoding='utf-8', errors='replace').splitlines():
            try:
                obj = json.loads(line)
            except Exception:
                continue
            kind = str(obj.get('kind', 'unknown'))
            counts[kind] += 1
            if kind == 'exception':
                crashes.append(obj)
            if kind in IMPORTANT_NATIVE:
                t = obj.pop('time', '')
                native_lines.append(f'{t}  {kind}: {compact(obj)}')
    summary.append('NATIVE EVENT COUNTS')
    summary.append('-' * 58)
    if counts:
        summary.extend(f'{k}: {v}' for k, v in counts.most_common())
    else:
        summary.append('(native tracer did not produce a JSONL file)')
    summary.append('')
    summary.append('IMPORTANT NATIVE EVENT TIMELINE')
    summary.append('-' * 58)
    summary.extend(native_lines[-1000:] or ['(none captured)'])
    summary.append('')
    summary.append('NATIVE EXCEPTIONS')
    summary.append('-' * 58)
    if crashes:
        for crash in crashes[-20:]:
            summary.append(compact(crash, 4000))
    else:
        summary.append('(none captured)')
    summary.append('')

    # Errors from child process stderr.
    errors = []
    for p in files:
        if '.err.log' in p.name and p.stat().st_size:
            text = p.read_text(encoding='utf-8', errors='replace').strip()
            if text:
                errors.append(f'--- {p.name} ---\n{text[-12000:]}')
    summary.append('PROCESS STDERR')
    summary.append('-' * 58)
    summary.extend(errors or ['(none)'])
    summary.append('')

    summary_text = '\n'.join(summary) + '\n'
    instructions = f'''FIFA 13 trace session {session}\n\nTracing is ALWAYS ON for the whole FIFA session. No manual marker is required.\nPlay/test normally, then upload this ZIP after FIFA closes or crashes together\nwith a short description of what happened.\n\nTRACE_SUMMARY.txt is the first file to inspect. raw/ contains the original\nbridge, RS4, DIME, native Frida and crash logs used to generate it.\n'''

    with zipfile.ZipFile(out_zip, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr('TRACE_SUMMARY.txt', summary_text)
        zf.writestr('README_TRACE.txt', instructions)
        for p in files:
            add_file(zf, root, p)

    print(str(out_zip))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
