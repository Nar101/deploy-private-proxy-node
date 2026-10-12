#!/usr/bin/env bash
set -euo pipefail
usage() {
  cat >&2 <<'EOF'
Usage: diagnose-node.sh
  --server-received unknown|none|tcp|clienthello
  --reality unknown|failed|passed --vless unknown|failed|passed
  --exit unknown|wrong|expected --effective-config yes|no
  --contaminated yes|no --restored yes|no
  [--observation-valid yes|no] (default no; required for none)
  [--isolated-client unknown|failed|passed] [--native-client unknown|failed|passed]
  [--same-parameters unknown|yes|no]
Observation must cover the same request. Protocol states refer to the failing client.
EOF
  exit 2
}
server_received=''
reality=''
vless=''
exit_state=''
effective_config=''
contaminated=''
restored=''
observation_valid='no'
isolated_client='unknown'
native_client='unknown'
same_parameters='unknown'
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --server-received) server_received="$2" ;;
    --reality) reality="$2" ;;
    --vless) vless="$2" ;;
    --exit) exit_state="$2" ;;
    --effective-config) effective_config="$2" ;;
    --contaminated) contaminated="$2" ;;
    --restored) restored="$2" ;;
    --observation-valid) observation_valid="$2" ;;
    --isolated-client) isolated_client="$2" ;;
    --native-client) native_client="$2" ;;
    --same-parameters) same_parameters="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[[ "$server_received" =~ ^(unknown|none|tcp|clienthello)$ ]] || usage
for result in "$reality" "$vless" "$isolated_client" "$native_client"; do
  [[ "$result" =~ ^(unknown|failed|passed)$ ]] || usage
done
[[ "$exit_state" =~ ^(unknown|wrong|expected)$ ]] || usage
for flag in "$effective_config" "$contaminated" "$restored" "$observation_valid"; do
  [[ "$flag" =~ ^(yes|no)$ ]] || usage
done
[[ "$same_parameters" =~ ^(unknown|yes|no)$ ]] || usage
if [[ "$restored" == no ]]; then
  echo 'STOP formal_state=not_restored'
  echo 'NEXT restore and verify formal service and main client before any new hypothesis'
  exit 1
fi
if [[ "$contaminated" == yes ]]; then
  echo 'INVALID test_evidence=contaminated'
  echo 'NEXT discard this result; repeat one synchronized test after verifying formal state'
  exit 1
fi
if [[ "$server_received" == none && "$observation_valid" != yes ]]; then
  echo 'INVALID no_connection_claim=unsynchronized_observation'
  echo 'NEXT use server-received unknown; read paired client/server logs before changing routes'
  exit 1
fi
if [[ "$vless" == passed && "$reality" != passed ]] ||
   [[ "$exit_state" != unknown && "$vless" != passed ]] ||
   [[ "$server_received" == none && ( "$reality" != unknown || "$vless" != unknown ) ]]; then
  echo 'INVALID contradiction=protocol_evidence'
  exit 1
fi
if [[ "$server_received" == unknown ]]; then
  echo 'BRANCH synchronized_observation'
  echo 'NEXT read the failing client diagnostic and server log for one timed request; do not infer none from a late capture'
  exit 0
fi
if [[ "$server_received" == none ]]; then
  echo 'BRANCH pre_server_path'
  echo 'NEXT verify instance/IP, cloud firewall, physical TUN exclusion, saved node and runtime snapshot'
  exit 0
fi
if [[ "$effective_config" == no ]]; then
  echo 'BRANCH effective_config_unknown'
  echo 'NEXT read the configuration loaded by the running Xray before changing parameters'
  exit 0
fi
if [[ "$isolated_client" == passed && "$native_client" == failed && "$same_parameters" == yes && "$reality" != passed ]]; then
  echo 'BRANCH handshake_compatibility'
  echo 'NEXT compare ClientHello key_share requirements and exact core/client versions; relaxing minClientVer cannot supply missing fields'
  exit 0
fi
case "$reality" in
  failed)
    echo 'BRANCH reality_authentication'
    echo 'NEXT compare credential hashes, SNI, time, key_share features, ClientVer and fallback in paired logs'
    exit 0 ;;
  unknown)
    echo 'BRANCH reality_observability'
    echo 'NEXT read client diagnostics first; if server logs are absent use one watchdog-protected debug window'
    exit 0 ;;
esac
case "$vless" in
  failed)
    echo 'BRANCH vless_xtls'
    echo 'NEXT compare VLESS credential hash, Vision flow, TCP and client serialization'
    exit 0 ;;
  unknown)
    echo 'BRANCH vless_observability'
    echo 'NEXT collect native client and server logs for the same connection'
    exit 0 ;;
esac
case "$exit_state" in
  wrong)
    echo 'BRANCH routing_policy'
    echo 'NEXT inspect rule order, selected config, group delegation and runtime route log' ;;
  unknown)
    echo 'BRANCH business_acceptance'
    echo 'NEXT verify exit and user-selected HTTP targets through the native client' ;;
  expected) echo 'PASS node_path=protocol_and_exit_verified' ;;
esac
