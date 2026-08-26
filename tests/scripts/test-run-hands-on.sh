#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/.test-run-hands-on"

cleanup() {
  rm -rf "$TMP"
}

trap cleanup EXIT
cleanup
mkdir -p "$TMP/bin" "$TMP/logs" "$TMP/state"

cat >"$TMP/bin/check-standby-pool.sh" <<'FAKE_STANDBY'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_LOG_DIR/standby.log"
call_number="$(wc -l <"$TEST_LOG_DIR/standby.log")"
if [[ "${STANDBY_FAIL_CALL:-0}" == "$call_number" ]]; then
  printf '%s\n' '{"health":"degraded","running":0}'
  exit "${STANDBY_FAIL_EXIT_CODE:-1}"
fi
printf '%s\n' '{"health":"healthy","running":1}'
FAKE_STANDBY
chmod +x "$TMP/bin/check-standby-pool.sh"

cat >"$TMP/bin/az" <<'FAKE_AZ'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_LOG_DIR/az.log"
if [[ "${1-}" == "container" && "${2-}" == "list" && "${FAIL_AZ_CONTAINER_LIST:-0}" == "1" ]]; then
  printf 'container list failed\n' >&2
  exit 1
fi
printf '%s\n' '[{"name":"cg-test"}]'
FAKE_AZ
chmod +x "$TMP/bin/az"

cat >"$TMP/bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_LOG_DIR/kubectl.log"

case "$*" in
  "create namespace "*)
    touch "$TEST_STATE_DIR/namespace"
    ;;
  "apply -n "*" -f "*)
    if [[ "${APPLY_FAIL:-0}" == "1" ]]; then
      printf 'apply failed\n' >&2
      exit 1
    fi
    cp "${@: -1}" "$TEST_STATE_DIR/applied.yaml"
    pod_name="$(sed -n 's/^  name: //p' "$TEST_STATE_DIR/applied.yaml" | head -n 1)"
    node_name="virtual-node-standby"
    if grep -Fq 'benchmark-path: ondemand' "$TEST_STATE_DIR/applied.yaml"; then
      node_name="virtual-node-ondemand"
    fi
    printf '%s' "${pod_name:-vn2-standby}" >"$TEST_STATE_DIR/pod-name"
    printf '%s' "$node_name" >"$TEST_STATE_DIR/node-name"
    ;;
  "get pod "*" -n "*" -o json")
    if [[ "${APPLY_FAIL:-0}" == "1" || ! -f "$TEST_STATE_DIR/applied.yaml" ]]; then
      printf '%s\n' 'Error from server (NotFound): pods not found' >&2
      exit 1
    fi
    count="$(cat "$TEST_STATE_DIR/polls" 2>/dev/null || printf 0)"
    count=$((count + 1))
    printf '%s' "$count" >"$TEST_STATE_DIR/polls"
    pod_name="$(cat "$TEST_STATE_DIR/pod-name" 2>/dev/null || printf vn2-standby)"
    node_name="$(cat "$TEST_STATE_DIR/node-name" 2>/dev/null || printf virtual-node-standby)"
    if [[ "${POD_MODE:-ready}" == "ready" && "$count" -ge 2 ]]; then
      printf '%s\n' "{\"metadata\":{\"name\":\"$pod_name\"},\"spec\":{\"nodeName\":\"$node_name\"},\"status\":{\"phase\":\"Running\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastTransitionTime\":\"2026-08-26T00:00:01Z\"}]}}"
    else
      printf '%s\n' "{\"metadata\":{\"name\":\"$pod_name\"},\"spec\":{\"nodeName\":\"$node_name\"},\"status\":{\"phase\":\"Pending\",\"conditions\":[]}}"
    fi
    ;;
  "get pod "*" -n "*" -o yaml")
    if [[ "${APPLY_FAIL:-0}" == "1" || ! -f "$TEST_STATE_DIR/applied.yaml" ]]; then
      printf '%s\n' 'Error from server (NotFound): pods not found' >&2
      exit 1
    fi
    pod_name="$(cat "$TEST_STATE_DIR/pod-name" 2>/dev/null || printf vn2-standby)"
    printf '%s\n' 'apiVersion: v1' 'kind: Pod' 'metadata:' "  name: $pod_name"
    ;;
  "get events -n "*)
    printf '%s\n' 'Normal Scheduled'
    ;;
  "get nodes -o json")
    if [[ "${FAIL_NODES_JSON:-0}" == "1" ]]; then
      printf '%s\n' 'nodes list failed' >&2
      exit 1
    fi
    printf '%s\n' '{"items":[]}'
    ;;
  "delete namespace "*)
    rm -f "$TEST_STATE_DIR/namespace"
    ;;
  "get namespace "*)
    case "${NAMESPACE_GET_MODE:-notfound}" in
      error)
        printf '%s\n' 'Unable to connect to the server' >&2
        exit 1
        ;;
      lowercase-not-found)
        printf '%s\n' 'namespace cache entry not found during verification' >&2
        exit 1
        ;;
      *)
        printf '%s\n' 'Error from server (NotFound): namespaces not found' >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'Unexpected kubectl call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE_KUBECTL
