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
module07 = root / "docs/07-limitations-troubleshooting-cleanup.md"

if not module07.exists():
    raise SystemExit(f"Missing required document: {module07.relative_to(root).as_posix()}")

text07 = module07.read_text(encoding="utf-8")

for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
    if heading not in text07:
        raise SystemExit(f"docs/07-limitations-troubleshooting-cleanup.md is missing required section: {heading}")

duration_match = re.search(r"^## 예상 소요 시간\s*\n\s*(\d+)분\s*$", text07, re.M)
if not duration_match:
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must declare an exact duration")
if int(duration_match.group(1)) != 10:
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must use duration 10분")

required_07 = [
    "for scenario in vn2-ondemand vn2-standby vn2-standby-cached; do",
    "jq -r '[.scenario, .status, (.elapsed_ms | tostring), .node_name, .cleanup.status] | @tsv' \\",
    '"results/observations/${scenario}.json"',
    "results/observations/vn2-ondemand.json",
    "results/observations/vn2-standby.json",
    "results/observations/vn2-standby-cached.json",
    "| 경로 | 관찰 시간 | lifecycle에서 확인한 점 | 증적 경로 |",
    "| VN2 OnDemand |",
    "| StandbyPool |",
    "| Image Cache |",
    "세 값은 순위를 매기거나 일반화하지 않습니다.",
    "source results/workshop.env",
    "scripts/cleanup.sh --resource-group \"$RG\" --yes",
    "az group exists --name \"$RG\"",
    "type the resource group name exactly to continue",
    "az resource list --resource-group \"$RG\" --query '[].id' --output tsv",
    "residual resource IDs",
    "billing-critical RG deletion",
    "fresh Cloud Shell recovery",
    "fresh Cloud Shell session",
    "missing kubeconfig",
    "WORKSHOP_STATE=\"results/workshop.env\"",
    "STATE_TMP=\"${WORKSHOP_STATE}.tmp.$$\"",
    "az group list --query \"[?starts_with(name, 'rg-vn2-hands-on-')].[name, location]\" --output table",
    "export RG='rg-vn2-hands-on-12345'",
    'printf "export RG=\'%s\'\\n" "$RG" >"$STATE_TMP"',
    'chmod 600 "$STATE_TMP"',
    'source "$WORKSHOP_STATE"',
    "Never pass a wildcard or broad match into cleanup.",
    "Save the recovered exact RG back into results/workshop.env before deleting anything.",
    "StandbyPoolReuseFailure",
    "StandbyPoolExhaustedPool",
    "status.code",
    '\"health\":\"degraded\"',
    "HealthState/Degraded",
    "running 1",
    "ImagePullBackOff",
    "ErrImagePull",
    "quota",
    "NAT Gateway",
    "- 이전: [Module 06](./06-image-cache-hands-on.md)",
    "- 다음: [README](../README.md)",
]

for item in required_07:
    if item not in text07:
        raise SystemExit(f"docs/07-limitations-troubleshooting-cleanup.md is missing required text: {item}")

for forbidden in (
    "180분",
    "5개 Pod × 3회",
    "12 raw JSON",
    "60 Pod",
    "Standard_D4s_v5",
    "workshop-nap",
    "summary.json",
    "median",
    "p95",
    "speed-up",
    "NodePool Ready",
    "NodeClaim 0",
    "consolidation 시간은 run reset",
    "Pod Ready latency에는 포함되지 않습니다",
    "kubectl get nodepool workshop-nap",
    "kubectl get nodeclaims -l karpenter.sh/nodepool=workshop-nap",
):
    if forbidden in text07:
        raise SystemExit(f"docs/07-limitations-troubleshooting-cleanup.md must not contain stale text: {forbidden}")

cleanup_block = re.compile(
    r"```bash\nsource results/workshop\.env\nscripts/cleanup\.sh --resource-group \"\$RG\" --yes\naz group exists --name \"\$RG\"\n```",
    re.M,
)
if not cleanup_block.search(text07):
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md is missing the exact cleanup command block")

if not re.search(r"```text\nfalse\n```", text07):
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must show false as the expected az group exists output")

fallback_match = re.search(
    r"만약 `results/workshop\.env` 자체가 없다면, 아래 fallback 은 후보 RG를 찾는 용도만 사용합니다\.\n\n(?:🟢 \*\*실행\*\*\n\n)?```bash\n(.*?)```",
    text07,
    re.S,
)
if not fallback_match:
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must contain the fallback recovery bash block")

fallback_block = fallback_match.group(1)
scratch = root / ".test-doc-review-cleanup"
if scratch.exists():
    shutil.rmtree(scratch)

try:
    workspace = scratch / "aci-vn2-performance-workshop"
    workspace.mkdir(parents=True)
    subprocess.run(
        [
            "bash",
            "-c",
            "\n".join(
                [
                    "set -euo pipefail",
                    "umask 0022",
                    'before="$(umask)"',
                    "az() { return 0; }",
                    fallback_block,
                    'after="$(umask)"',
                    'if [[ "$after" != "$before" ]]; then',
                    '  printf "fallback changed parent umask from %s to %s\\n" "$before" "$after" >&2',
                    "  exit 1",
                    "fi",
                    'if [[ "${RG:-}" != "rg-vn2-hands-on-12345" ]]; then',
                    '  printf "fallback did not restore RG into the shell\\n" >&2',
                    "  exit 1",
                    "fi",
                ]
            ),
        ],
        check=True,
        cwd=workspace,
        env={**os.environ, "HOME": str(scratch)},
        text=True,
    )

    state_path = workspace / "results" / "workshop.env"
    if not state_path.exists():
        raise SystemExit("Fallback recovery must recreate results/workshop.env")
    state_text = state_path.read_text(encoding="utf-8")
    expected_state = "export RG='rg-vn2-hands-on-12345'\n"
    if state_text != expected_state:
        raise SystemExit(
            "Fallback recovery must rewrite results/workshop.env with exactly export RG='rg-vn2-hands-on-12345'"
        )
    file_mode = stat.S_IMODE(state_path.stat().st_mode)
    if file_mode != 0o600:
        raise SystemExit(f"Fallback recovery must leave results/workshop.env mode 600, found {oct(file_mode)}")
finally:
    if scratch.exists():
        shutil.rmtree(scratch)

print("PASS: review and cleanup docs match the active three-observation contract")
PY
