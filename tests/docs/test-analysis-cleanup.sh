#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
module06 = root / "docs/06-analyze-results.md"
module07 = root / "docs/07-limitations-troubleshooting-cleanup.md"

for path in (module06, module07):
    if not path.exists():
        raise SystemExit(f"Missing required document: {path.relative_to(root).as_posix()}")

text06 = module06.read_text(encoding="utf-8")
text07 = module07.read_text(encoding="utf-8")

for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
    if heading not in text06:
        raise SystemExit(f"docs/06-analyze-results.md is missing required section: {heading}")
    if heading not in text07:
        raise SystemExit(f"docs/07-limitations-troubleshooting-cleanup.md is missing required section: {heading}")

required_06 = [
    "python3 scripts/summarize-results.py \\",
    "--input results/raw",
    "--output-dir results",
    "Successfully generated results/summary.json, results/summary.csv, and results/summary.md.",
    "results/summary.json",
    "results/summary.csv",
    "results/summary.md",
    "create->scheduled",
    "scheduled->ready",
    "create->ready",
    "batch first-ready",
    "batch all-ready",
    "nearest-rank p95",
    "보간하지 않습니다",
    "ready_samples",
    "failed_count",
    "timeout_count",
    "create_to_scheduled_ms",
    "scheduled_to_ready_ms",
    "create_to_ready_ms",
    "batch_first_ready_ms",
    "batch_all_ready_ms",
    "pod_speedup_ratio",
    "batch_speedup_ratio",
    "evidence_json",
    ".evidence.runs[]",
    "non_ready_pods",
    "vn2-ondemand",
    "speed-up",
    "median 은 `ready_samples` 기준으로 계산합니다",
    "all-success 시나리오에서는 `ready_samples=15`",
    "`pod_speedup_ratio` 는 `create_to_ready_ms` median 기준",
    "`batch_speedup_ratio` 는 `batch_all_ready_ms` median 기준",
    "first-ready 기준이 아닙니다",
    "개별 run",
    "시나리오 aggregate",
    "SLA가 아닙니다",
    "제품 전체 성능 보장이 아닙니다",
    "regular AKS",
    "warm image cache",
    "burst 비용 비교가 아닙니다",
    "실패/timeout sample을 숨기지 않습니다",
]

for item in required_06:
    if item not in text06:
        raise SystemExit(f"docs/06-analyze-results.md is missing required text: {item}")

summary_contract_pattern = re.compile(
    r"jq '\.\[\"vn2-standby-cached\"\] \| \{scenario, runs_count, ready_samples, failed_count, timeout_count, create_to_ready_ms, create_to_scheduled_ms, scheduled_to_ready_ms, batch_first_ready_ms, batch_all_ready_ms, pod_speedup_ratio, batch_speedup_ratio\}' results/summary\.json",
    re.M,
)
if not summary_contract_pattern.search(text06):
    raise SystemExit("docs/06-analyze-results.md is missing the exact summary.json aggregate inspection command")

evidence_pattern = re.compile(
    r"jq '\.\[\"vn2-standby-cached\"\]\.evidence\.runs\[\] \| \{run, metadata, batch, non_ready_pods\}' results/summary\.json",
    re.M,
)
if not evidence_pattern.search(text06):
    raise SystemExit("docs/06-analyze-results.md is missing the exact per-run evidence inspection command")

csv_header = (
    "scenario,runs_count,ready_samples,failed_count,timeout_count,pod_median_ms,pod_p95_ms,"
    "pod_min_ms,pod_max_ms,batch_first_ready_median_ms,batch_all_ready_median_ms,"
    "pod_speedup_ratio,batch_speedup_ratio,evidence_json"
)
if csv_header not in text06:
    raise SystemExit("docs/06-analyze-results.md must document the exact summary.csv header")

required_07 = [
    "scripts/cleanup.sh --resource-group \"$RG\" --yes",
    "az group exists --name \"$RG\"",
    "type the resource group name exactly to continue",
    "az standby-container-group-pool list --resource-group \"$RG\" --query '[].name' --output tsv",
    "az resource list --resource-group \"$RG\" --query '[].id' --output tsv",
    "StandbyPoolReuseFailure",
    "StandbyPoolExhaustedPool",
    "status.code",
    "\"health\":\"degraded\"",
    "HealthState/Degraded",
    "NotReady",
    "running 5",
    "vn2-image-cache",
    "cache Pod",
    "kubectl get pod -n vn2-image-cache vn2-benchmark-image-cache -o yaml",
    "--max-ready-capacity 0",
    "--max-ready-capacity 5",
    "results/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt",
    "results/diagnostics/vn2-standby-cached-run-1/az-container-list.json",
    "results/raw/vn2-standby-cached-run-1.json",
    "terminal_failure_reason",
    "ImagePullBackOff",
    "ErrImagePull",
    "quota",
    "NAT Gateway",
    "API server authorized IP ranges",
    "Windows",
    "IPv6",
    "DaemonSet",
    "Kubernetes network policy",
    "residual resource IDs",
    "fresh Cloud Shell session",
    "missing kubeconfig",
    "billing-critical RG deletion",
    "WARNING: graceful cluster cleanup failed; continuing with standby pool and resource group deletion.",
    "Cleanup completed with warnings.",
]

for item in required_07:
    if item not in text07:
        raise SystemExit(f"docs/07-limitations-troubleshooting-cleanup.md is missing required text: {item}")

cleanup_block = re.compile(
    r"```bash\nscripts/cleanup\.sh --resource-group \"\$RG\" --yes\naz group exists --name \"\$RG\"\n```",
    re.M,
)
if not cleanup_block.search(text07):
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md is missing the exact cleanup command block")

if not re.search(r"```text\nfalse\n```", text07):
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must show false as the expected az group exists output")

for forbidden in ("$WORKSHOP_RG", "STANDBY_POOL_NAME"):
    if forbidden in text06:
        raise SystemExit(f"docs/06-analyze-results.md must not contain outdated text: {forbidden}")
    if forbidden in text07:
        raise SystemExit(f"docs/07-limitations-troubleshooting-cleanup.md must not contain outdated text: {forbidden}")

if "- 이전: [Module 05](./05-standby-cache-benchmark.md)" not in text06:
    raise SystemExit("docs/06-analyze-results.md must link back to Module 05")
if "- 다음: [Module 07](./07-limitations-troubleshooting-cleanup.md)" not in text06:
    raise SystemExit("docs/06-analyze-results.md must link forward to Module 07")
if "- 이전: [Module 06](./06-analyze-results.md)" not in text07:
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must link back to Module 06")
if "- 다음: [README](../README.md)" not in text07:
    raise SystemExit("docs/07-limitations-troubleshooting-cleanup.md must link forward to README")

PY
