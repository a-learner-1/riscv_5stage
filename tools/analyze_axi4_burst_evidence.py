#!/usr/bin/env python3
"""Reconcile public AR/R evidence with the real demo's specified transactions.

No latency is inferred from the number of Lite transactions. Each AR must
carry one descriptor and be followed by exactly LEN+1 accepted R beats.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path


COMMANDS = (
    (0x40000040, 3, 0, 0), (0x40001040, 3, 1, 0),
    (0x40000044, 0, 0, 0), (0x40001048, 0, 1, 0),
    (0x40000041, 3, -1, 2), (0x40001040, 3, 1, 0),
    (0x50000000, 3, -1, 3), (0x40000040, 3, 0, 0),
    (0x40000FF8, 3, -1, 2), (0x40001040, 3, 1, 0),
)
EXPECTED = ((0x11AA3344, 0x5566BEEF, 0x10203040, 0x76543210),
            (0x8933CD77, 0x01234567, 0x55AA00FF, 0xA51E5A3C))
MARKERS = {
    "axi4_burst_fabric": (
        "AXI4 BURST FABRIC test_pass=1", "AXI4 RAM CONTRACT PASS reads=18 seeds=72 resets=6",
        "AXI4 ROUTER CONTRACT PASS transactions=35 resets=5", "AXI4 HIGH ADDRESS PASS:"),
    "axi4_burst_reader": (
        "AXI4 BURST READER test_pass=1", "commands=14 reset_cases=8 busy_tail_refusals=4"),
    "axi4_burst_soc": (
        "AXI4 BURST SOC test_pass=1", "AXI4 DEMO INPUTS PASS",
        "AXI4 CSR CPU TRAPS PASS:", "AXI4 REAL C PASS:",
        "AR=10 R=34 LAST=10 seeds=12 endpoint_AR=3/4"),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True,
                        help="Independent execution cwd containing logs and build/verification trace")
    parser.add_argument("--d0-comparison", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = {"schema_version": 1, "verification": "FAIL", "input_sha256": {}, "executions": []}
    try:
        for name, markers in MARKERS.items():
            path = args.directory / (name + ".execution.json")
            execution = json.loads(path.read_text(encoding="utf-8-sig"))
            require(execution["exit_code"] == 0 and not execution["errors"] and not execution["warnings"],
                    f"{name}: requires process exit0 and zero errors/warnings")
            log_path = args.directory / (name + ".console.log")
            text = log_path.read_text(encoding="utf-8", errors="replace")
            require(all(marker in text for marker in markers), f"{name}: missing actual test/coverage marker")
            result["executions"].append({"name": name, "exit_code": 0, "errors": 0, "warnings": 0})
            result["input_sha256"][path.name] = digest(path)
            result["input_sha256"][log_path.name] = digest(log_path)
        trace = args.directory / "build/verification/axi4_burst_soc_trace.csv"
        with trace.open(newline="", encoding="utf-8") as stream:
            records = list(csv.DictReader(stream))
        position = 0
        for sequence, (address, length, target, error) in enumerate(COMMANDS, 1):
            row = records[position]
            require(row["event"] == "AR" and int(row["ar_sequence"]) == sequence and
                    int(row["address"], 16) == address and int(row["arlen"]) == length and
                    int(row["beat_or_target"]) == target, f"Command {sequence}: wrong accepted AR descriptor")
            position += 1
            for beat in range(length + 1):
                row = records[position]
                expected_data = 0 if error else EXPECTED[target][((address & 0xFFF) - 0x40) // 4 + beat]
                require(row["event"] == "R" and int(row["ar_sequence"]) == sequence and
                        int(row["address"], 16) == address and int(row["arlen"]) == length and
                        int(row["beat_or_target"]) == beat and int(row["data"], 16) == expected_data and
                        int(row["response"]) == error and int(row["last"]) == (beat == length),
                        f"Command {sequence}: missing/incorrect public R beat {beat}")
                position += 1
        require(position == len(records) == 44, "Extra/missing AR or R handshakes in trace")
        result["input_sha256"][trace.name] = digest(trace)
        result["real_c_fabric"] = {"accepted_ar": 10, "accepted_r": 34, "accepted_rlast": 10,
                                   "endpoint_ar": [3, 4], "native_seed_writes": 12,
                                   "single_ar_descriptors": 2, "four_beat_ar_descriptors": 8,
                                   "real_decode_alignment_page_errors_drained": 3,
                                   "physical_uart_simulation_baud": 5000000,
                                   "unmodified_hardware_image_baud": 115200}
        if args.d0_comparison:
            comparison = json.loads(args.d0_comparison.read_text(encoding="utf-8-sig"))
            require(comparison["verification"] == "PASS", "D0 unchanged-baseline comparison failed")
            result["d0_unchanged_baseline"] = comparison["profiles"]
            result["input_sha256"][args.d0_comparison.name] = digest(args.d0_comparison)
        result["verification"] = "PASS"
        result["problem"] = None
    except (OSError, ValueError, KeyError, IndexError) as error:
        result["problem"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"verification": result["verification"], "problem": result.get("problem"),
                      "real_c_fabric": result.get("real_c_fabric")}, indent=2))
    return result["verification"] != "PASS"


if __name__ == "__main__":
    raise SystemExit(main())
