#!/usr/bin/env bash
set -euo pipefail

resource_group=""
pool_name=""
expect_running=""
timeout_seconds=""
interval_seconds="5"

usage() {
  cat <<'EOF'
Usage: check-standby-pool.sh --resource-group RG --name NAME --expect-running N --timeout-seconds S --interval-seconds S
   or: check-standby-pool.sh -g RG -n NAME --expect-running N --timeout-seconds S --interval-seconds S
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    printf 'ERROR: %s requires a value\n' "$option" >&2
    usage >&2
    exit 64
  fi
}

while (($#)); do
  case "$1" in
    -g|--resource-group)
      require_value "$1" "${2-}"
      resource_group="$2"
      shift 2
      ;;
    -n|--name)
      require_value "$1" "${2-}"
      pool_name="$2"
      shift 2
      ;;
    --expect-running)
      require_value "$1" "${2-}"
      expect_running="$2"
      shift 2
      ;;
    --timeout-seconds)
      require_value "$1" "${2-}"
      timeout_seconds="$2"
      shift 2
      ;;
    --interval-seconds)
      require_value "$1" "${2-}"
      interval_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

for required in resource_group pool_name expect_running timeout_seconds interval_seconds; do
  if [[ -z "${!required}" ]]; then
    printf 'ERROR: missing required argument: %s\n' "$required" >&2
    usage >&2
    exit 64
  fi
done

python3 - "$resource_group" "$pool_name" "$expect_running" "$timeout_seconds" "$interval_seconds" <<'PY'
import json
import subprocess
import sys
import time

resource_group, pool_name, expect_running_s, timeout_seconds_s, interval_seconds_s = sys.argv[1:]

try:
    expect_running = int(expect_running_s)
    timeout_seconds = float(timeout_seconds_s)
    interval_seconds = float(interval_seconds_s)
except ValueError as exc:
    print(f"Invalid numeric argument: {exc}", file=sys.stderr)
    raise SystemExit(64)

if expect_running < 0 or timeout_seconds < 0 or interval_seconds < 0:
    print("Numeric arguments must be non-negative", file=sys.stderr)
    raise SystemExit(64)


def lower_keys(value):
    if isinstance(value, dict):
        return {str(key).lower(): lower_keys(val) for key, val in value.items()}
    if isinstance(value, list):
        return [lower_keys(item) for item in value]
    return value


def load_status():
    completed = subprocess.run(
        [
            "az",
            "standby-container-group-pool",
            "status",
            "--resource-group",
            resource_group,
            "--name",
            pool_name,
            "--version",
            "latest",
            "--output",
            "json",
        ],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or "az standby-container-group-pool status failed"
        print(message, file=sys.stderr)
        raise SystemExit(1)
    try:
        return lower_keys(json.loads(completed.stdout))
    except json.JSONDecodeError as exc:
        print(f"Failed to parse Azure CLI JSON: {exc}", file=sys.stderr)
        raise SystemExit(1)


def normalize(payload):
    states = {}
    for summary in payload.get("instancecountsummary", []):
        for item in summary.get("instancecountsbystate", []):
            state = str(item.get("state", "")).lower()
            if not state:
                continue
            try:
                count = int(item.get("count", 0))
            except (TypeError, ValueError):
                count = 0
            states[state] = count

    status_code = payload.get("status", {}).get("code", "")
    health = str(status_code).split("/")[-1].lower() if status_code else ""
    return {
        "creating": states.get("creating", 0),
        "deleting": states.get("deleting", 0),
        "health": health,
        "provisioning_state": payload.get("provisioningstate"),
        "running": states.get("running", 0),
        "starting": states.get("starting", 0),
    }


def emit_and_exit(code, payload):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    raise SystemExit(code)


deadline = time.monotonic() + timeout_seconds
while True:
    normalized = normalize(load_status())
    if normalized["health"] == "degraded":
        emit_and_exit(2, normalized)
    if (
        normalized["health"] == "healthy"
        and str(normalized["provisioning_state"]).lower() == "succeeded"
        and normalized["running"] == expect_running
    ):
        emit_and_exit(0, normalized)
    if time.monotonic() >= deadline:
        emit_and_exit(3, normalized)
    if interval_seconds > 0:
        time.sleep(interval_seconds)
PY
