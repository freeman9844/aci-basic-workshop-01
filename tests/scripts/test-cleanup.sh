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
      "delete namespace vn2-image-cache --ignore-not-found=true --wait=false"|\
      "delete nodepool workshop-nap --ignore-not-found=true --wait=false"|\
      "delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false"|\
      "get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name")
        exit 0
        ;;
    esac
    ;;
  hang-nodepool)
    case "$*" in
      "delete nodepool workshop-nap --ignore-not-found=true"|\
      "delete nodepool workshop-nap --ignore-not-found=true --wait=false")
        sleep 30
        ;;
      "delete namespace benchmark --ignore-not-found=true --wait=false"|\
      "delete namespace vn2-image-cache --ignore-not-found=true --wait=false"|\
      "delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false"|\
      "get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name")
        exit 0
        ;;
    esac
    ;;
  hang-nodeclaims)
    case "$*" in
      "get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name")
        sleep 30
        ;;
      "delete namespace benchmark --ignore-not-found=true --wait=false"|\
      "delete namespace vn2-image-cache --ignore-not-found=true --wait=false"|\
      "delete nodepool workshop-nap --ignore-not-found=true --wait=false"|\
      "delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false")
        exit 0
        ;;
    esac
    ;;
  nodeclaims-remain)
    case "$*" in
      "get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name")
        printf 'nodeclaim.karpenter.sh/workshop-nap-test\n'
        exit 0
        ;;
      "delete namespace benchmark --ignore-not-found=true --wait=false"|\
      "delete namespace vn2-image-cache --ignore-not-found=true --wait=false"|\
      "delete nodepool workshop-nap --ignore-not-found=true --wait=false"|\
      "delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false")
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
  "group show --name rg-test --query name --output tsv")
    case "${AZ_MODE:-success}" in
      success|prompt|env-fallback|stuck|poll-error|pool-delete-fails)
        printf 'rg-test\n'
        ;;
      *)
        printf 'Unexpected group show for AZ_MODE=%s\n' "${AZ_MODE:-}" >&2
        exit 1
        ;;
    esac
    ;;
  "standby-container-group-pool list --resource-group rg-test --query [].name --output tsv")
    case "${AZ_MODE:-success}" in
      success|prompt|env-fallback|stuck|poll-error|pool-delete-fails)
        printf '%s\n' "${AZ_POOL_NAMES:-standby-pool-a}"
        ;;
      *)
        printf 'Unexpected AZ_MODE=%s\n' "${AZ_MODE:-}" >&2
        exit 1
        ;;
    esac
    ;;
  "standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes")
    case "${AZ_MODE:-success}" in
      pool-delete-fails)
        printf 'standby pool delete boom\n' >&2
        exit 12
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  "group delete --name rg-test --yes --no-wait")
    exit 0
    ;;
  "group exists --name rg-test")
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    case "${AZ_MODE:-success}" in
      success|env-fallback)
        if [[ "$count" -eq 1 ]]; then
          printf 'true\n'
        else
          printf 'false\n'
        fi
        ;;
      pool-delete-fails)
        if [[ "$count" -eq 1 ]]; then
          printf 'true\n'
        else
          printf 'false\n'
        fi
        ;;
      prompt)
        printf 'true\n'
        ;;
      missing-rg)
        printf 'false\n'
        ;;
      exists-error)
        printf 'group exists boom\n' >&2
        exit 9
        ;;
      stuck)
        printf 'true\n'
        ;;
      poll-error)
        if [[ "$count" -eq 1 ]]; then
          printf 'true\n'
        else
          printf 'poll exists boom\n' >&2
          exit 10
        fi
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
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
    "az group show --name rg-test --query name --output tsv",
    "kubectl delete namespace benchmark --ignore-not-found=true --wait=false",
    "kubectl delete namespace vn2-image-cache --ignore-not-found=true --wait=false",
    "kubectl delete nodepool workshop-nap --ignore-not-found=true --wait=false",
    "kubectl delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false",
    "kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name",
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
set +e
hanging_kubectl_output="$(timeout 5s env \
  TEST_LOG_DIR="$TMP/logs" \
  AZ_STATE_DIR="$TMP/state" \
  AZ_BIN="$TMP/bin/az" \
  KUBECTL_BIN="$TMP/bin/kubectl" \
  HELM_BIN="$TMP/bin/helm" \
  AZ_MODE=success \
  KUBECTL_MODE=hang-nodepool \
  CLUSTER_CLEANUP_TIMEOUT_SECONDS=1 \
  NAP_ZERO_POLL_INTERVAL_SECONDS=0 \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
hanging_kubectl_status=$?
set -e

