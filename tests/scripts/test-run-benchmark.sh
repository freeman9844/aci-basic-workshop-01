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
call_number="$(wc -l <"$TEST_LOG_DIR/standby.log")"
if [[ "${SLOW_STANDBY_CALL:-}" == "$call_number" ]]; then
  sleep "${SLOW_STANDBY_SECONDS:-4}"
fi
printf '{"health":"healthy","running":5}\n'
FAKE_STANDBY
chmod +x "$TMP/bin/check-standby-pool.sh"

cat >"$TMP/bin/check-nap-capacity.sh" <<'FAKE_NAP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG_DIR/nap.log"
call_number="$(wc -l <"$TEST_LOG_DIR/nap.log")"
if [[ "${SLOW_NAP_CALL:-}" == "$call_number" ]]; then
  sleep "${SLOW_NAP_SECONDS:-4}"
fi
printf '{"health":"ready","node_pool":"workshop-nap","nodes":0,"nodeclaims":0,"ready":true}\n'
FAKE_NAP
chmod +x "$TMP/bin/check-nap-capacity.sh"

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
timeout_seconds=""

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
    --timeout-seconds)
      timeout_seconds="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "${SLOW_COLLECTOR:-0}" == "1" ]]; then
  if [[ "${COLLECTOR_HONOR_TIMEOUT:-0}" == "1" ]]; then
    sleep "$timeout_seconds"
  else
    sleep "${SLOW_COLLECTOR_SECONDS:-4}"
  fi
fi

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
if [[ -n "${SLOW_KUBECTL_PREFIX:-}" && "$*" == "${SLOW_KUBECTL_PREFIX}"* ]]; then
  sleep "${SLOW_KUBECTL_SECONDS:-4}"
