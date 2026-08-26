#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
AZ_BIN="${AZ_BIN:-az}"
CHECK_STANDBY_BIN="${CHECK_STANDBY_BIN:-$ROOT/scripts/check-standby-pool.sh}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
STANDBY_TIMEOUT_SECONDS="${STANDBY_TIMEOUT_SECONDS:-1200}"
NAMESPACE_WAIT_TIMEOUT_SECONDS="${NAMESPACE_WAIT_TIMEOUT_SECONDS:-120}"
TEMPLATE_PATH="$ROOT/manifests/hands-on-pod-template.yaml"

scenario=""
resource_group=""
standby_pool=""
output_dir=""

status=""
failure_reason=""
final_exit_code=0
node_name=""
started_at=""
started_ms=""
ready_at=""
elapsed_ms=0
elapsed_recorded="false"
cleanup_status="not-created"
cleanup_reason=""
namespace_create_attempted="false"
namespace_created="false"
diagnostic_failures=()

usage() {
  cat <<'EOF'
Usage: run-hands-on.sh --scenario vn2-ondemand|vn2-standby|vn2-standby-cached --resource-group RG [--standby-pool NAME] --output-dir DIR
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

require_command() {
  local label="$1"
  local command_name="$2"
  if [[ "$command_name" == */* ]]; then
    if [[ ! -x "$command_name" ]]; then
      printf 'ERROR: missing %s executable: %s\n' "$label" "$command_name" >&2
      exit 1
    fi
  elif ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: missing %s executable: %s\n' "$label" "$command_name" >&2
    exit 1
  fi
}

require_file() {
  local label="$1"
  local path="$2"
  if [[ ! -f "$path" ]]; then
    printf 'ERROR: missing %s: %s\n' "$label" "$path" >&2
    exit 1
  fi
}

update_elapsed_ms() {
  if [[ -n "$started_ms" ]]; then
    elapsed_ms="$(($(date -u +%s%3N) - started_ms))"
    elapsed_recorded="true"
  fi
}

record_failure() {
  local reason="$1"
  local code="${2:-1}"

  if [[ -z "$status" ]]; then
    status="failed"
  fi
  if [[ -z "$failure_reason" ]]; then
    failure_reason="$reason"
  fi
  if [[ "$final_exit_code" -eq 0 ]]; then
    final_exit_code="$code"
  fi
}

json_value_or_null() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    jq -Rn --arg value "$value" '$value'
  else
    printf 'null'
  fi
}

json_file_or_null() {
  local path="$1"
  if [[ -s "$path" ]] && jq -e . "$path" >/dev/null 2>&1; then
    cat "$path"
  else
    printf 'null'
  fi
}

check_standby() {
  local output_path="$1"
  "$CHECK_STANDBY_BIN" \
    --resource-group "$resource_group" \
    --name "$standby_pool" \
    --expect-running 1 \
    --timeout-seconds "$STANDBY_TIMEOUT_SECONDS" \
    --interval-seconds 15 >"$output_path"
}

capture_diagnostic() {
  local label="$1"
  local output_path="$2"
  shift 2
  local diagnostic_output diagnostic_status
  set +e
  diagnostic_output="$("$@" 2>&1)"
  diagnostic_status=$?
  set -e
  printf '%s\n' "$diagnostic_output" >"$output_path"
  if [[ "$diagnostic_status" -ne 0 ]]; then
    diagnostic_failures+=("$label: ${diagnostic_output:-command failed}")
  fi
}

capture_diagnostics() {
  if [[ "$namespace_created" != "true" ]]; then
    return 0
  fi

  capture_diagnostic pod-json "$evidence_dir/pod.json" \
    "$KUBECTL_BIN" get pod "$pod_name" -n "$namespace" -o json
  capture_diagnostic pod-yaml "$evidence_dir/pod-live.yaml" \
    "$KUBECTL_BIN" get pod "$pod_name" -n "$namespace" -o yaml
  capture_diagnostic events "$evidence_dir/events.txt" \
    "$KUBECTL_BIN" get events -n "$namespace" --sort-by=.metadata.creationTimestamp
  capture_diagnostic nodes "$evidence_dir/nodes.json" \
    "$KUBECTL_BIN" get nodes -o json
  capture_diagnostic aci-inventory "$evidence_dir/aci-inventory.json" \
    "$AZ_BIN" container list --resource-group "$resource_group" --output json
}

wait_for_namespace_deleted() {
  local deadline=$((SECONDS + NAMESPACE_WAIT_TIMEOUT_SECONDS))
  local output get_status

  while true; do
    set +e
    output="$("$KUBECTL_BIN" get namespace "$namespace" 2>&1)"
    get_status=$?
    set -e

    if [[ "$get_status" -ne 0 ]]; then
      if grep -Eiq '\(NotFound\)|not found' <<<"$output"; then
        return 0
      fi
      cleanup_reason="Namespace cleanup verification failed: ${output:-kubectl get namespace failed}"
      return "$get_status"
    fi

    if (( SECONDS >= deadline )); then
      cleanup_reason="Namespace cleanup timed out after ${NAMESPACE_WAIT_TIMEOUT_SECONDS}s"
      return 1
    fi

    sleep 2
  done
}

perform_cleanup() {
  local delete_output delete_status

  if [[ "$namespace_create_attempted" != "true" ]]; then
    cleanup_status="not-created"
    cleanup_reason=""
    return 0
  fi

  set +e
  delete_output="$("$KUBECTL_BIN" delete namespace "$namespace" 2>&1)"
  delete_status=$?
  set -e

  if wait_for_namespace_deleted; then
    cleanup_status="deleted"
    cleanup_reason=""
    return 0
  fi

  cleanup_status="failed"
  if [[ -z "$cleanup_reason" ]]; then
    cleanup_reason="Namespace cleanup failed: ${delete_output:-kubectl delete namespace failed}"
  elif [[ "$delete_status" -ne 0 && -n "$delete_output" ]]; then
    cleanup_reason="$cleanup_reason; delete command: $delete_output"
  fi
  return 1
}

write_observation() {
  local node_name_json started_at_json ready_at_json failure_reason_json cleanup_reason_json
  local standby_pre_json standby_post_json standby_pool_json

  node_name_json="$(json_value_or_null "$node_name")"
  started_at_json="$(json_value_or_null "$started_at")"
  ready_at_json="$(json_value_or_null "$ready_at")"
  failure_reason_json="$(json_value_or_null "$failure_reason")"
  cleanup_reason_json="$(json_value_or_null "$cleanup_reason")"
  standby_pre_json="$(json_file_or_null "$standby_pre_path")"
  standby_post_json="$(json_file_or_null "$standby_post_path")"
  standby_pool_json="$(jq -n --argjson pre "$standby_pre_json" --argjson post "$standby_post_json" '{pre: $pre, post: $post}')"

  jq -n \
    --arg scenario "$scenario" \
    --arg namespace "$namespace" \
    --arg pod_name "$pod_name" \
    --argjson node_name "$node_name_json" \
    --argjson started_at "$started_at_json" \
    --argjson ready_at "$ready_at_json" \
    --argjson elapsed_ms "$elapsed_ms" \
    --arg status "$status" \
    --argjson failure_reason "$failure_reason_json" \
    --arg evidence_dir "$evidence_dir" \
    --argjson standby_pool "$standby_pool_json" \
    --arg cleanup_status "$cleanup_status" \
    --argjson cleanup_reason "$cleanup_reason_json" \
    '{
      schema_version: 1,
      scenario: $scenario,
      namespace: $namespace,
      pod_name: $pod_name,
      node_name: $node_name,
      started_at: $started_at,
      ready_at: $ready_at,
      elapsed_ms: $elapsed_ms,
      status: $status,
      failure_reason: $failure_reason,
      evidence_dir: $evidence_dir,
      standby_pool: $standby_pool,
      cleanup: {
        status: $cleanup_status,
        reason: $cleanup_reason
      }
    }' >"$observation_path"
}

finalize_run() {
  capture_diagnostics

  if [[ "$status" == "ready" && "${#diagnostic_failures[@]}" -gt 0 ]]; then
    status="failed"
    failure_reason="Diagnostic capture failed: ${diagnostic_failures[0]}"
    if [[ "$final_exit_code" -eq 0 ]]; then
      final_exit_code=1
    fi
  fi

  if ! perform_cleanup; then
    if [[ "$status" == "ready" ]]; then
      status="failed"
      failure_reason="$cleanup_reason"
      if [[ "$final_exit_code" -eq 0 ]]; then
        final_exit_code=1
      fi
    elif [[ -z "$failure_reason" && -n "$cleanup_reason" ]]; then
      failure_reason="$cleanup_reason"
    fi
  fi

  if [[ -z "$status" ]]; then
    record_failure "Run ended without a terminal status" 1
  fi

  if [[ -z "$ready_at" && "$elapsed_recorded" != "true" ]]; then
    update_elapsed_ms
  fi

  if [[ "$status" != "ready" && "$final_exit_code" -eq 0 ]]; then
    final_exit_code=1
  fi

  write_observation

  if [[ "$status" == "ready" ]]; then
    printf '%s Pod became Ready in %s seconds.\n' "$scenario" "$(awk "BEGIN {printf \"%.1f\", $elapsed_ms / 1000}")"
    printf 'This is one workshop observation, not a benchmark or SLA.\n'
    exit 0
  fi

  printf 'ERROR: %s\n' "$failure_reason" >&2
  exit "$final_exit_code"
}

poll_until_ready() {
  local pod_json poll_status phase phase_status node_name_candidate node_status ready ready_status
  local timeout_ms=$((TIMEOUT_SECONDS * 1000))

  while true; do
    set +e
    pod_json="$("$KUBECTL_BIN" get pod "$pod_name" -n "$namespace" -o json 2>&1)"
    poll_status=$?
    set -e
    if [[ "$poll_status" -ne 0 ]]; then
      update_elapsed_ms
      record_failure "Pod polling failed: ${pod_json:-kubectl get pod failed}" "$poll_status"
      return
    fi

    set +e
    phase="$(jq -r '.status.phase // "Unknown"' <<<"$pod_json")"
    phase_status=$?
    node_name_candidate="$(jq -r '.spec.nodeName // ""' <<<"$pod_json")"
    node_status=$?
    ready="$(jq -r '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0' <<<"$pod_json")"
    ready_status=$?
    set -e

    if [[ "$phase_status" -ne 0 || "$node_status" -ne 0 || "$ready_status" -ne 0 ]]; then
      update_elapsed_ms
      record_failure "Pod status parsing failed" 1
      return
    fi

    node_name="$node_name_candidate"
    elapsed_ms="$(($(date -u +%s%3N) - started_ms))"
    elapsed_recorded="true"
    printf '%s phase=%s node=%s ready=%s elapsed=%sms\n' "$scenario" "$phase" "${node_name:-unscheduled}" "$ready" "$elapsed_ms"

    if [[ "$ready" == "true" ]]; then
      status="ready"
      ready_at="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      return
    fi

    if (( elapsed_ms >= timeout_ms )); then
      status="timeout"
      failure_reason="Pod did not become Ready within ${TIMEOUT_SECONDS}s"
      if [[ "$final_exit_code" -eq 0 ]]; then
        final_exit_code=1
      fi
      return
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

while (($#)); do
  case "$1" in
    --scenario)
      require_value "$1" "${2-}"
      scenario="$2"
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
    --output-dir)
      require_value "$1" "${2-}"
      output_dir="$2"
      shift 2
      ;;
    --runs|--pod-count|--percentile|--baseline)
      printf 'ERROR: unsupported argument: %s\n' "$1" >&2
      usage >&2
      exit 64
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

for required in scenario resource_group output_dir; do
  if [[ -z "${!required}" ]]; then
    printf 'ERROR: missing required argument: %s\n' "$required" >&2
    usage >&2
    exit 64
  fi
done

case "$scenario" in
  vn2-ondemand)
    node_path="ondemand"
    ;;
  vn2-standby|vn2-standby-cached)
    node_path="standby"
    ;;
  *)
    printf 'ERROR: unsupported scenario: %s\n' "$scenario" >&2
    exit 64
    ;;
esac

if [[ "$node_path" == "standby" && -z "$standby_pool" ]]; then
  printf 'ERROR: standby scenarios require --standby-pool\n' >&2
  usage >&2
  exit 64
fi

require_command "jq" jq
require_command "kubectl" "$KUBECTL_BIN"
require_command "Azure CLI" "$AZ_BIN"
require_command "standby checker" "$CHECK_STANDBY_BIN"
require_file "manifest template" "$TEMPLATE_PATH"

attempt_id="$(date -u +%Y%m%dt%H%M%Sz)-$$"
namespace="vn2-hands-on-${scenario#vn2-}-$attempt_id"
pod_name="$scenario"
observations_dir="$output_dir/observations"
evidence_dir="$output_dir/evidence/${scenario}-$attempt_id"
observation_path="$observations_dir/$scenario.json"
manifest_path="$evidence_dir/pod.yaml"
standby_pre_path="$evidence_dir/standby-pre.json"
standby_post_path="$evidence_dir/standby-post.json"

mkdir -p "$observations_dir" "$evidence_dir"

sed \
  -e "s/@@NAME@@/$pod_name/g" \
  -e "s/@@PATH@@/$node_path/g" \
  "$TEMPLATE_PATH" >"$manifest_path"

if [[ "$node_path" == "standby" ]]; then
  set +e
  check_standby "$standby_pre_path"
  standby_status=$?
  set -e
  if [[ "$standby_status" -ne 0 ]]; then
    record_failure "Standby pool precheck failed (exit $standby_status)" "$standby_status"
  fi
fi

if [[ -z "$status" ]]; then
  namespace_create_attempted="true"
  set +e
  create_output="$("$KUBECTL_BIN" create namespace "$namespace" 2>&1)"
  create_status=$?
  set -e
  if [[ "$create_status" -ne 0 ]]; then
    record_failure "Namespace creation failed: ${create_output:-kubectl create namespace failed}" "$create_status"
  else
    namespace_created="true"
  fi
fi

if [[ -z "$status" ]]; then
  started_at="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  started_ms="$(date -u +%s%3N)"

  set +e
  apply_output="$("$KUBECTL_BIN" apply -n "$namespace" -f "$manifest_path" 2>&1)"
  apply_status=$?
  set -e
  if [[ "$apply_status" -ne 0 ]]; then
    update_elapsed_ms
    record_failure "Pod apply failed: ${apply_output:-kubectl apply failed}" "$apply_status"
  fi
fi

if [[ -z "$status" ]]; then
  poll_until_ready
fi

if [[ "$status" == "ready" && "$node_path" == "standby" ]]; then
  set +e
  check_standby "$standby_post_path"
  standby_status=$?
  set -e
  if [[ "$standby_status" -ne 0 ]]; then
    status="failed"
    failure_reason="Standby pool postcheck failed (exit $standby_status)"
    if [[ "$final_exit_code" -eq 0 ]]; then
      final_exit_code="$standby_status"
    fi
  fi
fi

finalize_run
