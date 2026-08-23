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

cat >"$TMP/bin/check-standby-pool.sh" <<'FAKE_STANDBY'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/standby.log"
printf '{"health":"healthy","running":5}\n'
FAKE_STANDBY
chmod +x "$TMP/bin/check-standby-pool.sh"

cat >"$TMP/bin/az" <<'FAKE_AZ'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/az.log"
if [[ "${1-}" == "container" && "${2-}" == "list" && "${FAIL_AZ_CONTAINER_LIST:-0}" == "1" ]]; then
  printf 'container list failed\n' >&2
  exit 1
fi
printf '[{"name":"cg-test"}]\n'
FAKE_AZ
chmod +x "$TMP/bin/az"

cat >"$TMP/bin/python3" <<'FAKE_PYTHON'
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
{"schema_version":1,"scenario":"$scenario","run":$run,"namespace":"$namespace","completion_reason":"$( [[ "${COLLECTOR_EXIT_RUN:-}" == "$run" ]] && printf timeout || printf all_ready )"}
JSON

if [[ -n "${COLLECTOR_EXIT_RUN:-}" && "$run" == "$COLLECTOR_EXIT_RUN" ]]; then
  exit "${COLLECTOR_EXIT_CODE:-2}"
fi
FAKE_PYTHON
chmod +x "$TMP/bin/python3"

cat >"$TMP/bin/kubectl" <<'FAKE_KUBECTL'
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
    if [[ "${FAIL_KUBECTL_DESCRIBE_PODS:-0}" == "1" ]]; then
      printf 'describe pods failed\n' >&2
      exit 1
    fi
    printf 'Name: bench-1\n'
    ;;
  "get events")
    if [[ "${FAIL_KUBECTL_GET_EVENTS:-0}" == "1" ]]; then
      printf 'get events failed\n' >&2
      exit 1
    fi
    printf 'EVENTS\n'
    ;;
  "get nodes")
    if [[ "${FAIL_KUBECTL_GET_NODES:-0}" == "1" ]]; then
      printf 'get nodes failed\n' >&2
      exit 1
    fi
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
FAKE_KUBECTL
chmod +x "$TMP/bin/kubectl"

