"""Audit real forwarding and baseline ALU top traces without trusting the RTL.

The stage 3A-1 analyzer supplies its second, independent machine-word interpreter
and strict CSV readers. This module audits the actual metrics directly: zero RAW
wait is required only for forwarding cases, and positive wait for both controls.
No metric is rewritten to make an older assertion accept a different behavior.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path

from analyze_cpu5_alu_trace import (
    FIELDS, HEX_COLUMNS, METRIC_HEADER, TRACE_HEADER, check_golden,
    interpret, read_csv, read_hex, require,
)

ROOT = Path(__file__).resolve().parents[1]


def audit_case(case: int, rows: list[dict], metrics: dict,
               expected: list[dict], forwarding: bool) -> dict:
    retired: list[dict] = []
    written_back: list[dict] = []
    last_cycle = 0
    kinds_on_cycle: set[str] = set()
    opcode_counts = Counter()
    gpr_writes = 0
    for ordinal, row in enumerate(rows):
        context = f"case{case} row{ordinal} {row['kind']}"
        cycle = row["cycle"]
        require(cycle >= last_cycle and cycle > 0, f"{context}: unordered cycle")
        if cycle != last_cycle:
            kinds_on_cycle.clear()
        require(row["kind"] not in kinds_on_cycle, f"{context}: duplicate same-edge event")
        kinds_on_cycle.add(row["kind"])
        last_cycle = cycle
        target = retired if row["kind"] == "retire" else written_back
        index = len(target)
        require(row["index"] == index and index < len(expected),
                f"{context}: extra/missing/reordered index")
        oracle = expected[index]
        for field in FIELDS:
            # A WB row records the pre-edge architectural cursor, owned by the
            # latest MEM retirement, rather than the WB packet's own next PC.
            if row["kind"] == "wb" and field == "nextpc":
                continue
            require(row[field] == oracle[field],
                    f"{context}: {field} observed={row[field]:x} expected={oracle[field]:x}")
        if row["kind"] == "retire":
            require(row["instret"] == len(retired) + 1,
                    f"{context}: post-edge instret")
            retired.append(row)
            opcode_counts[oracle["opcode"]] += 1
        else:
            require(index < len(retired), f"{context}: WB before MEM retirement")
            require(cycle == retired[index]["cycle"] + 1,
                    f"{context}: physical WB must follow MEM by one edge")
            require(row["instret"] == len(retired), f"{context}: pre-edge instret")
            require(row["nextpc"] == expected[len(retired) - 1]["nextpc"],
                    f"{context}: pre-edge architectural cursor")
            require("retire" not in kinds_on_cycle,
                    f"{context}: WB must precede post-edge retirement row")
            written_back.append(row)
            gpr_writes += row["writes"]
    require(len(retired) == len(expected), f"case{case}: missing MEM retirement")
    require(len(written_back) == len(expected), f"case{case}: missing WB including x0")
    require(metrics["case"] == case, f"case{case}: wrong metric owner")
    for name, actual in (("retired", len(retired)), ("wb_packets", len(written_back)),
                         ("gpr_writes", gpr_writes)):
        require(metrics[name] == actual, f"case{case}: {name} metric does not close")
    require(metrics["cycles"] > last_cycle,
            f"case{case}: metric cycle cursor does not cover halt/drain")
    if forwarding:
        require(metrics["raw_wait_cycles"] == 0,
                f"case{case}: forwarding ALU subset must have zero RAW wait")
    else:
        require(0 < metrics["raw_wait_cycles"] <= metrics["cycles"],
                f"case{case}: conservative baseline RAW wait not exercised")
    require(metrics["requests"] >= metrics["responses"] >= len(expected) + 1,
            f"case{case}: fetch request/response/halt-packet ledger")
    return dict(case=case, status="PASS", forwarding=forwarding,
                retired=len(retired), wb_packets=len(written_back), gpr_writes=gpr_writes,
                x0_write_disabled_packets=len(expected) - gpr_writes,
                opcode_counts=dict(sorted(opcode_counts.items())),
                first_retire_cycle=retired[0]["cycle"], last_retire_cycle=retired[-1]["cycle"],
                **{key: metrics[key] for key in ("cycles", "raw_wait_cycles", "requests", "responses")})


def compare_ab(forward_case: int, baseline_case: int, rows_by_case: dict,
               cases: list[dict]) -> dict:
    forward_retire = [row for row in rows_by_case[forward_case] if row["kind"] == "retire"]
    baseline_retire = [row for row in rows_by_case[baseline_case] if row["kind"] == "retire"]
    require(len(forward_retire) == len(baseline_retire) == 550,
            "A/B needs the full identical 550-instruction program")
    for index, (forward_row, baseline_row) in enumerate(zip(forward_retire, baseline_retire)):
        for field in FIELDS:
            require(forward_row[field] == baseline_row[field],
                    f"A/B case{forward_case}/case{baseline_case} row{index}: {field} differs")
    forward_cycles, baseline_cycles = cases[forward_case]["cycles"], cases[baseline_case]["cycles"]
    require(forward_cycles <= baseline_cycles,
            f"A/B case{forward_case}/case{baseline_case}: forwarding regressed test cycles")
    # The fast endpoint exposes RAW stalls. With a waited endpoint the IF
    # response schedule can hide every removed RAW wait, so equality is valid.
    if forward_case == 0:
        require(forward_cycles < baseline_cycles,
                "fast A/B must show a strict reduction in directed test cycles")
    measured_saving = baseline_cycles - forward_cycles
    return dict(forward_case=forward_case, baseline_case=baseline_case,
                endpoint="fast" if forward_case == 0 else "waited",
                status="PASS", identical_retirements=550, identical_fields=list(FIELDS),
                forward_cycles=forward_cycles, baseline_cycles=baseline_cycles,
                cycles_saved=measured_saving,
                cycle_result="measured cycle saving" if measured_saving else
                             "masked by IF backpressure; no measured cycle saving",
                cycle_reduction_percent=100 * (1 - forward_cycles / baseline_cycles),
                test_speedup=baseline_cycles / forward_cycles,
                forward_raw_wait_cycles=cases[forward_case]["raw_wait_cycles"],
                baseline_raw_wait_cycles=cases[baseline_case]["raw_wait_cycles"])


def analyze(directory: Path) -> dict:
    program = read_hex(directory / "program.hex")
    require(program[-1] == 0x00002023, "main program must terminate with unsupported SW")
    main_trace, registers = check_golden(directory, "", program[:-1])
    require(len(main_trace) == 550, "main program retirement count is not 550")
    require(read_hex(directory / "final_gpr.hex") == registers,
            "final 32 GPR golden differs from independent reference")
    fault_program = read_hex(directory / "if_fault_program.hex")
    fault_trace, _ = check_golden(directory, "if_fault_", fault_program[:-1])
    require(len(fault_trace) == 8 and fault_program[-1] == 0x00002023,
            "incorrect IF fault fixture")
    unsupported = read_hex(directory / "unsupported.hex")
    require(len(unsupported) == len(set(unsupported)) == 45,
            "unsupported fixtures must be 45 distinct words")
    for word in unsupported:
        try:
            interpret([word])
        except ValueError:
            pass
        else:
            raise ValueError(f"unsupported fixture was accepted: {word:08x}")
    stop_prefix, _ = interpret([0x00700093, 0x00508113])
    cases, rows_by_case = [], {}
    sources = ["program.hex", "if_fault_program.hex", "unsupported.hex", "final_gpr.hex"]
    sources += [f"{prefix}expected_{field}.hex"
                for prefix in ("", "if_fault_") for field in FIELDS]
    for case in range(50):
        trace_name, metric_name = f"case{case}_trace.csv", f"case{case}_metrics.csv"
        rows = read_csv(directory / trace_name, TRACE_HEADER)
        metric_rows = read_csv(directory / metric_name, METRIC_HEADER)
        require(len(metric_rows) == 1, f"case{case}: expected exactly one metrics row")
        expected = main_trace if case < 2 or case >= 48 else fault_trace[:3] if case == 2 else stop_prefix
        cases.append(audit_case(case, rows, metric_rows[0], expected, forwarding=case < 48))
        rows_by_case[case] = rows
        sources += [trace_name, metric_name]
    require(sum(case["retired"] for case in cases[:48]) == 1193,
            "forwarding cases must retire 1193 packets")
    require(sum(case["retired"] for case in cases[48:]) == 1100,
            "baseline controls must retire 1100 packets")
    aggregate = Counter()
    for case in cases:
        aggregate.update(case["opcode_counts"])
    ab = [compare_ab(0, 48, rows_by_case, cases), compare_ab(1, 49, rows_by_case, cases)]
    return dict(schema=1, status="PASS", scope="CPU5 integer ALU forwarding subset only",
                limitation="Directed simulation cycle savings are not CoreMark, board performance, STA, or full 3A-2 acceptance.",
                case_count=50, forwarding_cases=48, baseline_cases=2, cases=cases,
                total_retired=sum(case["retired"] for case in cases),
                total_wb_packets=sum(case["wb_packets"] for case in cases),
                total_gpr_writes=sum(case["gpr_writes"] for case in cases),
                total_x0_write_disabled_packets=sum(case["x0_write_disabled_packets"] for case in cases),
                opcode_counts=dict(sorted(aggregate.items())), ab_comparisons=ab,
                checks=["second independent machine-word interpreter", "all seven golden fields", "final 32 GPR golden",
                        "ordered complete MEM retirement", "post-edge instret and architectural nextpc",
                        "one subsequent physical WB per retirement including x0 packets",
                        "WB identity/value and pre-edge instret/nextpc", "actual per-case metrics closure",
                        "zero RAW wait in 48 forwarding cases", "positive RAW wait in two conservative controls",
                        "all seven retirement fields equal in same-program A/B",
                        "no cycle regression in either endpoint; strict cycle reduction in fast endpoint",
                        "waited endpoint equality is allowed and reported as no measured cycle saving",
                        "45 independently rejected unsupported words"],
                source_sha256={name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in sources})


def mutation_selftest(directory: Path) -> dict:
    """Reject actual corrupted CSV copies, without changing the good artifacts."""
    out = directory / "analyzer_mutation_selftest"
    out.mkdir(exist_ok=True)
    expected, _ = interpret(read_hex(directory / "program.hex")[:-1])
    results, originals = [], {}
    for name in ("wrong_wb_value", "deleted_wb_packet", "wrong_retire_instret",
                 "forwarding_raw_wait_nonzero", "baseline_raw_wait_zero"):
        case = 48 if name == "baseline_raw_wait_zero" else 0
        trace_path, metric_path = directory / f"case{case}_trace.csv", directory / f"case{case}_metrics.csv"
        for path in (trace_path, metric_path):
            originals[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        rows = read_csv(trace_path, TRACE_HEADER)
        metric = read_csv(metric_path, METRIC_HEADER)[0]
        if name == "wrong_wb_value":
            next(row for row in rows if row["kind"] == "wb")["value"] ^= 1
        elif name == "deleted_wb_packet":
            del rows[next(index for index, row in enumerate(rows) if row["kind"] == "wb")]
        elif name == "wrong_retire_instret":
            next(row for row in rows if row["kind"] == "retire")["instret"] += 1
        elif name == "forwarding_raw_wait_nonzero":
            metric["raw_wait_cycles"] = 1
        else:
            metric["raw_wait_cycles"] = 0
        trace_copy, metric_copy = out / f"{name}_trace.csv", out / f"{name}_metrics.csv"
        for path, header, values in ((trace_copy, TRACE_HEADER, rows),
                                     (metric_copy, METRIC_HEADER, [metric])):
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=header)
                writer.writeheader()
                for row in values:
                    writer.writerow({key: f"{value:08x}" if key in HEX_COLUMNS else value
                                     for key, value in row.items()})
        try:
            audit_case(case, read_csv(trace_copy, TRACE_HEADER),
                       read_csv(metric_copy, METRIC_HEADER)[0], expected, forwarding=case < 48)
        except ValueError as exc:
            reason = str(exc)
        else:
            raise ValueError(f"analyzer mutation escaped rejection: {name}")
        results.append(dict(name=name, rejected=True, reason=reason,
                            trace_sha256=hashlib.sha256(trace_copy.read_bytes()).hexdigest(),
                            metrics_sha256=hashlib.sha256(metric_copy.read_bytes()).hexdigest()))
    require(all(hashlib.sha256(Path(name).read_bytes()).hexdigest() == sha
                for name, sha in originals.items()), "selftest changed original good artifacts")
    result = dict(status="PASS", rejected_count=len(results), tests=results,
                  original_good_artifacts_unchanged=True, source_sha256=originals)
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "build" / "cpu5_s3_forward")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    result = analyze(args.directory)
    if args.selftest:
        result["mutation_selftest"] = mutation_selftest(args.directory)
    output = args.output or args.directory / "independent_forward_audit.json"
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in
                      ("status", "case_count", "total_retired", "total_wb_packets", "ab_comparisons")}))
