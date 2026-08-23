#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
AZ_BIN="${AZ_BIN:-az}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CHECK_STANDBY_BIN="${CHECK_STANDBY_BIN:-$ROOT/scripts/check-standby-pool.sh}"
CHECK_NAP_BIN="${CHECK_NAP_BIN:-$ROOT/scripts/check-nap-capacity.sh}"
COLLECTOR_SCRIPT="${COLLECTOR_SCRIPT:-$ROOT/scripts/collect-pod-latency.py}"
TEMPLATE_PATH="$ROOT/manifests/benchmark-pod-template.yaml"

EXPECTED_PODS="${EXPECTED_PODS:-5}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-0.25}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
NAP_POD_TIMEOUT_SECONDS="${NAP_POD_TIMEOUT_SECONDS:-900}"
NAP_RESET_TIMEOUT_SECONDS="${NAP_RESET_TIMEOUT_SECONDS:-1200}"
NAP_INTERVAL_SECONDS="${NAP_INTERVAL_SECONDS:-15}"
STANDBY_TIMEOUT_SECONDS="${STANDBY_TIMEOUT_SECONDS:-1200}"
STANDBY_INTERVAL_SECONDS="${STANDBY_INTERVAL_SECONDS:-15}"
NAMESPACE_WAIT_TIMEOUT_SECONDS="${NAMESPACE_WAIT_TIMEOUT_SECONDS:-120}"
NAMESPACE_WAIT_INTERVAL_SECONDS="${NAMESPACE_WAIT_INTERVAL_SECONDS:-2}"
POST_COLLECTOR_RESERVE_SECONDS="${POST_COLLECTOR_RESERVE_SECONDS:-30}"

scenario=""
runs=""
output_dir=""
resource_group=""
standby_pool=""
scenario_timeout_seconds=""
render_only="false"
work_dir=""
scenario_deadline=""
evidence_deadline=""
cleanup_deadline=""

RUN_CREATE_STATUS=0
RUN_COLLECTOR_STATUS=0
RUN_DIAGNOSTICS_STATUS=0
RUN_DELETE_STATUS=0
RUN_WAIT_STATUS=0

usage() {
  cat <<'EOF'
Usage: run-benchmark.sh --scenario NAME --runs N --output-dir DIR [--scenario-timeout-seconds N] [--render-only] [--resource-group RG --standby-pool NAME]
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
    --scenario-timeout-seconds)
      require_value "$1" "${2-}"
      scenario_timeout_seconds="$2"
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

if [[ -n "$scenario_timeout_seconds" ]] \
  && ! [[ "$scenario_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ERROR: --scenario-timeout-seconds must be a positive integer\n' >&2
  exit 64
fi

case "$scenario" in
  aks-nap) node_path="aks-nap" ;;
  vn2-ondemand) node_path="ondemand" ;;
  vn2-standby|vn2-standby-cached) node_path="standby" ;;
  *)
    printf 'ERROR: unsupported scenario: %s\n' "$scenario" >&2
    exit 64
    ;;
esac

collector_timeout="$TIMEOUT_SECONDS"
if [[ "$scenario" == "aks-nap" ]]; then
  collector_timeout="$NAP_POD_TIMEOUT_SECONDS"
fi

if [[ -z "$scenario_timeout_seconds" ]]; then
  case "$scenario" in
    aks-nap)
      scenario_timeout_seconds="$((((NAP_RESET_TIMEOUT_SECONDS * 2) + NAP_POD_TIMEOUT_SECONDS) * runs))"
      ;;
    vn2-standby|vn2-standby-cached)
      scenario_timeout_seconds="$((((STANDBY_TIMEOUT_SECONDS * 2) + TIMEOUT_SECONDS) * runs))"
      ;;
    *)
      scenario_timeout_seconds=$((TIMEOUT_SECONDS * runs))
      ;;
  esac
fi

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  printf 'ERROR: missing manifest template: %s\n' "$TEMPLATE_PATH" >&2
  exit 1
fi

mkdir -p "$output_dir"

scenario_slug="$(printf '%s' "$scenario" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
scenario_slug="${scenario_slug#-}"
scenario_slug="${scenario_slug%-}"

remaining_scenario_seconds() {
  local maximum="$1"
  local remaining="$maximum"

  if [[ -n "$scenario_deadline" ]]; then
    remaining=$((scenario_deadline - SECONDS))
    if (( remaining < 0 )); then
      remaining=0
    fi
    if (( remaining > maximum )); then
      remaining="$maximum"
    fi
  fi

  printf '%s\n' "$remaining"
}

