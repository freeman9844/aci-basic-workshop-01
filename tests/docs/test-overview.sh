#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
readme = root / "README.md"
module_files = {
    "01": root / "docs/01-prerequisites.md",
    "02": root / "docs/02-azure-foundation.md",
    "03": root / "docs/03-install-dual-vn2.md",
    "04": root / "docs/04-baseline-ondemand-benchmark.md",
    "05": root / "docs/05-standby-cache-benchmark.md",
    "06": root / "docs/06-analyze-results.md",
    "07": root / "docs/07-limitations-troubleshooting-cleanup.md",
}

missing = [path.relative_to(root).as_posix() for path in [readme, *module_files.values()] if not path.exists()]
if missing:
    raise SystemExit(f"Missing required documentation file(s): {', '.join(missing)}")

readme_text = readme.read_text(encoding="utf-8")
required_readme_strings = [
    "git clone",
    "~/aci-vn2-performance-workshop",
    "150분",
    "Korea Central",
    "5개 Pod × 3회",
    "일반 AKS 노드",
    "VN2 OnDemand",
    "StandbyPool",
    "Image Cache",
    "비용",
    "Module 01",
    "Module 07",
    "Owner",
    "AKS VM",
    "NAT Gateway",
    "public IP",
    "ACI OnDemand",
    "5개의 warm standby",
    "```mermaid",
    "VN2 Helm release: ondemand",
    "VN2 Helm release: standby",
    "Warm UVM, cached image",
    "Mandatory cleanup",
]
for required in required_readme_strings:
    if required not in readme_text:
        raise SystemExit(f"README is missing required text: {required}")

for scenario in ("aks", "vn2-ondemand", "vn2-standby-uncached", "vn2-standby-cached"):
    if scenario not in readme_text:
        raise SystemExit(f"README is missing scenario entry: {scenario}")

module_rows = {}
for line in readme_text.splitlines():
    match = re.match(r"^\|\s*Module\s+(\d{2})\s*\|.*\|\s*(\d+)분\s*\|", line)
    if match:
        module_rows[match.group(1)] = int(match.group(2))

expected_readme_durations = {
    "00": 5,
    "01": 15,
    "02": 30,
    "03": 20,
    "04": 25,
    "05": 25,
    "06": 20,
    "07": 10,
}
if module_rows != expected_readme_durations:
    raise SystemExit(f"README module duration table mismatch: {module_rows}")
if sum(module_rows.values()) != 150:
    raise SystemExit(f"README module duration total must be 150, found {sum(module_rows.values())}")

expected_doc_durations = {
    "01": 15,
    "02": 30,
    "03": 20,
    "04": 25,
    "05": 25,
    "06": 20,
    "07": 10,
}
expected_navigation = {
    "01": ("../README.md", "./02-azure-foundation.md"),
    "02": ("./01-prerequisites.md", "./03-install-dual-vn2.md"),
    "03": ("./02-azure-foundation.md", "./04-baseline-ondemand-benchmark.md"),
    "04": ("./03-install-dual-vn2.md", "./05-standby-cache-benchmark.md"),
    "05": ("./04-baseline-ondemand-benchmark.md", "./06-analyze-results.md"),
    "06": ("./05-standby-cache-benchmark.md", "./07-limitations-troubleshooting-cleanup.md"),
    "07": ("./06-analyze-results.md", "../README.md"),
}

banned_markers = ("TODO", "TBD", "FIXME", "작성 예정", "미정", "incomplete")

for module, path in module_files.items():
    text = path.read_text(encoding="utf-8")
    first_line = text.splitlines()[0] if text.splitlines() else ""
    if not re.match(rf"^# Module {module}\. .*[가-힣]", first_line):
        raise SystemExit(f"{path.name} is missing a final Korean title line")
    for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트", "## 이전/다음"):
        if heading not in text:
            raise SystemExit(f"{path.name} is missing required section: {heading}")
    if f"{expected_doc_durations[module]}분" not in text:
        raise SystemExit(f"{path.name} is missing its duration: {expected_doc_durations[module]}분")
    for marker in banned_markers:
        if marker.lower() in text.lower():
            raise SystemExit(f"{path.name} contains incomplete marker: {marker}")
    non_empty_lines = [line for line in text.splitlines() if line.strip()]
    if len(non_empty_lines) < 20:
        raise SystemExit(f"{path.name} must contain meaningful body content")
    previous_target, next_target = expected_navigation[module]
    if f"]({previous_target})" not in text:
        raise SystemExit(f"{path.name} is missing previous link to {previous_target}")
    if f"]({next_target})" not in text:
        raise SystemExit(f"{path.name} is missing next link to {next_target}")

PY
