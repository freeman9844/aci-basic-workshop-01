import importlib.util
import json
import shutil
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "collect-pod-latency.py"
SPEC = importlib.util.spec_from_file_location("collect_pod_latency", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture(name):
    return json.loads((Path(__file__).parent / "fixtures" / name).read_text(encoding="utf-8"))


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

    def test_timeout_is_preserved(self):
        result = MODULE.finalize_run(
            scenario="vn2-ondemand",
            run_number=1,
            expected_pods=1,
            observations={"bench-1": {"ready_observed_ms": None}},
            timeout_ms=300000.0,
        )
        self.assertEqual(result["pods"][0]["terminal_state"], "timeout")

    def test_collect_run_writes_complete_raw_result(self):
        workspace = self._workspace("collect-run")
        output = workspace / "run.json"
        pod_snapshots = iter(
            [
                fixture("pods-pending.json"),
                fixture("pods-ready.json"),
            ]
        )
        ticks = iter([0, 250_000_000, 1_000_000_000, 1_250_000_000])

        def fake_runner(args, stdout=None, stderr=None, text=None):
            if args[:3] == ["kubectl", "apply", "-f"]:
                return _FakeCompletedProcess(stdout="", stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "pods", "-n"]:
                return _FakeCompletedProcess(stdout=json.dumps(next(pod_snapshots)), stderr="", returncode=0)
            if args[:4] == ["kubectl", "get", "events", "-n"]:
                return _FakeCompletedProcess(stdout="EVENTS", stderr="", returncode=0)
            raise AssertionError(f"Unexpected command: {args}")

        try:
            result_code = MODULE.collect_run(
                scenario="aks",
                run_number=1,
                namespace="vn2-bench-aks-1",
                manifest=workspace / "manifest.yaml",
                expected_pods=1,
                poll_interval_seconds=0.25,
                timeout_seconds=300,
                output=output,
                runner=fake_runner,
                sleeper=lambda _: None,
                monotonic_ns=lambda: next(ticks),
                utc_now=lambda: "2026-08-23T00:00:00Z",
            )

            self.assertEqual(result_code, 0)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["schema_version"], 1)
            self.assertEqual(payload["completion_reason"], "all_ready")
            self.assertEqual(payload["pods"][0]["terminal_state"], "ready")
            self.assertEqual(payload["batch"]["all_ready_ms"], 1000.0)
            self.assertEqual(payload["latest_snapshot"]["events"], "EVENTS")
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)


if __name__ == "__main__":
    unittest.main()
