#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" <<'PY'
"""Behavior tests. Uses fixtures, fake curl/systemctl/ss and local processes only."""
import copy
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import select
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
scripts = root / 'scripts'
count = 0


def check(ok, label):
    global count
    if not ok:
        raise AssertionError(label)
    count += 1
    print('PASS ' + label, flush=True)


def run(name, *args, env=None, input=None, timeout=15):
    cmd = ['python3' if name.endswith('.py') else 'bash', str(scripts / name), *map(str, args)]
    return subprocess.run(cmd, input=input, capture_output=True, text=True, env=env, timeout=timeout)


def write_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


with tempfile.TemporaryDirectory(prefix='private-proxy-skill-test-') as temp:
    tmp = Path(temp)
    config = {
        'inbounds': [{'port': 443, 'protocol': 'vless', 'settings': {'clients': [
            {'id': 'fixture-client-id', 'flow': 'xtls-rprx-vision'}]}, 'streamSettings': {
            'network': 'tcp', 'security': 'reality', 'realitySettings': {
                'target': 'example.com:443', 'serverNames': ['example.com'],
                'privateKey': 'fixture-private-key', 'shortIds': ['aabbccdd']}}}]}
    effective = tmp / 'effective.json'
    write_json(effective, config)
    result = run('preflight-reality.sh', '--config', effective, '--xray-bin', tmp / 'missing')
    check(result.returncode == 0 and 'config_structure=valid' in result.stdout
          and 'compatibility=unverified_requires_handshake' in result.stdout,
          'structure pass does not claim client compatibility')
    check(not any(s in result.stdout for s in ('fixture-client-id', 'fixture-private-key', 'aabbccdd')),
          'preflight hides credentials')
    for label, mutate in (
        ('missing private key', lambda d: d['inbounds'][0]['streamSettings']['realitySettings'].pop('privateKey')),
        ('wrong protocol', lambda d: d['inbounds'][0].update(protocol='vmess')),
        ('missing Vision', lambda d: d['inbounds'][0]['settings']['clients'][0].pop('flow')),
        ('disabled client', lambda d: d['inbounds'][0]['settings']['clients'][0].update(enable=False)),
        ('empty credential', lambda d: d['inbounds'][0]['settings']['clients'][0].update(id='')),
        ('wrong transport', lambda d: d['inbounds'][0]['streamSettings'].update(network='ws')),
    ):
        bad = copy.deepcopy(config)
        mutate(bad)
        path = tmp / 'bad.json'
        write_json(path, bad)
        check(run('preflight-reality.sh', '--config', path).returncode != 0, 'reject ' + label)
    xray = tmp / 'fake-xray'
    xray.write_text('#!/bin/sh\nprintf "Xray 26.9.30 fixture\\n"\n')
    xray.chmod(0o700)
    result = run('preflight-reality.sh', '--config', effective, '--xray-bin', xray,
                 '--client-name', 'Shadowrocket', '--client-version', '2.2.92 (3445)')
    check('known_pair_failed=2026-10-12' in result.stdout, 'known failing version pair is flagged before GUI work')

    def diagnosis(**overrides):
        values = {'server-received': 'clienthello', 'reality': 'failed', 'vless': 'unknown',
                  'exit': 'unknown', 'effective-config': 'yes', 'contaminated': 'no',
                  'restored': 'yes', 'observation-valid': 'yes'}
        values.update(overrides)
        argv = [arg for key, value in values.items() for arg in ('--' + key, value)]
        return run('diagnose-node.sh', *argv)

    result = diagnosis(**{'isolated-client': 'passed', 'native-client': 'failed', 'same-parameters': 'yes'})
    check(result.returncode == 0 and 'BRANCH handshake_compatibility' in result.stdout,
          'same-parameter cross-implementation failure selects handshake compatibility')
    check('BRANCH reality_authentication' in diagnosis().stdout, 'authentication failure remains distinct')
    result = diagnosis(**{'server-received': 'none', 'reality': 'unknown', 'observation-valid': 'no'})
    check(result.returncode != 0 and 'unsynchronized_observation' in result.stdout,
          'late capture cannot become no-connection evidence')
    check('BRANCH pre_server_path' in diagnosis(**{'server-received': 'none', 'reality': 'unknown'}).stdout,
          'valid synchronized no-connection evidence selects network path')
    check('BRANCH synchronized_observation' in diagnosis(**{'server-received': 'unknown', 'reality': 'unknown'}).stdout,
          'unknown connection status asks for paired logs')
    check(diagnosis(**{'contaminated': 'yes'}).returncode != 0, 'contaminated result is rejected')
    check(diagnosis(**{'server-received': 'none', 'reality': 'passed', 'vless': 'passed', 'exit': 'expected'}).returncode != 0,
          'contradictory protocol evidence is rejected')
    check(diagnosis(**{'restored': 'no'}).stdout.startswith('STOP'), 'unrestored state blocks new diagnosis')
    check('routing_policy' in diagnosis(reality='passed', vless='passed', exit='wrong').stdout,
          'wrong exit selects routing instead of server reinstall')

    node_uri_prefix = 'vless' + '://'
    fixture_uuid = '-'.join(('123e4567', 'e89b', '42d3', 'a456', '426614174000'))
    private_begin = '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----'
    private_end = '-----END OPENSSH ' + 'PRIVATE KEY-----'
    sensitive = ('hs.c.AuthKey[:16]: [11 22 33]\nhello.SessionId[:16]: [44 55 66]\n'
                 'hs.c.ClientShortId: [77 88 99]\nclientHello: [101 102]\n'
                 'privateKey=fixture-private-key\nshortId=aabbccdd\n'
                 f'uuid={fixture_uuid}\n'
                 f'{node_uri_prefix}fixture-client-id@example.invalid:443?sid=aabbccdd\n'
                 f'{private_begin}\nfixture-pem-body\n{private_end}\n'
                 'hs.c.ClientVer: [26 7 11]\nconn == conn: true\n')
    result = run('redact-debug-log.py', effective, input=sensitive)
    check(result.returncode == 0 and not any(s in result.stdout for s in (
        '11 22 33', '44 55 66', '77 88 99', '101 102', 'fixture-private-key', 'aabbccdd',
        '123e4567', node_uri_prefix, 'fixture-pem-body')), 'handshake fields and node URI are redacted')
    check('ClientVer: [26 7 11]' in result.stdout and 'conn == conn: true' in result.stdout,
          'diagnostic version and success facts survive redaction')
    stream = subprocess.Popen(['python3', str(scripts / 'redact-debug-log.py'), str(effective)],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    try:
        stream.stdin.write('conn == conn: true\n')
        stream.stdin.flush()
        ready, _, _ = select.select([stream.stdout], [], [], 2)
        check(bool(ready) and stream.stdout.readline().strip() == 'conn == conn: true',
              'redacted output is visible before input closes')
    finally:
        stream.stdin.close()
        stream.wait(timeout=3)
        stream.stdout.close()

    group = tmp / 'group'
    (group / 'Library/Preferences').mkdir(parents=True)
    logdir = group / 'Library/Caches/DebugLogs'
    logdir.mkdir(parents=True)
    with (group / 'Library/Preferences/config.plist').open('wb') as fh:
        plistlib.dump({'group.com.liguangming.CurrentRuleFileName': 'FixtureCurrent'}, fh)
    (logdir / 'PacketTunnel-fixture.log').write_text(
        '2026-10-12 01:00:00 handshake old-window\n'
        '2026-10-12 02:00:01 REALITY connected fixture-node\n'
        '2026-10-12 02:00:02 AuthKey[:16]: [11 22 33]\n'
        '2026-10-12 02:00:03 invalid backend status 503\n')
    result = run('read-shadowrocket-diagnostics.py', '--group-dir', group, '--since', '2026-10-12T02:00:00',
                 '--node-name', 'fixture-node')
    check(result.returncode == 0 and 'FixtureCurrent' in result.stdout and '503' in result.stdout
          and 'old-window' not in result.stdout and '11 22 33' not in result.stdout,
          'diagnostic reader discovers active config and filters and redacts the request window')

    evidence = {'captured_at': datetime.now(timezone.utc).isoformat(), 'authorized': True,
                'baseline': {'main_node': 'main-fixture', 'configuration': 'active-fixture',
                             'exit_ip': '127.0.0.1', 'http_ok': True}, 'physical_route_verified': True,
                'standby': {'proxy': 'http://127.0.0.1:19999', 'independent_process': True, 'http_ok': True},
                'recovery': {'detached': True, 'permissions_verified': True, 'end_condition_verified': True}}
    evidence_file = tmp / 'recovery.json'
    write_json(evidence_file, evidence)
    check(run('check-reload-safety.sh', '--evidence', evidence_file).returncode == 0,
          'complete current recovery evidence passes without network changes')
    for section, key in (('recovery', 'permissions_verified'), ('standby', 'http_ok'), ('recovery', 'detached')):
        bad = copy.deepcopy(evidence)
        bad[section][key] = False
        write_json(evidence_file, bad)
        check(run('check-reload-safety.sh', '--evidence', evidence_file).returncode != 0,
              'rebuild is blocked without ' + section + '.' + key)
    bad = copy.deepcopy(evidence)
    bad['captured_at'] = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    write_json(evidence_file, bad)
    check(run('check-reload-safety.sh', '--evidence', evidence_file).returncode != 0,
          'stale recovery evidence cannot authorize rebuild')

    mock = tmp / 'bin'
    mock.mkdir()
    curl_log = tmp / 'curl-requests.jsonl'
    fake_curl = mock / 'curl'
    fake_curl.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['FIXTURE_CURL_LOG'],'a') as fh: fh.write(json.dumps(args)+'\\n')
