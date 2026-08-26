#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
module = root / "docs/03-install-dual-vn2.md"

if not module.exists():
    raise SystemExit("Missing required document: docs/03-install-dual-vn2.md")

text = module.read_text(encoding="utf-8")

foundation_keys = [
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
]
release_keys = foundation_keys + [
    "VN2_CHART_VERSION",
    "ONDEMAND_RELEASE",
    "STANDBY_RELEASE",
]
final_keys = release_keys + ["STANDBY_POOL"]

required_strings = [
    "1.3410.26081102",
    "vn2-ondemand",
    "vn2-standby",
    "WORKSHOP_STATE=\"results/workshop.env\"",
    "if [[ ! -f \"$WORKSHOP_STATE\" ]]; then",
    "source \"$WORKSHOP_STATE\"",
    "az aks get-credentials --resource-group \"$RG\" --name \"$AKS\" --overwrite-existing",
    ": \"${RG:?Run Module 02 first or recover results/workshop.env before continuing.}\"",
    ": \"${AKS:?Run Module 02 first or recover results/workshop.env before continuing.}\"",
    ": \"${CG_SUBNET:?Run Module 02 first or recover results/workshop.env before continuing.}\"",
    ": \"${AKS_IDENTITY:?Run Module 02 first or recover results/workshop.env before continuing.}\"",
    ": \"${AKS_IDENTITY_ID:?Run Module 02 first or recover results/workshop.env before continuing.}\"",
    "--namespace vn2-ondemand",
    "--namespace vn2-standby",
    "--create-namespace",
    "admissionControllerReplicaCount=0",
    "sandboxProviderType=OnDemand",
    "sandboxProviderType=StandbyPool",
    "standbyPoolShareType=Node",
    "standbyPool.standbyPoolsCpu=1",
    "standbyPool.standbyPoolsMemory=2",
    "standbyPool.maxReadyCapacity=1",
    "standbyPool.refillPolicy=always",
    "benchmark-path=ondemand",
    "benchmark-path=standby",
    "두 가지 VN2 node path",
    "세 가지 hands-on exercise",
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
    "printf 'export AKS_IDENTITY=%q\\n' \"$AKS_IDENTITY\"",
    "printf 'export AKS_IDENTITY_ID=%q\\n' \"$AKS_IDENTITY_ID\"",
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
    "--expect-running 1",
    "--timeout-seconds 1200",
    "--interval-seconds 15",
    "16-vCPU/64-GiB",
    "fixed system node",
    "두 VN2 infrastructure release",
    "duplicate webhook ownership",
    "rejected 1 vCPU/2 GiB profile",
    "missing RBAC",
    "degraded pool",
    "kubectl get events",
    "helm status vn2-standby -n vn2-standby",
    "az standby-container-group-pool status",
    "results/workshop.env is the authoritative workshop state",
]

stale_aks_path = "benchmark-path=" + "aks"
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
    "NAP_VM_SIZE",
    "NAP_NODEPOOL",
    "workshop-nap",
    "karpenter.sh/nodepool",
    "check-nap-capacity.sh",
    "standbyPool.maxReadyCapacity=5",
    "--expect-running 5",
    "네 가지 benchmark scenario",
    "일반 AKS 노드에 `" + stale_aks_path + "`",
]

for item in required_strings:
    if item not in text:
        raise SystemExit(f"docs/03-install-dual-vn2.md is missing required text: {item}")

for item in forbidden_strings:
    if item in text:
        raise SystemExit(f"docs/03-install-dual-vn2.md must not contain outdated text: {item}")

if re.search(re.escape(stale_aks_path) + r"(?!-nap)", text):
    raise SystemExit("docs/03-install-dual-vn2.md must not route benchmark Pods to the fixed system node")

for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
    if heading not in text:
        raise SystemExit(f"docs/03-install-dual-vn2.md is missing required section: {heading}")

if "다음 모듈에서 그대로 재사용" not in text:
    raise SystemExit("docs/03-install-dual-vn2.md must say STANDBY_POOL continues into the next module")


