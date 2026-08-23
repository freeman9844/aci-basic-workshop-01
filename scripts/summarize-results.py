#!/usr/bin/env python3
import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path

VALID_SCENARIOS = (
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
)

SCENARIO_ORDER = [
    "aks-nap",
    "vn2-ondemand",
    "vn2-standby",
    "vn2-standby-cached",
]

SUMMARY_FIELDS = {
    "schema_version",
    "scenario",
    "run",
    "pods",
    "batch",
}


def nearest_rank(values, percentile):
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    rank = max(1, math.ceil((percentile / 100.0) * len(ordered)))
    return ordered[rank - 1]


def metric_summary(values):
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return {"count": 0, "median": None, "p95": None, "min": None, "max": None}
    return {
        "count": len(ordered),
        "median": statistics.median(ordered),
        "p95": nearest_rank(ordered, 95),
        "min": ordered[0],
        "max": ordered[-1],
    }


def speedup_ratio(baseline_ms, candidate_ms):
    if baseline_ms is None or candidate_ms in (None, 0):
        return None
    return round(float(baseline_ms) / float(candidate_ms), 3)


def _load_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Malformed JSON in {path}: {exc.msg}") from exc


def load_runs(path):
    path = Path(path)
    runs = []
    if path.is_file():
        if path.suffix.lower() == ".json":
            runs.append(_load_json_file(path))
        return runs

    if path.is_dir():
        for item in sorted(path.glob("**/*.json")):
            runs.append(_load_json_file(item))

    return runs


def _run_metadata(run):
    return {
        key: value
        for key, value in run.items()
        if key not in SUMMARY_FIELDS
    }


def _copy_pod(pod, pod_index):
    copied = {"pod_index": pod_index}
    copied.update(pod)
    return copied


def summarize_scenario(runs):
    if not runs:
        return {}

    scenario = runs[0].get("scenario")
    if scenario not in VALID_SCENARIOS:
        raise ValueError(f"Unknown scenario name: {scenario}")

    ready_samples = 0
    failed_count = 0
    timeout_count = 0

    create_to_ready_vals = []
    create_to_scheduled_vals = []
    scheduled_to_ready_vals = []
    first_ready_vals = []
    all_ready_vals = []
    evidence_runs = []

    for run in runs:
        if run.get("schema_version") != 1:
            raise ValueError(f"Unsupported schema version: {run.get('schema_version')}")
        run_scenario = run.get("scenario")
        if run_scenario not in VALID_SCENARIOS:
            raise ValueError(f"Unknown scenario name: {run_scenario}")
        if run_scenario != scenario:
            raise ValueError(f"Mixed scenarios in run list: {run_scenario} and {scenario}")

        pods = []
        non_ready_pods = []
        for pod_index, pod in enumerate(run.get("pods", []), start=1):
            pod_record = _copy_pod(pod, pod_index)
            pods.append(pod_record)

            state = pod_record.get("terminal_state")
            if state == "failed":
                failed_count += 1
                non_ready_pods.append(pod_record)
            elif state == "timeout":
                timeout_count += 1
                non_ready_pods.append(pod_record)
            elif state == "ready":
                ready_samples += 1
            else:
                non_ready_pods.append(pod_record)

            cr = pod_record.get("create_to_ready_ms")
            cs = pod_record.get("create_to_scheduled_ms")
            sr = pod_record.get("scheduled_to_ready_ms")

            if cr is not None:
                create_to_ready_vals.append(cr)
            if cs is not None:
                create_to_scheduled_vals.append(cs)
            if sr is not None:
                scheduled_to_ready_vals.append(sr)

        batch = dict(run.get("batch", {}))
        fr = batch.get("first_ready_ms")
        ar = batch.get("all_ready_ms")
        if fr is not None:
            first_ready_vals.append(fr)
        if ar is not None:
            all_ready_vals.append(ar)

        evidence_runs.append(
            {
                "run": run.get("run"),
                "metadata": _run_metadata(run),
                "batch": batch,
                "pods": pods,
                "non_ready_pods": non_ready_pods,
            }
        )

    return {
        "scenario": scenario,
        "runs_count": len(runs),
        "ready_samples": ready_samples,
        "failed_count": failed_count,
        "timeout_count": timeout_count,
        "create_to_ready_ms": metric_summary(create_to_ready_vals),
        "create_to_scheduled_ms": metric_summary(create_to_scheduled_vals),
        "scheduled_to_ready_ms": metric_summary(scheduled_to_ready_vals),
        "batch_first_ready_ms": metric_summary(first_ready_vals),
        "batch_all_ready_ms": metric_summary(all_ready_vals),
        "evidence": {"runs": evidence_runs},
    }


def _format_cell(value):
    return "" if value is None else value


def _format_md_number(value):
    return "-" if value is None else f"{value:.1f}"


def _summaries_by_scenario(runs):
    grouped = {scenario: [] for scenario in VALID_SCENARIOS}
    for run in runs:
        scenario = run.get("scenario")
        grouped.setdefault(scenario, []).append(run)
    return grouped


def _apply_speedups(summaries):
    ondemand_summary = summaries.get("vn2-ondemand", {})
    ondemand_pod_median = ondemand_summary.get("create_to_ready_ms", {}).get("median")
    ondemand_batch_median = ondemand_summary.get("batch_all_ready_ms", {}).get("median")

    for scenario, summary in summaries.items():
        pod_median = summary.get("create_to_ready_ms", {}).get("median")
        batch_median = summary.get("batch_all_ready_ms", {}).get("median")
        if scenario != "vn2-ondemand":
            summary["pod_speedup_ratio"] = speedup_ratio(ondemand_pod_median, pod_median)
            summary["batch_speedup_ratio"] = speedup_ratio(ondemand_batch_median, batch_median)
        else:
            summary["pod_speedup_ratio"] = None
            summary["batch_speedup_ratio"] = None


