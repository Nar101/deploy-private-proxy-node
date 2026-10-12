#!/usr/bin/env bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description='Verify exit and selected HTTP targets without changing routes.')
parser.add_argument('--proxy', required=True, help='socks5h://host:port, http://host:port, or direct')
parser.add_argument('--expected-ip', default='')
parser.add_argument('--targets', default='exit,google', help='comma-separated: exit,google,openai,claude; exit is always included')
parser.add_argument('--skip-claude', action='store_true', help='never issue an Anthropic/Claude request')
parser.add_argument('--download-url', default='')
parser.add_argument('--json-output')
parser.add_argument('--connect-timeout', type=int, default=10)
parser.add_argument('--max-time', type=int, default=20)
args = parser.parse_args()
if not 1 <= args.connect_timeout <= args.max_time <= 300:
    parser.error('timeouts must satisfy 1 <= connect-timeout <= max-time <= 300')
if args.proxy != 'direct' and not args.proxy.startswith(('http://', 'https://', 'socks5h://', 'socks5://')):
    parser.error('unsupported proxy scheme')
if args.expected_ip:
    try:
        ipaddress.ip_address(args.expected_ip)
    except ValueError:
        parser.error('expected-ip is invalid')
targets = list(dict.fromkeys(['exit'] + [t.strip() for t in args.targets.split(',') if t.strip()]))
if not set(targets) <= {'exit', 'google', 'openai', 'claude'}:
    parser.error('unknown target')
if args.skip_claude:
    targets = [t for t in targets if t != 'claude']
    if args.download_url:
        from urllib.parse import urlparse
        host = (urlparse(args.download_url).hostname or '').lower()
        if any(host == d or host.endswith('.' + d) for d in ('claude.ai', 'anthropic.com', 'claude.com')):
            parser.error('skip-claude conflicts with download host')

# -q must be the first curl option. Explicit --proxy and --noproxy override
# both curlrc and ambient proxy/no_proxy variables for this subprocess only.
common = ['curl', '-q', '--noproxy', '', '--proxy', '' if args.proxy == 'direct' else args.proxy,
          '--connect-timeout', str(args.connect_timeout), '--max-time', str(args.max_time), '-sS']


def fetch(url, capture=False, download=False):
    body_path = None
    try:
        if capture:
            fd, body_path = tempfile.mkstemp(prefix='private-proxy-exit-')
            os.close(fd)
        format_string = '%{http_code} %{time_total}'
        if download:
            format_string += ' %{size_download} %{speed_download}'
        result = subprocess.run(common + ['-o', body_path or os.devnull, '-w', format_string, url],
                                capture_output=True, text=True)
        fields = result.stdout.strip().split()
        code = int(fields[0]) if fields and fields[0].isdigit() else 0
        seconds = float(fields[1]) if len(fields) > 1 else 0.0
        body = Path(body_path).read_text().strip() if body_path else ''
        failure = None
        if result.returncode or not code:
            failure = 'curl_transport_error'
        if code == 503 or (result.returncode and '503' in result.stderr):
            failure = 'proxy_forwarding_failed_503' if args.proxy != 'direct' else 'target_http_503'
        item = {'status': code, 'seconds': seconds, 'curl_exit': result.returncode, 'failure': failure,
                'http_reachable': bool(code and not failure)}
        if download:
            item.update(bytes=int(float(fields[2])) if len(fields) > 2 else 0,
                        mbps=round(float(fields[3]) * 8 / 1000000, 2) if len(fields) > 3 else 0,
                        requires_runtime_route_evidence=True)
        return item, body
    except (OSError, ValueError):
        return {'status': 0, 'seconds': 0, 'curl_exit': 1, 'failure': 'probe_error', 'http_reachable': False}, ''
    finally:
        if body_path:
            Path(body_path).unlink(missing_ok=True)


urls = {'exit': 'https://api.ipify.org', 'google': 'https://www.google.com/generate_204',
        'openai': 'https://api.openai.com/v1/models', 'claude': 'https://api.anthropic.com/v1/models'}
services = {}
exit_result, actual_ip = fetch(urls['exit'], capture=True)
try:
    ipaddress.ip_address(actual_ip)
    valid_ip = True
except ValueError:
    valid_ip = False
exit_result['passed'] = bool(valid_ip and exit_result['status'] == 200 and not exit_result['failure']
                             and (not args.expected_ip or actual_ip == args.expected_ip))
actual_ip = actual_ip if valid_ip else None
print(f'exit_ip {actual_ip or "unknown"} status={exit_result["status"]} passed={exit_result["passed"]}')
for target in targets:
    if target == 'exit':
        continue
    item, _ = fetch(urls[target])
    item['passed'] = not item['failure'] and item['status'] == (204 if target == 'google' else 401)
    if item['status'] == 403:
        item['service_access'] = 'not_proven_forbidden_response'
    services[target] = item
    print(f'{target} status={item["status"]} seconds={item["seconds"]} passed={item["passed"]} failure={item["failure"] or "none"}')
print('skipped ' + ','.join(t for t in ('google', 'openai', 'claude') if t not in targets))
download = None
if args.download_url:
    download, _ = fetch(args.download_url, download=True)
    download['passed'] = bool(not download['failure'] and 200 <= download['status'] < 300 and download.get('bytes', 0) > 0)
    print(f'download status={download["status"]} passed={download["passed"]}')
    print('NOTE download requires runtime evidence that this domain used the new node.')
passed = exit_result['passed'] and all(x['passed'] for x in services.values()) and (download is None or download['passed'])
payload = {'exit_ip': actual_ip, 'expected_ip': args.expected_ip or None, 'exit_probe': exit_result,
           'targets': targets, 'services': services, 'download': download, 'passed': passed,
           'requires_runtime_route_evidence': True, 'account_access_tested': False}
if args.json_output:
    path = Path(args.json_output)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write('\n')
print('PASS client_http_probe' if passed else 'FAIL client_http_probe')
raise SystemExit(0 if passed else 1)
PY
