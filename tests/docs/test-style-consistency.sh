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

legend_rows = (
    "| 🟢 **실행** |",
    "| 👁️ **설명** |",
    "| 📋 **예상 출력** |",
    "| ⚠️ **주의** |",
)
marker_lines = (
    "👁️ **설명**",
    "🟢 **실행**",
    "📋 **예상 출력**",
    "⚠️ **주의**",
)
step_heading_pattern = re.compile(r"^(## 0\. .+|### \d+\) .+)$", re.M)
bash_block_pattern = re.compile(r"```bash\n.*?```", re.S)


def fail(message: str) -> None:
    raise SystemExit(message)


def validate_marker_standalone(path: Path, section_heading: str, body: str) -> None:
    inside_code = False
    for line_number, line in enumerate(body.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("```"):
            inside_code = not inside_code
            continue
        if inside_code:
            continue
        for marker in marker_lines:
            if marker in line and stripped != marker:
                fail(
                    f"{path.name} step '{section_heading}' must keep marker '{marker}' on its own line"
                )


def validate_step(path: Path, heading: str, body: str) -> None:
    validate_marker_standalone(path, heading, body)

    markers_in_step = [line.strip() for line in body.splitlines() if line.strip() in marker_lines]
    if not markers_in_step:
        fail(f"{path.name} step '{heading}' must contain at least one standalone marker")

    previous_end = 0
    for index, match in enumerate(bash_block_pattern.finditer(body), start=1):
        prefix = body[previous_end:match.start()]
        if "🟢 **실행**" not in prefix:
            fail(
                f"{path.name} step '{heading}' bash block {index} must be introduced by '🟢 **실행**'"
            )
        previous_end = match.end()


def extract_step_sections(text: str):
    progress_match = re.search(r"## 진행 순서\s*(.*?)\n## 완료 체크포인트", text, re.S)
    if not progress_match:
        fail("Document is missing a bounded '## 진행 순서' section")
    progress_body = progress_match.group(1)
    matches = list(step_heading_pattern.finditer(progress_body))
    if not matches:
        fail("Document must contain numbered participant step headings inside '## 진행 순서'")
    sections = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(progress_body)
        sections.append((match.group(1), progress_body[start:end]))
    return sections


readme_text = readme.read_text(encoding="utf-8")
readme_lines = [line for line in readme_text.splitlines() if line.strip()]
if len(readme_lines) < 2:
    fail("README.md must contain a title and summary")
if not re.match(r"^# .+", readme_lines[0]):
    fail("README.md must start with a level-1 title")
if not readme_lines[1].startswith("> "):
    fail("README.md title must be followed by a concise blockquote summary")

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
        fail(f"README.md is missing workshop style section: {heading}")

if readme_text.count("\n---\n") < 8:
    fail("README.md must use horizontal separators between major sections")

prereq_table_pattern = re.compile(r"## 사전 요구사항.*?\n\|[^\n]+\|\n\|(?:-+\|)+", re.S)
if not prereq_table_pattern.search(readme_text):
    fail("README.md must present prerequisites as a table")

module_table_pattern = re.compile(
    r"## 모듈 구성.*?\n\|\s*Module\s*\|\s*주제\s*\|\s*시간\s*\|\s*결과\s*\|",
    re.S,
)
if not module_table_pattern.search(readme_text):
    fail("README.md must include the module outcome/time table")

for row in legend_rows:
    if row not in readme_text:
        fail(f"README.md shared tag legend is missing: {row}")

for module, path in module_files.items():
    text = path.read_text(encoding="utf-8")
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 3:
        fail(f"{path.name} must contain a title, summary, and body")
    if not re.match(rf"^# {module}\. .+", lines[0]):
        fail(f"{path.name} must start with '# {module}. ...'")
    if not lines[1].startswith("> "):
        fail(f"{path.name} must place a concise blockquote summary after the title")

    for heading in ("## 목표", "## 태그 범례", "## 완료 체크포인트", "## 문제 해결", "## 이전/다음"):
        if heading not in text:
            fail(f"{path.name} is missing style section: {heading}")

    for row in legend_rows:
        if row not in text:
            fail(f"{path.name} shared tag legend is missing: {row}")

    step_sections = extract_step_sections(text)
    if not any(heading.startswith("### 1)") for heading, _ in step_sections):
        fail(f"{path.name} must keep numbered step headings")

    for heading, body in step_sections:
        validate_step(path, heading, body)

    nav_section = re.search(r"## 이전/다음\s*\n+(- .+\n){2,}", text)
    if not nav_section:
        fail(f"{path.name} must keep previous/next navigation as bullet links")

print("PASS: workshop style consistency contract")
PY
