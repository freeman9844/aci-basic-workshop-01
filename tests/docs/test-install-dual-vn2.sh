#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
module = root / "docs/03-install-dual-vn2.md"

if not module.exists():
    raise SystemExit("Missing required document: docs/03-install-dual-vn2.md")

text = module.read_text(encoding="utf-8")

required_strings = [
    "1.3410.26081102",
    "vn2-ondemand",
    "vn2-standby",
    "WORKSHOP_STATE=\"results/workshop.env\"",
    "if [[ ! -f \"$WORKSHOP_STATE\" ]]; then",
    "source \"$WORKSHOP_STATE\"",
    "--namespace vn2-ondemand",
    "--namespace vn2-standby",
    "--create-namespace",
    "admissionControllerReplicaCount=0",
    "sandboxProviderType=OnDemand",
    "sandboxProviderType=StandbyPool",
    "standbyPoolShareType=Node",
    "standbyPool.standbyPoolsCpu=1",
    "standbyPool.standbyPoolsMemory=2",
    "standbyPool.maxReadyCapacity=5",
    "benchmark-path=ondemand",
    "benchmark-path=standby",
    "세 가지 node path",
    "네 가지 benchmark scenario",
    "image cache",
    "pool 상태",
    "cluster-scoped",
    "virtual-node-admission-controller",
    "meta.helm.sh/release-name",
    "meta.helm.sh/release-namespace",
    "kubectl get mutatingwebhookconfiguration virtual-node-admission-controller \\",
    "$RG",
    "`cg`",
    "kubectl config current-context",
    "helm repo add virtualnode",
    "https://microsoft.github.io/virtualnodesOnAzureContainerInstances/",
    "helm repo update",
    "helm upgrade --install vn2-ondemand",
    "helm upgrade --install vn2-standby",
    "--set fullnameOverride=vn2-ondemand",
    "--set fullnameOverride=vn2-standby",
    "--set aciSubnetName=cg",
    "--set aciResourceGroupName=\"$RG\"",
    "--set nodeLabels=\"benchmark-path=ondemand\"",
    "--set nodeLabels=\"benchmark-path=standby\"",
    "for label in ondemand standby; do",
    "deadline=$((SECONDS + 600))",
    "kubectl get nodes -l \"benchmark-path=${label}\" --no-headers 2>/dev/null",
    "Label benchmark-path=%s did not appear within 10 minutes\\n",
    "kubectl get nodes -L benchmark-path -o wide >&2",
    "sleep 10",
    "kubectl wait --for=condition=Ready node \\",
    "-l \"benchmark-path=${label}\" --timeout=10m",
    "kubectl get nodes -L benchmark-path -o wide",
    "mapfile -t POOLS < <(az standby-container-group-pool list",
    "--query '[].name' -o tsv",
    "test \"${#POOLS[@]}\" -eq 1",
    "export STANDBY_POOL=\"${POOLS[0]}\"",
    "printf 'export LOCATION=%q\\n' \"$LOCATION\"",
    "printf 'export RG=%q\\n' \"$RG\"",
    "printf 'export VNET=%q\\n' \"$VNET\"",
    "printf 'export AKS_SUBNET=%q\\n' \"$AKS_SUBNET\"",
    "printf 'export CG_SUBNET=%q\\n' \"$CG_SUBNET\"",
    "printf 'export NAT_NAME=%q\\n' \"$NAT_NAME\"",
    "printf 'export NAT_PIP_NAME=%q\\n' \"$NAT_PIP_NAME\"",
    "printf 'export AKS=%q\\n' \"$AKS\"",
    "printf 'export VM_SIZE=%q\\n' \"$VM_SIZE\"",
    "printf 'export K8S_VERSION=%q\\n' \"$K8S_VERSION\"",
    "printf 'export VN2_CHART_VERSION=%q\\n' \"$VN2_CHART_VERSION\"",
    "printf 'export ONDEMAND_RELEASE=%q\\n' \"$ONDEMAND_RELEASE\"",
    "printf 'export STANDBY_RELEASE=%q\\n' \"$STANDBY_RELEASE\"",
    "printf 'export STANDBY_POOL=%q\\n' \"$STANDBY_POOL\"",
    "chmod 600 \"$STATE_TMP\"",
    "mv \"$STATE_TMP\" \"$WORKSHOP_STATE\"",
    "./scripts/check-standby-pool.sh \\",
    "--resource-group \"$RG\"",
    "--name \"$STANDBY_POOL\"",
    "--expect-running 5",
    "--timeout-seconds 1200",
    "--interval-seconds 15",
    "8-vCPU/32-GiB",
    "duplicate webhook ownership",
    "rejected 1 vCPU/2 GiB profile",
    "missing RBAC",
    "degraded pool",
    "kubectl get events",
    "helm status vn2-standby -n vn2-standby",
    "az standby-container-group-pool status",
    "results/workshop.env is the authoritative workshop state",
]

forbidden_strings = [
    "$WORKSHOP_RG",
    "STANDBY_POOL_NAME",
    "nodeLabels.benchmark-path=ondemand",
    "nodeLabels.benchmark-path=standby",
    "check-standby-pool.sh -g",
    "kubectl get validatingwebhookconfiguration virtual-node-admission-controller",
    "같은 Cloud Shell 세션에 남아 있다",
    ">> \"$WORKSHOP_STATE\"",
    "tee -a \"$WORKSHOP_STATE\"",
]

for item in required_strings:
    if item not in text:
        raise SystemExit(f"docs/03-install-dual-vn2.md is missing required text: {item}")

for item in forbidden_strings:
    if item in text:
        raise SystemExit(f"docs/03-install-dual-vn2.md must not contain outdated text: {item}")

for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
    if heading not in text:
        raise SystemExit(f"docs/03-install-dual-vn2.md is missing required section: {heading}")

if "다음 모듈에서 그대로 재사용" not in text:
    raise SystemExit("docs/03-install-dual-vn2.md must say STANDBY_POOL continues into the next module")

PY
