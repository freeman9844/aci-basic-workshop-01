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
run_step "Running shell script contract tests" bash tests/scripts/test-check-standby-pool.sh
run_step "Running preflight tests" bash tests/scripts/test-preflight.sh
run_step "Running cleanup tests" bash tests/scripts/test-cleanup.sh
run_step "Running hands-on orchestration tests" bash tests/scripts/test-run-hands-on.sh
run_step "Running validator regression tests" bash tests/scripts/test-validate-workshop.sh
run_step "Running overview documentation tests" bash tests/docs/test-overview.sh
run_step "Running workshop style consistency tests" bash tests/docs/test-style-consistency.sh
run_step "Running prerequisites/foundation documentation tests" bash tests/docs/test-prerequisites-foundation.sh
run_step "Running dual VN2 installation documentation tests" bash tests/docs/test-install-dual-vn2.sh
run_step "Running hands-on module documentation tests" bash tests/docs/test-hands-on-modules.sh
run_step "Running review/cleanup documentation tests" bash tests/docs/test-review-cleanup.sh
run_step "Running optional appendix documentation tests" bash tests/docs/test-performance-appendix.sh
run_step "Syntax-checking documented bash fences" bash tests/docs/test-shell-survivability.sh
run_step "Appendix: Running benchmark orchestration tests" bash tests/scripts/test-run-benchmark.sh
run_step "Appendix: Running collector unit tests" python3 -m unittest tests.test_collect_pod_latency -v
run_step "Appendix: Running summarizer unit tests" python3 -m unittest tests.test_summarize_results -v
run_step "Appendix: Running NAP capacity checker tests" bash tests/scripts/test-check-nap-capacity.sh
run_step "Appendix: Running NAP template manifest tests" bash tests/manifests/test-nap-workshop-template.sh
run_step "Appendix: Running historical rehearsal reference tests" python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
reference_json = root / "docs/reference/korea-central-2026-08-23.json"
reference_markdown = root / "docs/reference/korea-central-2026-08-23.md"
expected_scenarios = {
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
}

for path in (reference_json, reference_markdown):
    if not path.exists():
        raise SystemExit(f"Missing historical reference artifact: {path.relative_to(root).as_posix()}")
    if path.stat().st_size == 0:
        raise SystemExit(f"Historical reference artifact is empty: {path.relative_to(root).as_posix()}")

reference = json.loads(reference_json.read_text(encoding="utf-8"))
markdown = reference_markdown.read_text(encoding="utf-8")

if set(reference.get("scenarios", {})) != expected_scenarios:
    raise SystemExit(f"Historical scenario set mismatch: {sorted(reference.get('scenarios', {}))}")
if reference.get("run_date") != "2026-08-23":
    raise SystemExit("Historical reference must keep run_date 2026-08-23")
if reference.get("environment", {}).get("region") != "koreacentral":
    raise SystemExit("Historical reference must keep region koreacentral")
if reference.get("environment", {}).get("system_node_sku") != "Standard_D16s_v5":
    raise SystemExit("Historical reference must keep system node Standard_D16s_v5")
if reference.get("environment", {}).get("nap_node_sku") != "Standard_D4s_v5":
    raise SystemExit("Historical reference must keep NAP node Standard_D4s_v5")
if reference.get("environment", {}).get("vn2_helm_chart_version") != "1.3410.26081102":
    raise SystemExit("Historical reference must keep the pinned VN2 chart version")
if reference.get("methodology", {}).get("runs_per_scenario") != 3:
    raise SystemExit("Historical reference must keep runs_per_scenario=3")
if reference.get("methodology", {}).get("pods_per_run") != 5:
    raise SystemExit("Historical reference must keep pods_per_run=5")
if reference.get("methodology", {}).get("total_runs") != 12:
    raise SystemExit("Historical reference must keep total_runs=12")
if reference.get("methodology", {}).get("total_ready_pods") != 60:
    raise SystemExit("Historical reference must keep total_ready_pods=60")
if reference.get("methodology", {}).get("raw_json_files") != 12:
    raise SystemExit("Historical reference must keep raw_json_files=12")
