#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AZ_BIN="${AZ_BIN:-az}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
HELM_BIN="${HELM_BIN:-helm}"

MIN_AZ_VERSION="2.75.0"
MIN_KUBECTL_VERSION="1.30.0"
REQUIRED_HELM_MAJOR="3"
REQUIRED_VM_VCPU_HEADROOM="8"
REQUIRED_ACI_GROUP_HEADROOM="10"
REQUIRED_ACI_CORE_HEADROOM="10"
VN2_CHART_VERSION="1.3410.26081102"
BENCHMARK_IMAGE="mcr.microsoft.com/azure-cli@sha256:0df3dcd6f4342770c2f0992c6c6552297fe8433195372fc2438a7c00bf3fd826"

location=""
vm_size=""
environment_tmp=""

usage() {
  cat <<'EOF'
Usage: preflight.sh --location LOCATION --vm-size VM_SIZE
EOF
}

cleanup() {
  if [[ -n "$environment_tmp" && -f "$environment_tmp" ]]; then
    rm -f "$environment_tmp"
  fi
}

trap cleanup EXIT

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

print_json_or_raw() {
  local payload="$1"
  if jq -e '.' >/dev/null 2>&1 <<<"$payload"; then
    jq '.' <<<"$payload" >&2
  else
    printf '%s\n' "$payload" >&2
  fi
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

normalize_version() {
  local version="$1"
  version="${version#v}"
  version="${version%%+*}"
  printf '%s\n' "$version"
}

version_at_least() {
  local actual
  local minimum="$2"
  actual="$(normalize_version "$1")"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    die "required command not found: $name"
  fi
}

jq_string() {
  local json="$1"
  local filter="$2"
  local description="$3"
  local result=""
  local status=0

  set +e
  result="$(jq -r "$filter" <<<"$json" 2>/dev/null)"
  status=$?
  set -e
  if [[ "$status" -ne 0 || -z "$result" || "$result" == "null" ]]; then
    die "failed to parse $description"
  fi
  printf '%s\n' "$result"
}

while (($#)); do
  case "$1" in
    --location)
      require_value "$1" "${2-}"
      location="$2"
      shift 2
      ;;
    --vm-size)
      require_value "$1" "${2-}"
      vm_size="$2"
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

for required in location vm_size; do
  if [[ -z "${!required}" ]]; then
    printf 'ERROR: missing required argument: %s\n' "$required" >&2
    usage >&2
    exit 64
  fi
done

require_command git
require_command jq
require_command python3

az_version_json="$("$AZ_BIN" version --output json)"
azure_cli_version="$(normalize_version "$(jq_string "$az_version_json" '."azure-cli"' 'Azure CLI version')")"
if ! version_at_least "$azure_cli_version" "$MIN_AZ_VERSION"; then
  die "Azure CLI $MIN_AZ_VERSION or newer is required; found $azure_cli_version"
fi

kubectl_version_json="$("$KUBECTL_BIN" version --client --output json)"
kubectl_version="$(normalize_version "$(jq_string "$kubectl_version_json" '.clientVersion.gitVersion' 'kubectl version')")"
if ! version_at_least "$kubectl_version" "$MIN_KUBECTL_VERSION"; then
  die "kubectl $MIN_KUBECTL_VERSION or newer is required; found $kubectl_version"
fi

helm_version_raw="$("$HELM_BIN" version --template '{{ .Version }}')"
helm_version="$(normalize_version "$helm_version_raw")"
helm_major="${helm_version%%.*}"
if [[ "$helm_major" != "$REQUIRED_HELM_MAJOR" ]]; then
  die "Helm major version $REQUIRED_HELM_MAJOR is required; found $helm_version"
fi

account_json="$("$AZ_BIN" account show --output json)"
subscription_id="$(jq_string "$account_json" '.id' 'subscription ID')"
tenant_id="$(jq_string "$account_json" '.tenantId' 'tenant ID')"
principal_name="$(jq_string "$account_json" '.user.name' 'signed-in principal name')"

provider_ci_json="$("$AZ_BIN" provider show --namespace Microsoft.ContainerInstance --output json)"
provider_ci_state="$(jq_string "$provider_ci_json" '.registrationState' 'Microsoft.ContainerInstance registration state')"
if [[ "$provider_ci_state" != "Registered" ]]; then
  die "Microsoft.ContainerInstance must be Registered; found $provider_ci_state"
fi

provider_standby_json="$("$AZ_BIN" provider show --namespace Microsoft.StandbyPool --output json)"
provider_standby_state="$(jq_string "$provider_standby_json" '.registrationState' 'Microsoft.StandbyPool registration state')"
if [[ "$provider_standby_state" != "Registered" ]]; then
  die "Microsoft.StandbyPool must be Registered; found $provider_standby_state"
fi

set +e
feature_output="$("$AZ_BIN" feature show \
  --namespace Microsoft.StandbyPool \
  --name StandbyContainerGroupPoolPreview \
  --output json 2>&1)"
feature_status=$?
set -e

if [[ "$feature_status" -eq 0 ]]; then
  feature_state="$(jq_string "$feature_output" '.properties.state' 'StandbyContainerGroupPoolPreview registration state')"
  if [[ "$feature_state" != "Registered" ]]; then
    die "StandbyContainerGroupPoolPreview is not registered. Run: az feature register --namespace Microsoft.StandbyPool --name StandbyContainerGroupPoolPreview"
  fi
elif grep -qi 'ResourceNotFound' <<<"$feature_output"; then
  printf 'INFO: StandbyContainerGroupPoolPreview is no longer exposed; Microsoft.StandbyPool provider registration is the GA gate.\n' >&2
else
  die "failed to query StandbyContainerGroupPoolPreview: $feature_output"
fi

role_assignments_json="$("$AZ_BIN" role assignment list \
  --assignee "$principal_name" \
  --scope "/subscriptions/$subscription_id" \
  --include-inherited \
  --output json)"
has_owner_role="$(jq_string "$role_assignments_json" 'map(select(.roleDefinitionName == "Owner")) | length > 0' 'Owner role assignments')"
if [[ "$has_owner_role" != "true" ]]; then
  die "signed-in principal must have inherited Owner at subscription scope"
fi

vm_skus_json="$("$AZ_BIN" vm list-skus --location "$location" --resource-type virtualMachines --output json)"
set +e
matching_vm_skus_json="$(jq -c --arg size "$vm_size" --arg location "$location" '
  [
    .[]
    | select((.name // "") == $size)
    | select(
        (
          ((.locations // []) | length) == 0
          and ((.locationInfo // []) | length) == 0
        )
        or (((.locations // []) | map(ascii_downcase) | index($location | ascii_downcase)) != null)
        or (((.locationInfo // []) | map(.location // "" | ascii_downcase) | index($location | ascii_downcase)) != null)
      )
    | {
        name: (.name // ""),
        locations: (.locations // []),
        locationInfo: (.locationInfo // []),
        restrictions: (.restrictions // [])
      }
  ]
' <<<"$vm_skus_json" 2>/dev/null)"
matching_vm_skus_status=$?
set -e
if [[ "$matching_vm_skus_status" -ne 0 || -z "$matching_vm_skus_json" || "$matching_vm_skus_json" == "null" ]]; then
  die "failed to parse VM SKU availability"
fi
matching_vm_skus_count="$(jq_string "$matching_vm_skus_json" 'length' 'matching VM SKU entries')"
if [[ "$matching_vm_skus_count" -eq 0 ]]; then
  die "VM size $vm_size is not available in $location"
fi

unrestricted_vm_sku_count="$(jq_string "$matching_vm_skus_json" '
  map(select((.restrictions // []) | length == 0)) | length
' 'unrestricted VM SKU entries')"
if [[ "$unrestricted_vm_sku_count" -eq 0 ]]; then
  printf 'ERROR: VM size %s is restricted in %s.\n' "$vm_size" "$location" >&2
  printf 'Restriction details:\n' >&2
  jq '.' <<<"$matching_vm_skus_json" >&2
  exit 1
fi

vm_usage_json="$("$AZ_BIN" vm list-usage --location "$location" --output json)"
regional_vcpu_available="$(jq_string "$vm_usage_json" '
  [
    .[]
    | select((.name.value // "") == "cores" or (.name.localizedValue // "") == "Total Regional vCPUs")
    | (.limit - .currentValue)
  ][0]
' 'regional vCPU usage')"
if [[ "$regional_vcpu_available" -lt "$REQUIRED_VM_VCPU_HEADROOM" ]]; then
  die "regional vCPU headroom is $regional_vcpu_available; need at least $REQUIRED_VM_VCPU_HEADROOM"
fi

aci_usage_url="https://management.azure.com/subscriptions/$subscription_id/providers/Microsoft.ContainerInstance/locations/$location/usages?api-version=2025-09-01"
set +e
aci_usage_response="$("$AZ_BIN" rest --method get --url "$aci_usage_url" --output json 2>&1)"
aci_usage_status=$?
set -e
if [[ "$aci_usage_status" -ne 0 ]]; then
  die "failed to query ACI usage via Azure REST API: $aci_usage_response"
fi

if ! jq -e '
  type == "object"
  and ((.value // null) | type == "array")
  and ([.value[]? | (
    type == "object"
    and ((.name? | type) == "object")
    and ((.name.value? | type) == "string")
    and (((.name.value? // "") | length) > 0)
    and ((.currentValue? | type) == "number")
    and ((.limit? | type) == "number")
  )] | all)
' >/dev/null 2>&1 <<<"$aci_usage_response"; then
  printf 'ERROR: Unexpected ACI usage response shape; refusing to guess.\n' >&2
  print_json_or_raw "$aci_usage_response"
  exit 1
fi

aci_usage_json="$(jq -c '.value' <<<"$aci_usage_response")"
aci_relevant_usage_json="$(jq -c '
  {
    group_alias_matches: [
      .[]
      | select(
          (.name.value // "") == "ContainerGroups"
          or (.name.value // "") == "StandardContainerGroups"
        )
    ],
    standard_core_matches: [
      .[]
      | select((.name.value // "") == "StandardCores")
    ]
  }
' <<<"$aci_usage_json")"
aci_group_alias_match_count="$(jq_string "$aci_relevant_usage_json" '.group_alias_matches | length' 'ACI container groups usage matches')"
aci_standard_core_match_count="$(jq_string "$aci_relevant_usage_json" '.standard_core_matches | length' 'ACI StandardCores usage matches')"
if [[ "$aci_group_alias_match_count" -ne 1 || "$aci_standard_core_match_count" -ne 1 ]]; then
  printf 'ERROR: Unexpected ACI usage fields; refusing to guess.\n' >&2
  print_json_or_raw "$aci_usage_response"
  exit 1
fi

aci_group_available="$(jq_string "$aci_relevant_usage_json" '.group_alias_matches[0] | (.limit - .currentValue)' 'ACI container groups usage')"
aci_core_available="$(jq_string "$aci_relevant_usage_json" '.standard_core_matches[0] | (.limit - .currentValue)' 'ACI StandardCores usage')"

if [[ "$aci_group_available" -lt "$REQUIRED_ACI_GROUP_HEADROOM" ]]; then
  die "ACI container groups headroom is $aci_group_available; need at least $REQUIRED_ACI_GROUP_HEADROOM"
fi
if [[ "$aci_core_available" -lt "$REQUIRED_ACI_CORE_HEADROOM" ]]; then
  die "ACI StandardCores headroom is $aci_core_available; need at least $REQUIRED_ACI_CORE_HEADROOM"
fi

results_dir="$ROOT/results"
mkdir -p "$results_dir"
environment_tmp="$results_dir/.environment.json.tmp.$$"
jq -n \
  --arg subscription_id "$subscription_id" \
  --arg tenant_id "$tenant_id" \
  --arg location "$location" \
  --arg vm_size "$vm_size" \
  --arg azure_cli_version "$azure_cli_version" \
  --arg kubectl_version "$kubectl_version" \
  --arg helm_version "$helm_version" \
  --arg vn2_chart_version "$VN2_CHART_VERSION" \
  --arg benchmark_image "$BENCHMARK_IMAGE" \
  '{
    schema_version: 1,
    subscription_id: $subscription_id,
    tenant_id: $tenant_id,
    location: $location,
    vm_size: $vm_size,
    azure_cli_version: $azure_cli_version,
    kubectl_version: $kubectl_version,
    helm_version: $helm_version,
    vn2_chart_version: $vn2_chart_version,
    benchmark_image: $benchmark_image
  }' >"$environment_tmp"
mv "$environment_tmp" "$results_dir/environment.json"
environment_tmp=""

printf 'Preflight checks passed.\n'
