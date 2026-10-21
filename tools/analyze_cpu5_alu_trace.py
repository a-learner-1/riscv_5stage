"""Fail-closed independent audit of the 48 CPU5 3A-1 retirement/WB traces.

This does not import the RTL decoder, the testbench, or the vector generator.
Machine words are decoded and executed here a second time.  Golden hexadecimal
files are also checked, rather than being accepted as self-authenticating truth.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MASK = 0xffffffff
FIELDS = ("pc", "instr", "rd", "value", "writes", "seq", "nextpc")
HEX_COLUMNS = {"pc", "instr", "value", "nextpc"}
TRACE_HEADER = ["kind", "cycle", "index", "seq", "pc", "instr", "rd", "value", "writes", "instret", "nextpc"]
METRIC_HEADER = ["case", "retired", "wb_packets", "gpr_writes", "raw_wait_cycles", "cycles", "requests", "responses"]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sx(number: int, width: int) -> int:
    sign = 1 << (width - 1)
    return (number & (sign - 1)) - (number & sign)


def interpret(words: list[int]) -> tuple[list[dict], list[int]]:
    """Independent integer reference: decode masks and an operation table."""
    registers = [0] * 32
    events = []
    binary = {
        (0, 0): ("ADD", lambda a, b: a + b),
        (0x20, 0): ("SUB", lambda a, b: a - b),
        (0, 1): ("SLL", lambda a, b: a << (b & 31)),
        (0, 2): ("SLT", lambda a, b: int(sx(a, 32) < sx(b, 32))),
        (0, 3): ("SLTU", lambda a, b: int(a < b)),
        (0, 4): ("XOR", lambda a, b: a ^ b),
        (0, 5): ("SRL", lambda a, b: a >> (b & 31)),
        (0x20, 5): ("SRA", lambda a, b: sx(a, 32) >> (b & 31)),
        (0, 6): ("OR", lambda a, b: a | b),
        (0, 7): ("AND", lambda a, b: a & b),
    }
    immediate = {
        0: ("ADDI", lambda a, b: a + b),
        2: ("SLTI", lambda a, b: int(sx(a, 32) < b)),
        3: ("SLTIU", lambda a, b: int(a < (b & MASK))),
        4: ("XORI", lambda a, b: a ^ b),
        6: ("ORI", lambda a, b: a | b),
        7: ("ANDI", lambda a, b: a & b),
    }
    shifts = {
        (0, 1): ("SLLI", lambda a, b: a << b),
        (0, 5): ("SRLI", lambda a, b: a >> b),
        (0x20, 5): ("SRAI", lambda a, b: sx(a, 32) >> b),
    }
    for seq, word in enumerate(words):
        pc = seq * 4
        opcode = word & 0x7f
        f3, f7 = (word >> 12) & 7, word >> 25
        dest, source1, source2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        if opcode == 0x33:
            require((f7, f3) in binary, f"reference rejects OP {word:08x}")
            name, operation = binary[f7, f3]
            result = operation(registers[source1], registers[source2])
        elif opcode == 0x13:
            if f3 in immediate:
                name, operation = immediate[f3]
                result = operation(registers[source1], sx(word >> 20, 12))
            else:
                require((f7, f3) in shifts, f"reference rejects OP-IMM {word:08x}")
                name, operation = shifts[f7, f3]
                result = operation(registers[source1], source2)
        elif opcode in (0x17, 0x37):
            name = "AUIPC" if opcode == 0x17 else "LUI"
            result = (word & 0xfffff000) + (pc if opcode == 0x17 else 0)
        else:
            raise ValueError(f"reference rejects opcode {word:08x}")
        result &= MASK
        event = dict(pc=pc, instr=word, rd=dest, value=result,
                     writes=int(dest != 0), seq=seq, nextpc=(pc + 4) & MASK, opcode=name)
        if dest:
            registers[dest] = result
        require(registers[0] == 0, "reference x0 corrupted")
        events.append(event)
    return events, registers


def read_hex(path: Path) -> list[int]:
    lines = path.read_text(encoding="ascii").splitlines()
    require(bool(lines), f"empty hex: {path}")
    for line in lines:
        require(len(line) == 8 and all(character in "0123456789abcdefABCDEF" for character in line),
                f"not an exact 32-bit hex word in {path}: {line!r}")
    return [int(line, 16) for line in lines]


def read_csv(path: Path, header: list[str]) -> list[dict]:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        require(reader.fieldnames == header, f"incorrect CSV header: {path}")
        result = []
        for row in reader:
            require(None not in row and all(value is not None for value in row.values()), f"ragged CSV: {path}")
            parsed = {}
            for key, value in row.items():
                if key == "kind":
                    require(value in {"retire", "wb"}, f"unknown event {value!r}: {path}")
                    parsed[key] = value
                else:
                    try:
                        parsed[key] = int(value, 16 if key in HEX_COLUMNS else 10)
                    except ValueError as exc:
                        raise ValueError(f"noninteger/X/Z value {key}={value!r}: {path}") from exc
                    require(parsed[key] >= 0, f"negative value {key}: {path}")
            result.append(parsed)
        return result


def check_golden(directory: Path, prefix: str, words: list[int]) -> tuple[list[dict], list[int]]:
    expected, registers = interpret(words)
    for field in FIELDS:
        golden = read_hex(directory / f"{prefix}expected_{field}.hex")
        require(golden == [event[field] for event in expected], f"independent reference differs from {prefix}expected_{field}.hex")
    return expected, registers


def audit_rows(case: int, rows: list[dict], metrics: dict, expected: list[dict]) -> dict:
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
        require(row["index"] == index and index < len(expected), f"{context}: extra/missing/reordered index")
        oracle = expected[index]
        for field in FIELDS:
            # WB's nextpc is the architectural cursor before this edge, which
            # belongs to the most recent preceding MEM retirement, not a WB PC.
            if row["kind"] == "wb" and field == "nextpc":
                continue
            require(row[field] == oracle[field],
                    f"{context}: {field} observed={row[field]:x} expected={oracle[field]:x}")
        if row["kind"] == "retire":
            require(row["instret"] == len(retired) + 1, f"{context}: post-edge instret")
            retired.append(row)
            opcode_counts[oracle["opcode"]] += 1
        else:
            require(index < len(retired), f"{context}: WB before corresponding MEM retirement")
            require(cycle == retired[index]["cycle"] + 1, f"{context}: physical WB must follow MEM by one edge")
            require(row["instret"] == len(retired), f"{context}: pre-edge instret")
            require(row["nextpc"] == expected[len(retired) - 1]["nextpc"], f"{context}: pre-edge architectural cursor")
            require("retire" not in kinds_on_cycle, f"{context}: WB row must precede post-edge retirement row")
            written_back.append(row)
            gpr_writes += row["writes"]
    require(len(retired) == len(expected), f"case{case}: missing MEM retirement")
    # This includes rd=x0 packets: they must traverse WB with writes=0.
    require(len(written_back) == len(expected), f"case{case}: missing WB packet, including legal x0 retirement")
    require(metrics["case"] == case, f"case{case}: wrong metric owner")
    for name, actual in (("retired", len(retired)), ("wb_packets", len(written_back)), ("gpr_writes", gpr_writes)):
        require(metrics[name] == actual, f"case{case}: {name} metric does not close")
    require(metrics["cycles"] > last_cycle, f"case{case}: metric cycle cursor does not cover halt/drain")
    require(0 < metrics["raw_wait_cycles"] <= metrics["cycles"], f"case{case}: RAW wait not exercised")
    require(metrics["requests"] >= metrics["responses"] >= len(expected) + 1,
            f"case{case}: fetch request/response/halt-packet ledger")
    return dict(case=case, status="PASS", retired=len(retired), wb_packets=len(written_back),
                gpr_writes=gpr_writes, x0_write_disabled_packets=len(expected) - gpr_writes,
                opcode_counts=dict(sorted(opcode_counts.items())), **{key: metrics[key] for key in ("cycles", "raw_wait_cycles", "requests", "responses")})


def analyze(directory: Path) -> dict:
    program = read_hex(directory / "program.hex")
    require(program[-1] == 0x00002023, "main program must terminate with unsupported SW")
    main_trace, final_registers = check_golden(directory, "", program[:-1])
    require(len(main_trace) == 550, "main program retirement count is not 550")
    require(read_hex(directory / "final_gpr.hex") == final_registers, "final GPR golden differs from independent reference")
    fault_program = read_hex(directory / "if_fault_program.hex")
    fault_trace, _ = check_golden(directory, "if_fault_", fault_program[:-1])
    require(len(fault_trace) == 8 and fault_program[-1] == 0x00002023, "incorrect IF fault fixture")
    unsupported = read_hex(directory / "unsupported.hex")
    require(len(unsupported) == 45 and len(set(unsupported)) == 45, "unsupported fixtures must be 45 distinct words")
    for word in unsupported:
        try:
            interpret([word])
        except ValueError:
            pass
        else:
            raise ValueError(f"unsupported fixture was accepted: {word:08x}")
    stop_prefix, _ = interpret([0x00700093, 0x00508113])
    case_results = []
    sources = ["program.hex", "if_fault_program.hex", "unsupported.hex", "final_gpr.hex"]
    sources += [f"{prefix}expected_{field}.hex" for prefix in ("", "if_fault_") for field in FIELDS]
    for case in range(48):
        trace_name, metrics_name = f"case{case}_trace.csv", f"case{case}_metrics.csv"
        rows = read_csv(directory / trace_name, TRACE_HEADER)
        metric_rows = read_csv(directory / metrics_name, METRIC_HEADER)
        require(len(metric_rows) == 1, f"case{case}: expected exactly one metrics row")
        expected = main_trace if case < 2 else fault_trace[:3] if case == 2 else stop_prefix
        case_results.append(audit_rows(case, rows, metric_rows[0], expected))
        sources += [trace_name, metrics_name]
    aggregate = Counter()
    for case in case_results:
        aggregate.update(case["opcode_counts"])
    require(sum(case["retired"] for case in case_results) == 1193, "48-case total retirement count")
    return dict(schema=1, status="PASS", cases=case_results, case_count=48,
                total_retired=sum(case["retired"] for case in case_results),
                total_wb_packets=sum(case["wb_packets"] for case in case_results),
                total_gpr_writes=sum(case["gpr_writes"] for case in case_results),
                total_x0_write_disabled_packets=sum(case["x0_write_disabled_packets"] for case in case_results),
                opcode_counts=dict(sorted(aggregate.items())),
                checks=["second independent machine-word interpreter", "all seven golden fields", "final 32 GPR golden",
                        "ordered complete MEM retirement", "post-edge instret and architectural nextpc",
                        "one subsequent WB packet per retirement, including writes=0",
                        "WB identity/value and pre-edge instret/nextpc", "per-case metrics closure",
                        "45 independently rejected unsupported machine words"],
                source_sha256={name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in sources})


def mutation_selftest(directory: Path) -> dict:
    """Save separate bad CSVs and prove rejection; never overwrite good traces."""
    destination = directory / "analyzer_mutation_selftest"
    destination.mkdir(exist_ok=True)
    baseline = directory / "case0_trace.csv"
    baseline_sha = hashlib.sha256(baseline.read_bytes()).hexdigest()
    good_rows = read_csv(baseline, TRACE_HEADER)
    metric = read_csv(directory / "case0_metrics.csv", METRIC_HEADER)[0]
    expected, _ = interpret(read_hex(directory / "program.hex")[:-1])
    first_wb = next(index for index, row in enumerate(good_rows) if row["kind"] == "wb")
    first_retire = next(index for index, row in enumerate(good_rows) if row["kind"] == "retire")
    results = []
    for name in ("wrong_wb_value", "deleted_wb_packet", "wrong_retire_instret"):
        bad_rows = [dict(row) for row in good_rows]
        if name == "wrong_wb_value":
            bad_rows[first_wb]["value"] ^= 1
        elif name == "deleted_wb_packet":
            del bad_rows[first_wb]
        else:
            bad_rows[first_retire]["instret"] += 1
        path = destination / f"{name}.csv"
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=TRACE_HEADER)
            writer.writeheader()
            for row in bad_rows:
                writer.writerow({key: f"{value:08x}" if key in HEX_COLUMNS else value
                                 for key, value in row.items()})
        try:
            audit_rows(0, read_csv(path, TRACE_HEADER), metric, expected)
        except ValueError as exc:
            reason = str(exc)
        else:
            raise ValueError(f"analyzer mutation escaped rejection: {name}")
        results.append(dict(name=name, rejected=True, reason=reason,
                            mutated_csv=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    require(hashlib.sha256(baseline.read_bytes()).hexdigest() == baseline_sha, "selftest changed original good trace")
    result = dict(status="PASS", tests=results, rejected_count=len(results),
                  good_trace_sha256=baseline_sha, original_good_trace_unchanged=True)
    (destination / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "build" / "cpu5_s2_alu")
    parser.add_argument("--output", type=Path, help="defaults to <directory>/independent_trace_audit.json")
    parser.add_argument("--selftest", action="store_true", help="also save/reject three independently corrupted CSV copies")
    args = parser.parse_args()
    result = analyze(args.directory)
    if args.selftest:
        result["mutation_selftest"] = mutation_selftest(args.directory)
    output = args.output or args.directory / "independent_trace_audit.json"
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in ("status", "case_count", "total_retired", "total_wb_packets", "total_gpr_writes", "total_x0_write_disabled_packets")}))
