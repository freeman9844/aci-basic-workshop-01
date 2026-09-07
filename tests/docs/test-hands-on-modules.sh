#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
module_contract = {
    "04-vn2-ondemand-hands-on.md": {
        "duration": 10,
        "scenario": "vn2-ondemand",
        "previous": "./03-install-dual-vn2.md",
        "next": "./05-standby-pool-hands-on.md",
    },
    "05-standby-pool-hands-on.md": {
        "duration": 15,
        "scenario": "vn2-standby",
        "previous": "./04-vn2-ondemand-hands-on.md",
        "next": "./06-image-cache-hands-on.md",
    },
    "06-image-cache-hands-on.md": {
        "duration": 15,
        "scenario": "vn2-standby-cached",
        "previous": "./05-standby-pool-hands-on.md",
        "next": "./07-limitations-troubleshooting-cleanup.md",
    },
}

required_headings = (
    "## 목표",
    "## 예상 소요 시간",
    "## 시작 전 상태",
    "## 진행 순서",
    "## 완료 체크포인트",
    "## 트러블슈팅",
)

common_required = (
    "./scripts/run-hands-on.sh",
    "--resource-group \"$RG\"",
    "--output-dir results",
    "Pod 1개",
    "한 번",
    "benchmark 또는 SLA가 아닙니다",
    "results/observations/",
    "results/evidence/",
)

common_forbidden = (
    "run-benchmark.sh",
    "--runs",
    "results/raw",
    "summary.json",
    "median",
    "p95",
    "speed-up",
    "5개 Pod",
    "3회",
    "aks-nap",
)

module_specific_required = {
    "04-vn2-ondemand-hands-on.md": (
        "source results/workshop.env",
        "az aks get-credentials --resource-group \"$RG\" --name \"$AKS\" --overwrite-existing",
        "./scripts/run-hands-on.sh \\\n  --scenario vn2-ondemand \\\n  --resource-group \"$RG\" \\\n  --output-dir results",
        "jq '{scenario, status, node_name, elapsed_ms, cleanup}' \\\n  results/observations/vn2-ondemand.json",
        "find results/evidence -maxdepth 1 -type d -name 'vn2-ondemand-*' \\| sort \\| tail -n 1",
        "net-new ACI",
        "phase=Pending",
        "phase=Running",
    ),
    "05-standby-pool-hands-on.md": (
        "source results/workshop.env",
        "./scripts/check-standby-pool.sh \\\n  --resource-group \"$RG\" \\\n  --name \"$STANDBY_POOL\" \\\n  --expect-running 1 \\\n  --timeout-seconds 1200 \\\n  --interval-seconds 15",
        "./scripts/run-hands-on.sh \\\n  --scenario vn2-standby \\\n  --resource-group \"$RG\" \\\n  --standby-pool \"$STANDBY_POOL\" \\\n  --output-dir results",
        "jq '{scenario, status, elapsed_ms, standby_pool, cleanup}' \\\n  results/observations/vn2-standby.json",
        "pre.running=1",
        "post.running=1",
        "workload가 아직 running인 동안",
    ),
    "06-image-cache-hands-on.md": (
        "source results/workshop.env",
        "kubectl create namespace vn2-image-cache --dry-run=client -o yaml | kubectl apply -f -",
        "kubectl apply -f manifests/image-cache-pod.yaml",
        "kubectl get pod -n vn2-image-cache vn2-hands-on-image-cache -o yaml",
        "az standby-container-group-pool update \\\n  --resource-group \"$RG\" \\\n  --name \"$STANDBY_POOL\" \\\n  --max-ready-capacity 0 \\\n  --refill-policy always",
        "./scripts/check-standby-pool.sh \\\n  --resource-group \"$RG\" \\\n  --name \"$STANDBY_POOL\" \\\n  --expect-running 0 \\\n  --timeout-seconds 1200 \\\n  --interval-seconds 15",
        "az standby-container-group-pool update \\\n  --resource-group \"$RG\" \\\n  --name \"$STANDBY_POOL\" \\\n  --max-ready-capacity 1 \\\n  --refill-policy always",
        "./scripts/check-standby-pool.sh \\\n  --resource-group \"$RG\" \\\n  --name \"$STANDBY_POOL\" \\\n  --expect-running 1 \\\n  --timeout-seconds 1200 \\\n  --interval-seconds 15",
        "./scripts/run-hands-on.sh \\\n  --scenario vn2-standby-cached \\\n  --resource-group \"$RG\" \\\n  --standby-pool \"$STANDBY_POOL\" \\\n  --output-dir results",
        "request/template input",
        "한 번의 관찰만으로는 보편적인 개선을 증명할 수 없습니다",
    ),
}

for filename, contract in module_contract.items():
    path = root / "docs" / filename
    if not path.exists():
        raise SystemExit(f"Missing required document: {path.relative_to(root).as_posix()}")

    text = path.read_text(encoding="utf-8")

    for heading in required_headings:
        if heading not in text:
            raise SystemExit(f"{filename} is missing required section: {heading}")

    duration_match = re.search(r"^## 예상 소요 시간\s*\n\s*(\d+)분\s*$", text, re.M)
    if not duration_match:
        raise SystemExit(f"{filename} is missing an exact duration under 예상 소요 시간")
    if int(duration_match.group(1)) != contract["duration"]:
        raise SystemExit(f"{filename} must use duration {contract['duration']}분")

    if f"]({contract['previous']})" not in text:
        raise SystemExit(f"{filename} must link back to {contract['previous']}")
    if f"]({contract['next']})" not in text:
        raise SystemExit(f"{filename} must link forward to {contract['next']}")

    scenario = contract["scenario"]
    if f"--scenario {scenario}" not in text:
        raise SystemExit(f"{filename} must contain the active scenario {scenario}")

    for snippet in common_required:
        if snippet not in text:
            raise SystemExit(f"{filename} is missing required text: {snippet}")

    for snippet in common_forbidden:
        if snippet in text:
            raise SystemExit(f"{filename} must not contain outdated text: {snippet}")

    for snippet in module_specific_required[filename]:
        if snippet not in text:
            raise SystemExit(f"{filename} is missing required text: {snippet}")

    has_standby_flag = '--standby-pool "$STANDBY_POOL"' in text
    if filename == "04-vn2-ondemand-hands-on.md" and has_standby_flag:
        raise SystemExit(f"{filename} must not include --standby-pool")
    if filename != "04-vn2-ondemand-hands-on.md" and not has_standby_flag:
        raise SystemExit(f"{filename} must include --standby-pool \"$STANDBY_POOL\"")

    if filename == "04-vn2-ondemand-hands-on.md":
        bad_table_row = "| Pod가 `phase=Running`으로 가지 못한다 | `find results/evidence -maxdepth 1 -type d -name 'vn2-ondemand-*' | sort | tail -n 1`, `kubectl get nodes -L benchmark-path -o wide` | 최신 evidence의 `events.txt` 와 `pod-live.yaml`을 먼저 확인한 뒤 VN2 OnDemand path 상태를 점검합니다 |"
        if bad_table_row in text:
            raise SystemExit(f"{filename} troubleshooting table must escape pipes in the find command")

    if filename == "06-image-cache-hands-on.md":
        for snippet in ("--max-ready-capacity 0", "--max-ready-capacity 1", "--expect-running 0", "--expect-running 1"):
            if snippet not in text:
                raise SystemExit(f"{filename} is missing required text: {snippet}")

print("PASS: hands-on modules match the active one-observation contract")
PY
