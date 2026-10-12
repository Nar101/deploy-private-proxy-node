#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: preflight-reality.sh --config <effective-xray-config.json> [options]
  --xray-bin <path>       Default: xray
  --expected-port <port>  Default: 443
  --client-name <name>
  --client-version <version>
Checks structure only; compatibility requires an actual client handshake.
Prints non-sensitive fields and hashes, never credentials.
EOF
  exit 2
}

config=''
xray_bin='xray'
expected_port='443'
client_name='unknown'
client_version='unknown'
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --config) config="$2" ;;
    --xray-bin) xray_bin="$2" ;;
    --expected-port) expected_port="$2" ;;
    --client-name) client_name="$2" ;;
    --client-version) client_version="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[[ -r "$config" && "$expected_port" =~ ^[0-9]+$ ]] || usage
xray_version='unavailable'
if command -v "$xray_bin" >/dev/null 2>&1; then
  xray_version="$("$xray_bin" version 2>/dev/null | sed -n '1p' || true)"
fi

python3 - "$config" "$expected_port" "$xray_version" "$client_name" "$client_version" <<'PY'
import hashlib
import json
import re
import sys

path, port, version_text, client_name, client_version = sys.argv[1:]
port = int(port)
if not 1 <= port <= 65535:
    raise SystemExit('FAIL expected_port=invalid')
try:
    with open(path, encoding='utf-8') as fh:
        data = json.load(fh)
except (OSError, ValueError):
    raise SystemExit('FAIL effective_config=unreadable_or_invalid')
if not isinstance(data, dict) or not isinstance(data.get('inbounds'), list):
    raise SystemExit('FAIL effective_config=inbounds_missing')

version = re.search(r'\b\d+\.\d+\.\d+\b', version_text)
core_version = version.group() if version else 'unknown'
print(f'INFO xray_version={core_version}')
print('INFO native_client_compatibility=unverified_requires_handshake')
if (core_version == '26.9.30' and client_name.lower() == 'shadowrocket'
        and client_version.startswith('2.2.92')):
    print('WARN known_pair_failed=2026-10-12; inspect ClientHello key_share requirements before GUI work')


def digest(value):
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


reality = []
for inbound in data['inbounds']:
    if not isinstance(inbound, dict):
        raise SystemExit('FAIL inbound=invalid_structure')
    stream = inbound.get('streamSettings') or {}
    if not isinstance(stream, dict):
        raise SystemExit('FAIL stream_settings=invalid_structure')
    if str(stream.get('security', '')).lower() == 'reality':
        reality.append((inbound, stream, stream.get('realitySettings') or {}))
if not reality:
    raise SystemExit('FAIL reality_inbound=missing')
if len(reality) > 1:
    print(f'WARN reality_inbound_count={len(reality)}')
failed = False
for index, (inbound, stream, settings) in enumerate(reality):
    if not isinstance(settings, dict) or not isinstance(inbound.get('settings'), dict):
        raise SystemExit('FAIL reality_settings=invalid_structure')
    names = settings.get('serverNames') or []
    ids = settings.get('shortIds') or []
    clients = inbound['settings'].get('clients') or []
    clients_ok = isinstance(clients, list) and bool(clients) and all(
        isinstance(c, dict) and isinstance(c.get('id'), str) and bool(c['id'])
        and c.get('enable', True) is True and c.get('flow') == 'xtls-rprx-vision'
        for c in clients
    )
    checks = {
        'port': inbound.get('port') == port,
        'vless': inbound.get('protocol') == 'vless',
        'tcp': stream.get('network', 'tcp') in ('tcp', 'raw'),
        'enabled': inbound.get('enable', True) is True,
        'target_present': bool(settings.get('target') or settings.get('dest')),
        'server_names': isinstance(names, list) and bool(names) and all(isinstance(n, str) and n for n in names),
        'private_key_present': isinstance(settings.get('privateKey'), str) and bool(settings['privateKey']),
        'short_ids': isinstance(ids, list) and bool(ids) and all(isinstance(s, str) for s in ids),
        'active_vless_vision_clients': clients_ok,
    }
    for name, ok in checks.items():
        print(f'{"PASS" if ok else "FAIL"} inbound[{index}].{name}={"yes" if ok else "no"}')
    failed |= not all(checks.values())
    if checks['private_key_present']:
        print(f'INFO inbound[{index}].private_key_sha256={digest(settings["privateKey"])}')
    if checks['short_ids']:
        print(f'INFO inbound[{index}].short_ids_sha256={digest(ids)}')
    if clients_ok:
        print(f'INFO inbound[{index}].client_ids_sha256={digest([c["id"] for c in clients])}')
    if settings.get('minClientVer') in (None, ''):
        print(f'WARN inbound[{index}].min_client_ver=unset_version_dependent; check installed source or handshake log')
    else:
        print(f'INFO inbound[{index}].min_client_ver=explicit; does not prove ClientHello feature compatibility')
if failed:
    raise SystemExit(1)
print('PASS config_structure=valid')
PY
