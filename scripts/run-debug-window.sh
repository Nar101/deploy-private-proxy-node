#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat >&2 <<'EOF'
Usage: sudo run-debug-window.sh --redact-config <json> [options] -- <debug command> [args...]
  --seconds <10..300>       Watchdog deadline, default 45
  --service <systemd-unit>  Default x-ui
  --port <1..65535>         Default 443
  --expected-process <name> Default xray (formal listener)
  --ready-timeout <1..30>   Default 10
  --restore-timeout <1..60> Default 30
  --log <path>
  --prepare-only           Render helpers without starting/stopping a service
  --state-root <directory> Default /run (or temporary directory in prepare-only)
Wait for READY before issuing one timed request. All debug output is redacted.
A server-local systemd timer restores production even after SSH disconnects.
EOF
  exit 2
}
seconds=45
service=x-ui
port=443
expected_process=xray
ready_timeout=10
restore_timeout=30
log_file=''
redact_config=''
prepare_only=no
state_root=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; break ;;
    --prepare-only) prepare_only=yes; shift; continue ;;
  esac
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --seconds) seconds="$2" ;;
    --service) service="$2" ;;
    --port) port="$2" ;;
    --expected-process) expected_process="$2" ;;
    --ready-timeout) ready_timeout="$2" ;;
    --restore-timeout) restore_timeout="$2" ;;
    --log) log_file="$2" ;;
    --redact-config) redact_config="$2" ;;
    --state-root) state_root="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 10 && "$seconds" -le 300 ]] || usage
