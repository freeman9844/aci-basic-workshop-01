#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import os
import re
import shutil
import stat
import subprocess
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
    "15분",
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
    "SP_OBJECT_ID=\"$(az ad sp list",
    "test -n \"$SP_OBJECT_ID\"",
    "Azure CLI 2.76.0",
    "--system-vm-size Standard_D16s_v5",
    "16 regional vCPU",
    "2 available container groups and 2 available StandardCores",
    "one ready standby instance plus one active or refilling workload instance",
    "production sizing recommendation",
    "cat results/environment.json",
    "Preflight checks passed.",
    "subshell keeps the interactive parent Cloud Shell safe",
    "regional vCPU headroom is 15; need at least 16",
]

required_foundation = [
    "30분",
    "WORKSHOP_STATE=\"results/workshop.env\"",
    "STATE_TMP=\"${WORKSHOP_STATE}.tmp.$$\"",
    "LOCATION=\"koreacentral\"",
    "RG=\"rg-vn2-hands-on-$RANDOM\"",
    "VNET=\"vnet-vn2-hands-on\"",
    "AKS_SUBNET=\"snet-aks\"",
    "CG_SUBNET=\"cg\"",
    "NAT_NAME=\"nat-vn2-hands-on\"",
    "NAT_PIP_NAME=\"pip-vn2-hands-on\"",
    "AKS=\"aks-vn2-hands-on\"",
    "AKS_IDENTITY=\"id-aks-vn2-hands-on\"",
    "AKS_IDENTITY_ID",
    "Azure CNI, Standard Load Balancer, user-assigned managed identity, NAP Auto",
    "Module 01의 `results/environment.json` 이 이미 `Standard_D16s_v5` 와 `koreacentral` 을 검증했더라도",
    "VM_SIZE=\"Standard_D16s_v5\"",
    "fixed system node",
    "NAP은 활성화하지만 이 workshop에서는 custom NodePool을 만들지 않습니다.",
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
    "AKS_SUBNET_ID=\"$(az network vnet subnet show",
    "az aks create",
    "--nodepool-name system",
    "--node-count 1",
    "--network-plugin azure",
    "--vnet-subnet-id \"$AKS_SUBNET_ID\"",
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
    "WORKSHOP_RG_ID=\"$(az group show -n \"$RG\" --query id -o tsv)\"",
    "az role assignment create",
    "--role Contributor",
    "az aks get-credentials",
    "az aks show -g \"$RG\" -n \"$AKS\" \\",
    "--query '{nodeProvisioningMode:nodeProvisioningProfile.mode,nodeResourceGroup:nodeResourceGroup}'",
    "kubectl get nodes -o wide",
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
    "printf 'export K8S_VERSION=%q\\n' \"$K8S_VERSION\"",
    "chmod 600 \"$STATE_TMP\"",
    "mv \"$STATE_TMP\" \"$WORKSHOP_STATE\"",
    "source \"$WORKSHOP_STATE\"",
    "results/workshop.env is the authoritative workshop state",
]

forbidden_active_modules = [
    "--nap-vm-size",
    "Standard_D4s_v5",
    "NAP_VM_SIZE",
    "NAP_NODEPOOL",
    "AKSNodeClass",
    "manifests/nap-workshop-template.yaml",
    "kubectl apply -f results/nap-workshop.yaml",
    "check-nap-capacity.sh",
    "kubectl get nodeclaims",
    "kubectl get crd",
    "aksnodeclasses.karpenter.azure.com",
    "nodepools.karpenter.sh",
    "nodeclaims.karpenter.sh",
]

stale_aks_path = "benchmark-path=" + "aks"
forbidden_foundation = [
    "values[?starts_with(version, '1.34.')].version | [0]",
    "--service-cidr 10.4.0.0/16",
    "--dns-service-ip 10.4.0.10",
    ">> \"$WORKSHOP_STATE\"",
    ">>\"$WORKSHOP_STATE\"",
    "tee -a \"$WORKSHOP_STATE\"",
    "--enable-managed-identity",
    stale_aks_path + " --overwrite",
    "kubectl label node",
    "VM_SIZE=\"${VM_SIZE:-Standard_D16s_v5}\"",
]

for item in required_prereq:
    if item not in prereq_text:
        raise SystemExit(f"docs/01-prerequisites.md is missing required text: {item}")

for item in required_foundation:
    if item not in foundation_text:
        raise SystemExit(f"docs/02-azure-foundation.md is missing required text: {item}")