[[ "$hanging_kubectl_status" -eq 0 ]]
grep -F 'delete NodePool workshop-nap:' <<<"$hanging_kubectl_output" >/dev/null
grep -F 'Cleanup completed with warnings.' <<<"$hanging_kubectl_output" >/dev/null
grep -F 'az group delete --name rg-test --yes --no-wait' "$TMP/logs/commands.log" >/dev/null

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
hanging_nodeclaims_output="$(timeout 5s env \
  TEST_LOG_DIR="$TMP/logs" \
  AZ_STATE_DIR="$TMP/state" \
  AZ_BIN="$TMP/bin/az" \
  KUBECTL_BIN="$TMP/bin/kubectl" \
  HELM_BIN="$TMP/bin/helm" \
  AZ_MODE=success \
  KUBECTL_MODE=hang-nodeclaims \
  CLUSTER_CLEANUP_TIMEOUT_SECONDS=1 \
  NAP_ZERO_POLL_INTERVAL_SECONDS=0 \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
hanging_nodeclaims_status=$?
set -e

[[ "$hanging_nodeclaims_status" -eq 0 ]]
grep -F 'observe NodeClaim 0 for workshop-nap:' <<<"$hanging_nodeclaims_output" >/dev/null
grep -F 'Cleanup completed with warnings.' <<<"$hanging_nodeclaims_output" >/dev/null
grep -F 'az group delete --name rg-test --yes --no-wait' "$TMP/logs/commands.log" >/dev/null

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
remaining_nodeclaims_output="$(timeout 5s env \
  TEST_LOG_DIR="$TMP/logs" \
  AZ_STATE_DIR="$TMP/state" \
  AZ_BIN="$TMP/bin/az" \
  KUBECTL_BIN="$TMP/bin/kubectl" \
  HELM_BIN="$TMP/bin/helm" \
  AZ_MODE=success \
  KUBECTL_MODE=nodeclaims-remain \
  CLUSTER_CLEANUP_TIMEOUT_SECONDS=1 \
  NAP_ZERO_POLL_INTERVAL_SECONDS=30 \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
remaining_nodeclaims_status=$?
set -e

[[ "$remaining_nodeclaims_status" -eq 0 ]]
grep -F 'observe NodeClaim 0 for workshop-nap:' <<<"$remaining_nodeclaims_output" >/dev/null
grep -F 'Cleanup completed with warnings.' <<<"$remaining_nodeclaims_output" >/dev/null
grep -F 'az group delete --name rg-test --yes --no-wait' "$TMP/logs/commands.log" >/dev/null

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
cluster_unreachable_output="$(run_cleanup \
  AZ_MODE=success \
  KUBECTL_MODE=cluster-missing \
  HELM_MODE=cluster-missing \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
cluster_unreachable_status=$?
set -e

[[ "$cluster_unreachable_status" -eq 0 ]]
grep -F 'WARNING: graceful cluster cleanup failed; continuing with standby pool and resource group deletion.' <<<"$cluster_unreachable_output" >/dev/null
grep -F 'delete namespace benchmark: The connection to the server localhost:6443 was refused' <<<"$cluster_unreachable_output" >/dev/null
grep -F 'delete NodePool workshop-nap: The connection to the server localhost:6443 was refused' <<<"$cluster_unreachable_output" >/dev/null
grep -F 'uninstall Helm release vn2-standby: Kubernetes cluster unreachable' <<<"$cluster_unreachable_output" >/dev/null
grep -F 'Cleanup completed with warnings.' <<<"$cluster_unreachable_output" >/dev/null
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
    "az group show --name rg-test --query name --output tsv",
    "kubectl delete namespace benchmark --ignore-not-found=true --wait=false",
    "kubectl delete namespace vn2-image-cache --ignore-not-found=true --wait=false",
    "kubectl delete nodepool workshop-nap --ignore-not-found=true --wait=false",
    "kubectl delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false",
    "kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name",
    "helm uninstall vn2-standby --namespace vn2-standby --ignore-not-found",
    "helm uninstall vn2-ondemand --namespace vn2-ondemand --ignore-not-found",
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
    "az standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes",
    "az group delete --name rg-test --yes --no-wait",
    "az group exists --name rg-test",
]
if lines != expected:
    raise SystemExit(f"unexpected cluster-unreachable command order: {lines!r}")
PY

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
pool_delete_failure_output="$(run_cleanup \
  AZ_MODE=pool-delete-fails \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
pool_delete_failure_status=$?
set -e

