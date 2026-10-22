"""Recheck CPU5 RAM evidence with a second machine-word interpreter.

No generator or RTL module is imported.  The reference uses its own immediate
extraction and operation dispatch and follows the encoded PCs, including loops.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
FIELDS = ("pc", "instr", "rd", "value", "writes", "nextpc")
MASK32 = 0xffffffff
TRACE_HEADER = ("kind", "cycle", "index", "seq", "pc", "instr", "rd", "value", "writes", "instret", "nextpc")
ACCEPT_HEADER = ("cycle", "seq", "pc", "instr")
EVENT_HEADER = ("cycle", "event", "seq", "pc", "nextpc", "target", "taken", "pred_next", "pred_taken", "is_branch", "is_jal", "is_jalr")
D_HEADER = ("event", "cycle", "seq", "pc", "addr", "wdata", "wstrb", "size", "is_write", "rdata", "error")
HEX_COLUMNS = {"seq", "pc", "instr", "value", "nextpc", "target", "pred_next", "addr", "wdata", "wstrb", "rdata"}


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def read_hex(path: Path) -> list[int]:
    lines = path.read_text(encoding="ascii").splitlines()
    require(bool(lines) and all(len(line) == 8 and all(c in "0123456789abcdefABCDEF" for c in line) for line in lines), f"{path.name}: exact 32-bit hex required")
    return [int(line, 16) for line in lines]


def signed32(number: int) -> int:
    return number if number < 0x80000000 else number - 0x100000000


def simulate(words: list[int], initial: list[int]) -> dict:
    registers, cursor, events, accesses = [0] * 32, 0, [], []
    memory = bytearray(b"".join(word.to_bytes(4, "little") for word in initial))
    for index in range(20000):
        require(cursor & 3 == 0 and cursor < len(words) * 4, f"reference cursor outside ROM: {cursor:x}")
        instruction = words[cursor // 4]
        if instruction == 0x00100073:
            final_words = [int.from_bytes(memory[n:n+4], "little") for n in range(0, len(memory), 4)]
            return dict(trace=events, registers=registers, memory=final_words, accesses=accesses, halt_pc=cursor)
        op, sub = instruction % 128, (instruction // 4096) % 8
        destination = (instruction // 128) % 32
        left_reg, right_reg = (instruction // 32768) % 32, (instruction // 1048576) % 32
        left, right = registers[left_reg], registers[right_reg]
        immediate = instruction // 1048576
        if immediate >= 2048:
            immediate -= 4096
        result, following, redirect = 0, (cursor + 4) & MASK32, False
        operation = ""
        if op in (0x37, 0x17):
            result = instruction & 0xfffff000
            operation = "LUI" if op == 0x37 else "AUIPC"
            if op == 0x17:
                result += cursor
        elif op in (0x13, 0x33):
            second = immediate if op == 0x13 else right
            upper = instruction >> 25
            shift = right_reg if op == 0x13 else right & 31
            require(op == 0x13 or upper in (0, 32), f"reference invalid R major {instruction:x}")
            if sub == 0:
                if op == 0x13:
                    operation, result = "ADDI", left + second
                elif upper == 32:
                    operation, result = "SUB", left - second
                else:
                    operation, result = "ADD", left + second
            elif sub == 1:
                require(upper == 0, f"reference invalid shift {instruction:x}")
                operation, result = "SLLI" if op == 0x13 else "SLL", left << shift
            elif sub == 2:
                require(op == 0x13 or upper == 0, f"reference invalid SLT {instruction:x}")
                operation, result = "SLTI" if op == 0x13 else "SLT", int(signed32(left) < (immediate if op == 0x13 else signed32(second)))
            elif sub == 3:
                require(op == 0x13 or upper == 0, f"reference invalid SLTU {instruction:x}")
                operation, result = "SLTIU" if op == 0x13 else "SLTU", int(left < (second & MASK32))
            elif sub == 4:
                require(op == 0x13 or upper == 0, f"reference invalid XOR {instruction:x}")
                operation, result = "XORI" if op == 0x13 else "XOR", left ^ second
            elif sub == 5:
                require(upper in (0, 32), f"reference invalid right shift {instruction:x}")
                if upper == 32:
                    operation, result = "SRAI" if op == 0x13 else "SRA", signed32(left) >> shift
                else:
                    operation, result = "SRLI" if op == 0x13 else "SRL", left >> shift
            elif sub == 6:
                require(op == 0x13 or upper == 0, f"reference invalid OR {instruction:x}")
                operation, result = "ORI" if op == 0x13 else "OR", left | second
            else:
                require(op == 0x13 or upper == 0, f"reference invalid AND {instruction:x}")
                operation, result = "ANDI" if op == 0x13 else "AND", left & second
        elif op in (0x03, 0x23):
            store = op == 0x23
            if store:
                displacement = ((instruction & 0xfe000000) >> 20) + ((instruction & 0x00000f80) >> 7)
                if displacement >= 2048:
                    displacement -= 4096
            else:
                displacement = immediate
            address = (left + displacement) & MASK32
            names = {0: "SB", 1: "SH", 2: "SW"} if store else {0: "LB", 1: "LH", 2: "LW", 4: "LBU", 5: "LHU"}
            require(sub in names, "invalid memory function")
            operation = names[sub]
            count = 1 << (sub & 3)
            require(address >= 65536 and address + count <= 81920, "memory outside RAM")
            require(address % count == 0, "memory alignment fault")
            offset = address - 65536
            base = offset & ~3
            raw = sum(memory[base + k] * 256**k for k in range(4))
            lane = offset % 4
            store_data = (right << (lane * 8)) & MASK32 if store else 0
            store_mask = sum(1 << k for k in range(lane, lane + count)) if store else 0
            # Upper data outside active strobes is architecturally irrelevant;
            # the gold producer deliberately emits zeros in those lanes.
            store_data &= sum(255 << (k * 8) for k in range(lane, lane + count)) if store else 0
            accesses.append(dict(index=index, addr=address, wdata=store_data,
                                 wstrb=store_mask, size=sub & 3, is_write=int(store), rdata=raw))
            if store:
                for k in range(count):
                    memory[offset + k] = (right >> (8 * k)) & 255
                destination = 0
            else:
                result = sum(memory[offset + k] * 256**k for k in range(count))
                if sub in (0, 1) and result >= 1 << (count * 8 - 1):
                    result -= 1 << (count * 8)
        elif op == 0x63:
            # Extract the split B immediate with masks at each encoded bit site.
            displacement = ((instruction & 0x80000000) >> 19) + ((instruction & 0x00000080) << 4) + ((instruction & 0x7e000000) >> 20) + ((instruction & 0x00000f00) >> 7)
            if displacement >= 4096:
                displacement -= 8192
            if sub == 0:
                operation, redirect = "BEQ", left == right
            elif sub == 1:
                operation, redirect = "BNE", left != right
            elif sub == 4:
                operation, redirect = "BLT", signed32(left) < signed32(right)
            elif sub == 5:
                operation, redirect = "BGE", signed32(left) >= signed32(right)
            elif sub == 6:
                operation, redirect = "BLTU", left < right
            elif sub == 7:
                operation, redirect = "BGEU", left >= right
            else:
                raise ValueError(f"reference invalid branch {instruction:x}")
            destination = 0
            if redirect:
                following = (cursor + displacement) & MASK32
        elif op == 0x6f:
            displacement = ((instruction & 0x80000000) >> 11) + (instruction & 0x000ff000) + ((instruction & 0x00100000) >> 9) + ((instruction & 0x7fe00000) >> 20)
            if displacement >= 1048576:
                displacement -= 2097152
            operation, result, redirect = "JAL", (cursor + 4) & MASK32, True
            following = (cursor + displacement) & MASK32
        elif op == 0x67:
            require(sub == 0, f"reference invalid JALR {instruction:x}")
            operation, result, redirect = "JALR", (cursor + 4) & MASK32, True
            following = (left + immediate) & 0xfffffffe
        else:
            raise ValueError(f"reference unsupported encoding {instruction:08x} at {cursor:08x}")
        if redirect and following & 3:
            raise ValueError("reference misaligned control target")
        result &= MASK32
        events.append(dict(pc=cursor, instr=instruction, rd=destination, value=result,
                           writes=int(destination != 0), nextpc=following, opcode=operation,
                           taken=int(redirect), index=index))
        if destination:
            registers[destination] = result
        registers[0] = 0
        cursor = following
    raise ValueError("reference execution bound exceeded")


def check_vectors(directory: Path) -> tuple[dict, dict]:
    results, golden = [], {}
    fields = ("index", "addr", "wdata", "wstrb", "size", "is_write", "rdata")
    summary = json.loads((directory / "oracle_summary.json").read_text(encoding="utf-8"))
    require(summary["selftests"] >= 51, "missing oracle selftests")
    for number in range(2):
        name = f"seed{number}"
        folder = directory / name
        meta = json.loads((folder / "meta.json").read_text(encoding="utf-8"))
        program, initial = read_hex(folder / "program.hex"), read_hex(folder / "ram_initial.hex")
        require(len(program) == 8192 and len(initial) == 4096, f"{name}: full memory dimensions")
        computed = simulate(program, initial)
        for field in FIELDS:
            observed = read_hex(folder / f"expected_{field}.hex")
            require(observed == [row[field] for row in computed["trace"]], f"{name}: independent retirement {field}")
        for field in fields:
            observed = read_hex(folder / f"expected_mem_{field}.hex")
            require(observed == [row[field] for row in computed["accesses"]], f"{name}: independent D field {field}")
        require(computed["memory"] == read_hex(folder / "ram_final.hex"), f"{name}: complete final RAM")
        require(computed["registers"] == read_hex(folder / "final_gpr.hex"), f"{name}: complete final GPR")
        require(computed["halt_pc"] == meta["halt_pc"] and meta["halt_instr"] == 0x00100073, f"{name}: EBREAK stop")
        require(len(computed["trace"]) == meta["retire_count"] and len(computed["accesses"]) == meta["mem_access_count"], f"{name}: populations")
        counts = Counter(row["opcode"] for row in computed["trace"])
        require(dict(counts) == meta["coverage"], f"{name}: opcode population")
        require(all(counts[x] > 0 for x in ("LB", "LH", "LW", "LBU", "LHU", "SB", "SH", "SW", "JALR")), f"{name}: required RAM and return instructions")
        golden[name] = computed
        results.append(dict(name=name, status="PASS", retire_count=len(computed["trace"]),
                            mem_access_count=len(computed["accesses"]), opcode_counts=dict(sorted(counts.items())), halt_pc=computed["halt_pc"]))
    for name, digest in json.loads((directory / "manifest.json").read_text(encoding="utf-8")).items():
        require(hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest, f"{name}: generated evidence SHA256")
    return dict(status="PASS", seeds=results, selftests=summary["selftests"],
                checks=["independent machine-word interpreter", "six retirement fields", "seven D request fields", "entire final RAM and GPR images", "ELF/vector manifest SHA256"]), golden


def read_csv(path: Path, header: tuple[str, ...]) -> list[dict]:
    with path.open(newline="", encoding="ascii") as source:
        reader = csv.DictReader(source)
        require(tuple(reader.fieldnames or ()) == header, f"{path}: unexpected CSV header")
        rows = []
        for index, row in enumerate(reader):
            require(None not in row and all(value is not None and value != "" for value in row.values()), f"{path.name} row{index}: incomplete CSV")
            parsed = {}
            for key, value in row.items():
                if key in ("kind", "event"):
                    parsed[key] = value
                else:
                    require(value.strip() == value, f"{path.name} row{index}: whitespace around {key}")
                    try:
                        number = int(value, 16 if key in HEX_COLUMNS else 10)
                    except ValueError as error:
                        raise ValueError(f"{path.name} row{index}: invalid numeric {key}={value}") from error
                    require(number >= 0, f"{path.name} row{index}: negative {key}")
                    if key in HEX_COLUMNS:
                        require(number <= (0xffffffffffffffff if key == "seq" else MASK32), f"{path.name} row{index}: oversized {key}")
                    parsed[key] = number
            rows.append(parsed)
    return rows


def control_fields(oracle: dict) -> dict:
    word, pc, name = oracle["instr"], oracle["pc"], oracle["opcode"]
    branch, jal, jalr = name.startswith("B"), name == "JAL", name == "JALR"
    if branch:
        immediate = ((word >> 31) & 1) * 4096 + ((word >> 7) & 1) * 2048 + ((word >> 25) & 63) * 32 + ((word >> 8) & 15) * 2
        if immediate & 4096:
            immediate -= 8192
        target = (pc + immediate) & MASK32
    elif jal or jalr:
        target = oracle["nextpc"]
    else:
        target = (pc + 4) & MASK32
    return dict(pc=pc, nextpc=oracle["nextpc"], target=target, taken=oracle["taken"],
                is_branch=int(branch), is_jal=int(jal), is_jalr=int(jalr))


def audit_case(directory: Path, expected: list[dict]) -> dict:
    descriptor = json.loads((directory / "descriptor.json").read_text(encoding="utf-8"))
    for key in ("case", "id_mode", "predict", "wait", "fixture_name"):
        require(key in descriptor, f"{directory.name}: missing descriptor {key}")
    case = descriptor["case"]
    require(type(case) is int and case >= 0 and directory.name == f"case{case}", f"{directory.name}: incorrect case identity")
    for name in ("id_mode", "predict", "wait"):
        require(type(descriptor[name]) in (int, bool) and descriptor[name] in (0, 1), f"case{case}: invalid {name}")
    predicted = descriptor["predict"]
    accepts = read_csv(directory / "accept.csv", ACCEPT_HEADER)
    rows = read_csv(directory / "trace.csv", TRACE_HEADER)
    events = read_csv(directory / "events.csv", EVENT_HEADER)
    metrics = json.loads((directory / "metrics.json").read_text(encoding="utf-8"))
    accepted_by_seq = {}
    last_seq, last_cycle = -1, 0
    for index, row in enumerate(accepts):
        require(row["cycle"] > last_cycle and row["seq"] > last_seq, f"case{case} accept{index}: non-monotonic cycle/age")
        accepted_by_seq[row["seq"]] = row
        last_seq, last_cycle = row["seq"], row["cycle"]
    retired, back = [], []
    retired_by_seq = {}
    last_cycle, last_retired_seq, kinds_on_cycle = 0, -1, set()
    for ordinal, row in enumerate(rows):
        context = f"case{case} row{ordinal} {row['kind']}"
        require(row["kind"] in ("wb", "retire"), f"{context}: unknown trace event")
        require(row["cycle"] > 0 and row["cycle"] >= last_cycle, f"{context}: unordered cycle")
        if row["cycle"] != last_cycle:
            kinds_on_cycle.clear()
        require(row["kind"] not in kinds_on_cycle, f"{context}: repeated same-edge event")
        kinds_on_cycle.add(row["kind"])
        last_cycle = row["cycle"]
        packet_list = retired if row["kind"] == "retire" else back
        index = len(packet_list)
        require(row["index"] == index and index < len(expected), f"{context}: extra/missing/reordered index")
        oracle = expected[index]
        for field in FIELDS:
            if row["kind"] == "wb" and field == "nextpc":
                continue
            require(row[field] == oracle[field], f"{context}: {field} observed={row[field]:x} expected={oracle[field]:x}")
        require(row["writes"] in (0, 1), f"{context}: non-boolean writes")
        if row["kind"] == "retire":
            require(row["seq"] > last_retired_seq, f"{context}: duplicate/reordered retirement age")
            require(row["seq"] in accepted_by_seq, f"{context}: no accepted IFID owner")
            owner = accepted_by_seq[row["seq"]]
            require(owner["pc"] == row["pc"] and owner["instr"] == row["instr"] and owner["cycle"] < row["cycle"], f"{context}: IFID ownership mismatch")
            require(row["instret"] == len(retired) + 1, f"{context}: post-edge instret mismatch")
            retired.append(row)
            retired_by_seq[row["seq"]] = (index, row)
            last_retired_seq = row["seq"]
        else:
            require(index < len(retired), f"{context}: WB before MEM retirement")
            require(row["seq"] == retired[index]["seq"], f"{context}: WB age differs from retired owner")
            require(row["cycle"] == retired[index]["cycle"] + 1, f"{context}: WB must follow MEM by one edge")
            require(row["instret"] == len(retired), f"{context}: pre-edge instret mismatch")
            require(row["nextpc"] == expected[len(retired) - 1]["nextpc"], f"{context}: pre-edge architectural PC mismatch")
            require("retire" not in kinds_on_cycle, f"{context}: WB row must precede same-edge retirement")
            back.append(row)
    require(len(retired) == len(back) == len(expected), f"case{case}: missing retirement/WB packets")
    bp, redirects = {}, {}
    last_cycle, on_cycle = 0, set()
    for ordinal, event in enumerate(events):
        context = f"case{case} event{ordinal} {event['event']}"
        kind = event["event"]
        require(kind in ("bp", "redirect"), f"{context}: unknown event")
        require(event["cycle"] > 0 and event["cycle"] >= last_cycle, f"{context}: unordered event cycle")
        if event["cycle"] != last_cycle:
            on_cycle.clear()
        require(kind not in on_cycle, f"{context}: repeated event on same edge")
        on_cycle.add(kind)
        last_cycle = event["cycle"]
        require(event["seq"] in retired_by_seq, f"{context}: wrong-path/fault packet had control side effect")
        index, retired_row = retired_by_seq[event["seq"]]
        oracle = expected[index]
        actual = control_fields(oracle)
        for field, value in actual.items():
            require(event[field] == value, f"{context}: {field} observed={event[field]:x} expected={value:x}")
        for name in ("taken", "pred_taken", "is_branch", "is_jal", "is_jalr"):
            require(event[name] in (0, 1), f"{context}: non-boolean {name}")
        ledger = bp if kind == "bp" else redirects
        require(event["seq"] not in ledger, f"{context}: repeated age event")
        if kind == "bp":
            require(event["cycle"] == retired_row["cycle"], f"{context}: BP commit must share current MEM retirement edge")
        else:
            require(event["pred_next"] != event["nextpc"], f"{context}: unnecessary redirect")
            require(accepted_by_seq[event["seq"]]["cycle"] <= event["cycle"] < retired_row["cycle"], f"{context}: redirect outside owner lifetime")
            if not predicted:
                require(event["pred_next"] == ((event["pc"] + 4) & MASK32) and event["pred_taken"] == 0,
                        f"{context}: disabled predictor must supply sequential/not-taken metadata")
        ledger[event["seq"]] = event
    if predicted:
        require(set(bp) == set(retired_by_seq), f"case{case}: enabled BP commit ledger must exactly match MEM retirements")
        expected_redirects = {seq for seq, event in bp.items() if event["pred_next"] != event["nextpc"]}
    else:
        # The pipeline's internal MEM authorization is not a predictor update.
        # The disabled IF adapter emits zero actual BP commits and predicts PC+4.
        require(not bp, f"case{case}: disabled predictor must not receive training")
        expected_redirects = {seq for seq, (index, _) in retired_by_seq.items()
                              if expected[index]["nextpc"] != ((expected[index]["pc"] + 4) & MASK32)}
    require(set(redirects) == expected_redirects, f"case{case}: redirect/mismatch ledger does not close")
    if predicted:
        for seq in redirects:
            for field in EVENT_HEADER:
                if field not in ("cycle", "event"):
                    require(redirects[seq][field] == bp[seq][field], f"case{case}: redirect/BP owner field {field} mismatch")
    counters = dict(resolved=sum(e["is_branch"] or e["is_jal"] for e in bp.values()),
                    mispredict=len(expected_redirects),
                    direction_error=sum((e["is_branch"] or e["is_jal"]) and e["taken"] != e["pred_taken"] for e in bp.values()),
                    target_error=sum((e["is_branch"] or e["is_jal"]) and e["taken"] and e["pred_taken"] and e["nextpc"] != e["pred_next"] for e in bp.values()))
    required_counts = dict(retired=len(retired), wb_packets=len(back), accepted=len(accepts),
                           redirects=len(redirects), bp_commits=len(bp),
                           **{key: value if predicted else 0 for key, value in counters.items()})
    for name, count in required_counts.items():
        require(name in metrics and type(metrics[name]) is int and metrics[name] == count, f"case{case}: metric {name} does not close (wanted {count})")
    for name in ("cycles", "requests", "responses", "raw_wait_cycles"):
        require(name in metrics and type(metrics[name]) is int and metrics[name] >= 0, f"case{case}: missing/invalid {name} metric")
    require(metrics["cycles"] > max([0] + [r["cycle"] for r in rows + accepts + events]), f"case{case}: metric cycle cursor does not cover halt/drain")
    require(metrics["requests"] >= metrics["responses"] >= len(accepts) >= len(retired) + 1, f"case{case}: fetch transaction/accepted/halt ledger does not close")
    require(metrics["raw_wait_cycles"] <= metrics["cycles"], f"case{case}: RAW-wait metric exceeds cycles")
    return dict(case=case, status="PASS", **{name: descriptor[name] for name in ("id_mode", "predict", "wait", "fixture_name")},
                **required_counts, cycles=metrics["cycles"], raw_wait_cycles=metrics["raw_wait_cycles"],
                requests=metrics["requests"], responses=metrics["responses"],
                killed_or_blocked_accepted=len(accepts) - len(retired),
                first_retire_cycle=retired[0]["cycle"] if retired else None,
                last_retire_cycle=retired[-1]["cycle"] if retired else None,
                observed_mismatches=counters["mispredict"],
                opcode_counts=dict(sorted(Counter(e["opcode"] for e in expected).items())))


def audit_ram_case(directory: Path, reference: dict) -> dict:
    result = audit_case(directory, reference["trace"])
    case = result["case"]
    rows = read_csv(directory / "trace.csv", TRACE_HEADER)
    retired = [row for row in rows if row["kind"] == "retire"]
    retired_by_seq = {row["seq"]: row for row in retired}
    accepted = {row["seq"]: row for row in read_csv(directory / "accept.csv", ACCEPT_HEADER)}
    expected_accesses = {row["index"]: row for row in reference["accesses"]}
    accesses = read_csv(directory / "d.csv", D_HEADER)
    requests, responses, pending = {}, {}, {}
    last_cycle, last_index = -1, -1
    for number, row in enumerate(accesses):
        message = f"case{case} D{number} {row['event']}"
        require(row["cycle"] >= last_cycle and row["cycle"] > 0, f"{message}: unordered cycle")
        if row["cycle"] != last_cycle:
            require(len(pending) <= 1, f"{message}: more than one outstanding owner")
        last_cycle = row["cycle"]
        require(row["event"] in ("req", "rsp"), f"{message}: unknown event")
        require(row["is_write"] in (0, 1) and row["error"] == 0, f"{message}: invalid write/error flag")
        require(row["seq"] in retired_by_seq, f"{message}: request/response owner did not retire")
        owner = retired_by_seq[row["seq"]]
        index = owner["index"]
        require(index in expected_accesses, f"{message}: non-memory instruction acquired D ownership")
        gold = expected_accesses[index]
        require(row["pc"] == owner["pc"], f"{message}: owner PC mismatch")
        for field in ("addr", "wstrb", "size", "is_write"):
            require(row[field] == gold[field], f"{message}: {field} observed={row[field]:x} expected={gold[field]:x}")
        mask = sum(255 << (8 * lane) for lane in range(4) if gold["wstrb"] & (1 << lane))
        require((row["wdata"] & mask) == gold["wdata"], f"{message}: enabled store bytes mismatch")
        require(accepted[row["seq"]]["cycle"] < row["cycle"] <= owner["cycle"], f"{message}: D event outside owner lifetime")
        if row["event"] == "req":
            require(row["seq"] not in requests and index > last_index, f"{message}: duplicate/reordered D request")
            require(row["cycle"] < owner["cycle"], f"{message}: memory retired before its request completed")
            requests[row["seq"]] = row
            pending[row["seq"]] = row
            last_index = index
        else:
            require(row["seq"] in pending and row["seq"] not in responses, f"{message}: response has no outstanding request")
            request = pending.pop(row["seq"])
            require(row["cycle"] >= request["cycle"], f"{message}: response precedes request")
            require(all(row[field] == request[field] for field in ("pc", "addr", "wstrb", "size", "is_write")), f"{message}: response descriptor changed owner")
            if not row["is_write"]:
                require(row["rdata"] == gold["rdata"], f"{message}: raw load response word mismatch")
            responses[row["seq"]] = row
    require(not pending, f"case{case}: uncompleted D request at final halt")
    require(set(requests) == set(responses), f"case{case}: D ownership ledger does not close")
    require(len(requests) == len(reference["accesses"]), f"case{case}: missing or extra memory transactions")
    require({retired_by_seq[seq]["index"] for seq in requests} == set(expected_accesses), f"case{case}: memory retirement coverage")
    observed_ram = read_hex(directory / "actual_ram_final.hex")
    require(observed_ram == reference["memory"], f"case{case}: complete final RAM mismatch")
    metrics = json.loads((directory / "metrics.json").read_text(encoding="utf-8"))
    for field, value in (("d_requests", len(requests)), ("d_responses", len(responses))):
        require(metrics.get(field) == value, f"case{case}: metric {field} does not close")
    result.update(d_requests=len(requests), d_responses=len(responses),
                  loads=sum(not row["is_write"] for row in requests.values()),
                  stores=sum(row["is_write"] for row in requests.values()),
                  complete_ram_words=len(observed_ram))
    return result


def analyze(directory: Path, vectors_only: bool = False) -> dict:
    vectors, golden = check_vectors(directory)
    if vectors_only:
        return dict(schema=1, status="PASS", scope="CPU5 real C RAM vectors only", vectors=vectors)
    paths = sorted((directory / "cases").glob("case*"), key=lambda path: int(path.name[4:]))
    require([path.name for path in paths] == [f"case{x}" for x in range(16)], "all sixteen RAM simulation case IDs are required")
    cases = []
    for number, folder in enumerate(paths):
        descriptor = json.loads((folder / "descriptor.json").read_text(encoding="utf-8"))
        wanted = (number % 2, (number // 2) % 2, (number // 4) % 2, f"seed{number // 8}")
        actual = tuple(descriptor.get(key) for key in ("id_mode", "predict", "wait", "fixture_name"))
        require(actual == wanted, f"case{number}: expected seed x ID/EX x prediction x wait matrix")
        cases.append(audit_ram_case(folder, golden[descriptor["fixture_name"]]))
    total = sum(case["retired"] for case in cases)
    mem_total = sum(case["d_requests"] for case in cases)
    require(total == 8 * sum(len(ref["trace"]) for ref in golden.values()), "sixteen-case retirement population closure")
    require(mem_total == 8 * sum(len(ref["accesses"]) for ref in golden.values()), "sixteen-case D access population closure")
    return dict(schema=1, status="PASS", scope="CPU5 integer control flow and ordinary RAM with a compiled C workload",
                limitation="Simulation only; no full CPU5, MMIO, AXI/SoC integration, Trap/IRQ, M, STA, or board-performance claim.",
                vectors=vectors, case_count=len(cases), cases=cases, total_retired=total,
                total_wb_packets=sum(case["wb_packets"] for case in cases),
                total_d_requests=mem_total, total_d_responses=sum(case["d_responses"] for case in cases),
                total_loads=sum(case["loads"] for case in cases), total_stores=sum(case["stores"] for case in cases),
                checks=["two independent machine-word interpreters", "six retirement golden fields", "unique accepted 64-bit IFID age ownership", "physical WB after MEM retirement", "same-edge BP authorization and redirect ledger", "D request/response age and immutable descriptor", "all enabled store bytes and masks", "all raw read response words", "one completed D access per architectural memory instruction", "entire 16KiB final RAM in every case", "two seeds x ID/EX x BP off/on x fast/waited"])


def selftest(directory: Path) -> dict:
    """Reject damaged copies of actual CSV/RAM evidence; never edit good inputs."""
    _, golden = check_vectors(directory)
    scratch = directory.parent / (directory.name + "_analyzer_selftest")
    require(directory.resolve() not in scratch.resolve().parents, "negative fixtures must be outside good evidence")
    scratch.mkdir(parents=True, exist_ok=True)
    good_files = sorted(path for path in (directory / "cases").rglob("*") if path.is_file())
    good_files += sorted(path for path in directory.glob("seed[01]/*") if path.is_file())
    good_files += [directory / "manifest.json", directory / "oracle_summary.json"]

    def hashes() -> dict:
        return {path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in good_files}

    def load(path: Path) -> tuple[list[str], list[dict]]:
        with path.open(newline="", encoding="ascii") as stream:
            reader = csv.DictReader(stream)
            return list(reader.fieldnames or []), list(reader)

    def save(path: Path, fields: list[str], rows: list[dict]) -> None:
        with path.open("w", newline="", encoding="ascii") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)

    mutations = [
        ("load_retire_value_wrong", "trace.csv", "value"),
        ("physical_wb_missing", "trace.csv", "extra/missing/reordered index"),
        ("accepted_owner_wrong", "accept.csv", "IFID ownership mismatch"),
        ("store_mask_wrong", "d.csv", "wstrb"),
        ("store_enabled_byte_wrong", "d.csv", "enabled store bytes"),
        ("duplicate_d_request", "d.csv", "duplicate/reordered D request"),
        ("last_d_response_missing", "d.csv", "uncompleted D request"),
        ("response_owner_pc_wrong", "d.csv", "owner PC mismatch"),
        ("load_raw_word_wrong", "d.csv", "raw load response word"),
        ("final_ram_wrong", "actual_ram_final.hex", "complete final RAM"),
    ]
    before, rejected = hashes(), []
    source = directory / "cases/case0"
    audit_ram_case(source, golden["seed0"])
    for name, filename, wanted_error in mutations:
        target = scratch / name / "case0"
        shutil.copytree(source, target, dirs_exist_ok=True)
        path = target / filename
        if filename.endswith(".csv"):
            fields, rows = load(path)
            if name == "load_retire_value_wrong":
                row = next(row for row in rows if row["kind"] == "retire" and (int(row["instr"], 16) & 127) == 3 and row["writes"] == "1")
                row["value"] = f'{int(row["value"], 16) ^ 1:08x}'
            elif name == "physical_wb_missing":
                rows.pop(next(i for i, row in enumerate(rows) if row["kind"] == "wb"))
            elif name == "accepted_owner_wrong":
                rows[0]["pc"] = f'{int(rows[0]["pc"], 16) ^ 4:08x}'
            elif name == "store_mask_wrong":
                row = next(row for row in rows if row["event"] == "req" and row["is_write"] == "1")
                row["wstrb"] = f'{int(row["wstrb"], 16) ^ 1:x}'
            elif name == "store_enabled_byte_wrong":
                row = next(row for row in rows if row["event"] == "req" and row["is_write"] == "1")
                strobe = int(row["wstrb"], 16)
                lane = next(lane for lane in range(4) if strobe & (1 << lane))
                row["wdata"] = f'{int(row["wdata"], 16) ^ (1 << (lane * 8)):08x}'
            elif name == "duplicate_d_request":
                position = next(i for i, row in enumerate(rows) if row["event"] == "req")
                rows.insert(position + 1, dict(rows[position]))
            elif name == "last_d_response_missing":
                rows.pop(max(i for i, row in enumerate(rows) if row["event"] == "rsp"))
            elif name == "response_owner_pc_wrong":
                row = next(row for row in rows if row["event"] == "rsp")
                row["pc"] = f'{int(row["pc"], 16) ^ 4:08x}'
            elif name == "load_raw_word_wrong":
                row = next(row for row in rows if row["event"] == "rsp" and row["is_write"] == "0")
                row["rdata"] = f'{int(row["rdata"], 16) ^ 1:08x}'
            save(path, fields, rows)
        else:
            contents = read_hex(path)
            contents[2] ^= 1
            path.write_text("".join(f"{value:08x}\n" for value in contents), encoding="ascii")
        try:
            audit_ram_case(target, golden["seed0"])
        except ValueError as error:
            message = str(error)
            require(wanted_error in message, f"negative fixture {name} failed for the wrong reason: {message}")
        else:
            raise ValueError(f"negative fixture {name} was falsely accepted")
        require(path.read_bytes() != (source / filename).read_bytes(), f"negative fixture {name} did not mutate its intended evidence")
        (target.parent / "rejection.txt").write_text(message + "\n", encoding="utf-8")
        rejected.append(dict(name=name, case=0, status="REJECTED", error=message,
                             changed_file=filename, good_sha256=hashlib.sha256((source / filename).read_bytes()).hexdigest(),
                             bad_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    after = hashes()
    require(before == after, "negative copies changed original good evidence")
    for name, values in (("before", before), ("after", after)):
        (scratch / f"good_{name}_sha256.json").write_text(json.dumps(values, indent=2) + "\n", encoding="utf-8")
    result = dict(schema=1, status="PASS", rejected_count=len(rejected), rejected=rejected,
                  good_inputs_unchanged=True, good_input_files=len(before),
                  good_manifest_sha256=hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest())
    (scratch / "summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "build/cpu5_s5_ram")
    parser.add_argument("--vectors-only", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    result = analyze(args.directory, args.vectors_only)
    if args.selftest:
        require(not args.vectors_only, "--selftest requires real simulation evidence")
        result["negative_evidence_tests"] = selftest(args.directory)
    destination = "independent_vectors.json" if args.vectors_only else "analysis.json"
    (args.directory / destination).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(status="PASS", scope=result["scope"], cases=result.get("case_count", 0),
                          total_retired=result.get("total_retired", 0), total_d_requests=result.get("total_d_requests", 0),
                          rejected=result.get("negative_evidence_tests", {}).get("rejected_count", 0))))


if __name__ == "__main__":
    main()
