#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/.test-cleanup"

cleanup() {
  rm -rf "$TMP"
}

trap cleanup EXIT
cleanup
mkdir -p "$TMP/bin" "$TMP/logs" "$TMP/state"

cat >"$TMP/bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "$TEST_LOG_DIR/commands.log"

case "${KUBECTL_MODE:-success}" in
  success)
    case "$*" in
      "delete namespace benchmark --ignore-not-found=true --wait=false"|\
      "delete namespace vn2-image-cache --ignore-not-found=true --wait=false")
        exit 0
        ;;
    esac
    ;;
  cluster-missing)
    printf 'The connection to the server localhost:6443 was refused\n' >&2
    exit 1
    ;;
esac

printf 'Unexpected kubectl call: %s\n' "$*" >&2
exit 1
FAKE_KUBECTL
chmod +x "$TMP/bin/kubectl"

cat >"$TMP/bin/helm" <<'FAKE_HELM'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "$TEST_LOG_DIR/commands.log"

case "${HELM_MODE:-success}" in
  success)
    case "$*" in
      "uninstall vn2-standby --namespace vn2-standby --ignore-not-found"|\
      "uninstall vn2-ondemand --namespace vn2-ondemand --ignore-not-found")
        exit 0
        ;;
    esac
    ;;
  cluster-missing)
    printf 'Kubernetes cluster unreachable\n' >&2
    exit 1
    ;;
esac

printf 'Unexpected helm call: %s\n' "$*" >&2
exit 1
FAKE_HELM
chmod +x "$TMP/bin/helm"

cat >"$TMP/bin/az" <<'FAKE_AZ'
#!/usr/bin/env bash
set -euo pipefail
printf 'az %s\n' "$*" >> "$TEST_LOG_DIR/commands.log"

count_file="$AZ_STATE_DIR/group-exists-count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi

case "$*" in
  "account show --query id --output tsv")
    printf '%s\n' "${AZ_SUBSCRIPTION_ID:-00000000-0000-0000-0000-000000000001}"
    ;;
  "standby-container-group-pool list --resource-group rg-test --query [].name --output tsv")
    case "${AZ_MODE:-success}" in
      success|prompt|env-fallback)
        printf '%s\n' "${AZ_POOL_NAMES:-standby-pool-a}"
        ;;
      missing-rg)
        printf 'ResourceGroupNotFound\n' >&2
        exit 3
        ;;
      stuck)
        printf '%s\n' "${AZ_POOL_NAMES:-standby-pool-a}"
        ;;
      *)
        printf 'Unexpected AZ_MODE=%s\n' "${AZ_MODE:-}" >&2
        exit 1
        ;;
    esac
    ;;
  "standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes")
    exit 0
    ;;
  "group delete --name rg-test --yes --no-wait")
    exit 0
    ;;
  "group exists --name rg-test")
    case "${AZ_MODE:-success}" in
      success|env-fallback)
        printf 'false\n'
        ;;
      prompt)
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        if [[ "$count" -eq 1 ]]; then
          printf 'true\n'
        else
          printf 'false\n'
        fi
        ;;
      missing-rg)
        printf 'false\n'
        ;;
      stuck)
        printf 'true\n'
        ;;
      *)
        printf 'Unexpected AZ_MODE=%s\n' "${AZ_MODE:-}" >&2
        exit 1
        ;;
    esac
    ;;
  "resource list --resource-group rg-test --query [].id --output tsv")
    printf '%s\n' "${AZ_RESIDUAL_IDS:-/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.ContainerInstance/containerGroups/cg-a}"
    ;;
  *)
    printf 'Unexpected az call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE_AZ
chmod +x "$TMP/bin/az"

run_cleanup() {
  env \
    TEST_LOG_DIR="$TMP/logs" \
    AZ_STATE_DIR="$TMP/state" \
    AZ_BIN="$TMP/bin/az" \
    KUBECTL_BIN="$TMP/bin/kubectl" \
    HELM_BIN="$TMP/bin/helm" \
    "$@"
}

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
success_output="$(run_cleanup \
  AZ_MODE=success \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes)"

grep -F 'Cleanup completed.' <<<"$success_output" >/dev/null
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "kubectl delete namespace benchmark --ignore-not-found=true --wait=false",
    "kubectl delete namespace vn2-image-cache --ignore-not-found=true --wait=false",
    "helm uninstall vn2-standby --namespace vn2-standby --ignore-not-found",
    "helm uninstall vn2-ondemand --namespace vn2-ondemand --ignore-not-found",
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
    "az standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes",
    "az group delete --name rg-test --yes --no-wait",
    "az group exists --name rg-test",
]
if lines != expected:
    raise SystemExit(f"unexpected command order: {lines!r}")
PY

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
missing_output="$(run_cleanup \
  AZ_MODE=missing-rg \
  KUBECTL_MODE=cluster-missing \
  HELM_MODE=cluster-missing \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes)"

grep -F 'already absent' <<<"$missing_output" >/dev/null

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
prompt_output="$(printf 'wrong-rg\n' | run_cleanup \
  AZ_MODE=prompt \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby 2>&1)"
prompt_status=$?
set -e

[[ "$prompt_status" -ne 0 ]]
grep -F 'Subscription ID: 00000000-0000-0000-0000-000000000001' <<<"$prompt_output" >/dev/null
grep -F 'Resource group: rg-test' <<<"$prompt_output" >/dev/null
grep -F 'Helm releases: vn2-standby, vn2-ondemand' <<<"$prompt_output" >/dev/null
grep -F 'Standby pools: standby-pool-a' <<<"$prompt_output" >/dev/null
grep -F 'type the resource group name exactly' <<<"$prompt_output" >/dev/null
grep -F 'confirmation did not match' <<<"$prompt_output" >/dev/null
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
    "az account show --query id --output tsv",
]
if lines != expected:
    raise SystemExit(f"unexpected prompt command order: {lines!r}")
PY

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
env_output="$(run_cleanup \
  AZ_MODE=env-fallback \
  RG=rg-test \
  "$ROOT/scripts/cleanup.sh" \
  --yes)"

grep -F 'Cleanup completed.' <<<"$env_output" >/dev/null

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
stuck_output="$(run_cleanup \
  AZ_MODE=stuck \
  AZ_RESIDUAL_IDS=$'/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.ContainerInstance/containerGroups/cg-a\n/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-a' \
  DELETE_TIMEOUT_SECONDS=0 \
  POLL_INTERVAL_SECONDS=0 \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
stuck_status=$?
set -e

[[ "$stuck_status" -ne 0 ]]
grep -F 'still exists after 0s' <<<"$stuck_output" >/dev/null
grep -F '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.ContainerInstance/containerGroups/cg-a' <<<"$stuck_output" >/dev/null
grep -F '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-a' <<<"$stuck_output" >/dev/null
