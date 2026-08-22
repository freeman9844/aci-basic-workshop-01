#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
module04 = root / "docs/04-baseline-ondemand-benchmark.md"
module05 = root / "docs/05-standby-cache-benchmark.md"

for path in (module04, module05):
    if not path.exists():
        raise SystemExit(f"Missing required document: {path.relative_to(root).as_posix()}")

text04 = module04.read_text(encoding="utf-8")
text05 = module05.read_text(encoding="utf-8")

for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
    if heading not in text04:
        raise SystemExit(f"docs/04-baseline-ondemand-benchmark.md is missing required section: {heading}")
    if heading not in text05:
        raise SystemExit(f"docs/05-standby-cache-benchmark.md is missing required section: {heading}")

required_04 = [
    "require_workshop_vars() {",
    "run_and_capture_rc() {",
    "archive_failed_attempts() {",
    "if [[ -z \"${RG:-}\" ]]; then",
    "if [[ -z \"${STANDBY_POOL:-}\" ]]; then",
    "./scripts/run-benchmark.sh \\",
    "--scenario aks",
    "--scenario vn2-ondemand",
    "--runs 3",
    "--output-dir results",
    "find results/raw -maxdepth 1 -type f -name 'aks-run-*.json' | sort",
    "find results/raw -maxdepth 1 -type f -name 'vn2-ondemand-run-*.json' | sort",
    "jq -r '.pods[] | [.name, .terminal_state, .create_to_ready_ms, .node_name] | @tsv'",
    "jq '{scenario, run, batch: {first_ready_ms: .batch.first_ready_ms, all_ready_ms: .batch.all_ready_ms}}'",
    "첫 run",
    "node image cache",
    "run별 JSON",
    "results/diagnostics/aks-run-1/",
    "results/diagnostics/vn2-ondemand-run-1/",
    "kubectl-describe-pods.txt",
    "kubectl-events.txt",
    "kubectl-nodes.json",
    "az-container-list.json",
    "AKS_RC=$?",
    "ONDEMAND_RC=$?",
    "RC=2 means a benchmark sample timed out or failed after raw JSON and diagnostics were written.",
    "The runner stops remaining runs after the first failed sample.",
    "results/failed-attempts/${scenario}-",
    "find results/raw -maxdepth 1 -type f -name \"${scenario}-run-*.json\" | sort",
    "find results/diagnostics -maxdepth 1 -mindepth 1 -type d -name \"${scenario}-run-*\" | sort",
    "archive_failed_attempts aks",
    "archive_failed_attempts vn2-ondemand",
    "두 시나리오 명령이 모두 0으로 끝났을 때만 정확히 6개의 raw 파일을 기대합니다.",
    "regular AKS",
    "VN2 OnDemand",
    "$STANDBY_POOL",
]

