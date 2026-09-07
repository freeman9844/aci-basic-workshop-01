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
    "04": root / "docs/04-vn2-ondemand-hands-on.md",
    "05": root / "docs/05-standby-pool-hands-on.md",
    "06": root / "docs/06-image-cache-hands-on.md",
    "07": root / "docs/07-limitations-troubleshooting-cleanup.md",
}

missing = [path.relative_to(root).as_posix() for path in [readme, *module_files.values()] if not path.exists()]
if missing:
    raise SystemExit(f"Missing required documentation file(s): {', '.join(missing)}")

readme_text = readme.read_text(encoding="utf-8")
required_readme_strings = [
    "# ACI Basic 워크숍",
    "## 모듈 목차",
    "필수 경로는 Module 01 → 07 순서로 진행합니다.",
    "120분",
    "Pod 1개를 한 번",
    "성능 benchmark가 아닙니다",
    "VN2 OnDemand",
    "StandbyPool",
    "Image Cache",
    "Standard_D16s_v5",
    "ready capacity 1",
    "선택 사항: 과거 성능 benchmark",
    "docs/appendix/performance-benchmark.md",
    "docs/04-vn2-ondemand-hands-on.md",
    "docs/05-standby-pool-hands-on.md",
    "docs/06-image-cache-hands-on.md",
    "docs/07-limitations-troubleshooting-cleanup.md",
]
for required in required_readme_strings:
    if required not in readme_text:
        raise SystemExit(f"README is missing required text: {required}")

for removed_heading in ("## 빠른 시작", "## 세션 복구 가이드"):
    if removed_heading in readme_text:
        raise SystemExit(f"README must not contain removed section: {removed_heading}")

for replaced_heading in ("## 모듈 구성", "## 문서 흐름"):
    if replaced_heading in readme_text:
        raise SystemExit(f"README must consolidate the replaced section into 모듈 목차: {replaced_heading}")

if "## 시간표" not in readme_text:
    raise SystemExit("README must include a dedicated 시간표 section")

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
    "Korea Central 2026-08-23 live rehearsal reference",
    "docs/reference/korea-central-2026-08-23.md",
    "docs/reference/korea-central-2026-08-23.json",
):
    if forbidden in readme_text:
        raise SystemExit(f"README must not contain active-flow stale text: {forbidden}")

for scenario in ("vn2-ondemand", "vn2-standby", "vn2-standby-cached"):
    if scenario not in readme_text:
        raise SystemExit(f"README is missing active scenario entry: {scenario}")

module_rows = {}
for line in readme_text.splitlines():
    match = re.match(r"^\|\s*(\d{2})\s*\|.*\|\s*(\d+)분\s*\|", line)
    if match:
        module_rows[match.group(1)] = int(match.group(2))

expected_readme_durations = {
    "00": 5,
    "01": 15,
    "02": 30,
    "03": 20,
    "04": 10,
    "05": 15,
    "06": 15,
    "07": 10,
}
if module_rows != expected_readme_durations:
    raise SystemExit(f"README module duration table mismatch: {module_rows}")
if sum(module_rows.values()) != 120:
    raise SystemExit(f"README module duration total must be 120, found {sum(module_rows.values())}")

expected_doc_durations = {
    "01": 15,
    "02": 30,
    "03": 20,
    "04": 10,
    "05": 15,
    "06": 15,
    "07": 10,
}
expected_navigation = {
    "01": ("../README.md", "./02-azure-foundation.md"),
    "02": ("./01-prerequisites.md", "./03-install-dual-vn2.md"),
    "03": ("./02-azure-foundation.md", "./04-vn2-ondemand-hands-on.md"),
    "04": ("./03-install-dual-vn2.md", "./05-standby-pool-hands-on.md"),
    "05": ("./04-vn2-ondemand-hands-on.md", "./06-image-cache-hands-on.md"),
    "06": ("./05-standby-pool-hands-on.md", "./07-limitations-troubleshooting-cleanup.md"),
    "07": ("./06-image-cache-hands-on.md", "../README.md"),
}

banned_markers = ("TODO", "TBD", "FIXME", "작성 예정", "미정", "incomplete")

for module, path in module_files.items():
    text = path.read_text(encoding="utf-8")
    first_line = text.splitlines()[0] if text.splitlines() else ""
    if not re.match(rf"^# {module}\. .*[가-힣]", first_line):
        raise SystemExit(f"{path.name} is missing a final Korean title line")
    for heading in ("## 목표", "## 예상 소요 시간", "## 시작 전 상태", "## 진행 순서", "## 완료 체크포인트"):
        if heading not in text:
            raise SystemExit(f"{path.name} is missing required section: {heading}")
    duration_match = re.search(r"^## 예상 소요 시간\s*\n\s*(\d+)분\s*$", text, re.M)
    if not duration_match:
        raise SystemExit(f"{path.name} is missing an exact duration under 예상 소요 시간")
    duration = int(duration_match.group(1))
    if duration != expected_doc_durations[module]:
        raise SystemExit(
            f"{path.name} duration mismatch: expected {expected_doc_durations[module]}분, found {duration}분"
        )
    if duration != module_rows[module]:
        raise SystemExit(
            f"{path.name} duration {duration}분 disagrees with README {module_rows[module]}분"
        )
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

participant_total = module_rows["00"] + sum(expected_doc_durations.values())
if participant_total != 120:
    raise SystemExit(f"Cross-file participant duration total must be 120, found {participant_total}")

if "중간에 shell/session을 바꾸지 않았다." in readme_text:
    raise SystemExit("README must not require a single uninterrupted shell session anymore")

print("PASS: 120-minute workshop overview matches the active hands-on contract")
PY
