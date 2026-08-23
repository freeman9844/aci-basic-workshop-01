#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
prereq = root / "docs/01-prerequisites.md"
foundation = root / "docs/02-azure-foundation.md"

for path in (prereq, foundation):
    if not path.exists():
        raise SystemExit(f"Missing required document: {path.relative_to(root).as_posix()}")

prereq_text = prereq.read_text(encoding="utf-8")
foundation_text = foundation.read_text(encoding="utf-8")

required_prereq = [
    "az provider register --namespace Microsoft.ContainerInstance --wait",
    "az provider register --namespace Microsoft.StandbyPool --wait",
    "StandbyContainerGroupPoolPreview",
    "ResourceNotFound",
    "The preview feature is no longer exposed; provider registration is the current GA gate.",
    "Standby Pool Resource Provider",
    "Azure Container Instances Contributor",
    "Standby Container Group Pool Contributor",
    "Network Contributor",
    "FEATURE_JSON=\"$(az feature show",
    "FEATURE_RC=$?",
    "if [[ \"$FEATURE_RC\" -eq 0 ]]; then",
    "elif grep -qi 'ResourceNotFound'",
    "SUB_ID=\"$(az account show --query id -o tsv)\"",
    "SP_OBJECT_ID=\"$(az ad sp list",
    "test -n \"$SP_OBJECT_ID\"",
    "./scripts/preflight.sh --location koreacentral --vm-size Standard_D8s_v5",
    "cat results/environment.json",
    "Preflight checks passed.",
    "subshell keeps the interactive parent Cloud Shell safe",
]

required_foundation = [
    "WORKSHOP_STATE=\"results/workshop.env\"",
    "STATE_TMP=\"${WORKSHOP_STATE}.tmp.$$\"",
    "LOCATION=\"koreacentral\"",
    "RG=\"rg-vn2-bench-$RANDOM\"",
    "VNET=\"vnet-vn2-bench\"",
    "AKS_SUBNET=\"snet-aks\"",
    "CG_SUBNET=\"cg\"",
    "VM_SIZE=\"${VM_SIZE:-Standard_D8s_v5}\"",
    "--query \"values[?version=='1.34'].patchVersions | [0]\"",
    "jq -r 'if type==\"object\" then (keys_unsorted | map(select(startswith(\"1.34.\"))) | sort_by(split(\".\")|map(tonumber)) | last // \"\") else \"\" end'",
    "test -n \"$K8S_VERSION\"",
    "10.0.0.0/8",
    "10.0.0.0/24",
    "10.1.0.0/16",
    "10.2.0.0/16",
    "Microsoft.ContainerInstance/containerGroups",
    "az network public-ip create",
    "--sku Standard",
    "--allocation-method Static",
    "az network nat gateway create",
    "az network vnet subnet update",
    "--nat-gateway \"$NAT_NAME\"",
    "az aks create",
    "--network-plugin azure",
    "--node-vm-size \"$VM_SIZE\"",
    "--kubernetes-version \"$K8S_VERSION\"",
    "--service-cidr 172.16.0.0/16",
    "--dns-service-ip 172.16.0.10",
    "identityProfile.kubeletidentity.objectId",
    "nodeResourceGroup",
    "az role assignment create",
    "--role Contributor",
    "az aks get-credentials",
    "benchmark-path=aks",
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
    "chmod 600 \"$STATE_TMP\"",
    "mv \"$STATE_TMP\" \"$WORKSHOP_STATE\"",
    "source \"$WORKSHOP_STATE\"",
    "results/workshop.env is the authoritative workshop state",
]

forbidden_foundation = [
    "values[?starts_with(version, '1.34.')].version | [0]",
    "--service-cidr 10.4.0.0/16",
    "--dns-service-ip 10.4.0.10",
    ">> \"$WORKSHOP_STATE\"",
    ">>\"$WORKSHOP_STATE\"",
    "tee -a \"$WORKSHOP_STATE\"",
]

for item in required_prereq:
    if item not in prereq_text:
        raise SystemExit(f"docs/01-prerequisites.md is missing required text: {item}")

for item in required_foundation:
    if item not in foundation_text:
        raise SystemExit(f"docs/02-azure-foundation.md is missing required text: {item}")

for item in forbidden_foundation:
    if item in foundation_text:
        raise SystemExit(f"docs/02-azure-foundation.md must not contain outdated text: {item}")

for path, text in ((prereq, prereq_text), (foundation, foundation_text)):
    for heading in ("## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
        if heading not in text:
            raise SystemExit(f"{path.name} is missing required section: {heading}")

if "다음 모듈로 진행하지 말고" not in prereq_text:
    raise SystemExit("docs/01-prerequisites.md must tell participants not to continue on failed preflight")

if "kubelet identity" not in foundation_text:
    raise SystemExit("docs/02-azure-foundation.md must explain kubelet identity grants")

import re

code_block_pattern = re.compile(r"```bash\n(.*?)```", re.S)
for path, text in ((prereq, prereq_text), (foundation, foundation_text)):
    blocks = code_block_pattern.findall(text)
    if not blocks:
        raise SystemExit(f"{path.name} must contain bash code blocks")
    for block in blocks:
        for line in block.splitlines():
            if line.strip() in {"set -euo pipefail", "set -e", "set -u"}:
                raise SystemExit(
                    f"{path.name} must not leave interactive parent shell options enabled with bare line: {line.strip()}"
                )

if "results/workshop.env" not in foundation_text:
    raise SystemExit("docs/02-azure-foundation.md must persist results/workshop.env")

PY
