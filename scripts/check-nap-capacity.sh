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

for numeric in expect_nodes expect_nodeclaims timeout_seconds interval_seconds; do
  if [[ ! "${!numeric}" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: %s must be a non-negative integer\n' "$numeric" >&2
    exit 64
  fi
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

while true; do
  if ! node_pool_json="$(kubectl get nodepool "$node_pool" -o json)"; then
    printf 'ERROR: Failed to get NodePool %s\n' "$node_pool" >&2
    emit_status "missing" 0 0 false
    exit 2
  fi

  if ! nodes_json="$(kubectl get nodes -l "karpenter.sh/nodepool=$node_pool" -o json)"; then
    printf 'ERROR: Failed to get Nodes for NodePool %s\n' "$node_pool" >&2
    emit_status "error" 0 0 false
    exit 2
  fi

  if ! nodeclaims_json="$(kubectl get nodeclaims -l "karpenter.sh/nodepool=$node_pool" -o json)"; then
    printf 'ERROR: Failed to get NodeClaims for NodePool %s\n' "$node_pool" >&2
    emit_status "error" 0 0 false
    exit 2
  fi

  ready_condition="$(jq -r '
    [.status.conditions[]? | select(.type == "Ready") | .status] | last // ""
  ' <<<"$node_pool_json")"
  latest_nodes="$(jq -r '.items | length' <<<"$nodes_json")"
  latest_nodeclaims="$(jq -r '.items | length' <<<"$nodeclaims_json")"

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