if not reference.get("methodology", {}).get("reference_only"):
    raise SystemExit("Historical reference must remain reference_only")
if not reference.get("methodology", {}).get("not_sla"):
    raise SystemExit("Historical reference must remain not_sla")

scenarios = reference["scenarios"]
baseline = scenarios["vn2-ondemand"]
for scenario_name, scenario in scenarios.items():
    if scenario.get("runs_count") != 3:
        raise SystemExit(f"Historical scenario {scenario_name} must keep runs_count=3")
    if scenario.get("ready_samples") != 15:
        raise SystemExit(f"Historical scenario {scenario_name} must keep ready_samples=15")
    if scenario.get("failed_count") != 0:
        raise SystemExit(f"Historical scenario {scenario_name} must keep failed_count=0")
    if scenario.get("timeout_count") != 0:
        raise SystemExit(f"Historical scenario {scenario_name} must keep timeout_count=0")
    for metric in (
        "create_to_ready_ms",
        "batch_first_ready_ms",
        "batch_all_ready_ms",
    ):
        payload = scenario.get(metric, {})
        if not isinstance(payload.get("median"), (int, float)):
            raise SystemExit(f"Historical scenario {scenario_name} is missing numeric {metric}.median")
        if not isinstance(payload.get("p95"), (int, float)):
            raise SystemExit(f"Historical scenario {scenario_name} is missing numeric {metric}.p95")

for scenario_name in ("aks-nap", "vn2-standby", "vn2-standby-cached"):
    scenario = scenarios[scenario_name]
    expected_pod_ratio = round(
        baseline["create_to_ready_ms"]["median"]
        / scenario["create_to_ready_ms"]["median"],
        3,
    )
    expected_batch_ratio = round(
        baseline["batch_all_ready_ms"]["median"]
        / scenario["batch_all_ready_ms"]["median"],
        3,
    )
    comparisons = reference.get("comparisons", {}).get(scenario_name, {})
    if comparisons.get("pod_speedup_ratio") != expected_pod_ratio:
        raise SystemExit(f"Historical scenario {scenario_name} pod ratio mismatch")
    if comparisons.get("batch_speedup_ratio") != expected_batch_ratio:
        raise SystemExit(f"Historical scenario {scenario_name} batch ratio mismatch")

for required in (
    "5 Pods × 3",
    "0→1→0",
    "healthy",
    "running=5",
    "5→0→5",
    "fallback",
    "reference",
    "SLA",
    "ACI inventory diagnostic was not captured",
    "skip placeholder",
    "does not substitute for the missing ACI inventory",
):
    if required not in markdown:
        raise SystemExit(f"Historical reference markdown is missing required text: {required}")