[[ "$ready_timeout" =~ ^[0-9]+$ && "$ready_timeout" -ge 1 && "$ready_timeout" -le 30 ]] || usage
[[ "$restore_timeout" =~ ^[0-9]+$ && "$restore_timeout" -ge 1 && "$restore_timeout" -le 60 ]] || usage
[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || usage
[[ "$service" =~ ^[A-Za-z0-9@_.-]+$ && "$service" != -* ]] || usage
[[ "$expected_process" =~ ^[A-Za-z0-9_.-]+$ ]] || usage
[[ $# -gt 0 && -r "$redact_config" ]] || usage
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
filter_script="$script_dir/redact-debug-log.py"
[[ -r "$filter_script" ]] || { echo 'FAIL log_redactor=missing' >&2; exit 1; }
# Parse the redaction source now, before production can be stopped.
python3 "$filter_script" "$redact_config" </dev/null >/dev/null
if [[ "$prepare_only" != yes ]]; then
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
  for dependency in systemd-run systemctl setsid ss ps python3; do
    command -v "$dependency" >/dev/null || { echo "FAIL dependency=$dependency" >&2; exit 1; }
  done
  systemctl is-active --quiet "$service" || { echo 'FAIL production_service=inactive' >&2; exit 1; }
  ps -eo pgid=,stat= >/dev/null || { echo 'FAIL process_observation=unavailable' >&2; exit 1; }
fi
state_root="${state_root:-/run}"
if [[ "$prepare_only" == yes && "$state_root" == /run ]]; then
  state_root="${TMPDIR:-/tmp}"
fi
state_dir="$(mktemp -d "$state_root/private-proxy-debug.XXXXXX")"
chmod 700 "$state_dir"
runner_script="$state_dir/run-debug.sh"
restore_script="$state_dir/restore.py"
ready_script="$state_dir/wait-ready.py"
pid_file="$state_dir/debug.pid"
log_file="${log_file:-$state_dir/debug.log}"
[[ ! -L "$log_file" ]] || { echo 'FAIL log_path=symlink' >&2; exit 1; }
(umask 077; : >"$log_file")
chmod 600 "$log_file"
unit="$(basename "$state_dir" | tr '[:upper:]' '[:lower:]')"
cat >"$runner_script" <<'RUNNER'
#!/usr/bin/env bash
set -o pipefail
pid_file="$1"
redact_config="$2"
filter_script="$3"
log_file="$4"
shift 4
printf '%s\n' "$$" >"$pid_file"
# The pipeline stays in the setsid process group; the watchdog kills all children.
PYTHONUNBUFFERED=1 "$@" 2>&1 | python3 -u "$filter_script" "$redact_config" >>"$log_file"
RUNNER
chmod 700 "$runner_script"
cat >"$restore_script" <<'RESTORE'
#!/usr/bin/env python3
import fcntl
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

state, service, port, expected_process, timeout = sys.argv[1:]
state = Path(state)
status = state / 'restore.status'
timeout = int(timeout)


def restored():
    active = subprocess.run(['systemctl', 'is-active', '--quiet', service],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    listeners = subprocess.run(['ss', '-lntpH', f'sport = :{port}'], capture_output=True, text=True)
    # Verify the expected formal listener, not just any process holding the port.
    return active and listeners.returncode == 0 and bool(
        re.search(r'\("' + re.escape(expected_process) + r'(?:[-_.A-Za-z0-9]*)"', listeners.stdout))


def group_alive(pid):
    members = subprocess.run(['ps', '-eo', 'pgid=,stat='], capture_output=True, text=True)
    if members.returncode:
        raise OSError('process observation failed')
    return any(len(parts) == 2 and parts[0] == str(pid) and not parts[1].startswith('Z')
               for parts in (line.split() for line in members.stdout.splitlines()))


with (state / 'restore.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if status.exists() and status.read_text().startswith('PASS') and restored():
        print('PASS production_restored')
        raise SystemExit(0)
    failure = 'listener_timeout'
    try:
        pid_path = state / 'debug.pid'
        if pid_path.exists():
            pid = int(pid_path.read_text().strip())
            if pid <= 1 or pid == os.getpgrp():
                raise ValueError('invalid debug process group')
            for sig in (signal.SIGTERM, signal.SIGKILL):
                if not group_alive(pid):
                    break
                try:
                    os.killpg(pid, sig)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    if group_alive(pid):
                        raise
                if sig == signal.SIGTERM:
                    time.sleep(0.3)
            if group_alive(pid):
                raise ValueError('debug process group remains alive')
        start_result = subprocess.run(['systemctl', 'start', service], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
        started = start_result.returncode == 0
        if not started:
            failure = f'service_start_exit_{start_result.returncode}'
        deadline = time.monotonic() + timeout
        while started and time.monotonic() < deadline:
            if restored():
                status.write_text('PASS production_restored\n')
                status.chmod(0o600)
                print('PASS production_restored')
                raise SystemExit(0)
            time.sleep(0.2)
    except OSError as exc:
        failure = f'os_error_{exc.errno}'
    except ValueError:
        failure = 'invalid_debug_process_group'
    status.write_text('FAIL production_restore_timeout_or_error reason=' + failure + '\n')
    status.chmod(0o600)
    print('FAIL production_restore_timeout_or_error reason=' + failure, file=sys.stderr)
    raise SystemExit(1)
RESTORE
chmod 700 "$restore_script"
# READY requires the live debug process group to own the listening socket.
cat >"$ready_script" <<'READY'
#!/usr/bin/env python3
from pathlib import Path
import os
import re
import subprocess
import sys
import time
pid_file, port, timeout, restored = sys.argv[1:]
deadline = time.monotonic() + int(timeout)
while time.monotonic() < deadline:
    if Path(restored).exists():
        raise SystemExit(1)
    try:
        pid = int(Path(pid_file).read_text())
        os.kill(pid, 0)
        result = subprocess.run(['ss', '-lntpH', f'sport = :{port}'], capture_output=True, text=True)
        for listener_pid in re.findall(r'pid=(\d+)', result.stdout):
            if os.getpgid(int(listener_pid)) == pid:
                raise SystemExit(0)
    except (OSError, ValueError):
        pass
    time.sleep(0.1)
raise SystemExit(1)
READY
chmod 700 "$ready_script"
restore_args=("$state_dir" "$service" "$port" "$expected_process" "$restore_timeout")
if [[ "$prepare_only" == yes ]]; then
  printf 'PREPARED state_dir=%s log=%s\n' "$state_dir" "$log_file"
  exit 0
fi
systemd-run --quiet --unit "$unit" --on-active="${seconds}s" \
  --timer-property=AccuracySec=1s python3 "$restore_script" "${restore_args[@]}"
# Confirm that the detached watchdog exists before stopping production.
systemctl is-active --quiet "${unit}.timer" || { echo 'FAIL watchdog=inactive' >&2; exit 1; }
restore_now() { python3 "$restore_script" "${restore_args[@]}"; }
finish() {
  local code=$?
  trap - EXIT INT TERM
  if restore_now; then
    systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
  else
    code=1  # Keep the timer armed when immediate restoration failed.
  fi
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
systemctl stop "$service"
setsid "$runner_script" "$pid_file" "$redact_config" "$filter_script" "$log_file" "$@" &
debug_pid=$!
if ! python3 "$ready_script" "$pid_file" "$port" "$ready_timeout" "$state_dir/restore.status";
then
  echo 'FAIL debug_listener=not_ready' >&2
  exit 1
fi
printf 'READY debug_pid=%s seconds=%s log=%s\n' "$debug_pid" "$seconds" "$log_file"
wait "$debug_pid" || true
if ! restore_now; then exit 1; fi
trap - EXIT INT TERM
systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
printf 'PASS production_restored service=%s port=%s log=%s\n' "$service" "$port" "$log_file"