for path, text in ((prereq, prereq_text), (foundation, foundation_text)):
    for item in forbidden_active_modules:
        if item in text:
            raise SystemExit(f"{path.name} must not contain outdated text: {item}")

for item in forbidden_foundation:
    if item in foundation_text:
        raise SystemExit(f"docs/02-azure-foundation.md must not contain outdated text: {item}")

for path, text in ((prereq, prereq_text), (foundation, foundation_text)):
    for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 트러블슈팅"):
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
    "az aks get-credentials",
    "--query '{nodeProvisioningMode:nodeProvisioningProfile.mode,nodeResourceGroup:nodeResourceGroup}'",
    "kubectl get nodes -o wide",
]
steps_match = re.search(
    r"## 진행 순서\n(.*?)(?=\n## 완료 체크포인트)",
    foundation_text,
    re.S,
)
if not steps_match:
    raise SystemExit("docs/02-azure-foundation.md is missing the foundation steps section")

foundation_steps_text = steps_match.group(1)
positions = [foundation_steps_text.index(item) for item in ordered_foundation_operations]
if positions != sorted(positions):
    raise SystemExit("docs/02-azure-foundation.md must keep the supported hands-on foundation operations in order")

code_block_pattern = re.compile(r"```bash\n(.*?)```", re.S)
protected_set_pattern = re.compile(r"^\(\s*set -(?:e|u|euo pipefail)\b")
bare_set_pattern = re.compile(r"^set -(?:e|u|euo pipefail)\b")
for path, text in ((prereq, prereq_text), (foundation, foundation_text)):
    blocks = code_block_pattern.findall(text)
    if not blocks:
        raise SystemExit(f"{path.name} must contain bash code blocks")
    for block in blocks:
        protected_depth = 0
        for line in block.splitlines():
            stripped = line.strip()
            if protected_set_pattern.match(stripped):
                protected_depth += 1
                continue
            if stripped == ")" and protected_depth:
                protected_depth -= 1
                continue
            normalized = stripped.split("#", 1)[0].rstrip().rstrip(";")
            if bare_set_pattern.match(normalized) and protected_depth == 0:
                raise SystemExit(
                    f"{path.name} must not leave interactive parent shell options enabled with bare line: {stripped}"
                )
        if path == foundation and "persist_workshop_state" in block and "persist_workshop_state()" not in block:
            raise SystemExit(
                "docs/02-azure-foundation.md must redefine persist_workshop_state in every independently runnable block that uses it"
            )

if "results/workshop.env" not in foundation_text:
    raise SystemExit("docs/02-azure-foundation.md must persist results/workshop.env")


def extract_first_bash_block(step_heading: str) -> str:
    section_match = re.search(
        rf"{re.escape(step_heading)}\n(.*?)(?=\n### \d+\)|\n## 완료 체크포인트)",
        foundation_text,
        re.S,
    )
    if not section_match:
        raise SystemExit(f"docs/02-azure-foundation.md is missing step section: {step_heading}")

    block_match = re.search(r"```bash\n(.*?)```", section_match.group(1), re.S)
    if not block_match:
        raise SystemExit(f"docs/02-azure-foundation.md must contain a bash block in step: {step_heading}")

    return block_match.group(1)


step1_block = extract_first_bash_block("### 1) 고정 변수와 지원되는 Kubernetes 1.34 패치 선택")
scratch = root / ".test-doc-prerequisites-foundation-state"
if scratch.exists():
    shutil.rmtree(scratch)

