#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
AZ_BIN="${AZ_BIN:-az}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CHECK_STANDBY_BIN="${CHECK_STANDBY_BIN:-$ROOT/scripts/check-standby-pool.sh}"
COLLECTOR_SCRIPT="${COLLECTOR_SCRIPT:-$ROOT/scripts/collect-pod-latency.py}"
TEMPLATE_PATH="$ROOT/manifests/benchmark-pod-template.yaml"

EXPECTED_PODS="${EXPECTED_PODS:-5}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-0.25}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
STANDBY_TIMEOUT_SECONDS="${STANDBY_TIMEOUT_SECONDS:-1200}"
STANDBY_INTERVAL_SECONDS="${STANDBY_INTERVAL_SECONDS:-15}"
NAMESPACE_WAIT_TIMEOUT_SECONDS="${NAMESPACE_WAIT_TIMEOUT_SECONDS:-120}"
NAMESPACE_WAIT_INTERVAL_SECONDS="${NAMESPACE_WAIT_INTERVAL_SECONDS:-2}"

scenario=""
runs=""
output_dir=""
resource_group=""
standby_pool=""
render_only="false"

usage() {
  cat <<'EOF'
Usage: run-benchmark.sh --scenario NAME --runs N --output-dir DIR [--render-only] [--resource-group RG --standby-pool NAME]
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
    --scenario)
      require_value "$1" "${2-}"
      scenario="$2"
      shift 2
      ;;
    --runs)
      require_value "$1" "${2-}"
      runs="$2"
      shift 2
      ;;
    --output-dir)
      require_value "$1" "${2-}"
      output_dir="$2"
      shift 2
      ;;
    --resource-group)
      require_value "$1" "${2-}"
      resource_group="$2"
      shift 2
      ;;
    --standby-pool)
      require_value "$1" "${2-}"
      standby_pool="$2"
      shift 2
      ;;
    --render-only)
      render_only="true"
      shift
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

for required in scenario runs output_dir; do
  if [[ -z "${!required}" ]]; then
    printf 'ERROR: missing required argument: %s\n' "$required" >&2
    usage >&2
    exit 64
  fi
done

if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ERROR: --runs must be a positive integer\n' >&2
  exit 64
fi

case "$scenario" in
  aks) node_path="aks" ;;
  vn2-ondemand) node_path="ondemand" ;;
  vn2-standby-uncached|vn2-standby-cached) node_path="standby" ;;
  *)
    printf 'ERROR: unsupported scenario: %s\n' "$scenario" >&2
    exit 64
    ;;
esac

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  printf 'ERROR: missing manifest template: %s\n' "$TEMPLATE_PATH" >&2
  exit 1
fi

mkdir -p "$output_dir"

scenario_slug="$(printf '%s' "$scenario" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
scenario_slug="${scenario_slug#-}"
scenario_slug="${scenario_slug%-}"

render_manifest() {
  local run_number="$1"
  local manifest_path="$2"
  : >"$manifest_path"
  for pod_index in $(seq 1 "$EXPECTED_PODS"); do
    if [[ "$pod_index" -gt 1 ]]; then
      printf -- '---\n' >>"$manifest_path"
    fi
    sed \
      -e "s/@@NAME@@/${scenario}-run-${run_number}-pod-${pod_index}/g" \
      -e "s/@@PATH@@/${node_path}/g" \
      "$TEMPLATE_PATH" >>"$manifest_path"
    printf '\n' >>"$manifest_path"
  done
}

wait_for_standby_pool() {
  if [[ "$node_path" != "standby" ]]; then
    return 0
  fi
  if [[ -z "$resource_group" || -z "$standby_pool" ]]; then
    printf 'ERROR: standby scenarios require --resource-group and --standby-pool\n' >&2
    exit 64
  fi

  "$CHECK_STANDBY_BIN" \
    --resource-group "$resource_group" \
    --name "$standby_pool" \
    --expect-running 5 \
    --timeout-seconds "$STANDBY_TIMEOUT_SECONDS" \
    --interval-seconds "$STANDBY_INTERVAL_SECONDS" >/dev/null
}

create_namespace() {
  local namespace="$1"
  "$KUBECTL_BIN" create namespace "$namespace" >/dev/null
}

