import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_PATH = ROOT / "docs" / "reference" / "korea-central-2026-08-23.json"


class RehearsalReferenceTests(unittest.TestCase):
    def test_reference_preserves_complete_live_rehearsal_evidence(self):
        self.assertTrue(
            REFERENCE_PATH.exists(),
            "live rehearsal reference JSON must be included in the workshop",
        )
        reference = json.loads(REFERENCE_PATH.read_text(encoding="utf-8"))

        self.assertEqual(reference["environment"]["region"], "Korea Central")
        self.assertEqual(reference["methodology"]["runs_per_scenario"], 3)
        self.assertEqual(reference["methodology"]["pods_per_run"], 5)
        self.assertTrue(reference["methodology"]["reference_only"])
        self.assertTrue(reference["methodology"]["not_sla"])

        scenarios = reference["scenarios"]
        self.assertEqual(
            set(scenarios),
            {
                "aks",
                "vn2-ondemand",
                "vn2-standby-uncached",
                "vn2-standby-cached",
            },
        )
        for scenario in scenarios.values():
            self.assertEqual(scenario["runs_count"], 3)
            self.assertEqual(scenario["ready_samples"], 15)
            self.assertEqual(scenario["failed_count"], 0)
            self.assertEqual(scenario["timeout_count"], 0)

        ondemand = scenarios["vn2-ondemand"]
        uncached = scenarios["vn2-standby-uncached"]
        cached = scenarios["vn2-standby-cached"]

        self.assertAlmostEqual(
            reference["comparisons"]["uncached_speedup_vs_ondemand"]["pod"],
            ondemand["pod_create_to_ready_median_ms"]
            / uncached["pod_create_to_ready_median_ms"],
            places=3,
        )
        self.assertAlmostEqual(
            reference["comparisons"]["cached_speedup_vs_ondemand"]["batch"],
            ondemand["batch_all_ready_median_ms"]
            / cached["batch_all_ready_median_ms"],
            places=3,
        )
        self.assertAlmostEqual(
            reference["comparisons"]["cached_gain_vs_uncached"]["batch"],
            uncached["batch_all_ready_median_ms"]
            / cached["batch_all_ready_median_ms"],
            places=3,
        )


if __name__ == "__main__":
    unittest.main()
