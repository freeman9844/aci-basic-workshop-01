#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_step() {
  local label="$1"
  shift
  printf '==> %s\n' "$label"
  "$@"
}

cd "$ROOT"

run_step "Syntax-checking workshop shell scripts" bash -n scripts/*.sh
run_step "Running Python unit tests" python3 -m unittest discover -s tests -p 'test_*.py' -v
run_step "Running shell script contract tests" bash tests/scripts/test-check-standby-pool.sh
run_step "Running benchmark orchestration tests" bash tests/scripts/test-run-benchmark.sh
run_step "Running preflight tests" bash tests/scripts/test-preflight.sh
run_step "Running cleanup tests" bash tests/scripts/test-cleanup.sh
run_step "Running overview documentation tests" bash tests/docs/test-overview.sh
run_step "Running prerequisites/foundation documentation tests" bash tests/docs/test-prerequisites-foundation.sh
run_step "Running dual VN2 installation documentation tests" bash tests/docs/test-install-dual-vn2.sh
run_step "Running benchmark module documentation tests" bash tests/docs/test-benchmark-modules.sh
run_step "Running analysis/cleanup documentation tests" bash tests/docs/test-analysis-cleanup.sh
run_step "Syntax-checking documented bash fences" bash tests/docs/test-shell-survivability.sh

run_step "Running integration contract checks" python3 - "$ROOT" <<'PY'
import ast
import os
import re
import sys
import tokenize
from pathlib import Path

root = Path(sys.argv[1])
expected_chart = "1.3410.26081102"
expected_image = "mcr.microsoft.com/azure-cli@sha256:0df3dcd6f4342770c2f0992c6c6552297fe8433195372fc2438a7c00bf3fd826"
expected_scenarios = {
    "aks",
    "vn2-ondemand",
    "vn2-standby-uncached",
    "vn2-standby-cached",
}
expected_scenario_order = [
    "aks",
    "vn2-ondemand",
    "vn2-standby-uncached",
    "vn2-standby-cached",
]
expected_navigation = {
    "01": ("../README.md", "./02-azure-foundation.md"),
    "02": ("./01-prerequisites.md", "./03-install-dual-vn2.md"),
    "03": ("./02-azure-foundation.md", "./04-baseline-ondemand-benchmark.md"),
    "04": ("./03-install-dual-vn2.md", "./05-standby-cache-benchmark.md"),
    "05": ("./04-baseline-ondemand-benchmark.md", "./06-analyze-results.md"),
    "06": ("./05-standby-cache-benchmark.md", "./07-limitations-troubleshooting-cleanup.md"),
    "07": ("./06-analyze-results.md", "../README.md"),
}
marker_pattern = re.compile(r"\b(?:TODO|TBD|FIXME|incomplete)\b", re.IGNORECASE)
korean_markers = ("작성 예정", "미정")
module_paths = {
    key: root / "docs" / name
    for key, name in (
        ("01", "01-prerequisites.md"),
        ("02", "02-azure-foundation.md"),
        ("03", "03-install-dual-vn2.md"),
        ("04", "04-baseline-ondemand-benchmark.md"),
        ("05", "05-standby-cache-benchmark.md"),
        ("06", "06-analyze-results.md"),
        ("07", "07-limitations-troubleshooting-cleanup.md"),
    )
}

required_files = [
    root / ".gitignore",
    root / "README.md",
    root / "tests/validate-workshop.sh",
    root / ".github/workflows/validate-workshop.yml",
    *module_paths.values(),
    *sorted((root / "manifests").glob("*.yaml")),
    *sorted((root / "scripts").glob("*.sh")),
    *sorted((root / "scripts").glob("*.py")),
    *sorted((root / "tests").glob("test_*.py")),
    *sorted((root / "tests/docs").glob("*.sh")),
    *sorted((root / "tests/scripts").glob("*.sh")),
]

for path in required_files:
    if not path.exists():
        raise SystemExit(f"Missing required file: {path.relative_to(root).as_posix()}")
    if path.stat().st_size == 0:
        raise SystemExit(f"Required file is empty: {path.relative_to(root).as_posix()}")

validator = root / "tests/validate-workshop.sh"
if not os.access(validator, os.X_OK):
    raise SystemExit("tests/validate-workshop.sh must be executable")


def scan_text_file(path):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if marker_pattern.search(line) or any(marker in line for marker in korean_markers):
            raise SystemExit(
                f"Incomplete marker found in {path.relative_to(root).as_posix()}:{line_number}: {line.strip()}"
            )


def scan_shell_comments(path):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith("#!") or not stripped.startswith("#"):
            continue
        comment = stripped[1:]
        if marker_pattern.search(comment) or any(marker in comment for marker in korean_markers):
            raise SystemExit(
                f"Incomplete marker found in {path.relative_to(root).as_posix()}:{line_number}: {line.strip()}"
            )


def scan_python_comments(path):
    with open(path, "r", encoding="utf-8") as handle:
        for token in tokenize.generate_tokens(handle.readline):
            if token.type != tokenize.COMMENT:
                continue
            if marker_pattern.search(token.string) or any(marker in token.string for marker in korean_markers):
                raise SystemExit(
                    f"Incomplete marker found in {path.relative_to(root).as_posix()}:{token.start[0]}: {token.string.strip()}"
                )


scan_text_file(root / "README.md")
for path in sorted((root / "docs").glob("*.md")):
    scan_text_file(path)
for path in sorted((root / "manifests").glob("*.yaml")):
    scan_text_file(path)
scan_text_file(root / ".github/workflows/validate-workshop.yml")
for path in sorted((root / "scripts").glob("*.sh")):
    scan_shell_comments(path)
for path in sorted((root / "tests").rglob("*.sh")):
    scan_shell_comments(path)
for path in sorted((root / "scripts").glob("*.py")):
    scan_python_comments(path)
for path in sorted((root / "tests").glob("test_*.py")):
    scan_python_comments(path)

readme_text = (root / "README.md").read_text(encoding="utf-8")

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

required_readme_fragments = [
    "[Module 07](docs/07-limitations-troubleshooting-cleanup.md)의 cleanup 절차",
    "## Operator-only smoke test checklist",
    "Fresh Cloud Shell Bash session",
    "Modules 01-07",
    "two VN2 virtual nodes show Ready concurrently",
    "Standby Pool running count is 5",
    "exactly 12 raw JSON files",
    "results/summary.json, results/summary.csv, and results/summary.md",
    "No timeout/failure samples are hidden",
    'az group exists --name "$RG"',
    "false",
]
for fragment in required_readme_fragments:
    if fragment not in readme_text:
        raise SystemExit(f"README is missing required operator/cleanup text: {fragment}")

for module, path in module_paths.items():
    text = path.read_text(encoding="utf-8")
    previous_target, next_target = expected_navigation[module]
    if f"]({previous_target})" not in text:
        raise SystemExit(f"{path.name} is missing previous link to {previous_target}")
    if f"]({next_target})" not in text:
        raise SystemExit(f"{path.name} is missing next link to {next_target}")


def extract_assignment_literal(path, name):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=path.as_posix())
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == name:
                return ast.literal_eval(node.value)
    raise SystemExit(f"Could not find {name} in {path.relative_to(root).as_posix()}")


collector_scenarios = set(extract_assignment_literal(root / "scripts/collect-pod-latency.py", "VALID_SCENARIOS"))
summary_scenarios = set(extract_assignment_literal(root / "scripts/summarize-results.py", "VALID_SCENARIOS"))
summary_order = list(extract_assignment_literal(root / "scripts/summarize-results.py", "SCENARIO_ORDER"))
if collector_scenarios != expected_scenarios:
    raise SystemExit(f"collect-pod-latency.py scenario contract mismatch: {sorted(collector_scenarios)}")
if summary_scenarios != expected_scenarios:
    raise SystemExit(f"summarize-results.py scenario contract mismatch: {sorted(summary_scenarios)}")
if summary_order != expected_scenario_order:
    raise SystemExit(f"summarize-results.py scenario order mismatch: {summary_order}")

preflight_text = (root / "scripts/preflight.sh").read_text(encoding="utf-8")
chart_match = re.search(r'^VN2_CHART_VERSION="([^"]+)"$', preflight_text, re.MULTILINE)
image_match = re.search(r'^BENCHMARK_IMAGE="([^"]+)"$', preflight_text, re.MULTILINE)
if not chart_match or chart_match.group(1) != expected_chart:
    raise SystemExit("scripts/preflight.sh must pin VN2_CHART_VERSION to 1.3410.26081102")
if not image_match or image_match.group(1) != expected_image:
    raise SystemExit("scripts/preflight.sh must pin the benchmark image digest")
if expected_chart not in (root / "docs/03-install-dual-vn2.md").read_text(encoding="utf-8"):
    raise SystemExit("docs/03-install-dual-vn2.md must document the pinned VN2 chart version")

for manifest_path in sorted((root / "manifests").glob("*.yaml")):
    images = re.findall(r'^\s*image:\s*(\S+)\s*$', manifest_path.read_text(encoding="utf-8"), re.MULTILINE)
    if not images:
        raise SystemExit(f"{manifest_path.relative_to(root).as_posix()} must declare an image")
    for image in images:
        if image != expected_image:
            raise SystemExit(
                f"{manifest_path.relative_to(root).as_posix()} must pin {expected_image}, found {image}"
            )
        if "@sha256:" not in image or re.search(r"mcr\.microsoft\.com/azure-cli:[^@\s]+", image):
            raise SystemExit(f"{manifest_path.relative_to(root).as_posix()} uses a floating benchmark image tag")

workflow_text = (root / ".github/workflows/validate-workshop.yml").read_text(encoding="utf-8")
required_workflow_lines = [
    "name: Validate workshop",
    "on:",
    "  push:",
    "  pull_request:",
    "permissions:",
    "  contents: read",
    "jobs:",
    "  validate:",
    "    runs-on: ubuntu-latest",
    "      - uses: actions/checkout@v4",
    "      - name: Validate workshop",
    "        run: bash tests/validate-workshop.sh",
]
for line in required_workflow_lines:
    if line not in workflow_text:
        raise SystemExit(f"Workflow is missing required line: {line}")
for forbidden in ("azure/login", "AZURE_", "contents: write", "id-token: write", "secrets."):
    if forbidden in workflow_text:
        raise SystemExit(f"Workflow must remain credential-free; found forbidden content: {forbidden}")

print("Integration contract checks passed.")
PY

printf 'PASS: complete ACI VN2 performance workshop validation\n'
