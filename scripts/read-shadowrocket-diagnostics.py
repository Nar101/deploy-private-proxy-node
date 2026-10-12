#!/usr/bin/env python3
"""Read current Shadowrocket metadata and a bounded, redacted diagnostic tail."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import re
import sys

from importlib.util import module_from_spec, spec_from_file_location
spec = spec_from_file_location('proxy_redactor', Path(__file__).with_name('redact-debug-log.py'))
module = module_from_spec(spec)
spec.loader.exec_module(module)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--group-dir', type=Path, help='override for a fixture or a discovered group container')
parser.add_argument('--since', help='ISO request-window start; timestamps without a zone use local time')
parser.add_argument('--node-name', default='')
parser.add_argument('--max-lines', type=int, default=30)
parser.add_argument('--max-files', type=int, default=2)
args = parser.parse_args()
if not 1 <= args.max_lines <= 200 or not 1 <= args.max_files <= 5:
    parser.error('max-lines must be 1..200, max-files 1..5')


def parse_time(value):
    value = value.strip().replace(',', '.').replace('Z', '+00:00')
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.astimezone()
    return dt.astimezone(timezone.utc)


try:
    since = parse_time(args.since) if args.since else None
except ValueError:
    parser.error('since must be an ISO timestamp')
if args.group_dir:
    groups = [args.group_dir]
else:
    groups = sorted((Path.home() / 'Library/Group Containers').glob('*Shadowrocket*'))
    groups = [p for p in groups if p.is_dir()]
if len(groups) != 1 or not groups[0].is_dir():
    raise SystemExit('STOP group_container=missing_or_ambiguous; pass --group-dir after inspecting enabled locations')
group = groups[0]
config_names = set()
preferences = group / 'Library/Preferences'
for path in preferences.glob('*.plist'):
    try:
        with path.open('rb') as fh:
            value = plistlib.load(fh).get('group.com.liguangming.CurrentRuleFileName')
        if isinstance(value, str) and value:
            config_names.add(value)
    except (OSError, ValueError, plistlib.InvalidFileException, AttributeError):
        continue
safe = module.Redactor()
if len(config_names) == 1:
    print('INFO current_rule_file=' + safe.line(next(iter(config_names))).strip())
else:
    print('WARN current_rule_file=unknown_or_ambiguous; do not select a historical database by name alone')
logs = sorted((group / 'Library/Caches/DebugLogs').glob('PacketTunnel-*.log'),
              key=lambda p: p.stat().st_mtime, reverse=True)[:args.max_files]
if not logs:
    raise SystemExit('STOP packet_tunnel_log=missing; enable diagnostics through the client UI if permitted')
pattern = re.compile(r'(?i)reality|vless|invalid backend|503|clienthello|client.?ver|handshake|connect(?:ed|ion)?.*|fallback|error')
ts_pattern = re.compile(r'^\s*\[?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)')
emitted = 0
unknown_times = 0
for path in reversed(logs):
    with path.open('rb') as fh:
        size = path.stat().st_size
        fh.seek(max(0, size - 512 * 1024))
        if size > 512 * 1024:
            fh.readline()  # discard a partial leading line
        lines = fh.read().decode('utf-8', errors='replace').splitlines(keepends=True)
    redactor = module.Redactor()
    selected = []
    current_time = None
    for line in lines:
        match = ts_pattern.match(line)
        if match:
            try:
                current_time = parse_time(match.group(1))
            except ValueError:
                current_time = None
        cleaned = redactor.line(line)
        if not cleaned or not (pattern.search(line) or (args.node_name and args.node_name in line)):
            continue
        if since and current_time and current_time < since:
            continue
        if since and current_time is None:
            unknown_times += 1
        selected.append(cleaned.rstrip())
    if selected:
        print('INFO diagnostic_file=' + path.name + ' kind=handshake_not_rule_hit')
        for line in selected[-args.max_lines:]:
            print(line)
            emitted += 1
if unknown_times:
    print(f'WARN lines_without_timestamp={unknown_times}; these lines cannot prove same-request timing')
if not emitted:
    print('WARN matching_diagnostics=none; absence in this bounded tail does not prove no server connection')
print('NOTE route proof requires the separate proxy rule log and expected exit IP.')
