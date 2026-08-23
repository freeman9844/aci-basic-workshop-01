#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/.test-preflight"
RESULTS_DIR="$ROOT/results"
ENVIRONMENT_JSON="$RESULTS_DIR/environment.json"
ORIGINAL_ENVIRONMENT_JSON="$TMP/original-environment.json"
HAD_ORIGINAL_ENVIRONMENT_JSON="0"

cleanup() {
  if [[ "$HAD_ORIGINAL_ENVIRONMENT_JSON" == "1" ]]; then
    mkdir -p "$RESULTS_DIR"
    cp "$ORIGINAL_ENVIRONMENT_JSON" "$ENVIRONMENT_JSON"
  else
    rm -f "$ENVIRONMENT_JSON"
    rmdir "$RESULTS_DIR" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}

trap cleanup EXIT

if [[ -f "$ENVIRONMENT_JSON" ]]; then
  HAD_ORIGINAL_ENVIRONMENT_JSON="1"
  mkdir -p "$TMP"
  cp "$ENVIRONMENT_JSON" "$ORIGINAL_ENVIRONMENT_JSON"
fi

rm -rf "$TMP"
mkdir -p "$TMP/bin" "$TMP/logs"
mkdir -p "$RESULTS_DIR"

cat >"$TMP/bin/az" <<'FAKE_AZ'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/az.log"

case "${1-} ${2-}" in
  "version --output")
    cat "$AZ_VERSION_JSON"
    ;;
  "account show")
    cat "$AZ_ACCOUNT_JSON"
    ;;
  "provider show")
    if [[ "${4-}" == "Microsoft.ContainerInstance" ]]; then
      cat "$AZ_PROVIDER_CI_JSON"
    elif [[ "${4-}" == "Microsoft.StandbyPool" ]]; then
      cat "$AZ_PROVIDER_STANDBY_JSON"
    else
      printf 'Unexpected provider namespace: %s\n' "${4-}" >&2
      exit 1
    fi
    ;;
  "feature show")
    case "${AZ_FEATURE_MODE:-registered}" in
      registered)
        cat "$AZ_FEATURE_JSON"
        ;;
      resource-not-found)
        printf 'ResourceNotFound: feature is no longer exposed\n' >&2
        exit 3
        ;;
      not-registered)
        cat "$AZ_FEATURE_JSON"
        ;;
      *)
        printf 'Unexpected AZ_FEATURE_MODE=%s\n' "${AZ_FEATURE_MODE:-}" >&2
        exit 1
        ;;
    esac
    ;;
  "role assignment")
    cat "$AZ_ROLE_ASSIGNMENTS_JSON"
    ;;
  "vm list-skus")
    cat "$AZ_VM_SKUS_JSON"
    ;;
  "vm list-usage")
    cat "$AZ_VM_USAGE_JSON"
    ;;
  "rest --method")
    expected_url="https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.ContainerInstance/locations/koreacentral/usages?api-version=2025-09-01"
    if [[ "$#" -ne 7 || "${3-}" != "get" || "${4-}" != "--url" || "${5-}" != "$expected_url" || "${6-}" != "--output" || "${7-}" != "json" ]]; then
      printf 'Unexpected az rest call: %s\n' "$*" >&2
      exit 1
    fi
    case "${AZ_ACI_USAGE_MODE:-success}" in
      success)
        cat "$AZ_ACI_USAGE_JSON"
        ;;
      error)
        printf '%s\n' "${AZ_ACI_USAGE_ERROR:-simulated az rest failure}" >&2
        exit "${AZ_ACI_USAGE_STATUS:-1}"
        ;;
      *)
        printf 'Unexpected AZ_ACI_USAGE_MODE=%s\n' "${AZ_ACI_USAGE_MODE:-}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'Unexpected az call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE_AZ
chmod +x "$TMP/bin/az"

cat >"$TMP/bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/kubectl.log"

if [[ "${1-}" == "version" && "${2-}" == "--client" && "${3-}" == "--output" && "${4-}" == "json" ]]; then
  cat "$KUBECTL_VERSION_JSON"
  exit 0
fi

printf 'Unexpected kubectl call: %s\n' "$*" >&2
exit 1
FAKE_KUBECTL
chmod +x "$TMP/bin/kubectl"

cat >"$TMP/bin/helm" <<'FAKE_HELM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/helm.log"

if [[ "${1-}" == "version" && "${2-}" == "--template" ]]; then
  printf '%s\n' "$HELM_VERSION"
  exit 0
fi

printf 'Unexpected helm call: %s\n' "$*" >&2
exit 1
FAKE_HELM
chmod +x "$TMP/bin/helm"

write_file() {
  local path="$1"
  shift
  cat >"$path" <<EOF_INNER
$*
EOF_INNER
}

