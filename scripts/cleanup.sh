#!/usr/bin/env bash
set -euo pipefail

AZ_BIN="${AZ_BIN:-az}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
HELM_BIN="${HELM_BIN:-helm}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
DELETE_TIMEOUT_SECONDS="${DELETE_TIMEOUT_SECONDS:-1200}"

resource_group="${RESOURCE_GROUP:-${RG:-}}"
ondemand_namespace="${ONDEMAND_NAMESPACE:-vn2-ondemand}"
standby_namespace="${STANDBY_NAMESPACE:-vn2-standby}"
ondemand_release="${ONDEMAND_RELEASE:-}"
standby_release="${STANDBY_RELEASE:-}"
assume_yes="false"

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

fail_with_residuals() {
  local message="$1"
  printf 'ERROR: %s\n' "$message" >&2
  show_residual_ids
  exit 1
}

group_exists() {
  local output
  output="$("$AZ_BIN" group exists --name "$resource_group")"
  [[ "$output" == "true" ]]
}

resolve_standby_pools() {
  local output status
  set +e
  output="$("$AZ_BIN" standby-container-group-pool list --resource-group "$resource_group" --query '[].name' --output tsv 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    if group_exists; then
      die "failed to list standby pools in $resource_group: $output"
    fi
    printf 'INFO: resource group %s already absent.\n' "$resource_group"
    exit 0
  fi

  standby_pools=()
  if [[ -n "$output" ]]; then
    mapfile -t standby_pools < <(printf '%s\n' "$output")
  fi
}

run_tolerant() {
  local description="$1"
  shift
  local output status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    operation_failures+=("$description: ${output:-command failed}")
  fi
}

prompt_for_confirmation() {
  local subscription_id pools_display confirmation
  local -a prompt_pools=("$@")

  subscription_id="$("$AZ_BIN" account show --query id --output tsv)"
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

  {
    printf 'One or more cleanup steps failed before resource group deletion:\n'
    printf '%s\n' "${operation_failures[@]}"
  } >&2
  fail_with_residuals "cleanup aborted before deleting resource group $resource_group"
}

wait_for_resource_group_gone() {
  local started_at exists_output
  started_at="$SECONDS"

  while true; do
    exists_output="$("$AZ_BIN" group exists --name "$resource_group")"
    if [[ "$exists_output" == "false" ]]; then
      printf 'Cleanup completed.\n'
      return 0
    fi
    if (( SECONDS - started_at >= DELETE_TIMEOUT_SECONDS )); then
      fail_with_residuals "resource group $resource_group still exists after ${DELETE_TIMEOUT_SECONDS}s"
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

if [[ "$assume_yes" != "true" ]]; then
  resolve_standby_pools
  prompt_for_confirmation "${standby_pools[@]}"
fi

run_tolerant "delete namespace benchmark" \
  "$KUBECTL_BIN" delete namespace benchmark --ignore-not-found=true --wait=false
run_tolerant "delete namespace vn2-image-cache" \
  "$KUBECTL_BIN" delete namespace vn2-image-cache --ignore-not-found=true --wait=false
run_tolerant "uninstall Helm release $standby_release" \
  "$HELM_BIN" uninstall "$standby_release" --namespace "$standby_namespace" --ignore-not-found
run_tolerant "uninstall Helm release $ondemand_release" \
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
  pool_delete_output="$("$AZ_BIN" standby-container-group-pool delete --resource-group "$resource_group" --name "$pool_name" --yes 2>&1)"
  pool_delete_status=$?
  set -e
  if [[ "$pool_delete_status" -ne 0 ]]; then
    fail_with_residuals "failed to delete standby pool $pool_name: ${pool_delete_output:-command failed}"
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