print("PASS: historical rehearsal reference appendix contract")
PY
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
active_scenarios = {
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
}
appendix_scenarios = {
    "aks-nap",
    *active_scenarios,
}
appendix_scenario_order = [
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
]
expected_navigation = {
    "01": ("../README.md", "./02-azure-foundation.md"),
    "02": ("./01-prerequisites.md", "./03-install-dual-vn2.md"),
    "03": ("./02-azure-foundation.md", "./04-vn2-ondemand-hands-on.md"),
    "04": ("./03-install-dual-vn2.md", "./05-standby-pool-hands-on.md"),
    "05": ("./04-vn2-ondemand-hands-on.md", "./06-image-cache-hands-on.md"),
    "06": ("./05-standby-pool-hands-on.md", "./07-limitations-troubleshooting-cleanup.md"),
    "07": ("./06-image-cache-hands-on.md", "../README.md"),
}
marker_pattern = re.compile(r"\b(?:TODO|TBD|FIXME|incomplete)\b", re.IGNORECASE)
korean_markers = ("작성 예정", "미정")
active_module_paths = {
    "01": root / "docs/01-prerequisites.md",
    "02": root / "docs/02-azure-foundation.md",
    "03": root / "docs/03-install-dual-vn2.md",
    "04": root / "docs/04-vn2-ondemand-hands-on.md",
    "05": root / "docs/05-standby-pool-hands-on.md",
    "06": root / "docs/06-image-cache-hands-on.md",
    "07": root / "docs/07-limitations-troubleshooting-cleanup.md",
}
active_paths = {
    root / "README.md",
    *active_module_paths.values(),
    root / "scripts/preflight.sh",
    root / "scripts/run-hands-on.sh",
    root / "scripts/check-standby-pool.sh",
    root / "scripts/cleanup.sh",
    root / "manifests/hands-on-pod-template.yaml",
    root / "manifests/image-cache-pod.yaml",
}
appendix_paths = {
    root / "docs/appendix/performance-benchmark.md",
    root / "scripts/run-benchmark.sh",
    root / "scripts/collect-pod-latency.py",
    root / "scripts/summarize-results.py",
    root / "scripts/check-nap-capacity.sh",
    root / "manifests/benchmark-pod-template.yaml",
    root / "manifests/nap-workshop-template.yaml",
    root / "docs/reference/korea-central-2026-08-23.md",
    root / "docs/reference/korea-central-2026-08-23.json",
}
required_paths = {
    root / ".gitignore",
    root / "tests/validate-workshop.sh",
    root / "tests/scripts/test-validate-workshop.sh",
    *active_paths,
    *appendix_paths,
}
text_paths = {
    root / "README.md",
    *active_module_paths.values(),
    root / "docs/appendix/performance-benchmark.md",
    root / "docs/reference/korea-central-2026-08-23.md",
    root / "docs/reference/korea-central-2026-08-23.json",
    *sorted((root / "manifests").glob("*.yaml")),
}
shell_paths = {
    *sorted((root / "scripts").glob("*.sh")),
    *sorted((root / "tests").rglob("*.sh")),
}
python_paths = {
    *sorted((root / "scripts").glob("*.py")),
    *sorted((root / "tests").glob("test_*.py")),
}
active_forbidden = (
    r"\baks-nap\b",
    r"\bStandard_D4s_v5\b",
    r"\bworkshop-nap\b",
    r"--runs\b",
    r"\bmedian\b",
    r"\bp95\b",
    r"\bspeed-up\b",
    r"\b12 raw JSON\b",
    r"\b60 Pod\b",
)

for path in sorted(required_paths):
    if not path.exists():
        raise SystemExit(f"Missing required file: {path.relative_to(root).as_posix()}")
    if path.stat().st_size == 0:
        raise SystemExit(f"Required file is empty: {path.relative_to(root).as_posix()}")

validator = root / "tests/validate-workshop.sh"
if not os.access(validator, os.X_OK):
    raise SystemExit("tests/validate-workshop.sh must be executable")

unexpected_sitecustomize = root / "sitecustomize.py"
if unexpected_sitecustomize.exists():
    raise SystemExit(
        "Root sitecustomize.py must not exist; Python auto-loads it globally and no slash-style import/invocation remains."
    )


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


for path in sorted(text_paths):
    scan_text_file(path)
for path in sorted(shell_paths):
    scan_shell_comments(path)
for path in sorted(python_paths):
    scan_python_comments(path)

readme_text = (root / "README.md").read_text(encoding="utf-8")
module_rows = {}
for line in readme_text.splitlines():
    match = re.match(r"^\|\s*Module\s+(\d{2})\s*\|.*\|\s*(\d+)분\s*\|", line)
    if match:
        module_rows[match.group(1)] = int(match.group(2))

if not set(active_module_paths).issubset(module_rows):
    raise SystemExit(f"README module duration table is missing active modules: {module_rows}")
if sum(module_rows.values()) != 120:
    raise SystemExit(f"README module duration total must be 120, found {sum(module_rows.values())}")

for scenario in active_scenarios:
    if scenario not in readme_text:
        raise SystemExit(f"README is missing active scenario reference: {scenario}")

for module, path in active_module_paths.items():
    text = path.read_text(encoding="utf-8")
    previous_target, next_target = expected_navigation[module]
    if f"]({previous_target})" not in text:
        raise SystemExit(f"{path.name} is missing previous link to {previous_target}")
    if f"]({next_target})" not in text:
        raise SystemExit(f"{path.name} is missing next link to {next_target}")

