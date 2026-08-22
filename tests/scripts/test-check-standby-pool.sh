#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$ROOT/.test-check-standby-pool"

cleanup() {
  rm -rf "$TMP"
}

trap cleanup EXIT
cleanup
mkdir -p "$TMP"

make_fake_az() {
  local fixture="$1"
  cat >"$TMP/az" <<EOF
#!/usr/bin/env bash
cat "$fixture"
EOF
  chmod +x "$TMP/az"
}

make_fake_az "$ROOT/tests/fixtures/standby-healthy-5.json"
output="$(PATH="$TMP:$PATH" "$ROOT/scripts/check-standby-pool.sh" \
  -g rg-test \
  -n pool-test \
  --expect-running 5 \
  --timeout-seconds 1 \
  --interval-seconds 0)"

grep -F '"health":"healthy"' <<<"$output"
grep -F '"running":5' <<<"$output"
grep -F '"provisioning_state":"Succeeded"' <<<"$output"

make_fake_az "$ROOT/tests/fixtures/standby-degraded.json"
set +e
output="$(PATH="$TMP:$PATH" "$ROOT/scripts/check-standby-pool.sh" \
  --resource-group rg-test \
  --name pool-test \
  --expect-running 5 \
  --timeout-seconds 1 \
  --interval-seconds 0)"
status=$?
set -e

[[ "$status" -eq 2 ]]
grep -F '"health":"degraded"' <<<"$output"

cat >"$TMP/standby-pending.json" <<'EOF'
{
  "Status": {
    "Code": "HealthState/Healthy"
  },
  "ProvisioningState": "Updating",
  "InstanceCountSummary": [
    {
      "InstanceCountsByState": [
        {
          "State": "Running",
          "Count": 4
        },
        {
          "State": "Creating",
          "Count": 1
        },
        {
          "State": "Starting",
          "Count": 0
        },
        {
          "State": "Deleting",
          "Count": 0
        }
      ]
    }
  ]
}
EOF
make_fake_az "$TMP/standby-pending.json"
start_ns="$(python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
)"
set +e
output="$(PATH="$TMP:$PATH" "$ROOT/scripts/check-standby-pool.sh" \
  -g rg-test \
  -n pool-test \
  --expect-running 5 \
  --timeout-seconds 0.4 \
  --interval-seconds 5)"
status=$?
set -e
end_ns="$(python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
)"
elapsed_ms="$(python3 - "$start_ns" "$end_ns" <<'PY'
import sys
start_ns = int(sys.argv[1])
end_ns = int(sys.argv[2])
print((end_ns - start_ns) / 1_000_000)
PY
)"

[[ "$status" -eq 3 ]]
python3 - "$elapsed_ms" <<'PY'
import sys
elapsed_ms = float(sys.argv[1])
if elapsed_ms > 1200:
    raise SystemExit(f"elapsed too long: {elapsed_ms:.3f}ms")
PY
grep -F '"health":"healthy"' <<<"$output"
grep -F '"running":4' <<<"$output"
