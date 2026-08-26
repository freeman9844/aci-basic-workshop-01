#!/usr/bin/env bash
set -euo pipefail

AZ_BIN="${AZ_BIN:-az}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
HELM_BIN="${HELM_BIN:-helm}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
DELETE_TIMEOUT_SECONDS="${DELETE_TIMEOUT_SECONDS:-1200}"
CLUSTER_CLEANUP_TIMEOUT_SECONDS="${CLUSTER_CLEANUP_TIMEOUT_SECONDS:-30}"
STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS="${STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS:-30}"

resource_group="${RESOURCE_GROUP:-${RG:-}}"
ondemand_namespace="${ONDEMAND_NAMESPACE:-vn2-ondemand}"
standby_namespace="${STANDBY_NAMESPACE:-vn2-standby}"
ondemand_release="${ONDEMAND_RELEASE:-}"
standby_release="${STANDBY_RELEASE:-}"
assume_yes="false"
subscription_id=""
resolved_resource_group=""
group_exists_result=""
group_exists_error=""

declare -a standby_pools=()
declare -a operation_failures=()

usage() {
  cat <<'EOF'
Usage: cleanup.sh [--resource-group RG] [--ondemand-namespace NAME] [--standby-namespace NAME] [--ondemand-release NAME] [--standby-release NAME] [--yes]
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
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
    --resource-group)
      require_value "$1" "${2-}"
      resource_group="$2"
      shift 2
      ;;
    --ondemand-namespace)
      require_value "$1" "${2-}"
      ondemand_namespace="$2"
      shift 2
      ;;
    --standby-namespace)
      require_value "$1" "${2-}"
      standby_namespace="$2"
      shift 2
      ;;
    --ondemand-release)
      require_value "$1" "${2-}"
      ondemand_release="$2"
      shift 2
      ;;
    --standby-release)
      require_value "$1" "${2-}"
      standby_release="$2"
      shift 2
      ;;
    --yes)
      assume_yes="true"
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

ondemand_release="${ondemand_release:-$ondemand_namespace}"
standby_release="${standby_release:-$standby_namespace}"

for required in resource_group ondemand_namespace standby_namespace ondemand_release standby_release; do
  if [[ -z "${!required}" ]]; then
    printf 'ERROR: missing required argument: %s\n' "$required" >&2
    usage >&2
    exit 64
  fi
done

show_residual_ids() {
  local output status
  set +e
  output="$("$AZ_BIN" resource list --resource-group "$resource_group" --query '[].id' --output tsv 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    printf 'Residual resource IDs could not be resolved: %s\n' "$output" >&2
    return
  fi

  if [[ -z "$output" ]]; then
    printf 'Residual resource IDs: none returned for %s\n' "$resource_group" >&2
    return
  fi

  printf 'Residual resource IDs:\n%s\n' "$output" >&2
}

print_warning_summary() {
  local header="$1"
  if ((${#operation_failures[@]} == 0)); then
    return 0
  fi

  {
    printf '%s\n' "$header"
    printf ' - %s\n' "${operation_failures[@]}"
  } >&2
}

fail_with_residuals() {
  local message="$1"
  print_warning_summary 'Warning summary:'
  printf 'ERROR: %s\n' "$message" >&2
  show_residual_ids
  exit 1
}

resolve_subscription_id() {
  local output status
  set +e
  output="$("$AZ_BIN" account show --query id --output tsv 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    die "Azure CLI error while resolving subscription ID: ${output:-command failed}"
  fi
  if [[ -z "$output" ]]; then
    die "Azure CLI returned an empty subscription ID"
  fi

  subscription_id="$output"
}

check_group_exists() {
  local output status
  set +e
  output="$("$AZ_BIN" group exists --name "$resource_group" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    group_exists_result="error"
    group_exists_error="${output:-command failed}"
    return 0
  fi

  case "$output" in
    true|false)
      group_exists_result="$output"
      group_exists_error=""
      ;;
    *)
      group_exists_result="error"
      group_exists_error="unexpected output: ${output:-<empty>}"
      ;;
  esac
}

resolve_resource_group_target() {
  local output status

  resolve_subscription_id
  check_group_exists

  case "$group_exists_result" in
    false)
      printf 'INFO: resource group %s already absent.\n' "$resource_group"
      exit 0
      ;;
    error)
      die "Azure CLI error while checking resource group $resource_group in subscription $subscription_id: $group_exists_error"
      ;;
  esac

  set +e
  output="$("$AZ_BIN" group show --name "$resource_group" --query name --output tsv 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    die "Azure CLI error while resolving resource group $resource_group in subscription $subscription_id: ${output:-command failed}"
  fi
  if [[ -z "$output" ]]; then
    die "Azure CLI returned an empty resource group name for $resource_group in subscription $subscription_id"
  fi

  resolved_resource_group="$output"
  resource_group="$resolved_resource_group"
}

