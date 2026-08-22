import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

# Absolute path relative to tests directory
MODULE_PATH = Path(__file__).parents[1] / "scripts" / "summarize-results.py"
SPEC = importlib.util.spec_from_file_location("summarize_results", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SummaryTests(unittest.TestCase):
    def test_nearest_rank_p95_uses_ceiling_rank(self):
        self.assertEqual(MODULE.nearest_rank([1, 2, 3, 4, 5], 95), 5)

    def test_scenario_summary_keeps_failures(self):
        runs = [{
            "schema_version": 1,
            "scenario": "aks",
            "pods": [
                {"terminal_state": "ready", "create_to_ready_ms": 1000.0},
                {"terminal_state": "timeout", "create_to_ready_ms": None},
            ],
            "batch": {"all_ready_ms": None},
        }]
        result = MODULE.summarize_scenario(runs)
        self.assertEqual(result["ready_samples"], 1)
        self.assertEqual(result["timeout_count"], 1)
        self.assertEqual(result["create_to_ready_ms"]["median"], 1000.0)

    def test_speedup_uses_ondemand_over_cached(self):
        self.assertEqual(MODULE.speedup_ratio(12000.0, 3000.0), 4.0)

    def test_summarize_scenario_raises_for_invalid_schema_or_scenario(self):
        runs_invalid_schema = [{
            "schema_version": 2,
            "scenario": "aks",
            "pods": [],
            "batch": {}
        }]
        with self.assertRaises(ValueError):
            MODULE.summarize_scenario(runs_invalid_schema)

        runs_invalid_scenario = [{
            "schema_version": 1,
            "scenario": "unknown-scenario",
            "pods": [],
            "batch": {}
        }]
        with self.assertRaises(ValueError):
            MODULE.summarize_scenario(runs_invalid_scenario)

    def test_load_runs_and_summary_output(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            raw_dir = tmp_path / "raw"
            raw_dir.mkdir()
            
            # Write synthetic run files
            run1 = {
                "schema_version": 1,
                "scenario": "vn2-ondemand",
                "run": 1,
                "pods": [
                    {"name": "pod1", "terminal_state": "ready", "create_to_ready_ms": 10000.0},
                    {"name": "pod2", "terminal_state": "ready", "create_to_ready_ms": 11000.0}
                ],
                "batch": {"all_ready_ms": 12000.0}
            }
            run2 = {
                "schema_version": 1,
                "scenario": "vn2-standby-cached",
                "run": 1,
                "pods": [
                    {"name": "pod3", "terminal_state": "ready", "create_to_ready_ms": 2500.0},
                    {"name": "pod4", "terminal_state": "ready", "create_to_ready_ms": 3500.0}
                ],
                "batch": {"all_ready_ms": 4000.0}
            }
            
            with open(raw_dir / "ondemand-1.json", "w") as f:
                json.dump(run1, f)
            with open(raw_dir / "cached-1.json", "w") as f:
                json.dump(run2, f)
                
            # Run summarizer via command line or calling main with arguments
            import sys
            orig_argv = sys.argv
            try:
                sys.argv = [
                    "summarize-results.py",
                    "--input", str(raw_dir),
                    "--output-dir", str(tmp_path)
                ]
                MODULE.main()
            finally:
                sys.argv = orig_argv
                
            # Check outputs
            self.assertTrue((tmp_path / "summary.json").exists())
            self.assertTrue((tmp_path / "summary.csv").exists())
            self.assertTrue((tmp_path / "summary.md").exists())
            
            with open(tmp_path / "summary.json") as f:
                sum_data = json.load(f)
                self.assertIn("vn2-ondemand", sum_data)
                self.assertIn("vn2-standby-cached", sum_data)
                self.assertEqual(sum_data["vn2-standby-cached"]["pod_speedup_ratio"], 3.5) # 10500 / 3000 = 3.5
                self.assertEqual(sum_data["vn2-standby-cached"]["batch_speedup_ratio"], 3.0) # 12000 / 4000 = 3.0

