import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_JSON = ROOT / "docs/reference/korea-central-hands-on-2026-08-26.json"
REFERENCE_MARKDOWN = ROOT / "docs/reference/korea-central-hands-on-2026-08-26.md"


class HandsOnRehearsalReferenceTest(unittest.TestCase):
    def load_reference(self):
        self.assertTrue(
            REFERENCE_JSON.exists(),
            f"Missing reference JSON: {REFERENCE_JSON.relative_to(ROOT)}",
        )
        self.assertTrue(
            REFERENCE_MARKDOWN.exists(),
            f"Missing reference Markdown: {REFERENCE_MARKDOWN.relative_to(ROOT)}",
        )
        payload = json.loads(REFERENCE_JSON.read_text(encoding="utf-8"))
        markdown = REFERENCE_MARKDOWN.read_text(encoding="utf-8")
        return payload, markdown

    def test_reference_json_matches_hands_on_contract(self):
        payload, _ = self.load_reference()

        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["purpose"], "hands-on rehearsal")
        self.assertEqual(payload["location"], "koreacentral")
        self.assertEqual(
            [item["scenario"] for item in payload["observations"]],
            [
                "vn2-ondemand",
                "vn2-standby",
                "vn2-standby-cached",
            ],
        )
        self.assertTrue(all(item["status"] == "ready" for item in payload["observations"]))
        self.assertTrue(all(item["elapsed_ms"] >= 0 for item in payload["observations"]))
        self.assertEqual(payload["standby_pool"]["initial_running"], 1)
        self.assertEqual(payload["standby_pool"]["recycle"], [1, 0, 1])
        self.assertIs(payload["cleanup"]["resource_group_exists"], False)

        serialized = json.dumps(payload, ensure_ascii=False).lower()
        for forbidden in ("median", "p95", "ratio", "speedup", "speed-up", "ranking"):
            self.assertNotIn(forbidden, serialized)

    def test_reference_markdown_discloses_scope_and_cleanup(self):
        _, markdown = self.load_reference()

        for required in (
            "한 번의 hands-on 관찰",
            "benchmark 또는 SLA가 아닙니다",
            "resource group exists: false",
        ):
            self.assertIn(required, markdown)


if __name__ == "__main__":
    unittest.main()
