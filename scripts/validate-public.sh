#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  SKILL.md README.md LICENSE NOTICE CITATION.cff agents/openai.yaml
  references/provider-selection.md references/client-adapters.md
  references/reality-compatibility.md references/shadowrocket.md
  references/troubleshooting.md references/security-and-acceptance.md
  references/tencent-lighthouse.md references/device-handoff.md
  references/clash-mihomo.md references/windows.md
  scripts/audit-server.sh scripts/preflight-reality.sh scripts/diagnose-node.sh
  scripts/run-debug-window.sh scripts/redact-debug-log.py scripts/verify-client.sh
  scripts/build-transfer-package.sh scripts/backup-xui.sh scripts/test-skill.sh
  scripts/read-shadowrocket-diagnostics.py scripts/check-reload-safety.sh
)

for path in "${required[@]}"; do
  [[ -f "$root/$path" ]] || { echo "Missing required file: $path" >&2; exit 1; }
done

for script in "$root"/scripts/*.sh; do
  bash -n "$script"
done
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/private-proxy-pycache" \
  python3 -m py_compile "$root/scripts/redact-debug-log.py" "$root/scripts/read-shadowrocket-diagnostics.py"
bash "$root/scripts/test-skill.sh"

if find "$root" -path "$root/.git" -prune -o -type f \
  \( -name '*.pem' -o -name '*.key' -o -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
  -print -quit | grep -q .; then
  echo 'Sensitive file type found in the release tree.' >&2
  exit 1
fi

secret_pattern='(vless|ss|trojan)://|BEGIN (OPENSSH |RSA |EC )?PRIVATE KEY|ssh-(rsa|ed25519) AAAA|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|~/Downloads'
if grep -REnI --exclude-dir=.git --exclude='.git' --exclude='validate-public.sh' --exclude='test-skill.sh' --exclude='redact-debug-log.py' --exclude='build-transfer-package.sh' "$secret_pattern" "$root"; then
  echo 'High-risk literal found in the release tree.' >&2
  exit 1
fi

public_ips="$({ grep -REhoI --exclude-dir=.git --exclude='.git' --exclude='validate-public.sh' --exclude='test-skill.sh' '([0-9]{1,3}\.){3}[0-9]{1,3}' "$root" || true; } | sort -u)"
while IFS= read -r ip; do
  [[ -z "$ip" ]] && continue
  case "$ip" in
    0.0.0.0|127.0.0.1) ;;
    *) echo "Unexpected IPv4 literal: $ip" >&2; exit 1 ;;
  esac
done <<<"$public_ips"

grep -q '^version: 0.6.0$' "$root/CITATION.cff"
grep -q '当前 `v0.6.0`' "$root/SKILL.md"
grep -q '/releases/tag/v0.6.0' "$root/README.md"

if command -v sqlite3 >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  sqlite3 "$tmpdir/source.db" 'CREATE TABLE test(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO test(value) VALUES("verified");'
  XUI_DB="$tmpdir/source.db" bash "$root/scripts/backup-xui.sh" "$tmpdir/backup.db" >/dev/null
  [[ "$(sqlite3 "$tmpdir/backup.db" 'PRAGMA integrity_check;')" == 'ok' ]]
  [[ "$(sqlite3 "$tmpdir/backup.db" 'SELECT value FROM test;')" == 'verified' ]]
else
  echo 'sqlite3 not installed; skipped hot-backup integration test.' >&2
fi

echo 'Public release validation passed.'