set_valid_defaults() {
  write_file "$TMP/az-version.json" '{"azure-cli":"2.75.0"}'
  write_file "$TMP/account.json" '{"id":"00000000-0000-0000-0000-000000000001","tenantId":"11111111-1111-1111-1111-111111111111","user":{"name":"workshop-user@example.com","type":"user"}}'
  write_file "$TMP/provider-ci.json" '{"namespace":"Microsoft.ContainerInstance","registrationState":"Registered"}'
  write_file "$TMP/provider-standby.json" '{"namespace":"Microsoft.StandbyPool","registrationState":"Registered"}'
  write_file "$TMP/feature.json" '{"name":"StandbyContainerGroupPoolPreview","properties":{"state":"Registered"}}'
  write_file "$TMP/role-assignments.json" '[{"roleDefinitionName":"Owner","scope":"/providers/Microsoft.Management/managementGroups/example"}]'
  write_file "$TMP/vm-skus.json" '[{"name":"Standard_D8s_v5","locations":["koreacentral"],"restrictions":[]}]'
  write_file "$TMP/vm-usage.json" '[{"name":{"value":"cores","localizedValue":"Total Regional vCPUs"},"currentValue":10,"limit":32}]'
  write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20},{"name":{"value":"StandardSpotCores","localizedValue":"Standard spot SKU cores"},"currentValue":0,"limit":20},{"name":{"value":"StandardK80Cores","localizedValue":"Standard K80 GPU cores"},"currentValue":0,"limit":0},{"name":{"value":"StandardP100Cores","localizedValue":"Standard P100 GPU cores"},"currentValue":0,"limit":0},{"name":{"value":"StandardV100Cores","localizedValue":"Standard V100 GPU cores"},"currentValue":0,"limit":0},{"name":{"value":"DedicatedContainerGroups","localizedValue":"Dedicated container groups"},"currentValue":0,"limit":20},{"name":{"value":"DedicatedCores","localizedValue":"Dedicated cores"},"currentValue":0,"limit":20},{"name":{"value":"ConfidentialContainerGroups","localizedValue":"Confidential container groups"},"currentValue":0,"limit":20},{"name":{"value":"ConfidentialCores","localizedValue":"Confidential cores"},"currentValue":0,"limit":20}]}'
  write_file "$TMP/kubectl-version.json" '{"clientVersion":{"gitVersion":"v1.30.2"}}'
  HELM_VERSION='v3.16.1'
  AZ_FEATURE_MODE='registered'
  AZ_ACI_USAGE_MODE='success'
  AZ_ACI_USAGE_ERROR='simulated az rest failure'
  AZ_ACI_USAGE_STATUS='1'
}

run_preflight() {
  env \
    TEST_LOG_DIR="$TMP/logs" \
    AZ_BIN="$TMP/bin/az" \
    KUBECTL_BIN="$TMP/bin/kubectl" \
    HELM_BIN="$TMP/bin/helm" \
    AZ_VERSION_JSON="$TMP/az-version.json" \
    AZ_ACCOUNT_JSON="$TMP/account.json" \
    AZ_PROVIDER_CI_JSON="$TMP/provider-ci.json" \
    AZ_PROVIDER_STANDBY_JSON="$TMP/provider-standby.json" \
    AZ_FEATURE_JSON="$TMP/feature.json" \
    AZ_FEATURE_MODE="${AZ_FEATURE_MODE-registered}" \
    AZ_ROLE_ASSIGNMENTS_JSON="$TMP/role-assignments.json" \
    AZ_VM_SKUS_JSON="$TMP/vm-skus.json" \
    AZ_VM_USAGE_JSON="$TMP/vm-usage.json" \
    AZ_ACI_USAGE_JSON="$TMP/aci-usage.json" \
    AZ_ACI_USAGE_MODE="${AZ_ACI_USAGE_MODE-success}" \
    AZ_ACI_USAGE_ERROR="${AZ_ACI_USAGE_ERROR-simulated az rest failure}" \
    AZ_ACI_USAGE_STATUS="${AZ_ACI_USAGE_STATUS-1}" \
    KUBECTL_VERSION_JSON="$TMP/kubectl-version.json" \
    HELM_VERSION="${HELM_VERSION-v3.16.1}" \
    "$ROOT/scripts/preflight.sh" \
    --location koreacentral \
    --vm-size Standard_D8s_v5 "$@"
}

set_valid_defaults
write_file "$TMP/az-version.json" '{"azure-cli":"2.74.0"}'
set +e
version_output="$(run_preflight 2>&1)"
version_status=$?
set -e
[[ "$version_status" -ne 0 ]]
grep -F 'Azure CLI 2.75.0 or newer is required' <<<"$version_output" >/dev/null
test ! -e "$ENVIRONMENT_JSON"