try:
    recovery_home = scratch / "home"
    workshop = recovery_home / "aci-vn2-performance-workshop"
    fake_bin = scratch / "bin"
    fake_bin.mkdir(parents=True)
    (workshop / "results").mkdir(parents=True)

    state_path = workshop / "results" / "workshop.env"
    state_path.write_text(
        "\n".join(
            [
                "export LOCATION='stale-location'",
                "export RG='stale-rg'",
                "export NAP_VM_SIZE='stale-d4'",
                "export NAP_NODEPOOL='stale-pool'",
                "export K8S_VERSION='stale-version'",
                "",
            ]
        ),
        encoding="utf-8",
    )

    fake_az = fake_bin / "az"
    fake_az.write_text(
        "\n".join(
            [
                "#!/usr/bin/env bash",
                "set -euo pipefail",
                'if [[ "${1-}" == "aks" && "${2-}" == "get-versions" ]]; then',
                "  printf '%s\\n' '{\"1.34.11\":{\"upgrades\":[\"1.34.12\"]},\"1.34.12\":{\"upgrades\":[]}}'",
                "  exit 0",
                "fi",
                'printf "unexpected az invocation: %s\\n" "$*" >&2',
                "exit 99",
                "",
            ]
        ),
        encoding="utf-8",
    )
    fake_az.chmod(0o755)

    subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "umask 0022",
                    'before="$(umask)"',
                    step1_block,
                    'after="$(umask)"',
                    'if [[ "$after" != "$before" ]]; then',
                    '  printf "step 1 changed parent umask from %s to %s\\n" "$before" "$after" >&2',
                    "  exit 1",
                    "fi",
                ]
            ),
        ],
        check=True,
        cwd=root,
        env={**os.environ, "HOME": str(recovery_home), "PATH": f"{fake_bin}:{os.environ['PATH']}"},
        text=True,
        capture_output=True,
    )

    state_text = state_path.read_text(encoding="utf-8")
    expected_keys = {
        "LOCATION",
        "RG",
        "VNET",
        "AKS_SUBNET",
        "CG_SUBNET",
        "NAT_NAME",
        "NAT_PIP_NAME",
        "AKS",
        "VM_SIZE",
        "AKS_IDENTITY",
        "AKS_IDENTITY_ID",
        "K8S_VERSION",
    }
    for key in expected_keys:
        if state_text.count(f"export {key}=") != 1:
            raise SystemExit(f"Step 1 must leave exactly one export for {key}")

    for forbidden_key in ("NAP_VM_SIZE", "NAP_NODEPOOL"):
        if f"export {forbidden_key}=" in state_text:
            raise SystemExit(f"Step 1 must not persist removed key {forbidden_key}")

    for stale in ("stale-location", "stale-rg", "stale-d4", "stale-pool", "stale-version"):
        if stale in state_text:
            raise SystemExit(f"Step 1 must replace stale workshop state; found {stale}")

    file_mode = stat.S_IMODE(state_path.stat().st_mode)
    if file_mode != 0o600:
        raise SystemExit(f"Step 1 must leave results/workshop.env mode 600, found {oct(file_mode)}")

    subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "source results/workshop.env",
                    ': "${LOCATION:?missing LOCATION}"',
                    ': "${RG:?missing RG}"',
                    ': "${VNET:?missing VNET}"',
                    ': "${AKS_SUBNET:?missing AKS_SUBNET}"',
                    ': "${CG_SUBNET:?missing CG_SUBNET}"',
                    ': "${NAT_NAME:?missing NAT_NAME}"',
                    ': "${NAT_PIP_NAME:?missing NAT_PIP_NAME}"',
                    ': "${AKS:?missing AKS}"',
                    ': "${VM_SIZE:?missing VM_SIZE}"',
                    ': "${AKS_IDENTITY:?missing AKS_IDENTITY}"',
                    ': "${K8S_VERSION:?missing K8S_VERSION}"',
                    '[[ "$LOCATION" == "koreacentral" ]]',
                    '[[ "$RG" =~ ^rg-vn2-hands-on-[0-9]+$ ]]',
                    '[[ "$VNET" == "vnet-vn2-hands-on" ]]',
                    '[[ "$AKS_SUBNET" == "snet-aks" ]]',
                    '[[ "$CG_SUBNET" == "cg" ]]',
                    '[[ "$NAT_NAME" == "nat-vn2-hands-on" ]]',
                    '[[ "$NAT_PIP_NAME" == "pip-vn2-hands-on" ]]',
                    '[[ "$AKS" == "aks-vn2-hands-on" ]]',
                    '[[ "$VM_SIZE" == "Standard_D16s_v5" ]]',
                    '[[ "$AKS_IDENTITY" == "id-aks-vn2-hands-on" ]]',
                    'if [[ -n "${AKS_IDENTITY_ID:-}" ]]; then',
                    '  printf "step 1 should persist empty AKS_IDENTITY_ID before identity creation\\n" >&2',
                    "  exit 1",
                    "fi",
                    '[[ "$K8S_VERSION" == "1.34.12" ]]',
                ]
            ),
        ],
        check=True,
        cwd=workshop,
        text=True,
    )
finally:
    if scratch.exists():
        shutil.rmtree(scratch)

print("PASS: prerequisites and foundation docs match the simplified hands-on NAP flow")
PY
