#!/usr/bin/env bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import ipaddress
import json

parser = argparse.ArgumentParser(description='Validate current recovery evidence; never stops or starts a tunnel.', epilog='''
Evidence JSON: captured_at (ISO with zone), authorized (bool),
baseline {main_node, configuration, exit_ip, http_ok}, physical_route_verified,
standby {proxy, independent_process, http_ok},
recovery {detached, permissions_verified, end_condition_verified}.
Populate from current observations, not assumptions. A PASS only validates the evidence record.
''')
parser.add_argument('--evidence', required=True)
args = parser.parse_args()
try:
    with open(args.evidence, encoding='utf-8') as fh:
        data = json.load(fh)
    stamp = datetime.fromisoformat(data['captured_at'].replace('Z', '+00:00'))
    baseline = data['baseline']
    standby = data['standby']
    recovery = data['recovery']
    age = (datetime.now(timezone.utc) - stamp).total_seconds()
    ipaddress.ip_address(baseline['exit_ip'])
except (OSError, ValueError, KeyError, TypeError):
    raise SystemExit('STOP recovery_evidence=missing_or_invalid')
checks = {
    'current_evidence': stamp.tzinfo is not None and -30 <= age <= 900,
    'authorized': data.get('authorized') is True,
    'main_baseline': bool(baseline.get('main_node') and baseline.get('configuration')) and baseline.get('http_ok') is True,
    'physical_route': data.get('physical_route_verified') is True,
    'independent_standby': bool(standby.get('proxy')) and standby.get('independent_process') is True and standby.get('http_ok') is True,
    'detached_recovery': recovery.get('detached') is True,
    'tool_permissions': recovery.get('permissions_verified') is True,
    'recovery_end_condition': recovery.get('end_condition_verified') is True,
}
for name, ok in checks.items():
    print(f'{"PASS" if ok else "STOP"} {name}')
if not all(checks.values()):
    print('NEXT keep the main tunnel; use logs or an isolated client until recovery conditions are verified')
    raise SystemExit(1)
print('PASS recovery_evidence=complete; no network action performed')
PY