run_with_scenario_deadline() {
  local operation="$1"
  shift

  if [[ -z "$scenario_deadline" ]]; then
    "$@"
    return
  fi

  local remaining status
  remaining="$(remaining_scenario_seconds "$scenario_timeout_seconds")"
  if (( remaining <= 0 )); then
    printf 'ERROR: scenario deadline exceeded before %s\n' "$operation" >&2
    return 124
  fi

  if timeout --signal=KILL "${remaining}s" "$@"; then
    return 0
  else
    status=$?
  fi

  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    printf 'ERROR: scenario deadline exceeded during %s\n' "$operation" >&2
    return 124
  fi
  return "$status"
}

run_with_evidence_deadline() {
  local operation="$1"
  shift

  local remaining status
  remaining=$((evidence_deadline - SECONDS))
  if (( remaining <= 0 )); then
    printf 'ERROR: scenario deadline exceeded before %s\n' "$operation" >&2
    return 124
  fi

  if timeout --signal=KILL "${remaining}s" "$@"; then
    return 0
  else
    status=$?
  fi

  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    printf 'ERROR: scenario deadline exceeded during %s\n' "$operation" >&2
    return 124
  fi
  return "$status"
}

run_with_cleanup_deadline() {
  local operation="$1"
  shift

  local remaining status
  remaining=$((cleanup_deadline - SECONDS))
  if (( remaining <= 0 )); then
    printf 'ERROR: namespace cleanup deadline exceeded before %s\n' "$operation" >&2
    return 124
  fi

  if timeout --signal=KILL "${remaining}s" "$@"; then
    return 0
  else
    status=$?
  fi

  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    printf 'ERROR: namespace cleanup deadline exceeded during %s\n' "$operation" >&2
    return 124
  fi
  return "$status"
}

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
  local output_path="$1"
  local checker_timeout
  if [[ "$node_path" != "standby" ]]; then
    return 0
  fi
  if [[ -z "$resource_group" || -z "$standby_pool" ]]; then
    printf 'ERROR: standby scenarios require --resource-group and --standby-pool\n' >&2
    exit 64
  fi

  : >"$output_path"
  checker_timeout="$(remaining_scenario_seconds "$STANDBY_TIMEOUT_SECONDS")"
  if (( checker_timeout <= 0 )); then
    printf 'ERROR: scenario deadline exceeded before standby capacity check\n' >&2
    return 124
  fi

  run_with_scenario_deadline "standby capacity check" "$CHECK_STANDBY_BIN" \
    --resource-group "$resource_group" \
    --name "$standby_pool" \
    --expect-running 5 \
    --timeout-seconds "$checker_timeout" \
    --interval-seconds "$STANDBY_INTERVAL_SECONDS" >"$output_path"
}

wait_for_nap_zero_capacity() {
  local output_path="$1"
  local checker_timeout
  if [[ "$scenario" != "aks-nap" ]]; then
    return 0
  fi

  : >"$output_path"
  checker_timeout="$(remaining_scenario_seconds "$NAP_RESET_TIMEOUT_SECONDS")"
  if (( checker_timeout <= 0 )); then
    printf 'ERROR: scenario deadline exceeded before NAP capacity check\n' >&2
    return 124
  fi

  run_with_scenario_deadline "NAP capacity check" "$CHECK_NAP_BIN" \
    --name workshop-nap \
    --expect-nodes 0 \
    --expect-nodeclaims 0 \
    --timeout-seconds "$checker_timeout" \
    --interval-seconds "$NAP_INTERVAL_SECONDS" >"$output_path"
}

cleanup_work_dir() {
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    rm -rf "$work_dir"
  fi
}

create_namespace() {
  local namespace="$1"
  run_with_scenario_deadline "namespace creation" \
    "$KUBECTL_BIN" create namespace "$namespace" >/dev/null
}

wait_for_namespace_gone() {
  local namespace="$1"
  local status sleep_timeout

  while true; do
    if run_with_cleanup_deadline "namespace cleanup verification" \
      "$KUBECTL_BIN" get namespace "$namespace" >/dev/null 2>&1; then
      :
    else
      status=$?
      if [[ "$status" -eq 124 ]]; then
        return 124
      fi
      return 0
    fi

    if (( SECONDS >= cleanup_deadline )); then
      printf 'ERROR: namespace %s still exists after %ss\n' \
        "$namespace" "$NAMESPACE_WAIT_TIMEOUT_SECONDS" >&2
      return 1
    fi

    sleep_timeout=$((cleanup_deadline - SECONDS))
    if (( sleep_timeout <= 0 )); then
      printf 'ERROR: namespace cleanup deadline exceeded during verification\n' >&2
      return 124
    fi
    if ! timeout --signal=KILL "${sleep_timeout}s" \
      sleep "$NAMESPACE_WAIT_INTERVAL_SECONDS"; then
      if (( SECONDS >= cleanup_deadline )); then
        printf 'ERROR: namespace cleanup deadline exceeded during verification\n' >&2
        return 124
      fi
    fi
  done
}

