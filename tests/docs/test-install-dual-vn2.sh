#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import sys
import re
import shutil
import stat
import subprocess
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
    "16-vCPU/64-GiB",
    "두 VN2 infrastructure release와 benchmark Pod 5개 × 500m baseline",
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

step2_match = re.search(
    r"### 2\) VN2 chart 저장소 추가와 pinned release 값 선언\n\n```bash\n(.*?)```",
    text,
    re.S,
)
if not step2_match:
    raise SystemExit("docs/03-install-dual-vn2.md must contain the step 2 bash block")

step2_block = step2_match.group(1)

scratch = root / ".test-doc-install-dual-vn2"
if scratch.exists():
    shutil.rmtree(scratch)

try:
    (scratch / "results").mkdir(parents=True)
    state_path = scratch / "results" / "workshop.env"
    state_path.write_text(
        "\n".join(
            [
                "export LOCATION='koreacentral'",
                "export RG='rg-vn2-bench-10001'",
                "export VNET='vnet-vn2-bench'",
                "export AKS_SUBNET='snet-aks'",
                "export CG_SUBNET='cg'",
                "export NAT_NAME='nat-vn2-bench'",
                "export NAT_PIP_NAME='pip-vn2-bench'",
                "export AKS='aks-vn2-bench'",
                "export VM_SIZE='Standard_D16s_v5'",
                "export K8S_VERSION='1.34.12'",
                "export VN2_CHART_VERSION='stale-chart'",
                "export ONDEMAND_RELEASE='stale-ondemand'",
                "export STANDBY_RELEASE='stale-standby'",
                "export STANDBY_POOL='stale-pool'",
                "",
            ]
        ),
        encoding="utf-8",
    )

    subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "umask 0022",
                    'before="$(umask)"',
                    "helm() { return 0; }",
                    step2_block,
                    'after="$(umask)"',
                    'if [[ "$after" != "$before" ]]; then',
                    '  printf "step 2 changed parent umask from %s to %s\\n" "$before" "$after" >&2',
                    "  exit 1",
                    "fi",
                    'if [[ -n "${STANDBY_POOL:-}" ]]; then',
                    '  printf "STANDBY_POOL leaked after step 2: %s\\n" "$STANDBY_POOL" >&2',
                    "  exit 1",
                    "fi",
                ]
            ),
        ],
        check=True,
        cwd=scratch,
        text=True,
    )

    state_text = state_path.read_text(encoding="utf-8")
    for key in {
        "LOCATION",
        "RG",
        "VNET",
        "AKS_SUBNET",
        "CG_SUBNET",
        "NAT_NAME",
        "NAT_PIP_NAME",
        "AKS",
        "VM_SIZE",
        "K8S_VERSION",
        "VN2_CHART_VERSION",
        "ONDEMAND_RELEASE",
        "STANDBY_RELEASE",
    }:
        if state_text.count(f"export {key}=") != 1:
            raise SystemExit(f"Step 2 must leave exactly one export for {key}")

    for stale in ("stale-chart", "stale-ondemand", "stale-standby", "stale-pool"):
        if stale in state_text:
            raise SystemExit(f"Step 2 must replace stale VN2 state; found {stale}")

    if "export STANDBY_POOL=" in state_text:
        raise SystemExit("Step 2 must not persist STANDBY_POOL before step 6 resolves it")

    file_mode = stat.S_IMODE(state_path.stat().st_mode)
    if file_mode != 0o600:
        raise SystemExit(f"Step 2 must leave results/workshop.env mode 600, found {oct(file_mode)}")

    subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "source results/workshop.env",
                    ': "${RG:?missing RG}"',
                    ': "${AKS:?missing AKS}"',
                    ': "${CG_SUBNET:?missing CG_SUBNET}"',
                    ': "${VN2_CHART_VERSION:?missing VN2_CHART_VERSION}"',
                    ': "${ONDEMAND_RELEASE:?missing ONDEMAND_RELEASE}"',
                    ': "${STANDBY_RELEASE:?missing STANDBY_RELEASE}"',
                    '[[ "$LOCATION" == "koreacentral" ]]',
                    '[[ "$RG" == "rg-vn2-bench-10001" ]]',
                    '[[ "$VNET" == "vnet-vn2-bench" ]]',
                    '[[ "$AKS_SUBNET" == "snet-aks" ]]',
                    '[[ "$CG_SUBNET" == "cg" ]]',
                    '[[ "$NAT_NAME" == "nat-vn2-bench" ]]',
                    '[[ "$NAT_PIP_NAME" == "pip-vn2-bench" ]]',
                    '[[ "$AKS" == "aks-vn2-bench" ]]',
                    '[[ "$VM_SIZE" == "Standard_D16s_v5" ]]',
                    '[[ "$K8S_VERSION" == "1.34.12" ]]',
                    '[[ "$VN2_CHART_VERSION" == "1.3410.26081102" ]]',
                    '[[ "$ONDEMAND_RELEASE" == "vn2-ondemand" ]]',
                    '[[ "$STANDBY_RELEASE" == "vn2-standby" ]]',
                    'if [[ -n "${STANDBY_POOL:-}" ]]; then',
                    '  printf "fresh Cloud Shell resume should not preload STANDBY_POOL\\n" >&2',
                    "  exit 1",
                    "fi",
                ]
            ),
        ],
        check=True,
        cwd=scratch,
        text=True,
    )
finally:
    if scratch.exists():
        shutil.rmtree(scratch)

PY