required_05 = [
    "require_workshop_vars() {",
    "run_and_capture_rc() {",
    "archive_failed_attempts() {",
    "check_pool_state() {",
    "POOL_RC=$?",
    "check_pool_state \"standby healthy check\" 5",
    "check_pool_state \"standby recycle-to-zero check\" 0",
    "check_pool_state \"standby refill check\" 5",
    "./scripts/check-standby-pool.sh -g \"$RG\" -n \"$STANDBY_POOL\" \\",
    "--expect-running 5 --timeout-seconds 1200 --interval-seconds 15",
    "./scripts/run-benchmark.sh \\",
    "--scenario vn2-standby-uncached",
    "--scenario vn2-standby-cached",
    "--resource-group \"$RG\"",
    "--standby-pool \"$STANDBY_POOL\"",
    "kubectl create namespace vn2-image-cache --dry-run=client -o yaml | kubectl apply -f -",
    "kubectl apply -f manifests/image-cache-pod.yaml",
    "kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml",
    "az standby-container-group-pool update \\",
    "--max-ready-capacity 0",
    "--max-ready-capacity 5",
    "--refill-policy always",
    "--expect-running 0 --timeout-seconds 1200 --interval-seconds 15",
    "find results/raw -maxdepth 1 -type f -name 'vn2-standby-uncached-run-*.json' | sort",
    "find results/raw -maxdepth 1 -type f -name 'vn2-standby-cached-run-*.json' | sort",
    "deterministic pool recycle",
    "Scenario C",
    "UVM",
    "request/template input",
    "benchmark sample",
    "results/diagnostics/vn2-standby-uncached-run-1/",
    "results/diagnostics/vn2-standby-cached-run-1/",
    "vn2-image-cache",
    "manifests/image-cache-pod.yaml",
    "RC=2 means the standby pool reported degraded health.",
    "RC=3 means the standby pool did not reach the expected running count before timeout.",
    "UNCACHED_RC=$?",
    "CACHED_RC=$?",
    "archive_failed_attempts vn2-standby-uncached",
    "archive_failed_attempts vn2-standby-cached",
    "results/failed-attempts/${scenario}-",
    "running 5 after recycle proves refill capacity, not by itself that image caching finished.",
    "Use the per-run JSON and diagnostics to judge whether image caching actually helped.",
    "두 standby 시나리오 명령이 모두 0으로 끝났을 때만 정확히 6개의 standby raw 파일을 기대합니다.",
    "Module 04와 Module 05의 네 시나리오 명령이 모두 0으로 끝났을 때만 정확히 12개의 전체 raw 파일을 기대합니다.",
]

for item in required_04:
    if item not in text04:
        raise SystemExit(f"docs/04-baseline-ondemand-benchmark.md is missing required text: {item}")

for item in required_05:
    if item not in text05:
        raise SystemExit(f"docs/05-standby-cache-benchmark.md is missing required text: {item}")

for forbidden in ("$WORKSHOP_RG", "STANDBY_POOL_NAME", "--pool-name", "--pool-health"):
    if forbidden in text04:
        raise SystemExit(f"docs/04-baseline-ondemand-benchmark.md must not contain outdated text: {forbidden}")
    if forbidden in text05:
        raise SystemExit(f"docs/05-standby-cache-benchmark.md must not contain outdated text: {forbidden}")

for path, text in ((module04, text04), (module05, text05)):
    if "set -euo pipefail" in text:
        raise SystemExit(f"{path.name} must not enable persistent set -euo pipefail in interactive steps")

allowed_run_benchmark_flags = {
    "--scenario",
    "--runs",
    "--output-dir",
    "--resource-group",
    "--standby-pool",
}

code_block_pattern = re.compile(r"```bash\n(.*?)```", re.S)
for text, path in ((text04, module04), (text05, module05)):
    for block in code_block_pattern.findall(text):
        if "run-benchmark.sh" not in block:
            continue
        for flag in re.findall(r"--[a-z0-9-]+", block):
            if flag not in allowed_run_benchmark_flags:
                raise SystemExit(f"{path.name} uses unsupported run-benchmark.sh flag: {flag}")

scenario_runs = {
    "aks": text04,
    "vn2-ondemand": text04,
    "vn2-standby-uncached": text05,
    "vn2-standby-cached": text05,
}
for scenario, text in scenario_runs.items():
    pattern = re.compile(
        rf"\.\/scripts\/run-benchmark\.sh \\\n\s+--scenario {re.escape(scenario)} \\\n\s+--runs 3 \\\n(?:\s+--resource-group \"\$RG\" \\\n\s+--standby-pool \"\$STANDBY_POOL\" \\\n)?\s+--output-dir results",
        re.M,
    )
    if not pattern.search(text):
        raise SystemExit(f"Missing exact benchmark invocation for scenario: {scenario}")

if text05.count("--refill-policy always") < 2:
    raise SystemExit("docs/05-standby-cache-benchmark.md must set --refill-policy always on both pool updates")

if text05.count("./scripts/check-standby-pool.sh -g \"$RG\" -n \"$STANDBY_POOL\" \\") < 1:
    raise SystemExit("docs/05-standby-cache-benchmark.md must show the standby checker command")

PY