module02_text = active_module_paths["02"].read_text(encoding="utf-8")
module03_text = active_module_paths["03"].read_text(encoding="utf-8")
preflight_text = (root / "scripts/preflight.sh").read_text(encoding="utf-8")
chart_match = re.search(r'^VN2_CHART_VERSION="([^"]+)"$', preflight_text, re.MULTILINE)
image_match = re.search(r'^HANDS_ON_IMAGE="([^"]+)"$', preflight_text, re.MULTILINE)
vm_headroom_match = re.search(r'^REQUIRED_VM_VCPU_HEADROOM="([^"]+)"$', preflight_text, re.MULTILINE)
az_version_match = re.search(r'^MIN_AZ_VERSION="([^"]+)"$', preflight_text, re.MULTILINE)
if not chart_match or chart_match.group(1) != expected_chart:
    raise SystemExit("scripts/preflight.sh must pin VN2_CHART_VERSION to 1.3410.26081102")
if not image_match or image_match.group(1) != expected_image:
    raise SystemExit("scripts/preflight.sh must pin the hands-on image digest")
if not vm_headroom_match or vm_headroom_match.group(1) != "16":
    raise SystemExit("scripts/preflight.sh must require 16 regional vCPU headroom")
if not az_version_match or az_version_match.group(1) != "2.76.0":
    raise SystemExit("scripts/preflight.sh must require Azure CLI 2.76.0")
if expected_chart not in module03_text:
    raise SystemExit("docs/03-install-dual-vn2.md must document the pinned VN2 chart version")
if "standbyPool.maxReadyCapacity=1" not in module03_text:
    raise SystemExit("docs/03-install-dual-vn2.md must document standbyPool.maxReadyCapacity=1")
if "--node-provisioning-mode Auto" not in module02_text:
    raise SystemExit("docs/02-azure-foundation.md must keep --node-provisioning-mode Auto")
if "--node-provisioning-default-pools None" not in module02_text:
    raise SystemExit("docs/02-azure-foundation.md must keep --node-provisioning-default-pools None")

for path in sorted(active_paths):
    text = path.read_text(encoding="utf-8")
    for pattern in active_forbidden:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            line_number = text.count("\n", 0, match.start()) + 1
            line = text.splitlines()[line_number - 1]
            if (
                path == root / "scripts/run-hands-on.sh"
                and pattern == r"--runs\b"
                and line.strip() == "--runs|--pod-count|--percentile|--baseline)"
            ):
                continue
            raise SystemExit(
                "Historical benchmark term leaked into active scope: "
                f"{path.relative_to(root).as_posix()}:{line_number}: {match.group(0)}"
            )


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
if collector_scenarios != appendix_scenarios:
    raise SystemExit(f"collect-pod-latency.py scenario contract mismatch: {sorted(collector_scenarios)}")
if summary_scenarios != appendix_scenarios:
    raise SystemExit(f"summarize-results.py scenario contract mismatch: {sorted(summary_scenarios)}")
if summary_order != appendix_scenario_order:
    raise SystemExit(f"summarize-results.py scenario order mismatch: {summary_order}")
if not active_scenarios.issubset(summary_scenarios):
    raise SystemExit("summarize-results.py must continue to retain all active scenarios")

for manifest_path in sorted({root / "manifests/hands-on-pod-template.yaml", root / "manifests/image-cache-pod.yaml"}):
    manifest_text = manifest_path.read_text(encoding="utf-8")
    images = re.findall(r'^\s*image:\s*(\S+)\s*$', manifest_text, re.MULTILINE)
    if not images:
        raise SystemExit(f"{manifest_path.relative_to(root).as_posix()} Pod manifest must declare an image")
    for image in images:
        if image != expected_image:
            raise SystemExit(
                f"{manifest_path.relative_to(root).as_posix()} must pin {expected_image}, found {image}"
            )
        if "@sha256:" not in image or re.search(r"mcr\.microsoft\.com/azure-cli:[^@\s]+", image):
            raise SystemExit(f"{manifest_path.relative_to(root).as_posix()} uses a floating hands-on image tag")

print("Integration contract checks passed.")
PY

printf 'PASS: complete ACI VN2 hands-on workshop validation\n'
