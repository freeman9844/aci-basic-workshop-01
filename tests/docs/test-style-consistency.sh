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

tag_rows = (
    "| 🟢 **실행** |",
    "| 👁️ **설명** |",
    "| 📋 **예상 출력** |",
    "| ⚠️ **주의** |",
)

readme_text = readme.read_text(encoding="utf-8")
readme_lines = [line for line in readme_text.splitlines() if line.strip()]
if len(readme_lines) < 2:
    raise SystemExit("README.md must contain a title and summary")
if not re.match(r"^# .+", readme_lines[0]):
    raise SystemExit("README.md must start with a level-1 title")
if not readme_lines[1].startswith("> "):
    raise SystemExit("README.md title must be followed by a concise blockquote summary")

required_readme_sections = (
    "## 빠른 시작",
    "## 아키텍처",
    "## 학습 목표",
    "## 사전 요구사항",
    "## 모듈 구성",
    "## 세션 복구 가이드",
    "## 완료 기준",
    "## 시간표",
    "## 비용 개요",
    "## 태그 범례",
    "## 트러블슈팅 색인",
    "## 참고 자료",
)
for heading in required_readme_sections:
    if heading not in readme_text:
        raise SystemExit(f"README.md is missing workshop style section: {heading}")

if readme_text.count("\n---\n") < 8:
    raise SystemExit("README.md must use horizontal separators between major sections")

prereq_table_pattern = re.compile(r"## 사전 요구사항.*?\n\|[^\n]+\|\n\|(?:-+\|)+", re.S)
if not prereq_table_pattern.search(readme_text):
    raise SystemExit("README.md must present prerequisites as a table")

module_table_pattern = re.compile(
    r"## 모듈 구성.*?\n\|\s*Module\s*\|\s*주제\s*\|\s*시간\s*\|\s*결과\s*\|",
    re.S,
)
if not module_table_pattern.search(readme_text):
    raise SystemExit("README.md must include the module outcome/time table")

for row in tag_rows:
    if row not in readme_text:
        raise SystemExit(f"README.md shared tag legend is missing: {row}")

for module, path in module_files.items():
    text = path.read_text(encoding="utf-8")
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 3:
        raise SystemExit(f"{path.name} must contain a title, summary, and body")
    if not re.match(rf"^# {module}\. .+", lines[0]):
        raise SystemExit(f"{path.name} must start with '# {module}. ...'")
    if not lines[1].startswith("> "):
        raise SystemExit(f"{path.name} must place a concise blockquote summary after the title")

    for heading in ("## 목표", "## 태그 범례", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
        if heading not in text:
            raise SystemExit(f"{path.name} is missing style section: {heading}")

    for row in tag_rows:
        if row not in text:
            raise SystemExit(f"{path.name} shared tag legend is missing: {row}")

    if not re.search(r"^### 1\)", text, re.M):
        raise SystemExit(f"{path.name} must keep numbered step headings")

    body_after_legend = text.split("## 태그 범례", 1)[1]
    markers = [
        "👁️ **설명**",
        "🟢 **실행**",
        "📋 **예상 출력**",
        "⚠️ **주의**",
    ]
    if sum(marker in body_after_legend for marker in markers) < 2:
        raise SystemExit(f"{path.name} must repeat the shared execution markers in the body")

    nav_section = re.search(r"## 이전/다음\s*\n+(- .+\n){2,}", text)
    if not nav_section:
        raise SystemExit(f"{path.name} must keep previous/next navigation as bullet links")

print("PASS: workshop style consistency contract")
PY