write_command_record() {
  local output_path="$1"
  shift
  {
    printf 'command:'
    printf ' %q' "$@"
    printf '\n'
    printf 'exit_status: 0\n'
    printf '%s\n' '--- stdout ---'
    printf '\n%s\n' '--- stderr ---'
  } >"$output_path"
}

capture_command_record() {
  local output_path="$1"
  shift
  local stdout_path="${output_path}.stdout"
  local stderr_path="${output_path}.stderr"
  local status=0

  : >"$stdout_path"
  : >"$stderr_path"

  set +e
  if run_with_evidence_deadline "diagnostic command" \
    "$@" >"$stdout_path" 2>"$stderr_path"; then
    status=0
  else
    status=$?
  fi
  set -e

  {
    printf 'command:'
    printf ' %q' "$@"
    printf '\n'
    printf 'exit_status: %s\n' "$status"
    printf '%s\n' '--- stdout ---'
    cat "$stdout_path"
    printf '\n%s\n' '--- stderr ---'
    cat "$stderr_path"
  } >"$output_path"

  rm -f "$stdout_path" "$stderr_path"
  return "$status"
}

capture_diagnostics() {
  local diagnostics_dir="$1"
  local namespace="$2"
  local status=0
  local command_status=0

  if capture_command_record \
    "$diagnostics_dir/kubectl-describe-pods.txt" \
    "$KUBECTL_BIN" describe pods -n "$namespace"; then
    :
  else
    command_status=$?
    if [[ "$status" -eq 0 ]]; then
      status="$command_status"
    fi
  fi

  if capture_command_record \
    "$diagnostics_dir/kubectl-events.txt" \
    "$KUBECTL_BIN" get events -n "$namespace" --sort-by=.lastTimestamp; then
    :
  else
    command_status=$?
    if [[ "$status" -eq 0 ]]; then
      status="$command_status"
    fi
  fi

  if capture_command_record \
    "$diagnostics_dir/kubectl-nodes.json" \
    "$KUBECTL_BIN" get nodes -o json; then
    :
  else
    command_status=$?
    if [[ "$status" -eq 0 ]]; then
      status="$command_status"
    fi
  fi

  if [[ "$scenario" == "aks-nap" ]]; then
    if capture_command_record \
      "$diagnostics_dir/nap-nodepool.yaml" \
      "$KUBECTL_BIN" get nodepool workshop-nap -o yaml; then
      :
    else
      command_status=$?
      if [[ "$status" -eq 0 ]]; then
        status="$command_status"
      fi
    fi

    if capture_command_record \
      "$diagnostics_dir/nap-nodeclaims.yaml" \
      "$KUBECTL_BIN" get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o yaml; then
      :
    else
      command_status=$?
      if [[ "$status" -eq 0 ]]; then
        status="$command_status"
      fi
    fi

    if capture_command_record \
      "$diagnostics_dir/nap-events.txt" \
      "$KUBECTL_BIN" get events -A --field-selector source=karpenter-events; then
      :
    else
      command_status=$?
      if [[ "$status" -eq 0 ]]; then
        status="$command_status"
      fi
    fi
  fi

  if [[ "$scenario" == vn2-* && -n "$resource_group" ]]; then
    if capture_command_record \
      "$diagnostics_dir/az-container-list.json" \
      "$AZ_BIN" container list --resource-group "$resource_group" --output json; then
      :
    else
      command_status=$?
      if [[ "$status" -eq 0 ]]; then
        status="$command_status"
      fi
    fi
  else
    write_command_record "$diagnostics_dir/az-container-list.json" skipped --resource-group not provided
  fi

  return "$status"
}

