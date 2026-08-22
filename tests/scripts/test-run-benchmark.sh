#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/.test-run-benchmark"

cleanup() {
  rm -rf "$TMP"
}

trap cleanup EXIT
cleanup
mkdir -p "$TMP/bin" "$TMP/logs" "$TMP/render" "$TMP/results" "$TMP/state"

cat >"$TMP/bin/check-standby-pool.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/standby.log"
printf '{"health":"healthy","running":5}\n'
EOF
chmod +x "$TMP/bin/check-standby-pool.sh"

cat >"$TMP/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/az.log"
printf '[{"name":"cg-test"}]\n'
EOF
chmod +x "$TMP/bin/az"

cat >"$TMP/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/collector.log"

output=""
run=""
namespace=""
scenario=""

shift
while (($#)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --run)
      run="$2"
      shift 2
      ;;
    --namespace)
      namespace="$2"
      shift 2
      ;;
    --scenario)
      scenario="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$output")"
cat >"$output" <<JSON
{"schema_version":1,"scenario":"$scenario","run":$run,"namespace":"$namespace","completion_reason":"$( [[ "$run" == "2" ]] && printf timeout || printf all_ready )"}
JSON

if [[ "$run" == "2" ]]; then
  exit 2
fi
EOF
chmod +x "$TMP/bin/python3"

cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/kubectl.log"

cmd="${1-}"
subcmd="${2-}"

case "$cmd $subcmd" in
  "create namespace")
    namespace="${3:?}"
    if [[ "${FAIL_CREATE_NAMESPACE:-0}" == "1" ]]; then
      printf 'create namespace failed\n' >&2
      exit 1
    fi
    touch "$TEST_STATE_DIR/ns-$namespace"
    printf 'namespace/%s created\n' "$namespace"
    ;;
  "describe pods")
    printf 'Name: bench-1\n'
    ;;
  "get events")
    printf 'EVENTS\n'
    ;;
  "get nodes")
    printf '{"items":[{"metadata":{"name":"node-1"}}]}\n'
    ;;
  "get namespace")
    namespace="${3:?}"
    if [[ -e "$TEST_STATE_DIR/ns-$namespace" ]]; then
      printf 'namespace/%s\n' "$namespace"
      exit 0
    fi
    printf 'Error from server (NotFound): namespaces "%s" not found\n' "$namespace" >&2
    exit 1
    ;;
  "delete namespace")
    namespace="${3:?}"
    rm -f "$TEST_STATE_DIR/ns-$namespace"
    printf 'namespace "%s" deleted\n' "$namespace"
    ;;
  *)
    printf 'Unexpected kubectl call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"

TEST_LOG_DIR="$TMP/logs" TEST_STATE_DIR="$TMP/state" \
KUBECTL_BIN="$TMP/bin/kubectl" \
AZ_BIN="$TMP/bin/az" \
PYTHON_BIN="$TMP/bin/python3" \
CHECK_STANDBY_BIN="$TMP/bin/check-standby-pool.sh" \
"$ROOT/scripts/run-benchmark.sh" \
  --scenario vn2-ondemand \
  --runs 1 \
  --render-only \
  --output-dir "$TMP/render"

test "$(grep -c '^kind: Pod$' "$TMP/render/vn2-ondemand-run-1.yaml")" -eq 5
grep -F 'benchmark-path: ondemand' "$TMP/render/vn2-ondemand-run-1.yaml" >/dev/null
grep -F 'mcr.microsoft.com/azure-cli@sha256:0df3dcd6f4342770c2f0992c6c6552297fe8433195372fc2438a7c00bf3fd826' \
  "$TMP/render/vn2-ondemand-run-1.yaml" >/dev/null
grep -F 'name: vn2-ondemand-run-1-pod-1' "$TMP/render/vn2-ondemand-run-1.yaml" >/dev/null
grep -F 'name: vn2-ondemand-run-1-pod-5' "$TMP/render/vn2-ondemand-run-1.yaml" >/dev/null

