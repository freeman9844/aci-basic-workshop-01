import importlib.util
import json
import os
import shutil
import textwrap
import time
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "collect-pod-latency.py"
SPEC = importlib.util.spec_from_file_location("collect_pod_latency", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

EXPECTED_SCENARIOS = {
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
}


def fixture(name):
    return json.loads((Path(__file__).parent / "fixtures" / name).read_text(encoding="utf-8"))


def manifest_text(*names):
    parts = []
    for name in names:
        parts.append(
            textwrap.dedent(
                f"""\
                apiVersion: v1
                kind: Pod
                metadata:
                  name: {name}
                spec:
                  containers:
                    - name: bench
                      image: example.com/bench:latest
                """
            ).strip()
        )
    return "\n---\n".join(parts) + "\n"


class _FakeCompletedProcess:
    def __init__(self, stdout="", stderr="", returncode=0):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode


class CollectorTests(unittest.TestCase):
    def _workspace(self, name):
        root = Path(__file__).resolve().parents[1] / ".test-collect-pod-latency" / name
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True, exist_ok=True)
        return root

    def test_valid_scenarios_match_benchmark_contract(self):
        self.assertEqual(set(MODULE.VALID_SCENARIOS), EXPECTED_SCENARIOS)

    def test_records_first_observed_transition_only(self):
        observations = {}
        pending = fixture("pods-pending.json")
        ready = fixture("pods-ready.json")

        MODULE.observe_snapshot(observations, pending, 250.0)
        MODULE.observe_snapshot(observations, ready, 1000.0)
        MODULE.observe_snapshot(observations, ready, 1250.0)

        pod = observations["bench-1"]
        self.assertEqual(pod["created_observed_ms"], 250.0)
        self.assertEqual(pod["scheduled_observed_ms"], 250.0)
        self.assertEqual(pod["ready_observed_ms"], 1000.0)

    def test_finalize_run_excludes_ready_then_failed_pod_from_batch_success(self):
        result = MODULE.finalize_run(
            scenario="aks-nap",
            run_number=1,
            expected_pods=2,
            observations={
                "bench-1": {
                    "name": "bench-1",
                    "created_observed_ms": 0.0,
                    "scheduled_observed_ms": 500.0,
                    "ready_observed_ms": 1000.0,
                    "failed_observed_ms": 1500.0,
                },
                "bench-2": {
                    "name": "bench-2",
                    "created_observed_ms": 0.0,
                    "scheduled_observed_ms": 750.0,
                    "ready_observed_ms": 2000.0,
                    "failed_observed_ms": None,
                },
            },
            timeout_ms=300000.0,
            stop_reason="failure",
        )

        self.assertEqual(result["pods"][0]["terminal_state"], "failed")
        self.assertEqual(result["pods"][1]["terminal_state"], "ready")
        self.assertEqual(result["batch"]["first_ready_ms"], 2000.0)
        self.assertIsNone(result["batch"]["all_ready_ms"])
        self.assertEqual(result["completion_reason"], "failure")

    def test_collect_run_applies_manifest_into_requested_namespace(self):
        workspace = self._workspace("apply-namespace")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1"), encoding="utf-8")
        commands = []

        def fake_runner(args, stdout=None, stderr=None, text=None, timeout=None):
            commands.append(args)
            if args == [
                "kubectl",
                "apply",
                "--namespace",
                "vn2-bench-aks-nap-1",
                "-f",
                str(manifest),
            ]:
                return _FakeCompletedProcess(stdout="", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "pods", "-n"]:
                return _FakeCompletedProcess(stdout=json.dumps(fixture("pods-ready.json")), stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="aks-nap",
                run_number=1,
                namespace="vn2-bench-aks-nap-1",
                manifest=manifest,
                expected_pods=1,
                poll_interval_seconds=0.25,
                timeout_seconds=300,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                monotonic_ns=lambda: 0,
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 0)
            self.assertIn(
                [
                    "kubectl",
                    "apply",
                    "--namespace",
                    "vn2-bench-aks-nap-1",
                    "-f",
                    str(manifest),
                ],
                commands,
            )
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_collect_run_preserves_unobserved_manifest_pods(self):
        workspace = self._workspace("never-observed")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1", "bench-2"), encoding="utf-8")

        pod_snapshots = iter(
            [
                fixture("pods-pending.json"),
                fixture("pods-ready.json"),
                fixture("pods-ready.json"),
            ]
        )
        ticks = iter([0, 250_000_000, 500_000_000, 750_000_000, 1_000_000_000])

        def fake_runner(args, stdout=None, stderr=None, text=None, timeout=None):
            if args[:4] == ["kubectl", "apply", "--namespace", "vn2-bench-aks-nap-1"]:
                return _FakeCompletedProcess(stdout="", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "pods", "-n"]:
                return _FakeCompletedProcess(stdout=json.dumps(next(pod_snapshots)), stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="aks-nap",
                run_number=1,
                namespace="vn2-bench-aks-nap-1",
                manifest=manifest,
                expected_pods=2,
                poll_interval_seconds=0.25,
                timeout_seconds=0.75,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                monotonic_ns=lambda: next(ticks),
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 2)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["schema_version"], 1)
            self.assertEqual(payload["completion_reason"], "timeout")
            self.assertEqual(len(payload["pods"]), 2)
            self.assertEqual(payload["pods"][0]["name"], "bench-1")
            self.assertEqual(payload["pods"][1]["name"], "bench-2")
            self.assertIsNone(payload["pods"][1]["ready_observed_ms"])
            self.assertIsNone(payload["pods"][1]["scheduled_observed_ms"])
            self.assertEqual(payload["pods"][1]["terminal_state"], "timeout")
            self.assertEqual(payload["latest_snapshot"]["events"], "")
            self.assertIn("timed out before execution", payload["events_error"])
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_apply_failure_persists_evidence(self):
        workspace = self._workspace("apply-failure")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1"), encoding="utf-8")

        def fake_runner(args, stdout=None, stderr=None, text=None, timeout=None):
            if args[:4] == ["kubectl", "apply", "--namespace", "vn2-bench-ondemand-1"]:
                return _FakeCompletedProcess(stdout="", stderr="apply boom", returncode=1)
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="vn2-ondemand",
                run_number=1,
                namespace="vn2-bench-ondemand-1",
                manifest=manifest,
                expected_pods=1,
                poll_interval_seconds=0.25,
                timeout_seconds=300,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                monotonic_ns=lambda: 0,
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 2)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["completion_reason"], "apply_failure")
            self.assertEqual(payload["apply_error"]["phase"], "apply")
            self.assertEqual(payload["pods"][0]["name"], "bench-1")
            self.assertEqual(payload["pods"][0]["terminal_state"], "timeout")
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_get_failure_persists_evidence(self):
        workspace = self._workspace("get-failure")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1"), encoding="utf-8")

        def fake_runner(args, stdout=None, stderr=None, text=None, timeout=None):
            if args[:4] == ["kubectl", "apply", "--namespace", "vn2-bench-standby-1"]:
                return _FakeCompletedProcess(stdout="", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "pods", "-n"]:
                return _FakeCompletedProcess(stdout="", stderr="get boom", returncode=1)
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="vn2-standby-cached",
                run_number=1,
                namespace="vn2-bench-standby-1",
                manifest=manifest,
                expected_pods=1,
                poll_interval_seconds=0.25,
                timeout_seconds=300,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                monotonic_ns=lambda: 0,
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 2)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["completion_reason"], "collection_failure")
            self.assertEqual(payload["collection_error"]["phase"], "get")
            self.assertEqual(payload["pods"][0]["name"], "bench-1")
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_json_failure_persists_evidence(self):
        workspace = self._workspace("json-failure")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1"), encoding="utf-8")

        def fake_runner(args, stdout=None, stderr=None, text=None, timeout=None):
            if args[:4] == ["kubectl", "apply", "--namespace", "vn2-bench-aks-nap-1"]:
                return _FakeCompletedProcess(stdout="", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "pods", "-n"]:
                return _FakeCompletedProcess(stdout="{", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="aks-nap",
                run_number=1,
                namespace="vn2-bench-aks-nap-1",
                manifest=manifest,
                expected_pods=1,
                poll_interval_seconds=0.25,
                timeout_seconds=300,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                monotonic_ns=lambda: 0,
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 2)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["completion_reason"], "collection_failure")
            self.assertEqual(payload["collection_error"]["phase"], "json")
            self.assertEqual(payload["pods"][0]["name"], "bench-1")
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_each_kubectl_probe_uses_remaining_collector_deadline(self):
        workspace = self._workspace("probe-deadlines")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1"), encoding="utf-8")
        timeouts = []

        def fake_runner(args, stdout=None, stderr=None, text=None, timeout=None):
            timeouts.append(timeout)
            if args[:2] == ["kubectl", "apply"]:
                return _FakeCompletedProcess(stdout="", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "pods", "-n"]:
                return _FakeCompletedProcess(
                    stdout=json.dumps(fixture("pods-ready.json")),
                    stderr="",
                    returncode=0,
                )
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="aks-nap",
                run_number=1,
                namespace="vn2-bench-aks-nap-1",
                manifest=manifest,
                expected_pods=1,
                poll_interval_seconds=0.25,
                timeout_seconds=1,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 0)
            self.assertEqual(len(timeouts), 3)
            self.assertTrue(all(isinstance(value, (int, float)) for value in timeouts))
            self.assertTrue(all(0 < value <= 1 for value in timeouts))
            self.assertGreaterEqual(timeouts[0], timeouts[1])
            self.assertGreaterEqual(timeouts[1], timeouts[2])
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_hanging_kubectl_probe_times_out_and_persists_raw_evidence(self):
        workspace = self._workspace("hanging-probe")
        output = workspace / "run.json"
        manifest = workspace / "manifest.yaml"
        manifest.write_text(manifest_text("bench-1"), encoding="utf-8")
        bin_dir = workspace / "bin"
        bin_dir.mkdir()
        kubectl = bin_dir / "kubectl"
        kubectl.write_text(
            "#!/usr/bin/env bash\nexec sleep 1\n",
            encoding="utf-8",
        )
        kubectl.chmod(0o755)
        old_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{bin_dir}:{old_path}"
        started_at = time.monotonic()

        try:
            result_code = MODULE.collect_run(
                scenario="aks-nap",
                run_number=1,
                namespace="vn2-bench-aks-nap-1",
                manifest=manifest,
                expected_pods=1,
                poll_interval_seconds=0.01,
                timeout_seconds=0.2,
                output=output,
            )

            elapsed = time.monotonic() - started_at
            self.assertEqual(result_code, 2)
            self.assertLess(elapsed, 0.75)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["completion_reason"], "timeout")
            self.assertEqual(payload["apply_error"]["phase"], "apply")
            self.assertTrue(payload["apply_error"]["timeout"])
            self.assertEqual(payload["pods"][0]["terminal_state"], "timeout")
        finally:
            os.environ["PATH"] = old_path
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_unsupported_scenario_uses_argparse_semantics(self):
        with self.assertRaises(SystemExit) as context:
            MODULE.build_parser().parse_args(
                [
                    "--scenario",
                    "unknown",
                    "--run",
                    "1",
                    "--namespace",
                    "vn2-bench",
                    "--manifest",
                    "manifest.yaml",
                    "--expected-pods",
                    "1",
                    "--poll-interval",
                    "0.25",
                    "--timeout-seconds",
                    "300",
                    "--output",
                    "out.json",
                ]
            )
        self.assertEqual(context.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