resolve_standby_pools() {
  local output status
  standby_pools=()

  set +e
  output="$(timeout --signal=KILL "${STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS}s" \
    "$AZ_BIN" standby-container-group-pool list --resource-group "$resource_group" \
    --query '[].name' --output tsv 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    operation_failures+=("discover standby pools in $resource_group: timed out after ${STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS}s")
    printf 'WARNING: standby pool discovery timed out in %s after %ss; continuing without explicit pool deletion because the resource group delete can remove child resources.\n' \
      "$resource_group" "$STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS" >&2
    return 0
  fi
  if [[ "$status" -ne 0 ]]; then
    operation_failures+=("failed to discover standby pools in $resource_group: ${output:-command failed}")
    printf 'WARNING: failed to discover standby pools in %s: %s; continuing without explicit pool deletion because the resource group delete can remove child resources.\n' \
      "$resource_group" "${output:-command failed}" >&2
    return 0
  fi

  if [[ -n "$output" ]]; then
    mapfile -t standby_pools < <(printf '%s\n' "$output")
  fi
}

run_tolerant_bounded() {
  local description="$1"
  shift
  local output status

  set +e
  output="$(timeout --signal=KILL "${CLUSTER_CLEANUP_TIMEOUT_SECONDS}s" "$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    operation_failures+=("$description: timed out after ${CLUSTER_CLEANUP_TIMEOUT_SECONDS}s")
  elif [[ "$status" -ne 0 ]]; then
    operation_failures+=("$description: ${output:-command failed}")
  fi
}

sweep_hands_on_namespaces() {
  local started_at output status elapsed remaining namespace
  started_at="$SECONDS"

  set +e
  output="$(timeout --signal=KILL "${CLUSTER_CLEANUP_TIMEOUT_SECONDS}s" \
    "$KUBECTL_BIN" get namespaces \
    -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    operation_failures+=("discover hands-on namespaces with prefix vn2-hands-on-: timed out after ${CLUSTER_CLEANUP_TIMEOUT_SECONDS}s")
    return
  fi
  if [[ "$status" -ne 0 ]]; then
    operation_failures+=("discover hands-on namespaces with prefix vn2-hands-on-: ${output:-command failed}")
    return
  fi

  while IFS= read -r namespace; do
    if [[ "$namespace" != vn2-hands-on-* ]]; then
      continue
    fi

    elapsed=$((SECONDS - started_at))
    remaining=$((CLUSTER_CLEANUP_TIMEOUT_SECONDS - elapsed))
    if ((remaining <= 0)); then
      operation_failures+=("hands-on namespace sweep: timed out after ${CLUSTER_CLEANUP_TIMEOUT_SECONDS}s before deleting remaining namespaces")
      return
    fi

    set +e
    output="$(timeout --signal=KILL "${remaining}s" \
      "$KUBECTL_BIN" delete namespace "$namespace" \
      --ignore-not-found=true --wait=false 2>&1)"
    status=$?
    set -e

    if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
      operation_failures+=("delete namespace $namespace: timed out after ${CLUSTER_CLEANUP_TIMEOUT_SECONDS}s")
    elif [[ "$status" -ne 0 ]]; then
      operation_failures+=("delete namespace $namespace: ${output:-command failed}")
    fi
  done <<<"$output"
}

