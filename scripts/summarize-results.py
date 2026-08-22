#!/usr/bin/env python3
import sys
import os
import json
import math
import statistics
import argparse
from pathlib import Path

VALID_SCENARIOS = {"aks", "vn2-ondemand", "vn2-standby-uncached", "vn2-standby-cached"}

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

def load_runs(path):
    path = Path(path)
    runs = []
    if path.is_file():
        # Single file
        if path.suffix == ".json":
            with open(path, "r", encoding="utf-8") as f:
                runs.append(json.load(f))
    elif path.is_dir():
        # Directory search
        for item in sorted(path.glob("**/*.json")):
            with open(item, "r", encoding="utf-8") as f:
                try:
                    runs.append(json.load(f))
                except json.JSONDecodeError:
                    pass
    return runs

def summarize_scenario(runs):
    # Runs should be from the same scenario
    if not runs:
        return {}

    scenario = runs[0].get("scenario")
    
    # Validation: schema version and scenario name
    for run in runs:
        if run.get("schema_version") != 1:
            raise ValueError(f"Unsupported schema version: {run.get('schema_version')}")
        sc = run.get("scenario")
        if sc not in VALID_SCENARIOS:
            raise ValueError(f"Unknown scenario name: {sc}")
        if sc != scenario:
            raise ValueError(f"Mixed scenarios in run list: {sc} and {scenario}")

    ready_samples = 0
    failed_count = 0
    timeout_count = 0

    create_to_ready_vals = []
    create_to_scheduled_vals = []
    scheduled_to_ready_vals = []

    first_ready_vals = []
    all_ready_vals = []

    for run in runs:
        # Pods
        for pod in run.get("pods", []):
            state = pod.get("terminal_state")
            if state == "failed":
                failed_count += 1
            elif state == "timeout":
                timeout_count += 1
            elif state == "ready":
                ready_samples += 1
                
            cr = pod.get("create_to_ready_ms")
            cs = pod.get("create_to_scheduled_ms")
            sr = pod.get("scheduled_to_ready_ms")

            if cr is not None:
                create_to_ready_vals.append(cr)
            if cs is not None:
                create_to_scheduled_vals.append(cs)
            if sr is not None:
                scheduled_to_ready_vals.append(sr)

        # Batch
        batch = run.get("batch", {})
        fr = batch.get("first_ready_ms")
        ar = batch.get("all_ready_ms")
        if fr is not None:
            first_ready_vals.append(fr)
        if ar is not None:
            all_ready_vals.append(ar)

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
        "batch_all_ready_ms": metric_summary(all_ready_vals)
    }