reset_logs() {
  : > "$TMP/logs/standby.log"
  : > "$TMP/logs/az.log"
  : > "$TMP/logs/collector.log"
  : > "$TMP/logs/kubectl.log"
  rm -f "$TMP/state"/*
}

reset_behavior() {
  unset COLLECTOR_EXIT_RUN COLLECTOR_EXIT_CODE
  unset FAIL_CREATE_NAMESPACE FAIL_KUBECTL_DESCRIBE_PODS FAIL_KUBECTL_GET_EVENTS
  unset FAIL_KUBECTL_GET_NODES FAIL_AZ_CONTAINER_LIST
}

run_with_fakes() {
  env \
    TEST_LOG_DIR="$TMP/logs" \
    TEST_STATE_DIR="$TMP/state" \
    KUBECTL_BIN="$TMP/bin/kubectl" \
    AZ_BIN="$TMP/bin/az" \
    PYTHON_BIN="$TMP/bin/python3" \
    CHECK_STANDBY_BIN="$TMP/bin/check-standby-pool.sh" \
    COLLECTOR_EXIT_RUN="${COLLECTOR_EXIT_RUN-}" \
    COLLECTOR_EXIT_CODE="${COLLECTOR_EXIT_CODE-}" \
    FAIL_CREATE_NAMESPACE="${FAIL_CREATE_NAMESPACE-}" \
    FAIL_KUBECTL_DESCRIBE_PODS="${FAIL_KUBECTL_DESCRIBE_PODS-}" \
    FAIL_KUBECTL_GET_EVENTS="${FAIL_KUBECTL_GET_EVENTS-}" \
    FAIL_KUBECTL_GET_NODES="${FAIL_KUBECTL_GET_NODES-}" \
    FAIL_AZ_CONTAINER_LIST="${FAIL_AZ_CONTAINER_LIST-}" \
    "$ROOT/scripts/run-benchmark.sh" "$@"
}

reset_behavior
reset_logs
run_with_fakes \
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

reset_behavior
reset_logs
FAIL_CREATE_NAMESPACE=1
set +e
run_with_fakes \
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

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-standby-uncached \
  --runs 1 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/standby-once"

test -f "$TMP/standby-once/raw/vn2-standby-uncached-run-1.json"
test "$(wc -l <"$TMP/logs/standby.log")" -eq 2
grep -F -- '--expect-running 5' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--resource-group rg-test' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--name pool-test' "$TMP/logs/standby.log" >/dev/null
if find "$TMP/standby-once" -name '*.yaml' -print -quit | grep -q .; then
  echo 'expected one-run standby path to clean generated manifests' >&2
  exit 1
fi

reset_behavior
reset_logs
COLLECTOR_EXIT_RUN=2
COLLECTOR_EXIT_CODE=2
set +e
run_with_fakes \
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

python3 - "$TMP/logs/collector.log" "$TMP/logs/kubectl.log" <<'PY'
import pathlib
import sys

collector_lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip().splitlines()
collector_namespaces = []
for line in collector_lines:
    parts = line.split()
    for index, part in enumerate(parts):
        if part == "--namespace":
            collector_namespaces.append(parts[index + 1])
            break

if len(collector_namespaces) != 2:
    raise SystemExit(f"expected 2 collector runs, got {len(collector_namespaces)}")
if len(set(collector_namespaces)) != 2:
    raise SystemExit(f"expected unique namespaces, got {collector_namespaces}")

kubectl_lines = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").strip().splitlines()
created_namespaces = []
for line in kubectl_lines:
    parts = line.split()
    if parts[:2] == ["create", "namespace"] and len(parts) >= 3:
        created_namespaces.append(parts[2])

if created_namespaces != collector_namespaces:
    raise SystemExit(
        f"collector namespaces {collector_namespaces} did not match created namespaces {created_namespaces}"
    )
PY

test "$(wc -l <"$TMP/logs/standby.log")" -eq 4
grep -F -- '--expect-running 5' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--resource-group rg-test' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--name pool-test' "$TMP/logs/standby.log" >/dev/null

grep -F 'delete namespace' "$TMP/logs/kubectl.log" >/dev/null
grep -F 'container list --resource-group rg-test --output json' "$TMP/logs/az.log" >/dev/null

if find "$TMP/results" -name '*.yaml' -print -quit | grep -q .; then
  echo 'expected generated manifests to be cleaned after real runs' >&2
  exit 1
fi

reset_behavior
reset_logs
COLLECTOR_EXIT_RUN=1
COLLECTOR_EXIT_CODE=2
FAIL_KUBECTL_DESCRIBE_PODS=1
FAIL_KUBECTL_GET_EVENTS=1
FAIL_AZ_CONTAINER_LIST=1
set +e
run_with_fakes \
  --scenario vn2-standby-cached \
  --runs 1 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/diagnostic-failures" \
  >"$TMP/diagnostic-failures.stdout" 2>"$TMP/diagnostic-failures.stderr"
status=$?
set -e

[[ "$status" -eq 2 ]]
test -s "$TMP/diagnostic-failures/raw/vn2-standby-cached-run-1.json"
test -s "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-describe-pods.txt"
test -s "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt"
test -s "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-nodes.json"
test -s "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/az-container-list.json"
grep -F 'exit_status: 1' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-describe-pods.txt" >/dev/null
grep -F 'describe pods failed' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-describe-pods.txt" >/dev/null
grep -F 'exit_status: 1' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt" >/dev/null
grep -F 'get events failed' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-events.txt" >/dev/null
grep -F 'exit_status: 0' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/kubectl-nodes.json" >/dev/null
grep -F 'exit_status: 1' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/az-container-list.json" >/dev/null
grep -F 'container list failed' "$TMP/diagnostic-failures/diagnostics/vn2-standby-cached-run-1/az-container-list.json" >/dev/null
grep -F 'WARN: one or more diagnostic commands failed for vn2-standby-cached run 1' "$TMP/diagnostic-failures.stderr" >/dev/null
test "$(wc -l <"$TMP/logs/standby.log")" -eq 2
grep -F 'delete namespace' "$TMP/logs/kubectl.log" >/dev/null