[[ "$pool_delete_failure_status" -eq 0 ]]
grep -F 'WARNING: failed to delete standby pool standby-pool-a; continuing with resource group deletion because the resource group delete can remove child resources.' <<<"$pool_delete_failure_output" >/dev/null
grep -F 'standby pool delete boom' <<<"$pool_delete_failure_output" >/dev/null
grep -F 'Cleanup completed with warnings.' <<<"$pool_delete_failure_output" >/dev/null
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
    "az group show --name rg-test --query name --output tsv",
    "kubectl delete namespace benchmark --ignore-not-found=true --wait=false",
    "kubectl delete namespace vn2-image-cache --ignore-not-found=true --wait=false",
    "kubectl delete nodepool workshop-nap --ignore-not-found=true --wait=false",
    "kubectl delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false",
    "kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name",
    "helm uninstall vn2-standby --namespace vn2-standby --ignore-not-found",
    "helm uninstall vn2-ondemand --namespace vn2-ondemand --ignore-not-found",
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
    "az standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes",
    "az group delete --name rg-test --yes --no-wait",
    "az group exists --name rg-test",
]
if lines != expected:
    raise SystemExit(f"unexpected pool-delete-fails command order: {lines!r}")
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
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
]
if lines != expected:
    raise SystemExit(f"unexpected missing-rg command order: {lines!r}")
PY

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
exists_error_output="$(run_cleanup \
  AZ_MODE=exists-error \
  KUBECTL_MODE=cluster-missing \
  HELM_MODE=cluster-missing \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
exists_error_status=$?
set -e

[[ "$exists_error_status" -ne 0 ]]
grep -F 'Azure CLI error while checking resource group rg-test' <<<"$exists_error_output" >/dev/null
grep -F 'group exists boom' <<<"$exists_error_output" >/dev/null
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
]
if lines != expected:
    raise SystemExit(f"unexpected exists-error command order: {lines!r}")
PY

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
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
    "az group show --name rg-test --query name --output tsv",
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
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
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
    "az group show --name rg-test --query name --output tsv",
    "kubectl delete namespace benchmark --ignore-not-found=true --wait=false",
    "kubectl delete namespace vn2-image-cache --ignore-not-found=true --wait=false",
    "kubectl delete nodepool workshop-nap --ignore-not-found=true --wait=false",
    "kubectl delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false",
    "kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name",
    "helm uninstall vn2-standby --namespace vn2-standby --ignore-not-found",
    "helm uninstall vn2-ondemand --namespace vn2-ondemand --ignore-not-found",
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
    "az standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes",
    "az group delete --name rg-test --yes --no-wait",
    "az group exists --name rg-test",
    "az resource list --resource-group rg-test --query [].id --output tsv",
]
if lines != expected:
    raise SystemExit(f"unexpected stuck command order: {lines!r}")
PY

rm -f "$TMP/logs/commands.log" "$TMP/state/group-exists-count"
set +e
poll_error_output="$(run_cleanup \
  AZ_MODE=poll-error \
  AZ_RESIDUAL_IDS=$'/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.ContainerInstance/containerGroups/cg-a' \
  "$ROOT/scripts/cleanup.sh" \
  --resource-group rg-test \
  --ondemand-namespace vn2-ondemand \
  --standby-namespace vn2-standby \
  --yes 2>&1)"
poll_error_status=$?
set -e

[[ "$poll_error_status" -ne 0 ]]
grep -F 'Azure CLI error while polling resource group rg-test' <<<"$poll_error_output" >/dev/null
grep -F 'poll exists boom' <<<"$poll_error_output" >/dev/null
grep -F '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.ContainerInstance/containerGroups/cg-a' <<<"$poll_error_output" >/dev/null
python3 - "$TMP/logs/commands.log" <<'PY'
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
expected = [
    "az account show --query id --output tsv",
    "az group exists --name rg-test",
    "az group show --name rg-test --query name --output tsv",
    "kubectl delete namespace benchmark --ignore-not-found=true --wait=false",
    "kubectl delete namespace vn2-image-cache --ignore-not-found=true --wait=false",
    "kubectl delete nodepool workshop-nap --ignore-not-found=true --wait=false",
    "kubectl delete aksnodeclass workshop-nap --ignore-not-found=true --wait=false",
    "kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o name",
    "helm uninstall vn2-standby --namespace vn2-standby --ignore-not-found",
    "helm uninstall vn2-ondemand --namespace vn2-ondemand --ignore-not-found",
    "az standby-container-group-pool list --resource-group rg-test --query [].name --output tsv",
    "az standby-container-group-pool delete --resource-group rg-test --name standby-pool-a --yes",
    "az group delete --name rg-test --yes --no-wait",
    "az group exists --name rg-test",
    "az resource list --resource-group rg-test --query [].id --output tsv",
]
if lines != expected:
    raise SystemExit(f"unexpected poll-error command order: {lines!r}")
PY
