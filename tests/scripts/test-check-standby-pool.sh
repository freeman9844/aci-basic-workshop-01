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
set +e
output="$(PATH="$TMP:$PATH" "$ROOT/scripts/check-standby-pool.sh" \
  -g rg-test \
  -n pool-test \
  --expect-running 5 \
  --timeout-seconds 0 \
  --interval-seconds 0)"
status=$?
set -e

[[ "$status" -eq 3 ]]
grep -F '"health":"healthy"' <<<"$output"
grep -F '"running":4' <<<"$output"

