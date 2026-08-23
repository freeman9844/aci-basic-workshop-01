#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
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
    "Azure Container Instances Contributor Role",
    "Standby Container Group Pool Contributor",
    "Network Contributor",
    "FEATURE_JSON=\"$(az feature show",
    "FEATURE_RC=$?",
    "if [[ \"$FEATURE_RC\" -eq 0 ]]; then",
    "elif grep -qi 'ResourceNotFound'",
    "SUB_ID=\"$(az account show --query id -o tsv)\"",
    "az rest --method get --url \"https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.ContainerInstance/locations/koreacentral/usages?api-version=2025-09-01\" --output json",
    "jq '.value'",
    "ContainerGroups",
    "StandardContainerGroups",
    "StandardSpotCores",
    "DedicatedContainerGroups",
    "ConfidentialCores",
    "current API may expose `ContainerGroups`",
    "historical responses may expose `StandardContainerGroups`",
    "No guessing beyond these two container group quota names is allowed.",
    "Other ACI quota rows are informational only.",
    "preflight gates only on exactly one container group alias plus exactly one `StandardCores` row",
    "need at least 10 available container groups and 10 available StandardCores",
    "5 warm standby instances while 5 benchmark Pods are active or refilling",
    "SP_OBJECT_ID=\"$(az ad sp list",
    "test -n \"$SP_OBJECT_ID\"",
    "Azure CLI 2.76.0",
    "--system-vm-size Standard_D16s_v5",
    "--nap-vm-size Standard_D4s_v5",
    "managed identity",
    "Standard Load Balancer",
    "NAP CRDs",
    "combined regional vCPU headroom of 20",
    "cat results/environment.json",
    "Preflight checks passed.",
    "subshell keeps the interactive parent Cloud Shell safe",
    "regional vCPU headroom is 15; need at least 20",
]