fi

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
    if [[ "${CREATE_NAMESPACE_THEN_SLEEP:-0}" == "1" ]]; then
      sleep "${CREATE_NAMESPACE_SLEEP_SECONDS:-4}"
    fi
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
  "get nodepool")
    printf 'apiVersion: karpenter.sh/v1\nkind: NodePool\nmetadata:\n  name: workshop-nap\n'
    ;;
  "get nodeclaims")
    printf 'apiVersion: v1\nitems: []\n'
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
  : > "$TMP/logs/nap.log"
  : > "$TMP/logs/az.log"
  : > "$TMP/logs/collector.log"
  : > "$TMP/logs/kubectl.log"
  rm -f "$TMP/state"/*
}

reset_behavior() {
  unset COLLECTOR_EXIT_RUN COLLECTOR_EXIT_CODE
  unset FAIL_CREATE_NAMESPACE CREATE_NAMESPACE_THEN_SLEEP CREATE_NAMESPACE_SLEEP_SECONDS
  unset FAIL_KUBECTL_DESCRIBE_PODS FAIL_KUBECTL_GET_EVENTS
  unset FAIL_KUBECTL_GET_NODES FAIL_AZ_CONTAINER_LIST
  unset SLOW_STANDBY_CALL SLOW_STANDBY_SECONDS SLOW_NAP_CALL SLOW_NAP_SECONDS
  unset SLOW_COLLECTOR SLOW_COLLECTOR_SECONDS COLLECTOR_HONOR_TIMEOUT
  unset SLOW_KUBECTL_PREFIX SLOW_KUBECTL_SECONDS
  unset TIMEOUT_SECONDS POST_COLLECTOR_RESERVE_SECONDS
  unset NAMESPACE_WAIT_TIMEOUT_SECONDS
}

run_with_fakes() {
  env \
    TEST_LOG_DIR="$TMP/logs" \
    TEST_STATE_DIR="$TMP/state" \
    KUBECTL_BIN="$TMP/bin/kubectl" \
    AZ_BIN="$TMP/bin/az" \
    PYTHON_BIN="$TMP/bin/python3" \
    CHECK_STANDBY_BIN="$TMP/bin/check-standby-pool.sh" \
    CHECK_NAP_BIN="$TMP/bin/check-nap-capacity.sh" \
    COLLECTOR_EXIT_RUN="${COLLECTOR_EXIT_RUN-}" \
    COLLECTOR_EXIT_CODE="${COLLECTOR_EXIT_CODE-}" \
    FAIL_CREATE_NAMESPACE="${FAIL_CREATE_NAMESPACE-}" \
    CREATE_NAMESPACE_THEN_SLEEP="${CREATE_NAMESPACE_THEN_SLEEP-}" \
    CREATE_NAMESPACE_SLEEP_SECONDS="${CREATE_NAMESPACE_SLEEP_SECONDS-}" \
    FAIL_KUBECTL_DESCRIBE_PODS="${FAIL_KUBECTL_DESCRIBE_PODS-}" \
    FAIL_KUBECTL_GET_EVENTS="${FAIL_KUBECTL_GET_EVENTS-}" \
    FAIL_KUBECTL_GET_NODES="${FAIL_KUBECTL_GET_NODES-}" \
    FAIL_AZ_CONTAINER_LIST="${FAIL_AZ_CONTAINER_LIST-}" \
    SLOW_STANDBY_CALL="${SLOW_STANDBY_CALL-}" \
    SLOW_STANDBY_SECONDS="${SLOW_STANDBY_SECONDS-}" \
    SLOW_NAP_CALL="${SLOW_NAP_CALL-}" \
    SLOW_NAP_SECONDS="${SLOW_NAP_SECONDS-}" \
    SLOW_COLLECTOR="${SLOW_COLLECTOR-}" \
    SLOW_COLLECTOR_SECONDS="${SLOW_COLLECTOR_SECONDS-}" \
    COLLECTOR_HONOR_TIMEOUT="${COLLECTOR_HONOR_TIMEOUT-}" \
    SLOW_KUBECTL_PREFIX="${SLOW_KUBECTL_PREFIX-}" \
    SLOW_KUBECTL_SECONDS="${SLOW_KUBECTL_SECONDS-}" \
    TIMEOUT_SECONDS="${TIMEOUT_SECONDS-}" \
    POST_COLLECTOR_RESERVE_SECONDS="${POST_COLLECTOR_RESERVE_SECONDS-}" \
    NAMESPACE_WAIT_TIMEOUT_SECONDS="${NAMESPACE_WAIT_TIMEOUT_SECONDS-}" \
    "$ROOT/scripts/run-benchmark.sh" "$@"
}

monotonic_milliseconds() {
  python3 - <<'PY'
import time

print(time.monotonic_ns() // 1_000_000)
PY
}

assert_deadline_status() {
  local status="$1"
  local started_at="$2"
  local label="$3"
  local elapsed
  elapsed=$(($(monotonic_milliseconds) - started_at))

  if [[ "$status" -ne 124 ]]; then
    printf 'expected %s to exit 124, got %s\n' "$label" "$status" >&2
    exit 1
  fi
  if [[ "$elapsed" -ge 3000 ]]; then
    printf 'expected %s to finish within deadline, took %sms\n' "$label" "$elapsed" >&2
    exit 1
  fi
}

assert_json_file() {
  python3 - "$1" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.stat().st_size:
    raise SystemExit(f"expected non-empty JSON evidence: {path}")
with path.open(encoding="utf-8") as handle:
    payload = json.load(handle)
if not isinstance(payload, dict):
    raise SystemExit(f"expected JSON object evidence: {path}")
PY
}

assert_timeout_json_file() {
  local path="$1"
  shift
  assert_json_file "$path"
  python3 - "$path" "$@" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open(encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("health") != "timeout":
    raise SystemExit(f"expected synthesized timeout evidence: {payload}")
for key in sys.argv[2:]:
    if key not in payload:
        raise SystemExit(f"expected synthesized timeout evidence to include {key}: {payload}")
    if payload[key] is not None:
        raise SystemExit(f"expected unknown {key}, got {payload[key]!r}: {payload}")
PY
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

reset_behavior
reset_logs
run_with_fakes \
  --scenario aks-nap \
  --runs 1 \
  --render-only \
  --output-dir "$TMP/render"

grep -F 'benchmark-path: aks-nap' "$TMP/render/aks-nap-run-1.yaml" >/dev/null
grep -F 'key: benchmark-path' "$TMP/render/aks-nap-run-1.yaml" >/dev/null
grep -F 'value: aks-nap' "$TMP/render/aks-nap-run-1.yaml" >/dev/null

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-standby \
  --runs 1 \
  --render-only \
  --output-dir "$TMP/render"

grep -F 'benchmark-path: standby' "$TMP/render/vn2-standby-run-1.yaml" >/dev/null

reset_behavior
reset_logs
run_with_fakes \
  --scenario aks-nap \
  --runs 3 \
  --output-dir "$TMP/documented-runs"
run_with_fakes \
  --scenario vn2-ondemand \
  --runs 3 \
  --output-dir "$TMP/documented-runs"
run_with_fakes \
  --scenario vn2-standby \
  --runs 3 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/documented-runs"
run_with_fakes \
  --scenario vn2-standby-cached \
  --runs 3 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/documented-runs"

python3 - "$TMP/documented-runs/raw" <<'PY'
import pathlib
import sys

raw_dir = pathlib.Path(sys.argv[1])
actual = sorted(path.name for path in raw_dir.glob("*.json"))
expected = [
    f"{scenario}-run-{run}.json"
    for scenario in (
        "aks-nap",
        "vn2-ondemand",
        "vn2-standby",
        "vn2-standby-cached",
    )
    for run in range(1, 4)
]
if actual != sorted(expected):
    raise SystemExit(f"expected the 12 documented raw artifacts, got {actual}")
PY

test "$(wc -l <"$TMP/logs/nap.log")" -eq 6
test "$(wc -l <"$TMP/logs/standby.log")" -eq 12
for run in 1 2 3; do
  assert_json_file "$TMP/documented-runs/diagnostics/aks-nap-run-$run/nap-precheck.json"
  assert_json_file "$TMP/documented-runs/diagnostics/aks-nap-run-$run/nap-postcheck.json"
  assert_json_file "$TMP/documented-runs/diagnostics/vn2-standby-run-$run/standby-precheck.json"
  assert_json_file "$TMP/documented-runs/diagnostics/vn2-standby-run-$run/standby-postcheck.json"
  assert_json_file "$TMP/documented-runs/diagnostics/vn2-standby-cached-run-$run/standby-precheck.json"
  assert_json_file "$TMP/documented-runs/diagnostics/vn2-standby-cached-run-$run/standby-postcheck.json"
done

reset_behavior
reset_logs
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
  --scenario aks-nap \
  --runs 1 \
  --output-dir "$TMP/create-failure" >/dev/null 2>&1
status=$?
set -e

[[ "$status" -ne 0 ]]
test ! -e "$TMP/create-failure/raw/aks-nap-run-1.json"
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
CREATE_NAMESPACE_THEN_SLEEP=1
CREATE_NAMESPACE_SLEEP_SECONDS=4
NAMESPACE_WAIT_TIMEOUT_SECONDS=1
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --runs 1 \
  --scenario-timeout-seconds 1 \
  --output-dir "$TMP/uncertain-create" >/dev/null 2>&1
status=$?
set -e
assert_deadline_status "$status" "$started_at" "uncertain namespace creation"
grep -F 'delete namespace ' "$TMP/logs/kubectl.log" | grep -F -- '--ignore-not-found=true' >/dev/null
if find "$TMP/state" -name 'ns-*' -print -quit | grep -q .; then
  echo 'expected uncertain namespace creation to be cleaned up' >&2
  exit 1
fi
test ! -s "$TMP/logs/collector.log"

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-standby \
  --runs 1 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/standby-once"

test -f "$TMP/standby-once/raw/vn2-standby-run-1.json"
test "$(wc -l <"$TMP/logs/standby.log")" -eq 2
grep -F -- '--expect-running 5' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--resource-group rg-test' "$TMP/logs/standby.log" >/dev/null
grep -F -- '--name pool-test' "$TMP/logs/standby.log" >/dev/null
assert_json_file "$TMP/standby-once/diagnostics/vn2-standby-run-1/standby-precheck.json"
assert_json_file "$TMP/standby-once/diagnostics/vn2-standby-run-1/standby-postcheck.json"
if find "$TMP/standby-once" -name '*.yaml' -print -quit | grep -q .; then
  echo 'expected one-run standby path to clean generated manifests' >&2
  exit 1
fi

reset_behavior
reset_logs
run_with_fakes \
  --scenario aks-nap \
  --runs 1 \
  --output-dir "$TMP/nap-once"

test -f "$TMP/nap-once/raw/aks-nap-run-1.json"
test "$(wc -l <"$TMP/logs/nap.log")" -eq 2
grep -F -- '--name workshop-nap --expect-nodes 0 --expect-nodeclaims 0' "$TMP/logs/nap.log" >/dev/null
grep -F -- '--timeout-seconds 900' "$TMP/logs/collector.log" >/dev/null
assert_json_file "$TMP/nap-once/diagnostics/aks-nap-run-1/nap-precheck.json"
assert_json_file "$TMP/nap-once/diagnostics/aks-nap-run-1/nap-postcheck.json"
test -s "$TMP/nap-once/diagnostics/aks-nap-run-1/nap-nodepool.yaml"
test -s "$TMP/nap-once/diagnostics/aks-nap-run-1/nap-nodeclaims.yaml"
test -s "$TMP/nap-once/diagnostics/aks-nap-run-1/nap-events.txt"
grep -F 'get nodepool workshop-nap -o yaml' "$TMP/logs/kubectl.log" >/dev/null
grep -F 'get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o yaml' "$TMP/logs/kubectl.log" >/dev/null
grep -F 'get events -A --field-selector source=karpenter-events' "$TMP/logs/kubectl.log" >/dev/null

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-ondemand \
  --runs 1 \
  --scenario-timeout-seconds 47 \
  --output-dir "$TMP/timeout-override"

grep -F -- '--timeout-seconds 47' "$TMP/logs/collector.log" >/dev/null
test ! -s "$TMP/logs/nap.log"
test ! -s "$TMP/logs/standby.log"

reset_behavior
reset_logs
COLLECTOR_EXIT_RUN=1
COLLECTOR_EXIT_CODE=2
SLOW_COLLECTOR=1
COLLECTOR_HONOR_TIMEOUT=1
POST_COLLECTOR_RESERVE_SECONDS=1
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario aks-nap \
  --runs 1 \
  --scenario-timeout-seconds 3 \
  --output-dir "$TMP/deadline-collector" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 2 ]]; then
  printf 'expected reserved collector timeout to exit 2, got %s\n' "$status" >&2
  exit 1
fi
assert_json_file "$TMP/deadline-collector/diagnostics/aks-nap-run-1/nap-precheck.json"
grep -F -- '--timeout-seconds 3' "$TMP/logs/collector.log" >/dev/null
test -s "$TMP/deadline-collector/raw/aks-nap-run-1.json"
grep -F '"completion_reason":"timeout"' \
  "$TMP/deadline-collector/raw/aks-nap-run-1.json" >/dev/null
test -e "$TMP/deadline-collector/diagnostics/aks-nap-run-1/kubectl-describe-pods.txt"
grep -F 'delete namespace' "$TMP/logs/kubectl.log" >/dev/null
test ! -e "$TMP/deadline-collector/.run-benchmark"

reset_behavior
reset_logs
TIMEOUT_SECONDS=1
POST_COLLECTOR_RESERVE_SECONDS=1
SLOW_COLLECTOR=1
SLOW_COLLECTOR_SECONDS=4
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --runs 1 \
  --output-dir "$TMP/default-deadline" >/dev/null 2>&1
status=$?
set -e
assert_deadline_status "$status" "$started_at" "default scenario lifecycle"
grep -F 'delete namespace' "$TMP/logs/kubectl.log" >/dev/null

reset_behavior
reset_logs
SLOW_STANDBY_CALL=1
SLOW_STANDBY_SECONDS=4
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario vn2-standby \
  --runs 1 \
  --resource-group rg-test \
  --standby-pool pool-test \
  --scenario-timeout-seconds 1 \
  --output-dir "$TMP/deadline-standby-precheck" >/dev/null 2>&1
status=$?
set -e
assert_deadline_status "$status" "$started_at" "standby precheck"
assert_timeout_json_file \
  "$TMP/deadline-standby-precheck/diagnostics/vn2-standby-run-1/standby-precheck.json" \
  creating deleting running starting
test ! -s "$TMP/logs/collector.log"

reset_behavior
reset_logs
SLOW_NAP_CALL=2
SLOW_NAP_SECONDS=4
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario aks-nap \
  --runs 1 \
  --scenario-timeout-seconds 2 \
  --output-dir "$TMP/deadline-postcheck" >/dev/null 2>&1
status=$?
set -e
assert_deadline_status "$status" "$started_at" "NAP postcheck"
test -f "$TMP/deadline-postcheck/raw/aks-nap-run-1.json"
assert_timeout_json_file \
  "$TMP/deadline-postcheck/diagnostics/aks-nap-run-1/nap-postcheck.json" \
  nodes nodeclaims

reset_behavior
reset_logs
SLOW_KUBECTL_PREFIX="describe pods"
SLOW_KUBECTL_SECONDS=4
POST_COLLECTOR_RESERVE_SECONDS=1
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --runs 1 \
  --scenario-timeout-seconds 1 \
  --output-dir "$TMP/deadline-diagnostics" >/dev/null 2>&1
status=$?
set -e
assert_deadline_status "$status" "$started_at" "diagnostics"
test -f "$TMP/deadline-diagnostics/raw/vn2-ondemand-run-1.json"
test -e "$TMP/deadline-diagnostics/diagnostics/vn2-ondemand-run-1/kubectl-describe-pods.txt"
grep -F 'exit_status: 124' \
  "$TMP/deadline-diagnostics/diagnostics/vn2-ondemand-run-1/kubectl-describe-pods.txt" >/dev/null

reset_behavior
reset_logs
SLOW_KUBECTL_PREFIX="delete namespace"
SLOW_KUBECTL_SECONDS=4
NAMESPACE_WAIT_TIMEOUT_SECONDS=1
started_at="$(monotonic_milliseconds)"
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --runs 1 \
  --scenario-timeout-seconds 1 \
  --output-dir "$TMP/deadline-cleanup" >/dev/null 2>&1
status=$?
set -e
assert_deadline_status "$status" "$started_at" "namespace cleanup"
test -f "$TMP/deadline-cleanup/raw/vn2-ondemand-run-1.json"
grep -F 'delete namespace' "$TMP/logs/kubectl.log" >/dev/null

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