chmod +x "$TMP/bin/kubectl"

reset_logs() {
  : >"$TMP/logs/az.log"
  : >"$TMP/logs/kubectl.log"
  : >"$TMP/logs/standby.log"
  rm -f "$TMP/state"/*
}

reset_behavior() {
  unset APPLY_FAIL
  unset FAIL_AZ_CONTAINER_LIST
  unset FAIL_NODES_JSON
  unset NAMESPACE_GET_MODE
  unset POD_MODE
  unset POLL_INTERVAL_SECONDS
  unset STANDBY_FAIL_CALL
  unset STANDBY_FAIL_EXIT_CODE
  unset STANDBY_TIMEOUT_SECONDS
  unset TIMEOUT_SECONDS
}

run_with_fakes() {
  env \
    TEST_LOG_DIR="$TMP/logs" \
    TEST_STATE_DIR="$TMP/state" \
    KUBECTL_BIN="$TMP/bin/kubectl" \
    AZ_BIN="$TMP/bin/az" \
    CHECK_STANDBY_BIN="$TMP/bin/check-standby-pool.sh" \
    APPLY_FAIL="${APPLY_FAIL-}" \
    FAIL_AZ_CONTAINER_LIST="${FAIL_AZ_CONTAINER_LIST-}" \
    FAIL_NODES_JSON="${FAIL_NODES_JSON-}" \
    NAMESPACE_GET_MODE="${NAMESPACE_GET_MODE-}" \
    POD_MODE="${POD_MODE-}" \
    POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS-}" \
    STANDBY_FAIL_CALL="${STANDBY_FAIL_CALL-}" \
    STANDBY_FAIL_EXIT_CODE="${STANDBY_FAIL_EXIT_CODE-}" \
    STANDBY_TIMEOUT_SECONDS="${STANDBY_TIMEOUT_SECONDS-}" \
    TIMEOUT_SECONDS="${TIMEOUT_SECONDS-}" \
    "$ROOT/scripts/run-hands-on.sh" "$@"
}

assert_observation() {
  local path="$1"
  local expected_scenario="$2"
  local expected_status="$3"
  local expected_cleanup_status="$4"
  local ready_expectation="$5"

  python3 - "$path" "$expected_scenario" "$expected_status" "$expected_cleanup_status" "$ready_expectation" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))

if payload["schema_version"] != 1:
    raise SystemExit(payload)
if payload["scenario"] != sys.argv[2]:
    raise SystemExit(payload)
if payload["status"] != sys.argv[3]:
    raise SystemExit(payload)
if payload["cleanup"]["status"] != sys.argv[4]:
    raise SystemExit(payload)
if not isinstance(payload["elapsed_ms"], int) or payload["elapsed_ms"] < 0:
    raise SystemExit(payload)

ready_expectation = sys.argv[5]
if ready_expectation == "required":
    if not payload["ready_at"]:
        raise SystemExit(payload)
elif ready_expectation == "forbidden":
    if payload["ready_at"] is not None:
        raise SystemExit(payload)
PY
}

assert_failure_reason_contains() {
  local path="$1"
  local needle="$2"

  python3 - "$path" "$needle" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
reason = payload.get("failure_reason") or ""
if sys.argv[2] not in reason:
    raise SystemExit(payload)
PY
}

assert_stdout_lacks_success_footer() {
  local path="$1"
  if grep -Fq 'Pod became Ready in ' "$path"; then
    printf 'expected failure path to omit success footer\n' >&2
    exit 1
  fi
}

assert_json_artifact_failure() {
  local pattern="$1"
  local expected_status="$2"
  local needle="$3"

  python3 - "$pattern" "$expected_status" "$needle" <<'PY'
import glob
import json
import pathlib
import sys

matches = glob.glob(sys.argv[1])
if len(matches) != 1:
    raise SystemExit(matches)

payload = json.loads(pathlib.Path(matches[0]).read_text(encoding="utf-8"))
if payload.get("ok") is not False:
    raise SystemExit(payload)
if payload.get("command_status") != int(sys.argv[2]):
    raise SystemExit(payload)

needle = sys.argv[3]
error = payload.get("error") or ""
raw_output = payload.get("raw_output") or ""
if needle not in error and needle not in raw_output:
    raise SystemExit(payload)
PY
}

reset_behavior
reset_logs
set +e
output="$(run_with_fakes \
  --scenario nope \
  --resource-group rg-test \
  --output-dir "$TMP/invalid" 2>&1)"
status=$?
set -e

[[ "$status" -eq 64 ]]
grep -F 'ERROR: unsupported scenario: nope' <<<"$output" >/dev/null

reset_behavior
reset_logs
set +e
output="$(run_with_fakes \
  --scenario vn2-ondemand \
  --output-dir "$TMP/missing-resource-group" 2>&1)"
status=$?
set -e

[[ "$status" -eq 64 ]]
grep -F 'ERROR: missing required argument: resource_group' <<<"$output" >/dev/null

reset_behavior
reset_logs
set +e
output="$(run_with_fakes \
  --scenario vn2-standby \
  --resource-group rg-test \
  --output-dir "$TMP/missing-standby-pool" 2>&1)"
status=$?
set -e

[[ "$status" -eq 64 ]]
grep -F 'ERROR: standby scenarios require --standby-pool' <<<"$output" >/dev/null

for rejected in --runs --pod-count --percentile --baseline; do
  reset_behavior
  reset_logs
  set +e
  output="$(run_with_fakes \
    --scenario vn2-ondemand \
    --resource-group rg-test \
    --output-dir "$TMP/rejected" \
    "$rejected" 1 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 64 ]]
  grep -F "ERROR: unsupported argument: $rejected" <<<"$output" >/dev/null
done

reset_behavior
reset_logs
rm -rf "$TMP/setup-failure"
mkdir -p "$TMP/setup-failure"
: >"$TMP/setup-failure/evidence"
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/setup-failure" \
  >"$TMP/setup-failure.stdout" 2>"$TMP/setup-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/setup-failure/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "failed" \
  "not-created" \
  "forbidden"
assert_failure_reason_contains \
  "$TMP/setup-failure/observations/vn2-ondemand.json" \
  'Evidence directory setup failed'
if grep -Fq 'create namespace ' "$TMP/logs/kubectl.log"; then
  printf 'expected setup failure to stop before namespace creation\n' >&2
  exit 1
fi

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/ondemand"

test ! -s "$TMP/logs/standby.log"
test "$(grep -c '^kind: Pod$' "$TMP/state/applied.yaml")" -eq 1
grep -F 'benchmark-path: ondemand' "$TMP/state/applied.yaml" >/dev/null
assert_observation \
  "$TMP/ondemand/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "ready" \
  "deleted" \
  "required"
python3 - "$TMP/ondemand/observations/vn2-ondemand.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload["failure_reason"] is not None:
    raise SystemExit(payload)
PY

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-standby \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/standby"

test "$(wc -l <"$TMP/logs/standby.log")" -eq 2
grep -F -- '--expect-running 1' "$TMP/logs/standby.log" >/dev/null
grep -F 'benchmark-path: standby' "$TMP/state/applied.yaml" >/dev/null
assert_observation \
  "$TMP/standby/observations/vn2-standby.json" \
  "vn2-standby" \
  "ready" \
  "deleted" \
  "required"

reset_behavior
reset_logs
run_with_fakes \
  --scenario vn2-standby-cached \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/standby-cached"

test "$(wc -l <"$TMP/logs/standby.log")" -eq 2
grep -F -- '--expect-running 1' "$TMP/logs/standby.log" >/dev/null
grep -F 'benchmark-path: standby' "$TMP/state/applied.yaml" >/dev/null
assert_observation \
  "$TMP/standby-cached/observations/vn2-standby-cached.json" \
  "vn2-standby-cached" \
  "ready" \
  "deleted" \
  "required"

reset_behavior
reset_logs
POD_MODE=never
POLL_INTERVAL_SECONDS=0.05
TIMEOUT_SECONDS=1
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/timeout" \
  >"$TMP/timeout.stdout" 2>"$TMP/timeout.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/timeout/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "timeout" \
  "deleted" \
  "forbidden"
test -s "$TMP/timeout/evidence"/vn2-ondemand-*/pod.json
test -s "$TMP/timeout/evidence"/vn2-ondemand-*/events.txt
test -s "$TMP/timeout/evidence"/vn2-ondemand-*/aci-inventory.json
grep -F 'delete namespace ' "$TMP/logs/kubectl.log" >/dev/null

reset_behavior
reset_logs
NAMESPACE_GET_MODE=error
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/cleanup-failure" \
  >"$TMP/cleanup-failure.stdout" 2>"$TMP/cleanup-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/cleanup-failure/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "failed" \
  "failed" \
  "required"
assert_failure_reason_contains \
  "$TMP/cleanup-failure/observations/vn2-ondemand.json" \
  'Namespace cleanup'

reset_behavior
reset_logs
NAMESPACE_GET_MODE=lowercase-not-found
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/cleanup-lowercase-not-found" \
  >"$TMP/cleanup-lowercase-not-found.stdout" 2>"$TMP/cleanup-lowercase-not-found.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/cleanup-lowercase-not-found/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "failed" \
  "failed" \
  "required"
assert_failure_reason_contains \
  "$TMP/cleanup-lowercase-not-found/observations/vn2-ondemand.json" \
  'Namespace cleanup verification failed'

reset_behavior
reset_logs
FAIL_AZ_CONTAINER_LIST=1
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/aci-failure" \
  >"$TMP/aci-failure.stdout" 2>"$TMP/aci-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/aci-failure/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "failed" \
  "deleted" \
  "required"
assert_failure_reason_contains \
  "$TMP/aci-failure/observations/vn2-ondemand.json" \
  'aci-inventory'
assert_json_artifact_failure \
  "$TMP/aci-failure/evidence/vn2-ondemand-*/aci-inventory.json" \
  1 \
  'container list failed'
assert_stdout_lacks_success_footer "$TMP/aci-failure.stdout"

reset_behavior
reset_logs
FAIL_NODES_JSON=1
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/nodes-failure" \
  >"$TMP/nodes-failure.stdout" 2>"$TMP/nodes-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/nodes-failure/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "failed" \
  "deleted" \
  "required"
assert_failure_reason_contains \
  "$TMP/nodes-failure/observations/vn2-ondemand.json" \
  'nodes'
assert_json_artifact_failure \
  "$TMP/nodes-failure/evidence/vn2-ondemand-*/nodes.json" \
  1 \
  'nodes list failed'
assert_stdout_lacks_success_footer "$TMP/nodes-failure.stdout"

reset_behavior
reset_logs
APPLY_FAIL=1
set +e
run_with_fakes \
  --scenario vn2-ondemand \
  --resource-group rg-test \
  --output-dir "$TMP/apply-failure" \
  >"$TMP/apply-failure.stdout" 2>"$TMP/apply-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/apply-failure/observations/vn2-ondemand.json" \
  "vn2-ondemand" \
  "failed" \
  "deleted" \
  "forbidden"
test -s "$TMP/apply-failure/evidence"/vn2-ondemand-*/pod.json
test -s "$TMP/apply-failure/evidence"/vn2-ondemand-*/events.txt
test -s "$TMP/apply-failure/evidence"/vn2-ondemand-*/aci-inventory.json
assert_json_artifact_failure \
  "$TMP/apply-failure/evidence/vn2-ondemand-*/pod.json" \
  1 \
  'pods not found'
grep -F 'delete namespace ' "$TMP/logs/kubectl.log" >/dev/null

reset_behavior
reset_logs
STANDBY_FAIL_CALL=1
set +e
run_with_fakes \
  --scenario vn2-standby \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/standby-precheck-failure" \
  >"$TMP/standby-precheck-failure.stdout" 2>"$TMP/standby-precheck-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/standby-precheck-failure/observations/vn2-standby.json" \
  "vn2-standby" \
  "failed" \
  "not-created" \
  "forbidden"
test ! -e "$TMP/state/namespace"
if grep -Fq 'create namespace ' "$TMP/logs/kubectl.log"; then
  printf 'expected standby precheck failure to stop before namespace creation\n' >&2
  exit 1
fi

reset_behavior
reset_logs
STANDBY_FAIL_CALL=2
set +e
run_with_fakes \
  --scenario vn2-standby \
  --resource-group rg-test \
  --standby-pool pool-test \
  --output-dir "$TMP/standby-postcheck-failure" \
  >"$TMP/standby-postcheck-failure.stdout" 2>"$TMP/standby-postcheck-failure.stderr"
status=$?
set -e

[[ "$status" -ne 0 ]]
assert_observation \
  "$TMP/standby-postcheck-failure/observations/vn2-standby.json" \
  "vn2-standby" \
  "failed" \
  "deleted" \
  "required"
grep -F 'delete namespace ' "$TMP/logs/kubectl.log" >/dev/null

printf 'PASS: one-Pod hands-on runner contract\n'