def extract_first_bash_block(step_heading: str) -> str:
    section_match = re.search(
        rf"{re.escape(step_heading)}\n(.*?)(?=\n### \d+\)|\n## 완료 체크포인트)",
        text,
        re.S,
    )
    if not section_match:
        raise SystemExit(f"docs/03-install-dual-vn2.md is missing step section: {step_heading}")

    block_match = re.search(r"```bash\n(.*?)```", section_match.group(1), re.S)
    if not block_match:
        raise SystemExit(f"docs/03-install-dual-vn2.md must contain a bash block in step: {step_heading}")

    return block_match.group(1)


def assert_exact_exports(state_text: str, keys: list[str], step_label: str) -> None:
    export_lines = [line for line in state_text.splitlines() if line.startswith("export ")]
    if len(export_lines) != len(keys):
        raise SystemExit(
            f"{step_label} must leave exactly {len(keys)} exported keys, found {len(export_lines)}"
        )

    for key in keys:
        if state_text.count(f"export {key}=") != 1:
            raise SystemExit(f"{step_label} must leave exactly one export for {key}")


step1_block = extract_first_bash_block("### 1) Module 02 state file 과 AKS context 연속성 확인")
recovery_scratch = root / ".test-doc-install-dual-vn2-recovery"
if recovery_scratch.exists():
    shutil.rmtree(recovery_scratch)

try:
    recovery_home = recovery_scratch / "home"
    workshop = recovery_home / "aci-vn2-performance-workshop"
    fake_bin = recovery_scratch / "bin"
    fake_bin.mkdir(parents=True)
    (workshop / "results").mkdir(parents=True)
    (workshop / "results" / "workshop.env").write_text(
        "\n".join(
            [
                "export RG='rg-vn2-hands-on-10001'",
                "export AKS='aks-vn2-hands-on'",
                "export CG_SUBNET='cg'",
                "export AKS_IDENTITY='id-aks-vn2-hands-on'",
                "export AKS_IDENTITY_ID='/subscriptions/test/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-vn2-hands-on'",
                "",
            ]
        ),
        encoding="utf-8",
    )
    fake_az = fake_bin / "az"
    fake_az.write_text("#!/usr/bin/env bash\nexit 42\n", encoding="utf-8")
    fake_az.chmod(0o755)
    fake_kubectl = fake_bin / "kubectl"
    fake_kubectl.write_text(
        f"#!/usr/bin/env bash\n: >{(recovery_scratch / 'kubectl-ran').as_posix()!r}\nexit 0\n",
        encoding="utf-8",
    )
    fake_kubectl.chmod(0o755)

    recovery = subprocess.run(
        ["bash", "-c", step1_block],
        cwd=root,
        env={"HOME": str(recovery_home), "PATH": f"{fake_bin}:/usr/bin:/bin"},
        text=True,
        capture_output=True,
    )
    if recovery.returncode != 42:
        raise SystemExit(
            f"Step 1 must return the az aks get-credentials failure (42), found {recovery.returncode}"
        )
    if (recovery_scratch / "kubectl-ran").exists():
        raise SystemExit("Step 1 must not run kubectl after az aks get-credentials fails")
finally:
    if recovery_scratch.exists():
        shutil.rmtree(recovery_scratch)

step2_block = extract_first_bash_block("### 2) VN2 chart 저장소 추가와 pinned release 값 선언")

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
                "export RG='rg-vn2-hands-on-10001'",
                "export VNET='vnet-vn2-hands-on'",
                "export AKS_SUBNET='snet-aks'",
                "export CG_SUBNET='cg'",
                "export NAT_NAME='nat-vn2-hands-on'",
                "export NAT_PIP_NAME='pip-vn2-hands-on'",
                "export AKS='aks-vn2-hands-on'",
                "export VM_SIZE='Standard_D16s_v5'",
                "export AKS_IDENTITY='id-aks-vn2-hands-on'",
                "export AKS_IDENTITY_ID='/subscriptions/test/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-vn2-hands-on'",
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
    assert_exact_exports(state_text, release_keys, "Step 2")

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
                    '[[ "$RG" == "rg-vn2-hands-on-10001" ]]',
                    '[[ "$VNET" == "vnet-vn2-hands-on" ]]',
                    '[[ "$AKS_SUBNET" == "snet-aks" ]]',
                    '[[ "$CG_SUBNET" == "cg" ]]',
                    '[[ "$NAT_NAME" == "nat-vn2-hands-on" ]]',
                    '[[ "$NAT_PIP_NAME" == "pip-vn2-hands-on" ]]',
                    '[[ "$AKS" == "aks-vn2-hands-on" ]]',
                    '[[ "$VM_SIZE" == "Standard_D16s_v5" ]]',
                    '[[ "$AKS_IDENTITY" == "id-aks-vn2-hands-on" ]]',
                    '[[ "$AKS_IDENTITY_ID" == "/subscriptions/test/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-vn2-hands-on" ]]',
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