prompt_for_confirmation() {
  local pools_display confirmation
  local -a prompt_pools=("$@")

  pools_display='(none found)'
  if ((${#prompt_pools[@]} > 0)); then
    pools_display="$(printf '%s, ' "${prompt_pools[@]}")"
    pools_display="${pools_display%, }"
  fi

  printf 'Subscription ID: %s\n' "$subscription_id"
  printf 'Resource group: %s\n' "$resource_group"
  printf 'Helm releases: %s, %s\n' "$standby_release" "$ondemand_release"
  printf 'Standby pools: %s\n' "$pools_display"
  printf 'type the resource group name exactly to continue: '
  IFS= read -r confirmation
  if [[ "$confirmation" != "$resource_group" ]]; then
    die "confirmation did not match $resource_group"
  fi
}

report_pending_failures_if_any() {
  if ((${#operation_failures[@]} == 0)); then
    return 0
  fi

  printf 'WARNING: graceful cluster cleanup failed; continuing with standby pool and resource group deletion.\n' >&2
}

wait_for_resource_group_gone() {
  local started_at exists_output
  started_at="$SECONDS"

  while true; do
    check_group_exists
    case "$group_exists_result" in
      false)
        if ((${#operation_failures[@]} == 0)); then
          printf 'Cleanup completed.\n'
        else
          printf 'Cleanup completed with warnings.\n'
          print_warning_summary 'Warning summary:'
        fi
        return 0
        ;;
      error)
        fail_with_residuals "Azure CLI error while polling resource group $resource_group: $group_exists_error"
        ;;
    esac
    if (( SECONDS - started_at >= DELETE_TIMEOUT_SECONDS )); then
      fail_with_residuals "resource group $resource_group still exists after ${DELETE_TIMEOUT_SECONDS}s"
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

resolve_resource_group_target

if [[ "$assume_yes" != "true" ]]; then
  resolve_standby_pools
  prompt_for_confirmation "${standby_pools[@]}"
fi

sweep_hands_on_namespaces
run_tolerant_bounded "delete namespace vn2-image-cache" \
  "$KUBECTL_BIN" delete namespace vn2-image-cache --ignore-not-found=true --wait=false

run_tolerant_bounded "uninstall Helm release $standby_release" \
  "$HELM_BIN" uninstall "$standby_release" --namespace "$standby_namespace" --ignore-not-found
run_tolerant_bounded "uninstall Helm release $ondemand_release" \
  "$HELM_BIN" uninstall "$ondemand_release" --namespace "$ondemand_namespace" --ignore-not-found

if [[ "$assume_yes" == "true" ]]; then
  resolve_standby_pools
fi

report_pending_failures_if_any

for pool_name in "${standby_pools[@]}"; do
  if [[ -z "$pool_name" ]]; then
    continue
  fi
  set +e
  pool_delete_output="$(timeout --signal=KILL "${STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS}s" \
    "$AZ_BIN" standby-container-group-pool delete --resource-group "$resource_group" \
    --name "$pool_name" --yes 2>&1)"
  pool_delete_status=$?
  set -e
  if [[ "$pool_delete_status" -eq 124 || "$pool_delete_status" -eq 137 ]]; then
    operation_failures+=("delete standby pool $pool_name: timed out after ${STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS}s")
    printf 'WARNING: standby pool deletion timed out for %s after %ss; continuing with resource group deletion because the resource group delete can remove child resources.\n' \
      "$pool_name" "$STANDBY_POOL_CLEANUP_TIMEOUT_SECONDS" >&2
  elif [[ "$pool_delete_status" -ne 0 ]]; then
    operation_failures+=("failed to delete standby pool $pool_name: ${pool_delete_output:-command failed}")
    printf 'WARNING: failed to delete standby pool %s; continuing with resource group deletion because the resource group delete can remove child resources.\n' "$pool_name" >&2
  fi
done

set +e
group_delete_output="$("$AZ_BIN" group delete --name "$resource_group" --yes --no-wait 2>&1)"
group_delete_status=$?
set -e
if [[ "$group_delete_status" -ne 0 ]]; then
  fail_with_residuals "failed to delete resource group $resource_group: ${group_delete_output:-command failed}"
fi
wait_for_resource_group_gone
