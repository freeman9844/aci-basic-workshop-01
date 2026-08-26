#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
appendix = root / "docs/appendix/performance-benchmark.md"
required_files = [
    root / "scripts/run-benchmark.sh",
    root / "scripts/collect-pod-latency.py",
    root / "scripts/summarize-results.py",
    root / "scripts/check-nap-capacity.sh",
    root / "manifests/benchmark-pod-template.yaml",
    root / "manifests/nap-workshop-template.yaml",
    root / "docs/reference/korea-central-2026-08-23.md",
    root / "docs/reference/korea-central-2026-08-23.json",
]

required = [
    "선택 사항",
    "120분 hands-on workshop에 필요하지 않습니다",
    "성능 보장 또는 SLA가 아닙니다",
    "../../scripts/run-benchmark.sh",
    "../../scripts/collect-pod-latency.py",
    "../../scripts/summarize-results.py",
    "../../scripts/check-nap-capacity.sh",
    "../../manifests/benchmark-pod-template.yaml",
    "../../manifests/nap-workshop-template.yaml",
    "../reference/korea-central-2026-08-23.md",
    "../reference/korea-central-2026-08-23.json",
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
]

for path in required_files:
    if not path.exists():
        raise SystemExit(f"Missing required reference file: {path.relative_to(root).as_posix()}")

if not appendix.exists():
    raise SystemExit("Missing required document: docs/appendix/performance-benchmark.md")

text = appendix.read_text(encoding="utf-8")

required_headings = [
    "# 선택 사항: 과거 성능 benchmark",
    "## active workshop과의 경계",
    "## 보존된 도구",
    "## historical scenarios",
    "## Korea Central historical reference",
    "## retained commands",
]
for heading in required_headings:
    if heading not in text:
        raise SystemExit(f"Appendix is missing required section or title: {heading}")

for item in required:
    if item not in text:
        raise SystemExit(f"Appendix is missing required text: {item}")

if "run-benchmark.sh --scenario" not in text or "--runs 3" not in text or "--output-dir results" not in text:
    raise SystemExit("Appendix must retain the benchmark command contract")

if "python3 scripts/summarize-results.py --input results/raw --output-dir results" not in text:
    raise SystemExit("Appendix must document the summarizer interface")

if not re.search(r"과거 결과는 .* 성능 보장 또는 SLA가 아닙니다", text):
    raise SystemExit("Appendix must clearly state historical numbers are not guarantees")

if re.search(r"(현재|current).{0,20}(워크숍|workshop).{0,20}(결과|results)", text, re.I):
    raise SystemExit("Appendix must not present historical numbers as current workshop results")

for reference in (
    "[Markdown](../reference/korea-central-2026-08-23.md)",
    "[JSON](../reference/korea-central-2026-08-23.json)",
):
    if reference not in text:
        raise SystemExit(f"Appendix is missing historical reference link: {reference}")

print("PASS: optional performance appendix contract")

PY