required_foundation = [
    "WORKSHOP_STATE=\"results/workshop.env\"",
    "STATE_TMP=\"${WORKSHOP_STATE}.tmp.$$\"",
    "LOCATION=\"koreacentral\"",
    "RG=\"rg-vn2-bench-$RANDOM\"",
    "VNET=\"vnet-vn2-bench\"",
    "AKS_SUBNET=\"snet-aks\"",
    "CG_SUBNET=\"cg\"",
    "AKS_IDENTITY=\"id-aks-vn2-bench\"",
    "AKS_IDENTITY_ID",
    "NAP_VM_SIZE=\"Standard_D4s_v5\"",
    "NAP_NODEPOOL=\"workshop-nap\"",
    "Azure CNI, Standard Load Balancer, user-assigned managed identity, NAP Auto",
    "Module 01의 `results/environment.json` 이 이미 `Standard_D16s_v5` 와 `koreacentral` 을 검증했더라도",
    "VM_SIZE=\"Standard_D16s_v5\"",
    "fixed system node",
    "NAP benchmark NodePool",
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
    "az identity create",
    "--name \"$AKS_IDENTITY\"",
    "--query id -o tsv",
    "--query principalId -o tsv",
    "VNET_ID=\"$(az network vnet show",
    "--role \"Network Contributor\"",
    "--scope \"$VNET_ID\"",
    "az aks create",
    "--network-plugin azure",
    "--node-vm-size \"$VM_SIZE\"",
    "--kubernetes-version \"$K8S_VERSION\"",
    "--service-cidr 172.16.0.0/16",
    "--dns-service-ip 172.16.0.10",
    "--load-balancer-sku standard",
    "--node-provisioning-mode Auto",
    "--node-provisioning-default-pools None",
    "--assign-identity \"$AKS_IDENTITY_ID\"",
    "identityProfile.kubeletidentity.objectId",
    "nodeResourceGroup",
    "az role assignment create",
    "--role Contributor",
    "az aks get-credentials",
    "sed \"s|@@AKS_SUBNET_ID@@|$AKS_SUBNET_ID|g\"",
    "manifests/nap-workshop-template.yaml",
    "kubectl apply -f results/nap-workshop.yaml",
    "kubectl wait --for=condition=Ready nodepool/\"$NAP_NODEPOOL\" --timeout=10m",
    "kubectl get nodepool workshop-nap",
    "kubectl get nodes -l karpenter.sh/nodepool=workshop-nap",
    "./scripts/check-nap-capacity.sh",
    "--name \"$NAP_NODEPOOL\"",
    "--expect-nodes 0",
    "--expect-nodeclaims 0",
    "printf 'export LOCATION=%q\\n' \"$LOCATION\"",
    "printf 'export RG=%q\\n' \"$RG\"",
    "printf 'export VNET=%q\\n' \"$VNET\"",
    "printf 'export AKS_SUBNET=%q\\n' \"$AKS_SUBNET\"",
    "printf 'export CG_SUBNET=%q\\n' \"$CG_SUBNET\"",
    "printf 'export NAT_NAME=%q\\n' \"$NAT_NAME\"",
    "printf 'export NAT_PIP_NAME=%q\\n' \"$NAT_PIP_NAME\"",
    "printf 'export AKS=%q\\n' \"$AKS\"",
    "printf 'export VM_SIZE=%q\\n' \"$VM_SIZE\"",
    "printf 'export AKS_IDENTITY=%q\\n' \"$AKS_IDENTITY\"",
    "printf 'export AKS_IDENTITY_ID=%q\\n' \"$AKS_IDENTITY_ID\"",
    "printf 'export NAP_VM_SIZE=%q\\n' \"$NAP_VM_SIZE\"",
    "printf 'export NAP_NODEPOOL=%q\\n' \"$NAP_NODEPOOL\"",
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
    "--enable-managed-identity",
    "benchmark-path=aks --overwrite",
    "kubectl label node",
    "VM_SIZE=\"${VM_SIZE:-Standard_D16s_v5}\"",
    "NAP_VM_SIZE=\"${NAP_VM_SIZE:-Standard_D4s_v5}\"",
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

for forbidden_prereq in (
    '"Azure Container Instances Contributor"',
    "`Azure Container Instances Contributor`",
):
    if forbidden_prereq in prereq_text:
        raise SystemExit(
            "docs/01-prerequisites.md must not use the stale no-suffix Azure Container Instances role name"
        )

if "kubelet identity" not in foundation_text:
    raise SystemExit("docs/02-azure-foundation.md must explain kubelet identity grants")

recovery_match = re.search(
    r"### fresh Cloud Shell에서 identity/VNet 권한 재확인\n\n"
    r".*?```bash\n(.*?)```",
    foundation_text,
    re.S,
)
if not recovery_match:
    raise SystemExit("docs/02-azure-foundation.md must contain the fresh-shell identity/VNet recovery block")

recovery_block = recovery_match.group(1)
for item in (
    'WORKSHOP_STATE="results/workshop.env"',
    'source "$WORKSHOP_STATE"',
    'AKS_IDENTITY_PRINCIPAL_ID="$(az identity show',
    'VNET_ID="$(az network vnet show',
    "az role assignment list",
    '--assignee-object-id "$AKS_IDENTITY_PRINCIPAL_ID"',
    '--scope "$VNET_ID"',
):
    if item not in recovery_block:
        raise SystemExit(
            f"docs/02-azure-foundation.md fresh-shell recovery is missing required text: {item}"
        )

ordered_foundation_operations = [
    "az identity create",
    "VNET_ID=\"$(az network vnet show",
    "--role \"Network Contributor\"",
    "az aks create",
    "identityProfile.kubeletidentity.objectId",
    "manifests/nap-workshop-template.yaml",
    "kubectl apply -f results/nap-workshop.yaml",
    "./scripts/check-nap-capacity.sh",
]
positions = [foundation_text.index(item) for item in ordered_foundation_operations]
if positions != sorted(positions):
    raise SystemExit("docs/02-azure-foundation.md must keep the supported NAP foundation operations in order")

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
        if path == foundation and "persist_workshop_state" in block and "persist_workshop_state()" not in block:
            raise SystemExit(
                "docs/02-azure-foundation.md must redefine persist_workshop_state in every independently runnable block that uses it"
            )

if "results/workshop.env" not in foundation_text:
    raise SystemExit("docs/02-azure-foundation.md must persist results/workshop.env")

PY