set_valid_defaults
success_output="$(run_preflight 2>&1)"
grep -F 'Preflight checks passed.' <<<"$success_output" >/dev/null
test -f "$ENVIRONMENT_JSON"
grep -F 'rest --method get --url https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.ContainerInstance/locations/koreacentral/usages?api-version=2025-09-01 --output json' "$TMP/logs/az.log" >/dev/null
python3 - "$ENVIRONMENT_JSON" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert payload["schema_version"] == 1
assert payload["subscription_id"] == "00000000-0000-0000-0000-000000000001"
assert payload["tenant_id"] == "11111111-1111-1111-1111-111111111111"
assert payload["location"] == "koreacentral"
assert payload["vm_size"] == "Standard_D8s_v5"
assert payload["azure_cli_version"] == "2.75.0"
assert payload["kubectl_version"] == "1.30.2"
assert payload["helm_version"] == "3.16.1"
assert payload["vn2_chart_version"] == "1.3410.26081102"
assert payload["benchmark_image"] == "mcr.microsoft.com/azure-cli@sha256:0df3dcd6f4342770c2f0992c6c6552297fe8433195372fc2438a7c00bf3fd826"
PY
baseline_environment_json="$(cat "$ENVIRONMENT_JSON")"

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"StandardContainerGroups","localizedValue":"Standard SKU container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20}]}'
legacy_success_output="$(run_preflight 2>&1)"
grep -F 'Preflight checks passed.' <<<"$legacy_success_output" >/dev/null
test -f "$ENVIRONMENT_JSON"

set_valid_defaults
write_file "$TMP/vm-skus.json" '[{"name":"Standard_D8s_v5","locations":["koreacentral"],"restrictions":[{"type":"Location","reasonCode":"NotAvailableForSubscription","restrictionInfo":{"locations":["koreacentral"]}}]}]'
set +e
restricted_sku_output="$(run_preflight 2>&1)"
restricted_sku_status=$?
set -e
[[ "$restricted_sku_status" -ne 0 ]]
grep -F 'ERROR: VM size Standard_D8s_v5 is restricted in koreacentral.' <<<"$restricted_sku_output" >/dev/null
grep -F '"reasonCode": "NotAvailableForSubscription"' <<<"$restricted_sku_output" >/dev/null
grep -F '"locations": [' <<<"$restricted_sku_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
AZ_FEATURE_MODE='resource-not-found'
ga_output="$(run_preflight 2>&1)"
grep -F 'StandbyContainerGroupPoolPreview is no longer exposed; Microsoft.StandbyPool provider registration is the GA gate.' <<<"$ga_output" >/dev/null
test -f "$ENVIRONMENT_JSON"

set_valid_defaults
write_file "$TMP/feature.json" '{"name":"StandbyContainerGroupPoolPreview","properties":{"state":"NotRegistered"}}'
set +e
feature_output="$(run_preflight 2>&1)"
feature_status=$?
set -e
[[ "$feature_status" -ne 0 ]]
grep -F 'az feature register --namespace Microsoft.StandbyPool --name StandbyContainerGroupPoolPreview' <<<"$feature_output" >/dev/null