url=args[-1]
code, seconds, body=200, '0.1', ''
if 'api.ipify.org' in url: body='127.0.0.1'
elif 'generate_204' in url: code=204
elif 'api.openai.com' in url or 'api.anthropic.com' in url: code=401
elif 'download.example' in url: body='download fixture'
else: sys.exit(22)
if os.environ.get('FIXTURE_FAIL')=='503' and 'generate_204' in url: code=503
if os.environ.get('FIXTURE_FAIL')=='403' and 'api.anthropic.com' in url: code=403
if os.environ.get('FIXTURE_FAIL')=='timeout' and 'generate_204' in url: sys.stdout.write('000 0.1'); sys.exit(28)
out=args[args.index('-o')+1]
Path(out).write_text(body)
format_string=args[args.index('-w')+1]
sys.stdout.write(f'{code} {seconds}' + (' 10000000 2500000' if 'size_download' in format_string else ''))
''')
    fake_curl.chmod(0o700)
    env = dict(os.environ, PATH=str(mock) + os.pathsep + os.environ['PATH'], FIXTURE_CURL_LOG=str(curl_log),
               NO_PROXY='*', no_proxy='*', HTTPS_PROXY='http://invalid.example:1')
    output = tmp / 'probe.json'
    result = run('verify-client.sh', '--proxy', 'http://127.0.0.1:19999', '--expected-ip', '127.0.0.1',
                 '--targets', 'exit,google,claude', '--skip-claude', '--json-output', output, env=env)
    requests = [json.loads(line) for line in curl_log.read_text().splitlines()]
    check(result.returncode == 0 and all('anthropic' not in x[-1] and 'claude' not in x[-1] for x in requests),
          'skip-Claude makes zero Claude requests even when selected')
    check(all(x[0] == '-q' and x[x.index('--noproxy') + 1] == ''
              and x[x.index('--proxy') + 1] == 'http://127.0.0.1:19999' for x in requests),
          'explicit proxy overrides curlrc and ambient NO_PROXY and proxy variables')
    check(output.stat().st_mode & 0o777 == 0o600 and json.loads(output.read_text())['passed'],
          'probe result is restricted and records actual success')
    result = run('verify-client.sh', '--proxy', 'direct', '--expected-ip', '127.0.0.1', env=env)
    request = json.loads(curl_log.read_text().splitlines()[-1])
    check(result.returncode == 0 and request[request.index('--proxy') + 1] == '',
          'direct mode also disables ambient proxies')
    result = run('verify-client.sh', '--proxy', 'http://127.0.0.1:19999', '--json-output', output,
                 env=dict(env, FIXTURE_FAIL='503'))
    payload = json.loads(output.read_text())
    check(result.returncode != 0 and payload['services']['google']['failure'] == 'proxy_forwarding_failed_503',
          'HTTP 503 is proxy failure rather than successful connectivity')
    result = run('verify-client.sh', '--proxy', 'http://127.0.0.1:19999', '--targets', 'exit,claude',
                 '--json-output', output, env=dict(env, FIXTURE_FAIL='403'))
    check(result.returncode != 0 and json.loads(output.read_text())['services']['claude']['http_reachable'],
          'HTTP 403 is reachable but does not claim service access')
    result = run('verify-client.sh', '--proxy', 'http://127.0.0.1:19999', '--json-output', output,
                 env=dict(env, FIXTURE_FAIL='timeout'))
    check(result.returncode != 0 and json.loads(output.read_text())['services']['google']['curl_exit'] == 28,
          'transport failure still produces an inspectable result')
    check(run('verify-client.sh', '--proxy', 'direct', '--expected-ip', '.'.join(('127', '0', '0', '9')), env=env).returncode != 0,
          'unexpected exit IP is rejected')
    result = run('verify-client.sh', '--proxy', 'direct', '--download-url', 'https://download.example/file',
                 '--json-output', output, env=env)
    check(result.returncode == 0 and json.loads(output.read_text())['download']['requires_runtime_route_evidence'],
          'download measurement still requires route proof')

    node = tmp / 'node.txt'
    node.write_text(node_uri_prefix + 'fixture-node-only\n')
    rules = tmp / 'rules.conf'
    rules.write_text('[Rule]\nDOMAIN,example.com,NEW-NODE-TEST\n')
    result = run('build-transfer-package.sh', '--node-file', node, '--rules-file', rules, '--output-dir', tmp / 'package')
    check(result.returncode == 0 and (tmp / 'package/node.txt').stat().st_mode & 0o777 == 0o600,
          'transfer package retains restricted file permissions')
    node.write_text(private_begin + '\n')
    check(run('build-transfer-package.sh', '--node-file', node, '--rules-file', rules, '--output-dir', tmp / 'rejected').returncode != 0,
          'transfer package rejects SSH private key material')

    result = run('run-debug-window.sh', '--prepare-only', '--state-root', tmp,
                 '--redact-config', effective, '--restore-timeout', '1', '--', 'sh', '-c', 'exit 0')
    check(result.returncode == 0 and 'PREPARED' in result.stdout, 'debug helpers can be prepared without stopping a service')
    state = next(tmp.glob('private-proxy-debug.*'))
    # Real local pipeline checks flushing and whole-process-group termination.
    debug = subprocess.Popen(['bash', str(state / 'run-debug.sh'), str(state / 'debug.pid'), str(effective),
                              str(scripts / 'redact-debug-log.py'), str(state / 'debug.log'), 'python3', '-u', '-c',
                              'import time; print("AuthKey[:16]: [11 22 33]",flush=True); print("conn == conn: true",flush=True); time.sleep(30)'],
                             start_new_session=True)
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if 'conn == conn: true' in (state / 'debug.log').read_text():
                break
            time.sleep(0.02)
        debug_text = (state / 'debug.log').read_text()
        check('conn == conn: true' in debug_text and '11 22 33' not in debug_text and debug.poll() is None,
              'live debug pipeline emits redacted diagnostics before process exit')
        (mock / 'systemctl').write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
p=Path(os.environ['FIXTURE_SERVICE_STATE'])
if sys.argv[1]=='start':
 if os.environ.get('FIXTURE_RESTORE_FAIL'): sys.exit(1)
 p.write_text('started')
elif sys.argv[1]=='is-active': sys.exit(0 if p.exists() else 3)
''')
        (mock / 'ss').write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