step6_block = extract_first_bash_block("### 6) standby pool 하나를 정확히 찾고 `STANDBY_POOL` export")
pool_scratch = root / ".test-doc-install-dual-vn2-pool"
if pool_scratch.exists():
    shutil.rmtree(pool_scratch)

try:
    fake_bin = pool_scratch / "bin"
    fake_bin.mkdir(parents=True)
    (pool_scratch / "results").mkdir(parents=True)
    state_path = pool_scratch / "results" / "workshop.env"
    state_path.write_text(
        "\n".join(
            [
                "export LOCATION='koreacentral'",
                "export RG='rg-vn2-hands-on-10001'",
                "export VNET='vnet-vn2-hands-on'",
                "export AKS_SUBNET='snet-aks'",
                "export CG_SUBNET='cg'",
                "export NAT_NAME='nat-vn2-hands-on'",
                "export NAT_PIP_NAME='pip-vn2-hands-on'",
                "export AKS='aks-vn2-hands-on'",
                "export VM_SIZE='Standard_D16s_v5'",
                "export AKS_IDENTITY='id-aks-vn2-hands-on'",
                "export AKS_IDENTITY_ID='/subscriptions/test/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-vn2-hands-on'",
                "export K8S_VERSION='1.34.12'",
                "export VN2_CHART_VERSION='1.3410.26081102'",
                "export ONDEMAND_RELEASE='vn2-ondemand'",
                "export STANDBY_RELEASE='vn2-standby'",
                "export STANDBY_POOL='stale-pool'",
                "",
            ]
        ),
        encoding="utf-8",
    )
    fake_az = fake_bin / "az"
    fake_az.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"${1:-}\" == \"standby-container-group-pool\" && \"${2:-}\" == \"list\" ]]; then\n"
        "  printf 'pool-vn2-ready\\n'\n"
        "  exit 0\n"
        "fi\n"
        "printf 'unexpected az call: %s\\n' \"$*\" >&2\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake_az.chmod(0o755)

    pool_result = subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "umask 0022",
                    'before="$(umask)"',
                    step6_block,
                    'after="$(umask)"',
                    'if [[ "$after" != "$before" ]]; then',
                    '  printf "step 6 changed parent umask from %s to %s\\n" "$before" "$after" >&2',
                    "  exit 1",
                    "fi",
                ]
            ),
        ],
        check=True,
        cwd=pool_scratch,
        env={"PATH": f"{fake_bin}:/usr/bin:/bin"},
        text=True,
        capture_output=True,
    )

    if "STANDBY_POOL=pool-vn2-ready" not in pool_result.stdout:
        raise SystemExit("Step 6 must print the discovered STANDBY_POOL value")

    state_text = state_path.read_text(encoding="utf-8")
    assert_exact_exports(state_text, final_keys, "Step 6")

    if "stale-pool" in state_text:
        raise SystemExit("Step 6 must replace stale STANDBY_POOL state")

    file_mode = stat.S_IMODE(state_path.stat().st_mode)
    if file_mode != 0o600:
        raise SystemExit(f"Step 6 must leave results/workshop.env mode 600, found {oct(file_mode)}")

    subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "source results/workshop.env",
                    ': "${STANDBY_POOL:?missing STANDBY_POOL}"',
                    '[[ "$RG" == "rg-vn2-hands-on-10001" ]]',
                    '[[ "$VN2_CHART_VERSION" == "1.3410.26081102" ]]',
                    '[[ "$ONDEMAND_RELEASE" == "vn2-ondemand" ]]',
                    '[[ "$STANDBY_RELEASE" == "vn2-standby" ]]',
                    '[[ "$STANDBY_POOL" == "pool-vn2-ready" ]]',
                ]
            ),
        ],
        check=True,
        cwd=pool_scratch,
        text=True,
    )
finally:
    if pool_scratch.exists():
        shutil.rmtree(pool_scratch)

print("PASS: install dual VN2 doc matches the one-capacity ready standby flow")
PY