set_valid_defaults
boundary_success_output="$(run_preflight 2>&1)"
grep -F 'Preflight checks passed.' <<<"$boundary_success_output" >/dev/null
test -f "$ENVIRONMENT_JSON"

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":11,"limit":20}]}'
set +e
aci_core_headroom_output="$(run_preflight 2>&1)"
aci_core_headroom_status=$?
set -e
[[ "$aci_core_headroom_status" -ne 0 ]]
grep -F 'ACI StandardCores headroom is 9; need at least 10' <<<"$aci_core_headroom_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":11,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20}]}'
set +e
aci_group_headroom_output="$(run_preflight 2>&1)"
aci_group_headroom_status=$?
set -e
[[ "$aci_group_headroom_status" -ne 0 ]]
grep -F 'ACI container groups headroom is 9; need at least 10' <<<"$aci_group_headroom_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{}'
set +e
aci_missing_value_output="$(run_preflight 2>&1)"
aci_missing_value_status=$?
set -e
[[ "$aci_missing_value_status" -ne 0 ]]
grep -F 'Unexpected ACI usage response shape; refusing to guess.' <<<"$aci_missing_value_output" >/dev/null
grep -F '{}' <<<"$aci_missing_value_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":{"name":{"value":"StandardContainerGroups"},"currentValue":0,"limit":10}}'
set +e
aci_non_array_output="$(run_preflight 2>&1)"
aci_non_array_status=$?
set -e
[[ "$aci_non_array_status" -ne 0 ]]
grep -F 'Unexpected ACI usage response shape; refusing to guess.' <<<"$aci_non_array_output" >/dev/null
grep -F '"value": {' <<<"$aci_non_array_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20}]}'
set +e
aci_missing_group_output="$(run_preflight 2>&1)"
aci_missing_group_status=$?
set -e
[[ "$aci_missing_group_status" -ne 0 ]]
grep -F 'Unexpected ACI usage fields; refusing to guess.' <<<"$aci_missing_group_output" >/dev/null
grep -F '"StandardCores"' <<<"$aci_missing_group_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardContainerGroups","localizedValue":"Standard SKU container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20}]}'
set +e
aci_both_aliases_output="$(run_preflight 2>&1)"
aci_both_aliases_status=$?
set -e
[[ "$aci_both_aliases_status" -ne 0 ]]
grep -F 'Unexpected ACI usage fields; refusing to guess.' <<<"$aci_both_aliases_output" >/dev/null
grep -F '"ContainerGroups"' <<<"$aci_both_aliases_output" >/dev/null
grep -F '"StandardContainerGroups"' <<<"$aci_both_aliases_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":11,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20}]}'
set +e
aci_duplicate_group_output="$(run_preflight 2>&1)"
aci_duplicate_group_status=$?
set -e
[[ "$aci_duplicate_group_status" -ne 0 ]]
grep -F 'Unexpected ACI usage fields; refusing to guess.' <<<"$aci_duplicate_group_output" >/dev/null
grep -F '"ContainerGroups"' <<<"$aci_duplicate_group_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20},{"name":{"value":"UnexpectedQuota","localizedValue":"Unexpected quota"},"currentValue":0,"limit":10}]}'
aci_extra_rows_output="$(run_preflight 2>&1)"
grep -F 'Preflight checks passed.' <<<"$aci_extra_rows_output" >/dev/null
test -f "$ENVIRONMENT_JSON"

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20}]}'
set +e
aci_missing_standard_cores_output="$(run_preflight 2>&1)"
aci_missing_standard_cores_status=$?
set -e
[[ "$aci_missing_standard_cores_status" -ne 0 ]]
grep -F 'Unexpected ACI usage fields; refusing to guess.' <<<"$aci_missing_standard_cores_output" >/dev/null
grep -F '"ContainerGroups"' <<<"$aci_missing_standard_cores_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":11,"limit":20}]}'
set +e
aci_duplicate_standard_cores_output="$(run_preflight 2>&1)"
aci_duplicate_standard_cores_status=$?
set -e
[[ "$aci_duplicate_standard_cores_status" -ne 0 ]]
grep -F 'Unexpected ACI usage fields; refusing to guess.' <<<"$aci_duplicate_standard_cores_output" >/dev/null
grep -F '"StandardCores"' <<<"$aci_duplicate_standard_cores_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20},{"name":{"value":"","localizedValue":"Broken quota row"},"currentValue":0,"limit":10}]}'
set +e
aci_empty_name_output="$(run_preflight 2>&1)"
aci_empty_name_status=$?
set -e
[[ "$aci_empty_name_status" -ne 0 ]]
grep -F 'Unexpected ACI usage response shape; refusing to guess.' <<<"$aci_empty_name_output" >/dev/null
grep -F '"Broken quota row"' <<<"$aci_empty_name_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
write_file "$TMP/aci-usage.json" '{"value":[{"name":{"value":"ContainerGroups","localizedValue":"Container groups"},"currentValue":10,"limit":20},{"name":{"value":"StandardCores","localizedValue":"Standard SKU cores"},"currentValue":10,"limit":20},{"currentValue":0,"limit":10}]}'
set +e
aci_malformed_item_output="$(run_preflight 2>&1)"
aci_malformed_item_status=$?
set -e
[[ "$aci_malformed_item_status" -ne 0 ]]
grep -F 'Unexpected ACI usage response shape; refusing to guess.' <<<"$aci_malformed_item_output" >/dev/null
grep -F '"currentValue": 0' <<<"$aci_malformed_item_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]

set_valid_defaults
AZ_ACI_USAGE_MODE='error'
AZ_ACI_USAGE_ERROR='simulated az rest failure from test'
AZ_ACI_USAGE_STATUS='7'
set +e
aci_rest_error_output="$(run_preflight 2>&1)"
aci_rest_error_status=$?
set -e
[[ "$aci_rest_error_status" -ne 0 ]]
grep -F 'failed to query ACI usage via Azure REST API: simulated az rest failure from test' <<<"$aci_rest_error_output" >/dev/null
[[ "$(cat "$ENVIRONMENT_JSON")" == "$baseline_environment_json" ]]
