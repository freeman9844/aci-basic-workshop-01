#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

VALID_SCENARIOS = (
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
)

TERMINAL_FAILURE_REASONS = {
    "CrashLoopBackOff",
    "CreateContainerConfigError",
    "CreateContainerError",
    "ErrImagePull",
    "ImageInspectError",
    "ImagePullBackOff",
    "InvalidImageName",
    "OOMKilled",
    "RunContainerError",
    "StartError",
    "ContainerCannotRun",
    "DeadlineExceeded",
}


class CommandError(RuntimeError):
    pass


class CommandTimeoutError(CommandError):
    pass


class JSONParseError(RuntimeError):
    pass


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_yaml_scalar(value):
    value = value.strip()
    if not value:
        return ""
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    return value


def _split_yaml_documents(text):
    documents = []
    current = []
    for line in text.splitlines():
        if line.strip() == "---":
            if current:
                documents.append("\n".join(current))
                current = []
            continue
        current.append(line)
    if current:
        documents.append("\n".join(current))
    return [document for document in documents if document.strip()]


def _parse_yaml_mapping(text):
    root = {}
    stack = [(-1, root)]

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped in {"---", "..."}:
            continue
        if stripped.startswith("- "):
            continue

        if ":" not in stripped:
            raise ValueError(f"Unsupported YAML line: {raw_line}")

        indent = len(line) - len(line.lstrip(" "))
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()

        parent = stack[-1][1]
        key, value = stripped.split(":", 1)
        key = key.strip()
        value = value.strip()

        if value:
            parent[key] = _parse_yaml_scalar(value)
            continue

        nested = {}
        parent[key] = nested
        stack.append((indent, nested))

    return root


def _seed_expected_pod_records(manifest_path, expected_pods):
    manifest_path = Path(manifest_path)
    text = manifest_path.read_text(encoding="utf-8")
    names = []

    for index, document in enumerate(_split_yaml_documents(text), start=1):
        parsed = _parse_yaml_mapping(document)
        kind = parsed.get("kind")
        if kind != "Pod":
            raise ValueError(
                f"Manifest {manifest_path} document {index} is not a Pod (found {kind!r})"
            )

        metadata = parsed.get("metadata")
        if not isinstance(metadata, dict) or not metadata.get("name"):
            raise ValueError(
                f"Manifest {manifest_path} document {index} is missing metadata.name"
            )

        names.append(metadata["name"])

    if len(names) != expected_pods:
        raise ValueError(
            f"Manifest {manifest_path} contains {len(names)} Pod documents but "
            f"--expected-pods is {expected_pods}"
        )

    if len(names) != len(set(names)):
        raise ValueError(f"Manifest {manifest_path} contains duplicate Pod names")

    observations = OrderedDict()
    for order, name in enumerate(names, start=1):
        observations[name] = {
            "name": name,
            "manifest_order": order,
            "created_observed_ms": None,
            "scheduled_observed_ms": None,
            "ready_observed_ms": None,
            "failed_observed_ms": None,
        }
    return observations, names


def condition_status(pod, condition_type):
    for condition in pod.get("status", {}).get("conditions", []):
        if condition.get("type") == condition_type:
            return condition.get("status") == "True", condition.get("lastTransitionTime")
    return False, None


def _container_state(container):
    state = container.get("state", {}) or {}
    waiting = state.get("waiting") or {}
    terminated = state.get("terminated") or {}
    running = state.get("running") or {}
    return {
        "waiting_reason": waiting.get("reason"),
        "waiting_message": waiting.get("message"),
        "terminated_reason": terminated.get("reason"),
        "terminated_message": terminated.get("message"),
        "running_started_at": running.get("startedAt"),
    }


def container_state_summary(pod):
    for container in pod.get("status", {}).get("containerStatuses", []):
        summary = _container_state(container)
        if any(summary.values()):
            summary["name"] = container.get("name")
            summary["ready"] = container.get("ready")
            return summary
    return {}


