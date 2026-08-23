#!/usr/bin/env bash
set -euo pipefail

node_pool=""
expect_nodes=""
expect_nodeclaims=""
timeout_seconds=""
interval_seconds=""

usage() {
  cat <<'EOF'
Usage: check-nap-capacity.sh --name NAME --expect-nodes N --expect-nodeclaims N --timeout-seconds N --interval-seconds N
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    printf 'ERROR: %s requires a value\n' "$option" >&2
    usage >&2
    exit 64
  fi
}

while (($#)); do
  case "$1" in
    --name)
      require_value "$1" "${2-}"
      node_pool="$2"
      shift 2
      ;;
    --expect-nodes)
      require_value "$1" "${2-}"
      expect_nodes="$2"
      shift 2
      ;;
    --expect-nodeclaims)
      require_value "$1" "${2-}"
      expect_nodeclaims="$2"
      shift 2
      ;;
    --timeout-seconds)
      require_value "$1" "${2-}"
      timeout_seconds="$2"
      shift 2
      ;;
    --interval-seconds)
      require_value "$1" "${2-}"
      interval_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

for required in node_pool expect_nodes expect_nodeclaims timeout_seconds interval_seconds; do
  if [[ -z "${!required}" ]]; then
    printf 'ERROR: missing required argument: %s\n' "$required" >&2
    usage >&2
    exit 64
  fi
done

normalize_non_negative_integer() {
  local variable="$1"
  local value="${!variable}"
  local max_value="2147483647"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: %s must be a non-negative integer\n' "$variable" >&2
    exit 64
  fi

  while [[ ${#value} -gt 1 && "${value:0:1}" == "0" ]]; do
    value="${value:1}"
  done

  if [[ ${#value} -gt ${#max_value} ]] \
    || [[ ${#value} -eq ${#max_value} && "$value" > "$max_value" ]]; then
    printf 'ERROR: %s must be in range 0..%s\n' "$variable" "$max_value" >&2
    exit 64
  fi

  printf -v "$variable" '%s' "$value"
}

for numeric in expect_nodes expect_nodeclaims timeout_seconds interval_seconds; do
  normalize_non_negative_integer "$numeric"
done

emit_status() {
  local health="$1"
  local nodes="$2"
  local nodeclaims="$3"
  local ready="$4"

  jq -cn \
    --arg health "$health" \
    --arg node_pool "$node_pool" \
    --argjson nodes "$nodes" \
    --argjson nodeclaims "$nodeclaims" \
    --argjson ready "$ready" \
    '{
      health: $health,
      node_pool: $node_pool,
      nodes: $nodes,
      nodeclaims: $nodeclaims,
      ready: $ready
    }'
}

deadline=$(($(date +%s) + timeout_seconds))
latest_health="missing"
latest_nodes=0
latest_nodeclaims=0
latest_ready=false
probe_output=""

emit_timeout() {
  emit_status "$latest_health" "$latest_nodes" "$latest_nodeclaims" false
  exit 3
}

run_probe() {
  local failure_health="$1"
  local failure_message="$2"
  local now remaining status output
  shift 2

  now="$(date +%s)"
  if ((now >= deadline)); then
    emit_timeout
  fi
  remaining=$((deadline - now))

  if output="$(timeout --signal=KILL "${remaining}s" kubectl "$@")"; then
    status=0
  else
    status=$?
  fi

  now="$(date +%s)"
  if ((status == 124 || status == 137 || now >= deadline)); then
    emit_timeout
  fi
  if ((status != 0)); then
    printf 'ERROR: %s\n' "$failure_message" >&2
    emit_status "$failure_health" 0 0 false
    exit 2
  fi

  probe_output="$output"
}

while true; do
  run_probe "missing" "Failed to get NodePool $node_pool" \
    get nodepool "$node_pool" -o json
  node_pool_json="$probe_output"

  run_probe "error" "Failed to get Nodes for NodePool $node_pool" \
    get nodes -l "karpenter.sh/nodepool=$node_pool" -o json
  nodes_json="$probe_output"

  run_probe "error" "Failed to get NodeClaims for NodePool $node_pool" \
    get nodeclaims -l "karpenter.sh/nodepool=$node_pool" -o json
  nodeclaims_json="$probe_output"

  ready_condition="$(jq -r '
    [.status.conditions[]? | select(.type == "Ready") | .status] | last // ""
  ' <<<"$node_pool_json")"
  latest_nodes="$(jq -r '.items | length' <<<"$nodes_json")"
  latest_nodeclaims="$(jq -r '.items | length' <<<"$nodeclaims_json")"

  now="$(date +%s)"
  if ((now >= deadline)); then
    emit_timeout
  fi

  if [[ "$ready_condition" != "True" ]]; then
    emit_status "degraded" "$latest_nodes" "$latest_nodeclaims" false
    exit 2
  fi

  latest_health="ready"
  if ((latest_nodes == expect_nodes && latest_nodeclaims == expect_nodeclaims)); then
    latest_ready=true
    emit_status "$latest_health" "$latest_nodes" "$latest_nodeclaims" "$latest_ready"
    exit 0
  fi

  latest_ready=false
  now="$(date +%s)"
  if ((now >= deadline)); then
    emit_status "$latest_health" "$latest_nodes" "$latest_nodeclaims" "$latest_ready"
    exit 3
  fi

  remaining=$((deadline - now))
  sleep_seconds="$interval_seconds"
  if ((sleep_seconds > remaining)); then
    sleep_seconds="$remaining"
  fi
  if ((sleep_seconds > 0)); then
    sleep "$sleep_seconds"
  fi
done
