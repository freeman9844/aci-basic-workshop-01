#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$ROOT/tests/validate-workshop.sh"
TEST_DIR="$ROOT/.test-validate-workshop"

cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT
cleanup
mkdir -p "$TEST_DIR"

python3 - "$ROOT" "$VALIDATOR" "$TEST_DIR" <<'PY'
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
validator = Path(sys.argv[2])
test_dir = Path(sys.argv[3])

validator_text = validator.read_text(encoding="utf-8")

required_lines = [
    'run_step "Running hands-on orchestration tests" bash tests/scripts/test-run-hands-on.sh',
    'run_step "Running hands-on module documentation tests" bash tests/docs/test-hands-on-modules.sh',
    'run_step "Running review/cleanup documentation tests" bash tests/docs/test-review-cleanup.sh',
    'run_step "Running optional appendix documentation tests" bash tests/docs/test-performance-appendix.sh',
    'run_step "Appendix: Running benchmark orchestration tests" bash tests/scripts/test-run-benchmark.sh',
    'run_step "Appendix: Running collector unit tests" python3 -m unittest tests.test_collect_pod_latency -v',
    'run_step "Appendix: Running summarizer unit tests" python3 -m unittest tests.test_summarize_results -v',
    'run_step "Appendix: Running NAP capacity checker tests" bash tests/scripts/test-check-nap-capacity.sh',
    'run_step "Appendix: Running NAP template manifest tests" bash tests/manifests/test-nap-workshop-template.sh',
    'run_step "Appendix: Running historical rehearsal reference tests" python3 - "$ROOT" <<\'PY\'',
    "printf 'PASS: complete ACI VN2 hands-on workshop validation\\n'",
]
for required in required_lines:
    if required not in validator_text:
        raise SystemExit(f"Validator is missing required orchestration text: {required}")

for removed in (
    "test-benchmark-modules.sh",
    "test-analysis-cleanup.sh",
    "python3 -m unittest discover -s tests -p 'test_*.py' -v",
    "PASS: complete ACI VN2 performance workshop validation",
):
    if removed in validator_text:
        raise SystemExit(f"Validator still contains stale text: {removed}")

integration_match = re.search(
    r'run_step "Running integration contract checks" python3 - "\$ROOT" <<\'PY\'\n(.*?)\nPY\n',
    validator_text,
    re.S,
)
if not integration_match:
    raise SystemExit("Could not locate the integration contract block in tests/validate-workshop.sh")

integration_script = integration_match.group(1)

copy_sources = [
    ".gitignore",
    "README.md",
    "docs",
    "manifests",
    "scripts",
    "tests",
]


def copy_repository(destination: Path) -> Path:
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for name in copy_sources:
        source = root / name
        target = destination / name
        if source.is_dir():
            shutil.copytree(
                source,
                target,
                ignore=shutil.ignore_patterns(
                    ".git",
                    "__pycache__",
                    ".pytest_cache",
                    ".mypy_cache",
                    ".test-*",
                    "results",
                ),
            )
        else:
            shutil.copy2(source, target)
    validator_copy = destination / "tests/validate-workshop.sh"
    validator_copy.chmod(validator_copy.stat().st_mode | stat.S_IXUSR)
    return destination


def run_integration_contract(fixture_root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-", str(fixture_root)],
        input=integration_script,
        text=True,
        capture_output=True,
        cwd=fixture_root,
        check=False,
    )


readme_fixture = copy_repository(test_dir / "median-in-readme")
readme_path = readme_fixture / "README.md"
readme_path.write_text(
    readme_path.read_text(encoding="utf-8") + "\nmedian\n",
    encoding="utf-8",
)
result = run_integration_contract(readme_fixture)
if result.returncode == 0:
    raise SystemExit("Integration contract must fail when README.md reintroduces median")
combined = f"{result.stdout}\n{result.stderr}"
if "median" not in combined.lower():
    raise SystemExit(
        "README median fixture failed for the wrong reason.\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )

appendix_fixture = copy_repository(test_dir / "median-in-appendix")
appendix_path = appendix_fixture / "docs/appendix/performance-benchmark.md"
appendix_path.write_text(
    appendix_path.read_text(encoding="utf-8") + "\nmedian\n",
    encoding="utf-8",
)
result = run_integration_contract(appendix_fixture)
if result.returncode != 0:
    raise SystemExit(
        "Integration contract must allow median inside docs/appendix/performance-benchmark.md.\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )
if "Integration contract checks passed." not in result.stdout:
    raise SystemExit(
        "Integration contract did not report success for the appendix-only median fixture.\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )

print("PASS: validator separates active and appendix contracts")
PY