p=Path(os.environ['FIXTURE_SS_COUNT'])
n=int(p.read_text())+1 if p.exists() else 1
p.write_text(str(n))
if n>=3: print('LISTEN 0 4096 0.0.0.0:443 users:(("xray",pid=99999,fd=8))')
''')
        fake_ss = (mock / 'ss').read_text()
        (mock / 'ss').write_text(fake_ss.replace("if n>=3:", "if os.environ.get('FIXTURE_READY') == 'yes':\n print('LISTEN 0 4096 0.0.0.0:443 users:((\"fixture-debug\",pid='+os.environ['FIXTURE_DEBUG_PID']+',fd=8))')\nelif os.environ.get('FIXTURE_READY') != 'no' and n>=3:"))
        # The desktop sandbox blocks ps. Model only its observation; termination
        # still targets the real fixture process group, never an existing app.
        (mock / 'ps').write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
p=Path(os.environ['FIXTURE_PS_COUNT'])
n=int(p.read_text())+1 if p.exists() else 1
p.write_text(str(n))
if n==1: print(os.environ['FIXTURE_DEBUG_PID']+' S')
''')
        for name in ('ss', 'systemctl', 'ps'):
            (mock / name).chmod(0o700)
        restore_env = dict(env, FIXTURE_SERVICE_STATE=str(tmp / 'service-state'), FIXTURE_SS_COUNT=str(tmp / 'ss-count'),
                           FIXTURE_PS_COUNT=str(tmp / 'ps-count'), FIXTURE_DEBUG_PID=str(debug.pid))
        ready_args = ['python3', str(state / 'wait-ready.py'), str(state / 'debug.pid'), '443', '1', str(state / 'restore.status')]
        result = subprocess.run(ready_args, capture_output=True, text=True, env=dict(restore_env, FIXTURE_READY='yes'), timeout=3)
        check(result.returncode == 0, 'READY requires a listener in the live debug process group')
        result = subprocess.run(ready_args, capture_output=True, text=True, env=dict(restore_env, FIXTURE_READY='no'), timeout=3)
        check(result.returncode != 0, 'READY is refused when the debug process has not opened the port')
        (state / 'restore.status').write_text('PASS production_restored\n')
        result = subprocess.run(ready_args, capture_output=True, text=True, env=dict(restore_env, FIXTURE_READY='yes'), timeout=3)
        check(result.returncode != 0, 'READY is refused after the watchdog has restored production')
        (state / 'restore.status').unlink()
        (tmp / 'ss-count').unlink()
        result = subprocess.run(['python3', str(state / 'restore.py'), str(state), 'x-ui', '443', 'xray', '2'],
                                capture_output=True, text=True, env=restore_env, timeout=5)
        debug.wait(timeout=3)
        if result.returncode != 0:
            print('Restore fixture output:', result.stdout.strip(), result.stderr.strip())
            print('Restore fixture status:', (state / 'restore.status').read_text().strip())
            print('Restore fixture probe count:', (tmp / 'ss-count').read_text() if (tmp / 'ss-count').exists() else 'none')
        check(result.returncode == 0 and (state / 'restore.status').read_text().startswith('PASS')
              and int((tmp / 'ss-count').read_text()) >= 3,
              'detached restorer kills debug group and waits for formal process and port')
        (state / 'debug.pid').unlink()
        (state / 'restore.status').unlink()
        result = subprocess.run(['python3', str(state / 'restore.py'), str(state), 'x-ui', '443', 'wrong-process', '1'],
                                capture_output=True, text=True, env=restore_env, timeout=5)
        check(result.returncode != 0 and 'FAIL' in (state / 'restore.status').read_text(),
              'another process on formal port cannot count as restored')
    finally:
        if debug.poll() is None:
            os.killpg(debug.pid, signal.SIGKILL)
            debug.wait(timeout=3)
print(f'Skill behavior tests passed: {count}. No live network or server changes.', flush=True)
PY
