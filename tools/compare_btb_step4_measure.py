#!/usr/bin/env python3
"""Compare a BTB-only candidate against frozen D0 measurements without tolerances.

The existing D0 analyzer remains the authority for each run's own contracts.
This additional check requires unchanged workload counters, complete windows,
and every native STORE phase, both absolute and relative to its launch.
"""
import argparse
import csv
import hashlib
import json
import re
from pathlib import Path


PROFILES = ("smoke", "smoke-validation")
PHASES = ("launch", "cpu_accept", "backend_accept", "commit", "cpu_response", "retire")
REQUIRED_COUNTERS = (
    "counter_valid", "counter_cycles", "counter_retired", "counter_cpi", "raw_ticks",
    "cycle_profile_valid", "cycle_work_other", "cycle_ifetch_wait", "cycle_data_read_wait",
    "cycle_data_write_wait", "cycle_local_mmio_wait", "cycle_redirect_wait", "cycle_profile_sum",
    "icache_access", "icache_hit", "icache_miss", "icache_refill_words", "icache_errors",
    "dcache_access", "dcache_hit", "dcache_miss", "dcache_refill_words", "dcache_errors",
    "dcache_write", "dcache_bypass", "bp_lookup", "bp_hit", "bp_predicted_taken",
    "bp_resolved", "bp_next_pc_mismatch", "bp_direction_error", "bp_target_error",
    "seedcrc", "crclist", "crcmatrix", "crcstate",
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rows(path):
    with path.open(newline="", encoding="utf-8-sig") as stream:
        return list(csv.DictReader(stream))


def reports(path):
    blocks = []
    current = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.fullmatch(r"# COREMARK ([A-Za-z0-9_]+)=(.*)", line)
        if not match:
            continue
        key, value = match.groups()
        if key == "platform":
            current = {}
            blocks.append(current)
        if current is not None:
            if key in current:
                raise ValueError(f"Repeated COREMARK field {key!r} in {path}")
            current[key] = value
    if len(blocks) != 2 or {block.get("profile") for block in blocks} != set(PROFILES):
        raise ValueError(f"Expected exactly two independent profile reports in {path}")
    for block in blocks:
        missing = set(REQUIRED_COUNTERS) - block.keys()
        if missing:
            raise ValueError(f"Missing counters {sorted(missing)} in {path}")
    return {block["profile"]: block for block in blocks}


def differences(left, right):
    return [{"key": key, "baseline": left.get(key), "candidate": right.get(key)}
            for key in sorted(left.keys() | right.keys()) if left.get(key) != right.get(key)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-cpu", type=Path)
    args = parser.parse_args()
    result = {"schema_version": 1, "verification": "FAIL", "baseline": str(args.baseline),
              "candidate": str(args.candidate), "profiles": [], "input_sha256": {}}
    problems = []
    try:
        old_reports = reports(args.baseline / "coremark_d0_measure.transcript.log")
        new_reports = reports(args.candidate / "coremark_d0_measure.transcript.log")
        for profile in PROFILES:
            section = {"profile": profile}
            old_report, new_report = old_reports[profile], new_reports[profile]
            section["report_fields_compared"] = len(old_report)
            section["report_differences"] = differences(old_report, new_report)
            if section["report_differences"]:
                problems.append(f"{profile}: printed counters/report changed")
            for kind in ("window", "transactions"):
                filename = f"coremark_d0_{profile}_{kind}.csv"
                old_path, new_path = args.baseline / filename, args.candidate / filename
                result["input_sha256"][filename] = {"baseline": sha(old_path), "candidate": sha(new_path)}
                old_rows, new_rows = rows(old_path), rows(new_path)
                section[kind + "_rows"] = {"baseline": len(old_rows), "candidate": len(new_rows)}
                section[kind + "_byte_identical"] = old_path.read_bytes() == new_path.read_bytes()
                section[kind + "_all_fields_equal"] = old_rows == new_rows
                if old_rows != new_rows:
                    problems.append(f"{profile}: {kind} complete CSV changed")
                if kind == "window":
                    old_window = {row["key"]: row["value"] for row in old_rows}
                    new_window = {row["key"]: row["value"] for row in new_rows}
                    section["window_differences"] = differences(old_window, new_window)
                    section["window_cycles"] = int(new_window["window_cycles"])
                    section["data_write_wait"] = int(new_window["frozen_data_write_wait"])
                else:
                    def relative(records):
                        return [{**{key: value for key, value in row.items() if key not in PHASES},
                                 **{phase: int(row[phase]) - int(row["launch"]) for phase in PHASES}}
                                for row in records]
                    section["store_relative_phases_and_metadata_equal"] = relative(old_rows) == relative(new_rows)
                    if not section["store_relative_phases_and_metadata_equal"]:
                        problems.append(f"{profile}: native STORE relative phases/metadata changed")
                    selected = [row for row in new_rows if row["in_window"] == "1"
                                and row["epoch"] == new_window["epoch"]]
                    section["selected_epoch"] = int(new_window["epoch"])
                    section["stores_window"] = len(selected)
                    section["store_latencies"] = sorted({int(row["total_cycles"]) for row in selected})
                    if len(selected) != int(new_window["stores_window"]):
                        problems.append(f"{profile}: selected-epoch STORE count does not close")
                    if not selected or section["store_latencies"] != [2]:
                        problems.append(f"{profile}: STORE must remain exactly 2 cycles")
            section["counters"] = {key: new_report[key] for key in REQUIRED_COUNTERS}
            result["profiles"].append(section)
        analysis_name = "coremark_d0_analysis.json"
        old_analysis = json.loads((args.baseline / analysis_name).read_text(encoding="utf-8-sig"))
        new_analysis = json.loads((args.candidate / analysis_name).read_text(encoding="utf-8-sig"))
        result["independent_d0_analyzer_both_pass"] = all(x.get("verification") == "PASS" for x in (old_analysis, new_analysis))
        result["analyzer_full_json_equal"] = old_analysis == new_analysis
        if not result["independent_d0_analyzer_both_pass"] or not result["analyzer_full_json_equal"]:
            problems.append("Independent D0 analyzer failed or its complete result changed")
        if args.baseline_cpu is not None:
            result["cpu_architectural_trace"] = []
            for case_id in range(4):
                filename = f"btb_rom_cpu_case_{case_id}.csv"
                old_path, new_path = args.baseline_cpu / filename, args.candidate / filename
                old_rows, new_rows = rows(old_path), rows(new_path)
                item = {"case_id": case_id, "baseline_rows": len(old_rows), "candidate_rows": len(new_rows),
                        "all_architectural_fields_equal": old_rows == new_rows,
                        "baseline_sha256": sha(old_path), "candidate_sha256": sha(new_path)}
                result["cpu_architectural_trace"].append(item)
                if old_rows != new_rows or len(new_rows) != 17:
                    problems.append(f"CPU case {case_id}: complete architectural retirement trace changed")
    except (OSError, ValueError, KeyError) as error:
        problems.append(str(error))
    result["problems"] = problems
    result["verification"] = "FAIL" if problems else "PASS"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"verification": result["verification"], "problems": problems,
                      "profiles": [{key: profile.get(key) for key in
                                    ("profile", "window_cycles", "data_write_wait", "stores_window", "store_latencies")}
                                   for profile in result["profiles"]]}, indent=2))
    return bool(problems)


if __name__ == "__main__":
    raise SystemExit(main())