run_single_benchmark() {
  local run_number="$1"
  local manifest_path="$2"
  local raw_path="$3"
  local diagnostics_dir="$4"
  local namespace="$5"
  local run_collector_timeout

  RUN_CREATE_STATUS=0
  RUN_COLLECTOR_STATUS=0
  RUN_DIAGNOSTICS_STATUS=0
  RUN_DELETE_STATUS=0
  RUN_WAIT_STATUS=0

  mkdir -p "$(dirname "$raw_path")" "$diagnostics_dir"

  set +e
  create_namespace "$namespace"
  RUN_CREATE_STATUS=$?
  set -e
  if [[ "$RUN_CREATE_STATUS" -ne 0 ]]; then
    rm -f "$manifest_path"
    return "$RUN_CREATE_STATUS"
  fi

  set +e
  run_collector_timeout="$(remaining_scenario_seconds "$collector_timeout")"
  if (( run_collector_timeout <= 0 )); then
    printf 'ERROR: scenario deadline exceeded before collector\n' >&2
    RUN_COLLECTOR_STATUS=124
  else
    run_with_evidence_deadline "collector" \
      "$PYTHON_BIN" "$COLLECTOR_SCRIPT" \
      --scenario "$scenario" \
      --run "$run_number" \
      --namespace "$namespace" \
      --manifest "$manifest_path" \
      --expected-pods "$EXPECTED_PODS" \
      --poll-interval "$POLL_INTERVAL_SECONDS" \
      --timeout-seconds "$run_collector_timeout" \
      --output "$raw_path"
    RUN_COLLECTOR_STATUS=$?
  fi

  if capture_diagnostics "$diagnostics_dir" "$namespace"; then
    RUN_DIAGNOSTICS_STATUS=0
  else
    RUN_DIAGNOSTICS_STATUS=$?
  fi

  cleanup_deadline=$((SECONDS + NAMESPACE_WAIT_TIMEOUT_SECONDS))
  if run_with_cleanup_deadline "namespace deletion" \
    "$KUBECTL_BIN" delete namespace "$namespace" >/dev/null; then
    RUN_DELETE_STATUS=0
  else
    RUN_DELETE_STATUS=$?
  fi
  wait_for_namespace_gone "$namespace"
  RUN_WAIT_STATUS=$?
  cleanup_deadline=""
  rm -f "$manifest_path"
  set -e

  if [[ "$RUN_DIAGNOSTICS_STATUS" -ne 0 ]]; then
    printf 'WARN: one or more diagnostic commands failed for %s run %s\n' \
      "$scenario" "$run_number" >&2
  fi

  if [[ "$RUN_COLLECTOR_STATUS" -ne 0 ]]; then
    return "$RUN_COLLECTOR_STATUS"
  fi
  if [[ "$RUN_DIAGNOSTICS_STATUS" -ne 0 ]]; then
    return "$RUN_DIAGNOSTICS_STATUS"
  fi
  if [[ "$RUN_DELETE_STATUS" -ne 0 ]]; then
    return "$RUN_DELETE_STATUS"
  fi
  if [[ "$RUN_WAIT_STATUS" -ne 0 ]]; then
    return "$RUN_WAIT_STATUS"
  fi

  return 0
}

if [[ "$render_only" == "true" ]]; then
  for run_number in $(seq 1 "$runs"); do
    render_manifest "$run_number" "$output_dir/${scenario}-run-${run_number}.yaml"
  done
  exit 0
fi

scenario_deadline=$((SECONDS + scenario_timeout_seconds))
evidence_deadline=$((scenario_deadline + POST_COLLECTOR_RESERVE_SECONDS))

work_dir="$output_dir/.run-benchmark"
mkdir -p "$work_dir"
trap cleanup_work_dir EXIT

for run_number in $(seq 1 "$runs"); do
  manifest_path="$work_dir/${scenario}-run-${run_number}.yaml"
  raw_path="$output_dir/raw/${scenario}-run-${run_number}.json"
  diagnostics_dir="$output_dir/diagnostics/${scenario}-run-${run_number}"
  namespace="vn2-bench-${scenario_slug}-r${run_number}-$(date +%s)-$$"

  mkdir -p "$diagnostics_dir"

  if wait_for_nap_zero_capacity "$diagnostics_dir/nap-precheck.json"; then
    :
  else
    exit "$?"
  fi

  if wait_for_standby_pool "$diagnostics_dir/standby-precheck.json"; then
    :
  else
    exit "$?"
  fi

  render_manifest "$run_number" "$manifest_path"

  if run_single_benchmark "$run_number" "$manifest_path" "$raw_path" "$diagnostics_dir" "$namespace"; then
    run_status=0
  else
    run_status=$?
  fi

  post_run_standby_status=0
  post_run_nap_status=0
  if [[ "$RUN_CREATE_STATUS" -eq 0 ]]; then
    if wait_for_nap_zero_capacity "$diagnostics_dir/nap-postcheck.json"; then
      :
    else
      post_run_nap_status=$?
    fi

    if wait_for_standby_pool "$diagnostics_dir/standby-postcheck.json"; then
      :
    else
      post_run_standby_status=$?
    fi
  fi

  if [[ "$run_status" -eq 2 ]]; then
    exit 2
  fi
  if [[ "$run_status" -ne 0 ]]; then
    exit "$run_status"
  fi
  if [[ "$post_run_standby_status" -ne 0 ]]; then
    exit "$post_run_standby_status"
  fi
  if [[ "$post_run_nap_status" -ne 0 ]]; then
    exit "$post_run_nap_status"
  fi
done

trap - EXIT
cleanup_work_dir