def terminal_failure(pod):
    status = pod.get("status", {})
    if status.get("phase") == "Failed":
        return {
            "reason": status.get("reason") or "Failed",
            "message": status.get("message"),
            "source": "phase",
        }

    for container in status.get("containerStatuses", []):
        container_name = container.get("name")
        state = container.get("state", {}) or {}
        waiting = state.get("waiting") or {}
        waiting_reason = waiting.get("reason")
        if waiting_reason in TERMINAL_FAILURE_REASONS:
            return {
                "reason": waiting_reason,
                "message": waiting.get("message"),
                "source": "waiting",
                "container": container_name,
            }
        terminated = state.get("terminated") or {}
        terminated_reason = terminated.get("reason")
        if terminated_reason in TERMINAL_FAILURE_REASONS:
            return {
                "reason": terminated_reason,
                "message": terminated.get("message"),
                "source": "terminated",
                "container": container_name,
            }
    return None


def observe_snapshot(observations, snapshot, elapsed_ms):
    for pod in snapshot.get("items", []):
        metadata = pod.get("metadata", {})
        name = metadata.get("name")
        if not name:
            continue

        record = observations.setdefault(
            name,
            {
                "name": name,
                "created_observed_ms": elapsed_ms,
                "scheduled_observed_ms": None,
                "ready_observed_ms": None,
                "failed_observed_ms": None,
            },
        )
        if record.get("created_observed_ms") is None:
            record["created_observed_ms"] = elapsed_ms

        record["creation_timestamp"] = metadata.get("creationTimestamp")
        record["phase"] = pod.get("status", {}).get("phase")
        record["node_name"] = pod.get("spec", {}).get("nodeName")

        scheduled, scheduled_at = condition_status(pod, "PodScheduled")
        ready, ready_at = condition_status(pod, "ContainersReady")

        if scheduled and record.get("scheduled_observed_ms") is None:
            record["scheduled_observed_ms"] = elapsed_ms
            record["server_scheduled_timestamp"] = scheduled_at
        if ready and record.get("ready_observed_ms") is None:
            record["ready_observed_ms"] = elapsed_ms
            record["server_ready_timestamp"] = ready_at

        container_summary = container_state_summary(pod)
        if container_summary:
            record["container_state"] = container_summary

        failure = terminal_failure(pod)
        if failure and record.get("failed_observed_ms") is None:
            record["failed_observed_ms"] = elapsed_ms
            record["terminal_failure_reason"] = failure.get("reason")
            record["terminal_failure_message"] = failure.get("message")
            record["terminal_failure_source"] = failure.get("source")
            if failure.get("container"):
                record["terminal_failure_container"] = failure.get("container")


def _pod_terminal_state(record, stop_reason):
    if record.get("failed_observed_ms") is not None:
        return "failed"
    if record.get("ready_observed_ms") is not None:
        return "ready"
    if stop_reason in {"timeout", "failure", "apply_failure", "collection_failure"}:
        return "timeout"
    return "timeout"


def _duration_ms(start_ms, end_ms):
    if start_ms is None or end_ms is None:
        return None
    return round(float(end_ms) - float(start_ms), 3)