set +e
output="$("$ROOT/scripts/run-benchmark.sh" \
  --scenario nope \
  --runs 1 \
  --render-only \
  --output-dir "$TMP/invalid" 2>&1)"
status=$?
set -e

[[ "$status" -eq 64 ]]
grep -F 'ERROR: unsupported scenario: nope' <<<"$output" >/dev/null

collector_lines_before=0
if [[ -f "$TMP/logs/collector.log" ]]; then
  collector_lines_before="$(wc -l <"$TMP/logs/collector.log")"
fi

set +e
TEST_LOG_DIR="$TMP/logs" TEST_STATE_DIR="$TMP/state" \
KUBECTL_BIN="$TMP/bin/kubectl" \
AZ_BIN="$TMP/bin/az" \
PYTHON_BIN="$TMP/bin/python3" \
CHECK_STANDBY_BIN="$TMP/bin/check-standby-pool.sh" \
FAIL_CREATE_NAMESPACE=1 \
"$ROOT/scripts/run-benchmark.sh" \
  --scenario aks \
  --runs 1 \
  --output-dir "$TMP/create-failure" >/dev/null 2>&1
status=$?
set -e

[[ "$status" -ne 0 ]]
test ! -e "$TMP/create-failure/raw/aks-run-1.json"
collector_lines_after=0
if [[ -f "$TMP/logs/collector.log" ]]; then
  collector_lines_after="$(wc -l <"$TMP/logs/collector.log")"
fi
[[ "$collector_lines_after" -eq "$collector_lines_before" ]]
if find "$TMP/create-failure" -name '*.yaml' -print -quit | grep -q .; then
  echo 'expected failed create path to clean generated manifests' >&2
  exit 1
fi

set +e
TEST_LOG_DIR="$TMP/logs" TEST_STATE_DIR="$TMP/state" \
KUBECTL_BIN="$TMP/bin/kubectl" \
AZ_BIN="$TMP/bin/az" \
PYTHON_BIN="$TMP/bin/python3" \
CHECK_STANDBY_BIN="$TMP/bin/check-standby-pool.sh" \
NAMESPACE_WAIT_INTERVAL_SECONDS=0 \
"$ROOT/scripts/run-benchmark.sh" \
  --scenario vn2-standby-cached \
  --runs 2 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/results"
status=$?
set -e

[[ "$status" -eq 2 ]]
test -f "$TMP/results/raw/vn2-standby-cached-run-1.json"
test -f "$TMP/results/raw/vn2-standby-cached-run-2.json"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-1/kubectl-describe-pods.txt"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-1/kubectl-nodes.json"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-1/az-container-list.json"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-2/kubectl-describe-pods.txt"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-2/kubectl-events.txt"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-2/kubectl-nodes.json"
test -f "$TMP/results/diagnostics/vn2-standby-cached-run-2/az-container-list.json"

python3 - "$TMP/logs/collector.log" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip().splitlines()
namespaces = []
for line in lines:
    parts = line.split()
    for index, part in enumerate(parts):
        if part == "--namespace":
            namespaces.append(parts[index + 1])
            break

if len(namespaces) != 2:
    raise SystemExit(f"expected 2 collector runs, got {len(namespaces)}")
if len(set(namespaces)) != 2:
    raise SystemExit(f"expected unique namespaces, got {namespaces}")
PY

test "$(wc -l <"$TMP/logs/standby.log")" -eq 2
grep -F -- '--expect-running 5' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--resource-group rg-test' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--name pool-test' "$TMP/logs/standby.log" >/dev/null

grep -F 'delete namespace' "$TMP/logs/kubectl.log" >/dev/null
grep -F 'container list --resource-group rg-test --output json' "$TMP/logs/az.log" >/dev/null

if find "$TMP/results" -name '*.yaml' -print -quit | grep -q .; then
  echo 'expected generated manifests to be cleaned after real runs' >&2
  exit 1
fi
