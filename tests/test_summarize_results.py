import importlib.util
import json
import shutil
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "summarize-results.py"
SPEC = importlib.util.spec_from_file_location("summarize_results", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

EXPECTED_SCENARIOS = {
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
}
EXPECTED_SCENARIO_ORDER = [
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
]


class SummaryTests(unittest.TestCase):
    def _workspace(self, name):
        root = Path(__file__).resolve().parents[1] / ".test-summarize-results" / name
        if root.exists():
            shutil.rmtree(root)
        root.mkdir(parents=True, exist_ok=True)
        return root

    def test_scenario_contract_matches_benchmark_order(self):
        self.assertEqual(set(MODULE.VALID_SCENARIOS), EXPECTED_SCENARIOS)
        self.assertEqual(MODULE.SCENARIO_ORDER, EXPECTED_SCENARIO_ORDER)

    def test_nearest_rank_p95_uses_ceiling_rank(self):
        self.assertEqual(MODULE.nearest_rank([1, 2, 3, 4, 5], 95), 5)

    def test_scenario_summary_preserves_non_ready_evidence_and_metadata(self):
        runs = [
            {
                "schema_version": 1,
                "scenario": "vn2-standby-cached",
                "run": 2,
                "pool_health": {"status": "healthy", "running": 5},
                "fallback": {"mode": "standby", "reason": "StandbyPoolReuseFailure"},
                "pods": [
                    {
                        "name": "bench-cached-2-pod-1",
                        "terminal_state": "ready",
                        "create_to_ready_ms": 3000.0,
                        "create_to_scheduled_ms": 200.0,
                        "scheduled_to_ready_ms": 2800.0,
                    },
                    {
                        "name": "bench-cached-2-pod-2",
                        "terminal_state": "timeout",
                        "create_to_ready_ms": None,
                        "create_to_scheduled_ms": 220.0,
                        "scheduled_to_ready_ms": None,
                        "fallback": {"observed": True},
                    },
                ],
                "batch": {"first_ready_ms": 3000.0, "all_ready_ms": 3200.0},
            }
        ]

        result = MODULE.summarize_scenario(runs)
        self.assertEqual(result["ready_samples"], 1)
        self.assertEqual(result["timeout_count"], 1)
        evidence = result["evidence"]["runs"][0]
        self.assertEqual(evidence["metadata"]["pool_health"]["status"], "healthy")
        self.assertEqual(evidence["metadata"]["fallback"]["reason"], "StandbyPoolReuseFailure")
        self.assertEqual(evidence["non_ready_pods"][0]["name"], "bench-cached-2-pod-2")
        self.assertEqual(evidence["non_ready_pods"][0]["terminal_state"], "timeout")
        self.assertEqual(evidence["pods"][1]["fallback"]["observed"], True)

    def test_scenario_summary_excludes_ready_then_failed_pod_from_latency_statistics(self):
        runs = [
            {
                "schema_version": 1,
                "scenario": "aks-nap",
                "run": 1,
                "pods": [
                    {
                        "name": "failed-after-ready",
                        "terminal_state": "failed",
                        "create_to_ready_ms": 999999.0,
                        "create_to_scheduled_ms": 999.0,
                        "scheduled_to_ready_ms": 999000.0,
                    },
                    {
                        "name": "ready",
                        "terminal_state": "ready",
                        "create_to_ready_ms": 3000.0,
                        "create_to_scheduled_ms": 200.0,
                        "scheduled_to_ready_ms": 2800.0,
                    },
                ],
                "batch": {"first_ready_ms": 3000.0, "all_ready_ms": None},
            }
        ]

        result = MODULE.summarize_scenario(runs)

        self.assertEqual(result["ready_samples"], 1)
        self.assertEqual(result["failed_count"], 1)
        self.assertEqual(result["create_to_ready_ms"]["count"], 1)
        self.assertEqual(result["create_to_ready_ms"]["median"], 3000.0)
        self.assertEqual(result["create_to_scheduled_ms"]["count"], 1)
        self.assertEqual(result["scheduled_to_ready_ms"]["count"], 1)

    def test_speedup_uses_ondemand_over_cached(self):
        self.assertEqual(MODULE.speedup_ratio(12000.0, 3000.0), 4.0)

    def test_apply_speedups_uses_vn2_ondemand_for_all_candidates(self):
        summaries = {
            "aks-nap": {
                "create_to_ready_ms": {"median": 120000.0},
                "batch_all_ready_ms": {"median": 130000.0},
            },
            "vn2-ondemand": {
                "create_to_ready_ms": {"median": 60000.0},
                "batch_all_ready_ms": {"median": 65000.0},
            },
            "vn2-standby": {
                "create_to_ready_ms": {"median": 10000.0},
                "batch_all_ready_ms": {"median": 20000.0},
            },
            "vn2-standby-cached": {
                "create_to_ready_ms": {"median": 5000.0},
                "batch_all_ready_ms": {"median": 8000.0},
            },
        }

        MODULE._apply_speedups(summaries)

        self.assertEqual(summaries["aks-nap"]["pod_speedup_ratio"], 0.5)
        self.assertEqual(summaries["aks-nap"]["batch_speedup_ratio"], 0.5)
        self.assertEqual(summaries["vn2-standby"]["pod_speedup_ratio"], 6.0)
        self.assertEqual(summaries["vn2-standby-cached"]["batch_speedup_ratio"], 8.125)
        self.assertIsNone(summaries["vn2-ondemand"]["pod_speedup_ratio"])

    def test_summarize_scenario_raises_for_invalid_schema_or_scenario(self):
        runs_invalid_schema = [
            {
                "schema_version": 2,
                "scenario": "aks-nap",
                "pods": [],
                "batch": {},
            }
        ]
        with self.assertRaises(ValueError):
            MODULE.summarize_scenario(runs_invalid_schema)

        runs_invalid_scenario = [
            {
                "schema_version": 1,
                "scenario": "unknown-scenario",
                "pods": [],
                "batch": {},
            }
        ]
        with self.assertRaises(ValueError):
            MODULE.summarize_scenario(runs_invalid_scenario)

    def test_load_runs_raises_for_malformed_json_with_filename(self):
        workspace = self._workspace("malformed")
        raw_dir = workspace / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)
        (raw_dir / "good.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "scenario": "aks-nap",
                    "pods": [],
                    "batch": {},
                }
            ),
            encoding="utf-8",
        )
        (raw_dir / "broken.json").write_text('{"schema_version": 1,', encoding="utf-8")

        try:
            with self.assertRaises(ValueError) as context:
                MODULE.load_runs(raw_dir)
            self.assertIn("broken.json", str(context.exception))
            self.assertIn("Malformed JSON", str(context.exception))
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)

    def test_load_runs_and_summary_output_preserves_evidence(self):
        workspace = self._workspace("summary-output")
        raw_dir = workspace / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)

        runs = [
            {
                "schema_version": 1,
                "scenario": "vn2-ondemand",
                "run": 1,
                "pods": [
                    {
                        "name": "ondemand-pod-1",
                        "terminal_state": "ready",
                        "create_to_ready_ms": 10000.0,
                        "create_to_scheduled_ms": 100.0,
                        "scheduled_to_ready_ms": 9900.0,
                    }
                ],
                "batch": {"first_ready_ms": 10000.0, "all_ready_ms": 10000.0},
            },
            {
                "schema_version": 1,
                "scenario": "vn2-standby-cached",
                "run": 1,
                "pool_health": {"status": "healthy", "running": 5},
                "fallback": {"mode": "standby", "reason": "StandbyPoolReuseFailure"},
                "pods": [
                    {
                        "name": "cached-pod-1",
                        "terminal_state": "ready",
                        "create_to_ready_ms": 2500.0,
                        "create_to_scheduled_ms": 90.0,
                        "scheduled_to_ready_ms": 2410.0,
                    },
                    {
                        "name": "cached-pod-2",
                        "terminal_state": "timeout",
                        "create_to_ready_ms": None,
                        "create_to_scheduled_ms": 95.0,
                        "scheduled_to_ready_ms": None,
                    },
                ],
                "batch": {"first_ready_ms": 2500.0, "all_ready_ms": 2600.0},
            },
        ]

        (raw_dir / "ondemand-1.json").write_text(json.dumps(runs[0]), encoding="utf-8")
        (raw_dir / "cached-1.json").write_text(json.dumps(runs[1]), encoding="utf-8")

        try:
            original_argv = sys.argv
            try:
                sys.argv = [
                    "summarize-results.py",
                    "--input",
                    str(raw_dir),
                    "--output-dir",
                    str(workspace),
                ]
                exit_code = MODULE.main()
            finally:
                sys.argv = original_argv

            self.assertEqual(exit_code, 0)
            summary_json = json.loads((workspace / "summary.json").read_text(encoding="utf-8"))
            self.assertIn("evidence", summary_json["vn2-standby-cached"])
            self.assertEqual(
                summary_json["vn2-standby-cached"]["evidence"]["runs"][0]["metadata"]["pool_health"]["running"],
                5,
            )
            self.assertEqual(
                summary_json["vn2-standby-cached"]["evidence"]["runs"][0]["non_ready_pods"][0]["terminal_state"],
                "timeout",
            )

            summary_csv = (workspace / "summary.csv").read_text(encoding="utf-8")
            self.assertIn("evidence_json", summary_csv.splitlines()[0])
            self.assertIn("StandbyPoolReuseFailure", summary_csv)

            summary_md = (workspace / "summary.md").read_text(encoding="utf-8")
            self.assertIn("## 증거", summary_md)
            self.assertIn("StandbyPoolReuseFailure", summary_md)
        finally:
            if workspace.parent.exists():
                shutil.rmtree(workspace.parent)


if __name__ == "__main__":
    unittest.main()
