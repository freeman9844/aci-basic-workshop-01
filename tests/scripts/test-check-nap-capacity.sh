#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-nap-capacity.sh"
TEST_DIR="$ROOT/.test-check-nap-capacity"

cleanup() {
  rm -rf "$TEST_DIR"
}

trap cleanup EXIT
cleanup
mkdir -p "$TEST_DIR"

cat >"$TEST_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "get nodepool workshop-nap -o json")
    if [[ "${KUBECTL_MODE:-healthy}" == "missing" ]]; then
      printf 'Error from server (NotFound): nodepools.karpenter.sh "workshop-nap" not found\n' >&2
      exit 1
    fi
    if [[ "${KUBECTL_MODE:-healthy}" == "degraded" ]]; then
      cat <<'JSON'
{"status":{"conditions":[{"type":"Ready","status":"False"}]}}
JSON
    else
      cat <<'JSON'
{"status":{"conditions":[{"type":"Ready","status":"True"}]}}
JSON
    fi
    ;;
  "get nodes -l karpenter.sh/nodepool=workshop-nap -o json")
    if [[ "${KUBECTL_MODE:-healthy}" == "timeout" ]]; then
      printf '{"items":[{}]}\n'
    else
      printf '{"items":[]}\n'
    fi
    ;;
  "get nodeclaims -l karpenter.sh/nodepool=workshop-nap -o json")
    if [[ "${KUBECTL_MODE:-healthy}" == "timeout" ]]; then
      printf '{"items":[{}]}\n'
    else
      printf '{"items":[]}\n'
    fi
    ;;
  *)
    printf 'Unexpected kubectl invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_DIR/kubectl"

output="$(PATH="$TEST_DIR:$PATH" "$SCRIPT" --name workshop-nap \
  --expect-nodes 0 --expect-nodeclaims 0 \
  --timeout-seconds 5 --interval-seconds 1)"
jq -e '
  .health == "ready"
  and .node_pool == "workshop-nap"
  and .nodes == 0
  and .nodeclaims == 0
  and .ready == true
' <<<"$output"

set +e
output="$(KUBECTL_MODE=degraded PATH="$TEST_DIR:$PATH" "$SCRIPT" \
  --name workshop-nap \
  --expect-nodes 0 --expect-nodeclaims 0 \
  --timeout-seconds 5 --interval-seconds 1)"
status=$?
set -e
[[ "$status" -eq 2 ]]
jq -e '.health == "degraded" and .ready == false' <<<"$output"

set +e
output="$(KUBECTL_MODE=timeout PATH="$TEST_DIR:$PATH" "$SCRIPT" \
  --name workshop-nap \
  --expect-nodes 0 --expect-nodeclaims 0 \
  --timeout-seconds 1 --interval-seconds 1)"
status=$?
set -e
[[ "$status" -eq 3 ]]
jq -e '
  .health == "ready"
  and .nodes == 1
  and .nodeclaims == 1
  and .ready == false
' <<<"$output"

set +e
error="$("$SCRIPT" --name 2>&1)"
status=$?
set -e
[[ "$status" -eq 64 ]]
grep -F -- '--name requires a value' <<<"$error"

set +e
output="$(KUBECTL_MODE=missing PATH="$TEST_DIR:$PATH" "$SCRIPT" \
  --name workshop-nap \
  --expect-nodes 0 --expect-nodeclaims 0 \
  --timeout-seconds 5 --interval-seconds 1 \
  2>"$TEST_DIR/missing.stderr")"
status=$?
set -e
[[ "$status" -eq 2 ]]
jq -e '
  .health == "missing"
  and .node_pool == "workshop-nap"
  and .nodes == 0
  and .nodeclaims == 0
  and .ready == false
' <<<"$output"
grep -F 'Failed to get NodePool workshop-nap' "$TEST_DIR/missing.stderr"

printf 'PASS: NAP capacity checker contract\n'