def finalize_run(
    *,
    scenario,
    run_number,
    expected_pods,
    observations,
    timeout_ms,
    stop_reason="timeout",
    namespace=None,
    manifest=None,
    started_at_utc=None,
    started_at_monotonic_ns=None,
    finished_at_utc=None,
    finished_at_monotonic_ns=None,
    poll_interval_seconds=None,
    apply_result=None,
    apply_error=None,
    collection_error=None,
    latest_pods_snapshot=None,
    events_text=None,
    poll_count=None,
    pod_order=None,
):
    pods = []
    ready_vals = []
    ordered_names = pod_order or list(observations.keys())
    all_ready = True

    for name in ordered_names:
        record = dict(
            observations.get(
                name,
                {
                    "name": name,
                    "created_observed_ms": None,
                    "scheduled_observed_ms": None,
                    "ready_observed_ms": None,
                    "failed_observed_ms": None,
                },
            )
        )
        record.setdefault("name", name)
        record["terminal_state"] = _pod_terminal_state(record, stop_reason)
        if record.get("ready_observed_ms") is not None:
            ready_vals.append(record["ready_observed_ms"])
        else:
            all_ready = False

        record["create_to_scheduled_ms"] = _duration_ms(
            record.get("created_observed_ms"), record.get("scheduled_observed_ms")
        )
        record["scheduled_to_ready_ms"] = _duration_ms(
            record.get("scheduled_observed_ms"), record.get("ready_observed_ms")
        )
        record["create_to_ready_ms"] = _duration_ms(
            record.get("created_observed_ms"), record.get("ready_observed_ms")
        )
        pods.append(record)

    batch = {
        "first_ready_ms": min(ready_vals) if ready_vals else None,
        "all_ready_ms": max(ready_vals) if all_ready and ready_vals else None,
        "timeout_ms": timeout_ms,
        "expected_pods": expected_pods,
    }

    if apply_error is not None and not apply_error.get("timeout"):
        completion_reason = "apply_failure"
    elif collection_error is not None and not collection_error.get("timeout"):
        completion_reason = "collection_failure"
    elif all_ready and len(pods) == expected_pods:
        completion_reason = "all_ready"
    else:
        completion_reason = stop_reason

    result = {
        "schema_version": 1,
        "scenario": scenario,
        "run": run_number,
        "namespace": namespace,
        "manifest": str(manifest) if manifest is not None else None,
        "expected_pods": expected_pods,
        "poll_interval_seconds": poll_interval_seconds,
        "timeout_seconds": None if timeout_ms is None else round(float(timeout_ms) / 1000.0, 3),
        "started_at_utc": started_at_utc,
        "started_at_monotonic_ns": started_at_monotonic_ns,
        "finished_at_utc": finished_at_utc,
        "finished_at_monotonic_ns": finished_at_monotonic_ns,
        "completion_reason": completion_reason,
        "poll_count": poll_count,
        "apply": apply_result,
        "apply_error": apply_error,
        "collection_error": collection_error,
        "pods": pods,
        "batch": batch,
        "latest_snapshot": {
            "pods": latest_pods_snapshot,
            "events": events_text,
        },
    }
    return result