def _build_csv(summaries):
    rows = []
    header = [
        "scenario",
        "runs_count",
        "ready_samples",
        "failed_count",
        "timeout_count",
        "pod_median_ms",
        "pod_p95_ms",
        "pod_min_ms",
        "pod_max_ms",
        "batch_first_ready_median_ms",
        "batch_all_ready_median_ms",
        "pod_speedup_ratio",
        "batch_speedup_ratio",
        "evidence_json",
    ]
    rows.append(header)

    for scenario in SCENARIO_ORDER:
        summary = summaries.get(scenario, {})
        if not summary:
            rows.append([scenario, 0, 0, 0, 0, "", "", "", "", "", "", "", "", ""])
            continue
        rows.append(
            [
                scenario,
                summary["runs_count"],
                summary["ready_samples"],
                summary["failed_count"],
                summary["timeout_count"],
                _format_cell(summary["create_to_ready_ms"]["median"]),
                _format_cell(summary["create_to_ready_ms"]["p95"]),
                _format_cell(summary["create_to_ready_ms"]["min"]),
                _format_cell(summary["create_to_ready_ms"]["max"]),
                _format_cell(summary["batch_first_ready_ms"]["median"]),
                _format_cell(summary["batch_all_ready_ms"]["median"]),
                _format_cell(summary["pod_speedup_ratio"]),
                _format_cell(summary["batch_speedup_ratio"]),
                json.dumps(summary["evidence"], ensure_ascii=False, sort_keys=True, separators=(",", ":")),
            ]
        )

    return rows


def _build_markdown(summaries):
    lines = []
    lines.append("# ACI VN2 성능 워크숍 결과 요약")
    lines.append("")
    lines.append("## 시나리오별 성능 비교")
    lines.append("")
    lines.append(
        "| 시나리오 | 실행 횟수 | 성공 Pod | 실패 Pod | 타임아웃 | "
        "Pod 기동 Median (ms) | Pod 기동 P95 (ms) | Batch 첫 Ready Median (ms) | "
        "Batch 완료 Median (ms) | Pod Speed-up | Batch Speed-up |"
    )
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")

    for scenario in SCENARIO_ORDER:
        summary = summaries.get(scenario, {})
        if not summary:
            lines.append(f"| {scenario} | 0 | 0 | 0 | 0 | - | - | - | - | - | - |")
            continue
        pod_median = summary["create_to_ready_ms"]["median"]
        pod_p95 = summary["create_to_ready_ms"]["p95"]
        batch_first_ready = summary["batch_first_ready_ms"]["median"]
        batch_all_ready = summary["batch_all_ready_ms"]["median"]
        pod_speedup = summary["pod_speedup_ratio"]
        batch_speedup = summary["batch_speedup_ratio"]
        lines.append(
            f"| {scenario} | {summary['runs_count']} | {summary['ready_samples']} | {summary['failed_count']} | "
            f"{summary['timeout_count']} | "
            f"{_format_md_number(pod_median)} | {_format_md_number(pod_p95)} | "
            f"{_format_md_number(batch_first_ready)} | {_format_md_number(batch_all_ready)} | "
            f"{(str(pod_speedup) + 'x') if pod_speedup is not None else '-'} | "
            f"{(str(batch_speedup) + 'x') if batch_speedup is not None else '-'} |"
        )

    lines.append("")
    lines.append("## 증거")
    lines.append("")
    for scenario in SCENARIO_ORDER:
        summary = summaries.get(scenario, {})
        if not summary:
            continue
        lines.append(f"### {scenario}")
        lines.append("```json")
        lines.extend(
            json.dumps(
                summary["evidence"],
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ).splitlines()
        )
        lines.append("```")
        lines.append("")

    lines.append(
        "> **주의:** 각 시나리오별 15개 Pod 표본(5개 Pod x 3회)은 "
        "기술 통계(descriptive statistics) 수준이며, 공식적인 SLA 또는 용량 산정의 근거로 사용될 수 없습니다."
    )
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Summarize raw VN2 benchmark results")
    parser.add_argument("--input", required=True, help="Input raw JSON files directory or file path")
    parser.add_argument("--output-dir", required=True, help="Output directory for summaries")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        runs = load_runs(input_path)
        if not runs:
            print(f"No runs found in {input_path}")
            return 0

        by_scenario = _summaries_by_scenario(runs)
        summaries = {}
        for scenario in SCENARIO_ORDER:
            if by_scenario.get(scenario):
                summaries[scenario] = summarize_scenario(by_scenario[scenario])

        # Preserve unknown scenarios as an explicit failure rather than hiding them.
        for scenario, scenario_runs in by_scenario.items():
            if scenario not in VALID_SCENARIOS and scenario_runs:
                summaries[scenario] = summarize_scenario(scenario_runs)

        _apply_speedups(summaries)

        with open(output_dir / "summary.json", "w", encoding="utf-8") as handle:
            json.dump(summaries, handle, indent=2, ensure_ascii=False)

        with open(output_dir / "summary.csv", "w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerows(_build_csv(summaries))

        with open(output_dir / "summary.md", "w", encoding="utf-8") as handle:
            handle.write(_build_markdown(summaries) + "\n")

        print(
            f"Successfully generated {output_dir / 'summary.json'}, "
            f"{output_dir / 'summary.csv'}, and {output_dir / 'summary.md'}."
        )
        return 0
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
