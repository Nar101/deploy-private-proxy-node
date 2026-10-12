#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Usage: build-transfer-package.sh --node-file <file> --rules-file <file> --output-dir <new-directory> [--archive <zip-path>]' >&2
  exit 2
}

node_file=''
rules_file=''
output_dir=''
archive=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-file) node_file="${2:-}"; shift 2 ;;
    --rules-file) rules_file="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --archive) archive="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -r "$node_file" && -r "$rules_file" && -n "$output_dir" ]] || usage
[[ ! -e "$output_dir" ]] || { echo "Refusing to overwrite existing output: $output_dir" >&2; exit 1; }
if [[ -n "$archive" && -e "$archive" ]]; then
  echo "Refusing to overwrite existing archive: $archive" >&2
  exit 1
fi

private_key_pattern='BEGIN (OPENSSH |RSA |EC )?PRIVATE KEY|PuTTY-User-Key-File|ssh-ed25519 [A-Za-z0-9+/]{40,}'
if grep -EIl "$private_key_pattern" "$node_file" "$rules_file" | grep -q .; then
  echo 'Private-key material detected; transfer package blocked.' >&2
  exit 1
fi

mkdir -m 700 "$output_dir"
install -m 600 "$node_file" "$output_dir/node.txt"
install -m 600 "$rules_file" "$output_dir/rules.conf"

printf '%s\n' \
  'Private Proxy Node Transfer' \
  '' \
  '1. Import node.txt as a server node without replacing existing nodes.' \
  '2. Import rules.conf as a configuration file and select it explicitly.' \
  '3. Keep automatic cloud sync disabled unless you intentionally choose it.' \
  '4. Verify native latency, expected exit IP, and target services on this device.' \
  '' \
  'Security: node.txt contains private connection credentials. This package does not contain an SSH private key. Keep it only on your own devices.' \
  >"$output_dir/README.txt"
chmod 600 "$output_dir/README.txt"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$output_dir" && sha256sum node.txt rules.conf README.txt >SHA256SUMS)
else
  (cd "$output_dir" && shasum -a 256 node.txt rules.conf README.txt >SHA256SUMS)
fi
chmod 600 "$output_dir/SHA256SUMS"

if [[ -n "$archive" ]]; then
  command -v zip >/dev/null 2>&1 || { echo 'zip is required to create an archive.' >&2; exit 1; }
  (cd "$output_dir" && zip -q -X "$archive" node.txt rules.conf README.txt SHA256SUMS)
  chmod 600 "$output_dir/$archive" 2>/dev/null || chmod 600 "$archive"
fi

echo "PASS transfer_package=$output_dir"