def main():
    parser = argparse.ArgumentParser(description="Summarize raw VN2 benchmark results")
    parser.add_argument("--input", required=True, help="Input raw JSON files directory or file path")
    parser.add_argument("--output-dir", required=True, help="Output directory for summaries")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    runs = load_runs(input_path)
    if not runs:
        print(f"No runs found in {input_path}")
        sys.exit(0)

    # Group runs by scenario
    by_scenario = {}
    for run in runs:
        sc = run.get("scenario")
        if sc:
            by_scenario.setdefault(sc, []).append(run)

    summaries = {}
    for sc, sc_runs in by_scenario.items():
        summaries[sc] = summarize_scenario(sc_runs)

    # Add speedup compared to vn2-ondemand baseline
    ondemand_summary = summaries.get("vn2-ondemand", {})
    ondemand_pod_median = ondemand_summary.get("create_to_ready_ms", {}).get("median")
    ondemand_batch_median = ondemand_summary.get("batch_all_ready_ms", {}).get("median")

    for sc, summary in summaries.items():
        pod_med = summary.get("create_to_ready_ms", {}).get("median")
        batch_med = summary.get("batch_all_ready_ms", {}).get("median")
        
        # Calculate speedup if they are standby scenarios
        if sc in ("vn2-standby-uncached", "vn2-standby-cached"):
            summary["pod_speedup_ratio"] = speedup_ratio(ondemand_pod_median, pod_med)
            summary["batch_speedup_ratio"] = speedup_ratio(ondemand_batch_median, batch_med)
        else:
            summary["pod_speedup_ratio"] = None
            summary["batch_speedup_ratio"] = None

    # Write summary.json
    with open(output_dir / "summary.json", "w", encoding="utf-8") as f:
        json.dump(summaries, f, indent=2)

    # Write summary.csv
    csv_rows = [
        "scenario,runs_count,ready_samples,failed_count,timeout_count,"
        "pod_median_ms,pod_p95_ms,pod_min_ms,pod_max_ms,"
        "batch_all_ready_median_ms,pod_speedup_ratio,batch_speedup_ratio"
    ]
    for sc in sorted(VALID_SCENARIOS):
        summary = summaries.get(sc, {})
        if not summary:
            # Empty placeholders
            csv_rows.append(f"{sc},0,0,0,0,,,,,,,")
            continue
        p_med = summary["create_to_ready_ms"]["median"]
        p_p95 = summary["create_to_ready_ms"]["p95"]
        p_min = summary["create_to_ready_ms"]["min"]
        p_max = summary["create_to_ready_ms"]["max"]
        b_med = summary["batch_all_ready_ms"]["median"]
        p_sp = summary["pod_speedup_ratio"]
        b_sp = summary["batch_speedup_ratio"]
        
        row = f"{sc},{summary['runs_count']},{summary['ready_samples']},{summary['failed_count']},{summary['timeout_count']}," \
              f"{p_med if p_med is not None else ''},{p_p95 if p_p95 is not None else ''},{p_min if p_min is not None else ''},{p_max if p_max is not None else ''}," \
              f"{b_med if b_med is not None else ''},{p_sp if p_sp is not None else ''},{b_sp if b_sp is not None else ''}"
        csv_rows.append(row)

    with open(output_dir / "summary.csv", "w", encoding="utf-8") as f:
        f.write("\n".join(csv_rows) + "\n")

    # Write summary.md
    md_content = []
    md_content.append("# ACI VN2 성능 워크숍 결과 요약")
    md_content.append("")
    md_content.append("## 시나리오별 성능 비교")
    md_content.append("")
    md_content.append("| 시나리오 | 실행 횟수 | 성공 Pod | 실패 Pod | 타임아웃 | Pod 기동 Median (ms) | Pod 기동 P95 (ms) | Batch 완료 Median (ms) | Pod Speed-up | Batch Speed-up |")
    md_content.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    
    for sc in ["aks", "vn2-ondemand", "vn2-standby-uncached", "vn2-standby-cached"]:
        summary = summaries.get(sc, {})
        if not summary:
            md_content.append(f"| {sc} | 0 | 0 | 0 | 0 | - | - | - | - | - |")
            continue
        p_med = f"{summary['create_to_ready_ms']['median']:.1f}" if summary['create_to_ready_ms']['median'] is not None else "-"
        p_p95 = f"{summary['create_to_ready_ms']['p95']:.1f}" if summary['create_to_ready_ms']['p95'] is not None else "-"
        b_med = f"{summary['batch_all_ready_ms']['median']:.1f}" if summary['batch_all_ready_ms']['median'] is not None else "-"
        p_sp = f"{summary['pod_speedup_ratio']:.3f}x" if summary['pod_speedup_ratio'] is not None else "-"
        b_sp = f"{summary['batch_speedup_ratio']:.3f}x" if summary['batch_speedup_ratio'] is not None else "-"
        
        md_content.append(
            f"| {sc} | {summary['runs_count']} | {summary['ready_samples']} | {summary['failed_count']} | {summary['timeout_count']} | "
            f"{p_med} | {p_p95} | {b_med} | {p_sp} | {b_sp} |"
        )
    
    md_content.append("")
    md_content.append("> **주의:** 각 시나리오별 15개 Pod 표본(5개 Pod x 3회)은 통계적 경향성을 보여주기 위한 기술 통계(descriptive statistics) 수준이며, 공식적인 SLA 또는 용량 산정의 근거로 사용될 수 없습니다.")
    md_content.append("")

    with open(output_dir / "summary.md", "w", encoding="utf-8") as f:
        f.write("\n".join(md_content) + "\n")

    print("Successfully generated results/summary.json, results/summary.csv, and results/summary.md.")

if __name__ == "__main__":
    main()