def _run_command(args, *, timeout_seconds=None, runner=subprocess.run):
    if timeout_seconds is not None and timeout_seconds <= 0:
        raise CommandTimeoutError(
            f"Command timed out before execution: {' '.join(args)}"
        )
    try:
        completed = runner(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise CommandTimeoutError(
            f"Command timed out after {timeout_seconds:.3f}s: {' '.join(args)}"
        ) from exc
    if completed.returncode != 0:
        raise CommandError(
            f"Command failed ({completed.returncode}): {' '.join(args)}\n{completed.stderr.strip()}"
        )
    return {
        "args": args,
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def _run_json_command(args, *, timeout_seconds=None, runner=subprocess.run):
    result = _run_command(args, timeout_seconds=timeout_seconds, runner=runner)
    try:
        payload = json.loads(result["stdout"])
    except json.JSONDecodeError as exc:
        raise JSONParseError(f"Failed to parse JSON from {' '.join(args)}: {exc}") from exc
    result["json"] = payload
    return result


def _fetch_events(namespace, *, timeout_seconds=None, runner=subprocess.run):
    result = _run_command(
        ["kubectl", "get", "events", "-n", namespace, "--sort-by=.lastTimestamp"],
        timeout_seconds=timeout_seconds,
        runner=runner,
    )
    return result["stdout"]


def _should_stop(observations, expected_pods):
    if any(record.get("failed_observed_ms") is not None for record in observations.values()):
        return "failure"
    if len(observations) >= expected_pods and all(
        record.get("ready_observed_ms") is not None for record in observations.values()
    ):
        return "all_ready"
    return None


def _write_json_atomic(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with open(temp_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
        temp_path.replace(path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def collect_run(
    *,
    scenario,
    run_number,
    namespace,
    manifest,
    expected_pods,
    poll_interval_seconds,
    timeout_seconds,
    output,
    runner=subprocess.run,
    sleeper=time.sleep,
    monotonic_ns=time.monotonic_ns,
    utc_now=utc_now_iso,
):
    start_utc = utc_now()
    start_ns = monotonic_ns()
    manifest = Path(manifest)
    output = Path(output)

    observations, pod_order = _seed_expected_pod_records(manifest, expected_pods)
    latest_snapshot = None
    poll_count = 0
    stop_reason = "timeout"
    timeout_ms = float(timeout_seconds) * 1000.0
    deadline_ns = start_ns + int(float(timeout_seconds) * 1_000_000_000)
    interval_seconds = max(0.0, float(poll_interval_seconds))
    apply_result = None
    apply_error = None
    collection_error = None

    def remaining_timeout_seconds(now_ns):
        return max(0.0, (deadline_ns - now_ns) / 1_000_000_000.0)

    try:
        apply_result = _run_command(
            ["kubectl", "apply", "--namespace", namespace, "-f", str(manifest)],
            timeout_seconds=remaining_timeout_seconds(monotonic_ns()),
            runner=runner,
        )
    except CommandTimeoutError as exc:
        apply_error = {
            "phase": "apply",
            "message": str(exc),
            "timeout": True,
        }
        stop_reason = "timeout"
    except CommandError as exc:
        apply_error = {
            "phase": "apply",
            "message": str(exc),
        }
        stop_reason = "apply_failure"
    else:
        while True:
            now_ns = monotonic_ns()
            elapsed_ms = (now_ns - start_ns) / 1_000_000.0
            if elapsed_ms >= timeout_ms:
                stop_reason = "timeout"
                break
            try:
                latest = _run_json_command(
                    ["kubectl", "get", "pods", "-n", namespace, "-o", "json"],
                    timeout_seconds=remaining_timeout_seconds(now_ns),
                    runner=runner,
                )
            except CommandTimeoutError as exc:
                collection_error = {
                    "phase": "get",
                    "message": str(exc),
                    "timeout": True,
                }
                stop_reason = "timeout"
                break
            except CommandError as exc:
                collection_error = {
                    "phase": "get",
                    "message": str(exc),
                }
                stop_reason = "collection_failure"
                break
            except JSONParseError as exc:
                collection_error = {
                    "phase": "json",
                    "message": str(exc),
                }
                stop_reason = "collection_failure"
                break

            latest_snapshot = latest["json"]
            observe_snapshot(observations, latest_snapshot, elapsed_ms)
            poll_count += 1

            stop_reason = _should_stop(observations, expected_pods)
            if stop_reason:
                break
            sleeper(interval_seconds)

    finished_utc = utc_now()
    finished_ns = monotonic_ns()
    events_error = None
    events_text = ""
    try:
        events_text = _fetch_events(
            namespace,
            timeout_seconds=remaining_timeout_seconds(finished_ns),
            runner=runner,
        )
    except Exception as exc:
        events_error = str(exc)

    result = finalize_run(
        scenario=scenario,
        run_number=run_number,
        expected_pods=expected_pods,
        observations=observations,
        timeout_ms=timeout_ms,
        stop_reason=stop_reason,
        namespace=namespace,
        manifest=manifest,
        started_at_utc=start_utc,
        started_at_monotonic_ns=start_ns,
        finished_at_utc=finished_utc,
        finished_at_monotonic_ns=finished_ns,
        poll_interval_seconds=poll_interval_seconds,
        apply_result=apply_result,
        apply_error=apply_error,
        collection_error=collection_error,
        latest_pods_snapshot=latest_snapshot,
        events_text=events_text,
        poll_count=poll_count,
        pod_order=pod_order,
    )
    if events_error is not None:
        result["events_error"] = events_error

    _write_json_atomic(output, result)
    return 0 if stop_reason == "all_ready" else 2


def build_parser():
    parser = argparse.ArgumentParser(description="Collect Pod startup latency evidence")
    parser.add_argument("--scenario", required=True, choices=VALID_SCENARIOS)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--expected-pods", required=True, type=int)
    parser.add_argument("--poll-interval", required=True, type=float)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--output", required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return collect_run(
            scenario=args.scenario,
            run_number=args.run,
            namespace=args.namespace,
            manifest=args.manifest,
            expected_pods=args.expected_pods,
            poll_interval_seconds=args.poll_interval,
            timeout_seconds=args.timeout_seconds,
            output=args.output,
        )
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
