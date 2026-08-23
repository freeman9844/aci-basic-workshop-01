import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_JSON = ROOT / "docs/reference/korea-central-2026-08-23.json"
REFERENCE_MARKDOWN = ROOT / "docs/reference/korea-central-2026-08-23.md"


class RehearsalReferenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference = json.loads(REFERENCE_JSON.read_text(encoding="utf-8"))
        cls.markdown = REFERENCE_MARKDOWN.read_text(encoding="utf-8")
        cls.readme = (ROOT / "README.md").read_text(encoding="utf-8")
        cls.module06 = (ROOT / "docs/06-analyze-results.md").read_text(encoding="utf-8")

    def test_records_live_environment_and_four_scenarios(self):
        expected = {
            "aks-nap",
            "vn2-ondemand",
            "vn2-standby",
            "vn2-standby-cached",
        }
        self.assertEqual(set(self.reference["scenarios"]), expected)
        self.assertEqual(self.reference["run_date"], "2026-08-23")
        self.assertEqual(self.reference["environment"]["region"], "koreacentral")
        self.assertEqual(
            self.reference["environment"]["system_node_sku"], "Standard_D16s_v5"
        )
        self.assertEqual(
            self.reference["environment"]["nap_node_sku"], "Standard_D4s_v5"
        )
        self.assertEqual(
            self.reference["environment"]["aks_kubernetes_version"], "1.34.9"
        )
        self.assertEqual(
            self.reference["environment"]["vn2_helm_chart_version"],
            "1.3410.26081102",
        )
        self.assertEqual(
            self.reference["environment"]["nap_api_versions"],
            {
                "aks_node_class": "karpenter.azure.com/v1beta1",
                "node_pool": "karpenter.sh/v1",
            },
        )

    def test_records_exact_run_and_sample_contract(self):
        methodology = self.reference["methodology"]
        self.assertEqual(methodology["runs_per_scenario"], 3)
        self.assertEqual(methodology["pods_per_run"], 5)
        self.assertEqual(methodology["total_runs"], 12)
        self.assertEqual(methodology["total_ready_pods"], 60)
        self.assertTrue(methodology["reference_only"])
        self.assertTrue(methodology["not_sla"])

        for scenario in self.reference["scenarios"].values():
            self.assertEqual(scenario["runs_count"], 3)
            self.assertEqual(scenario["ready_samples"], 15)
            self.assertEqual(scenario["failed_count"], 0)
            self.assertEqual(scenario["timeout_count"], 0)
            for metric in (
                "create_to_ready_ms",
                "batch_first_ready_ms",
                "batch_all_ready_ms",
            ):
                self.assertIsInstance(scenario[metric]["median"], (int, float))
                self.assertIsInstance(scenario[metric]["p95"], (int, float))

    def test_ratios_match_literal_stored_medians(self):
        scenarios = self.reference["scenarios"]
        baseline = scenarios["vn2-ondemand"]
        comparisons = self.reference["comparisons"]

        for scenario_name in ("aks-nap", "vn2-standby", "vn2-standby-cached"):
            scenario = scenarios[scenario_name]
            expected_pod_ratio = round(
                baseline["create_to_ready_ms"]["median"]
                / scenario["create_to_ready_ms"]["median"],
                3,
            )
            expected_batch_ratio = round(
                baseline["batch_all_ready_ms"]["median"]
                / scenario["batch_all_ready_ms"]["median"],
                3,
            )
            self.assertAlmostEqual(
                comparisons[scenario_name]["pod_speedup_ratio"],
                expected_pod_ratio,
                places=3,
            )
            self.assertAlmostEqual(
                comparisons[scenario_name]["batch_speedup_ratio"],
                expected_batch_ratio,
                places=3,
            )

    def test_reference_documents_lifecycle_pool_cache_and_caveat(self):
        for required in (
            "5 Pods × 3",
            "0→1→0",
            "healthy",
            "running=5",
            "5→0→5",
            "fallback",
            "reference",
            "SLA",
        ):
            self.assertIn(required, self.markdown)

    def test_participant_docs_link_current_reference_without_old_warm_aks_claims(self):
        markdown_link = (
            "[Korea Central 2026-08-23 live rehearsal reference]"
            "(docs/reference/korea-central-2026-08-23.md)"
        )
        json_link = (
            "[reference JSON]"
            "(docs/reference/korea-central-2026-08-23.json)"
        )
        self.assertIn(markdown_link, self.readme)
        self.assertIn(json_link, self.readme)
        self.assertIn(
            "[Korea Central 2026-08-23 live rehearsal reference]"
            "(./reference/korea-central-2026-08-23.md)",
            self.module06,
        )
        self.assertIn(
            "[reference JSON](./reference/korea-central-2026-08-23.json)",
            self.module06,
        )

        active_text = "\n".join(
            (self.readme, self.module06, self.markdown, json.dumps(self.reference))
        )
        for stale_claim in (
            "Pod median 9.796배",
            "Batch all-ready median 7.062배",
            "vn2-standby-" + "uncached",
            '"aks":',
        ):
            self.assertNotIn(stale_claim, active_text)


if __name__ == "__main__":
    unittest.main()