wait_for_namespace_gone() {
  local namespace="$1"
  local started_at current_at
  started_at="$(date +%s)"

  while "$KUBECTL_BIN" get namespace "$namespace" >/dev/null 2>&1; do
    current_at="$(date +%s)"
    if (( current_at - started_at >= NAMESPACE_WAIT_TIMEOUT_SECONDS )); then
      printf 'ERROR: namespace %s still exists after %ss\n' \
        "$namespace" "$NAMESPACE_WAIT_TIMEOUT_SECONDS" >&2
      return 1
    fi
    sleep "$NAMESPACE_WAIT_INTERVAL_SECONDS"
  done
}

capture_output() {
  local output_path="$1"
  shift
  "$@" >"$output_path"
}

write_aci_listing() {
  local output_path="$1"
  if [[ -n "$resource_group" ]]; then
    capture_output "$output_path" \
      "$AZ_BIN" container list --resource-group "$resource_group" --output json
    return
  fi

  cat >"$output_path" <<'EOF'
{"skipped":"--resource-group not provided"}
EOF
}

run_single_benchmark() {
  local run_number="$1"
  local manifest_path="$2"
  local raw_path="$3"
  local diagnostics_dir="$4"
  local namespace="$5"
  local create_status=0
  local collector_status=0
  local describe_status=0
  local events_status=0
  local nodes_status=0
  local aci_status=0
  local delete_status=0
  local wait_status=0

  mkdir -p "$(dirname "$raw_path")" "$diagnostics_dir"

  set +e
  create_namespace "$namespace"
  create_status=$?
  set -e
  if [[ "$create_status" -ne 0 ]]; then
    rm -f "$manifest_path"
    return "$create_status"
  fi

  set +e
  "$PYTHON_BIN" "$COLLECTOR_SCRIPT" \
    --scenario "$scenario" \
    --run "$run_number" \
    --namespace "$namespace" \
    --manifest "$manifest_path" \
    --expected-pods "$EXPECTED_PODS" \
    --poll-interval "$POLL_INTERVAL_SECONDS" \
    --timeout-seconds "$TIMEOUT_SECONDS" \
    --output "$raw_path"
  collector_status=$?
  capture_output "$diagnostics_dir/kubectl-describe-pods.txt" \
    "$KUBECTL_BIN" describe pods -n "$namespace"
  describe_status=$?
  capture_output "$diagnostics_dir/kubectl-events.txt" \
    "$KUBECTL_BIN" get events -n "$namespace" --sort-by=.lastTimestamp
  events_status=$?
  capture_output "$diagnostics_dir/kubectl-nodes.json" \
    "$KUBECTL_BIN" get nodes -o json
  nodes_status=$?
  write_aci_listing "$diagnostics_dir/az-container-list.json"
  aci_status=$?

  "$KUBECTL_BIN" delete namespace "$namespace" >/dev/null
  delete_status=$?
  wait_for_namespace_gone "$namespace"
  wait_status=$?
  rm -f "$manifest_path"
  set -e

  for status in \
    "$describe_status" \
    "$events_status" \
    "$nodes_status" \
    "$aci_status" \
    "$delete_status" \
    "$wait_status"; do
    if [[ "$status" -ne 0 ]]; then
      return "$status"
    fi
  done

  return "$collector_status"
}

if [[ "$render_only" == "true" ]]; then
  for run_number in $(seq 1 "$runs"); do
    render_manifest "$run_number" "$output_dir/${scenario}-run-${run_number}.yaml"
  done
  exit 0
fi

work_dir="$output_dir/.run-benchmark"
mkdir -p "$work_dir"

for run_number in $(seq 1 "$runs"); do
  wait_for_standby_pool

  manifest_path="$work_dir/${scenario}-run-${run_number}.yaml"
  raw_path="$output_dir/raw/${scenario}-run-${run_number}.json"
  diagnostics_dir="$output_dir/diagnostics/${scenario}-run-${run_number}"
  namespace="vn2-bench-${scenario_slug}-r${run_number}-$(date +%s)-$$"

  render_manifest "$run_number" "$manifest_path"

  if run_single_benchmark "$run_number" "$manifest_path" "$raw_path" "$diagnostics_dir" "$namespace"; then
    run_status=0
  else
    run_status=$?
  fi

  if [[ "$run_status" -eq 2 ]]; then
    exit 2
  fi
  if [[ "$run_status" -ne 0 ]]; then
    exit "$run_status"
  fi
done

rmdir "$work_dir" 2>/dev/null || true
