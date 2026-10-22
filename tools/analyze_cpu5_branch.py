"""Recheck CPU5 control-flow evidence with a second machine-word interpreter.

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
HEX_COLUMNS = {"seq", "pc", "instr", "value", "nextpc", "target", "pred_next"}


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def read_hex(path: Path) -> list[int]:
    lines = path.read_text(encoding="ascii").splitlines()
    require(bool(lines) and all(len(line) == 8 and all(c in "0123456789abcdefABCDEF" for c in line) for line in lines), f"{path.name}: exact 32-bit hex required")
    return [int(line, 16) for line in lines]


def signed32(number: int) -> int:
    return number if number < 0x80000000 else number - 0x100000000


def simulate(words: list[int], fault_pc: int | None = None) -> tuple[list[dict], list[int], dict]:
    registers, cursor, events = [0] * 32, 0, []
    for index in range(20000):
        require(cursor & 3 == 0 and cursor < len(words) * 4, f"reference cursor outside ROM: {cursor:x}")
        instruction = words[cursor // 4]
        if fault_pc == cursor:
            return events, registers, dict(kind="fetch_error", pc=cursor, instr=instruction, target=cursor)
        if instruction == 0x00002023:
            return events, registers, dict(kind="unsupported", pc=cursor, instr=instruction, target=cursor)
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
            return events, registers, dict(kind="misaligned", pc=cursor, instr=instruction, target=following)
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
    summary = json.loads((directory / "summary.json").read_text(encoding="utf-8"))
    fixture_info = json.loads((directory / "fixtures.json").read_text(encoding="utf-8"))
    require(fixture_info == summary["fixtures"], "fixture descriptors disagree")
    golden: dict[str, list[dict]] = {}
    results = []
    descriptors = [dict(name="", program_words=summary["program_words"], retire_count=summary["retire_count"], stop=summary["stop"], injected_fault_pc=None)] + fixture_info
    for descriptor in descriptors:
        name = descriptor["name"]
        prefix = name + "_" if name else ""
        program = read_hex(directory / f"{prefix}program.hex")
        require(len(program) == descriptor["program_words"], f"{name}: ROM length mismatch")
        expected, final_registers, stopped = simulate(program, descriptor["injected_fault_pc"])
        require(len(expected) == descriptor["retire_count"], f"{name}: retirement length mismatch")
        require(stopped == descriptor["stop"], f"{name}: stop descriptor mismatch")
        for field in FIELDS:
            require(read_hex(directory / f"{prefix}expected_{field}.hex") == [event[field] for event in expected], f"{name}: golden field {field} differs from second interpreter")
        require(read_hex(directory / f"{prefix}final_gpr.hex") == final_registers, f"{name}: final GPR mismatch")
        golden[name] = expected
        results.append(dict(name=name or "main", status="PASS", retire_count=len(expected), program_words=len(program), stop=stopped))
    primary = golden[""]
    require(len(primary) == 367 and summary["selftest_checks"] >= 59 and summary["known_fixed_encodings"] >= 30, "unexpected main test population/selftest count")
    counts = Counter(event["opcode"] for event in primary)
    require(dict(sorted(counts.items())) == summary["opcode_counts"], "opcode population mismatch")
    branch_outcomes = Counter(f'{event["opcode"]}_{"taken" if event["taken"] else "not_taken"}' for event in primary if event["opcode"].startswith("B"))
    require(dict(sorted(branch_outcomes.items())) == summary["branch_outcomes"], "branch outcome population mismatch")
    for name in ("BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"):
        require(branch_outcomes[f"{name}_taken"] > 0 and branch_outcomes[f"{name}_not_taken"] > 0, f"{name}: missing outcome coverage")
    require(len(fixture_info) == 10 and sum(x["stop"]["kind"] == "misaligned" for x in fixture_info) == 8, "fixture coverage mismatch")
    require(read_hex(directory / "final_gpr.hex")[31] == 0, "wrong-path x31 sentinel was modified")
    manifest = json.loads((directory / "sha256.json").read_text(encoding="utf-8"))
    for name, digest in manifest.items():
        require(hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest, f"{name}: vector hash mismatch")
    return dict(status="PASS", vector_cases=len(results), total_reference_retired=sum(case["retire_count"] for case in results), cases=results,
                opcode_counts=dict(sorted(counts.items())), branch_outcomes=dict(sorted(branch_outcomes.items())),
                checks=["second independent machine-word interpreter", "all six golden fields", "complete final GPR arrays", "misaligned target before link write", "not-taken misalignment ignored", "IF-fault retirement prefix", "unreachable x31 sentinels", "generated vector SHA256 manifest"]), golden


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


def analyze(directory: Path, vectors_only: bool = False) -> dict:
    vectors, golden = check_vectors(directory)
    if vectors_only:
        return dict(schema=1, status="PASS", scope="CPU5 branch vector audit only", vectors=vectors)
    cases_directory = directory / "cases"
    require(cases_directory.is_dir(), "missing real simulation cases; use --vectors-only for vector-only audit")
    case_paths = sorted(cases_directory.glob("case*"), key=lambda path: int(path.name[4:]))
    require(bool(case_paths), "no real simulation cases")
    cases = []
    for path in case_paths:
        descriptor = json.loads((path / "descriptor.json").read_text(encoding="utf-8"))
        fixture_name = descriptor.get("fixture_name")
        require(fixture_name in golden, f"{path.name}: unknown oracle fixture {fixture_name!r}")
        cases.append(audit_case(path, golden[fixture_name]))
    identities = [case["case"] for case in cases]
    require(identities == list(range(48)), "all 48 real simulation case IDs are required")
    fixture_order = [entry["name"] for entry in json.loads((directory / "fixtures.json").read_text(encoding="utf-8"))]
    for case in cases:
        index = case["case"]
        wanted = (index % 2, (index // 2) % 2, index // 4, "") if index < 8 else (index % 2, ((index - 8) // 2) % 2, 1, fixture_order[(index - 8) // 4])
        actual = tuple(case[name] for name in ("id_mode", "predict", "wait", "fixture_name"))
        require(actual == wanted, f"case{index}: simulation configuration differs from frozen matrix")
    wide_accepts = read_csv(cases_directory / "case7" / "accept.csv", ACCEPT_HEADER)
    require(wide_accepts[0]["seq"] == 0xfffffffc and wide_accepts[-1]["seq"] > MASK32, "case7: 64-bit ages must cross bit32 from fffffffc")
    main_configurations = [(case["id_mode"], case["predict"], case["wait"]) for case in cases if case["fixture_name"] == ""]
    require(len(main_configurations) == len(set(main_configurations)) == 8, "main program must cover exactly ID/EX x prediction on/off x fast/waited")
    tested_fixtures = {case["fixture_name"] for case in cases if case["fixture_name"]}
    require(tested_fixtures == set(golden) - {""}, "not all ten fault fixtures were simulated")
    for fixture in tested_fixtures:
        modes = {case["id_mode"] for case in cases if case["fixture_name"] == fixture}
        require(modes == {0, 1}, f"{fixture}: both ID and EX resolution must be tested")
    aggregate = Counter()
    for case in cases:
        aggregate.update(case["opcode_counts"])
    require(sum(case["retired"] for case in cases) == 3064, "48-case retirement population must close at 3064")
    return dict(schema=1, status="PASS", scope="CPU5 integer control-flow subset",
                limitation="Directed simulation only; no complete CPU5, RAM transactions, traps, IRQ, M, STA, or board-performance claim.",
                vectors=vectors, case_count=len(cases), cases=cases,
                total_retired=sum(case["retired"] for case in cases),
                total_wb_packets=sum(case["wb_packets"] for case in cases),
                total_redirects=sum(case["redirects"] for case in cases),
                total_bp_commits=sum(case["bp_commits"] for case in cases),
                opcode_counts=dict(sorted(aggregate.items())),
                checks=["second independent byte interpreter", "all six retirement golden fields", "unique accepted IFID age ownership", "strictly increasing 64-bit retirement ages with legal holes", "one subsequent physical WB per MEM retirement", "same-edge BP commit ownership", "redirect/mispredict ledger", "all control targets and direction outcomes", "prediction counters from actual retirement events", "fault and wrong-path zero retirement/control side effects", "per-case actual metric closure"])


def selftest(directory: Path) -> dict:
    """Reject six damaged real-CSV copies while proving good inputs unchanged."""
    _, golden = check_vectors(directory)
    scratch = directory.parent / (directory.name + "_analyzer_selftest")
    require(directory.resolve() not in scratch.resolve().parents,
            "negative CSV fixtures must live outside the good evidence directory")
    scratch.mkdir(parents=True, exist_ok=True)
    vector_names = list(json.loads((directory / "sha256.json").read_text(encoding="utf-8"))) + ["sha256.json"]
    inputs = sorted([path for path in (directory / "cases").rglob("*") if path.is_file()] +
                    [directory / name for name in vector_names])

    def hashes() -> dict:
        return {path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in inputs}

    def csv_rows(path: Path) -> tuple[list[str], list[dict]]:
        with path.open(newline="", encoding="ascii") as source:
            reader = csv.DictReader(source)
            return list(reader.fieldnames or []), list(reader)

    def save_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
        with path.open("w", newline="", encoding="ascii") as target:
            writer = csv.DictWriter(target, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)

    before = hashes()
    good_cases = []
    for case in (0, 2):
        source = directory / "cases" / f"case{case}"
        descriptor = json.loads((source / "descriptor.json").read_text(encoding="utf-8"))
        good_cases.append(audit_case(source, golden[descriptor["fixture_name"]]))
    mutations = [
        ("retire_nextpc_wrong", 0, "nextpc"),
        ("physical_wb_missing", 0, "extra/missing/reordered index"),
        ("accepted_seq_has_wrong_owner", 0, "IFID ownership mismatch"),
        ("redirect_target_wrong", 0, "target"),
        ("predictor_off_fake_training", 0, "disabled predictor must not receive training"),
        ("predictor_on_missing_training", 2, "enabled BP commit ledger"),
    ]
    rejected = []
    for name, case, expected_error in mutations:
        source = directory / "cases" / f"case{case}"
        broken = scratch / name / f"case{case}"
        shutil.copytree(source, broken, dirs_exist_ok=True)
        changed_file = ""
        if name in ("retire_nextpc_wrong", "physical_wb_missing"):
            changed_file = "trace.csv"
            fields, rows = csv_rows(broken / changed_file)
            if name == "retire_nextpc_wrong":
                row = next(row for row in rows if row["kind"] == "retire")
                row["nextpc"] = f'{int(row["nextpc"], 16) ^ 4:08x}'
            else:
                rows.pop(next(index for index, row in enumerate(rows) if row["kind"] == "wb"))
            save_csv(broken / changed_file, fields, rows)
        elif name == "accepted_seq_has_wrong_owner":
            changed_file = "accept.csv"
            fields, rows = csv_rows(broken / changed_file)
            # Keep valid, increasing ages but assign the first age another PC.
            # This specifically tests source ownership rather than CSV syntax.
            rows[0]["pc"] = f'{int(rows[0]["pc"], 16) ^ 4:08x}'
            save_csv(broken / changed_file, fields, rows)
        else:
            changed_file = "events.csv"
            fields, rows = csv_rows(broken / changed_file)
            if name == "redirect_target_wrong":
                row = next(row for row in rows if row["event"] == "redirect")
                row["target"] = f'{int(row["target"], 16) ^ 4:08x}'
            elif name == "predictor_on_missing_training":
                rows.pop(next(index for index, row in enumerate(rows) if row["event"] == "bp"))
            else:
                fake = dict(next(row for row in rows if row["event"] == "redirect"))
                _, traces = csv_rows(broken / "trace.csv")
                owner = next(row for row in traces if row["kind"] == "retire" and int(row["seq"], 16) == int(fake["seq"], 16))
                fake["event"], fake["cycle"] = "bp", owner["cycle"]
                rows.append(fake)
                rows.sort(key=lambda row: int(row["cycle"]))
            save_csv(broken / changed_file, fields, rows)
        descriptor = json.loads((broken / "descriptor.json").read_text(encoding="utf-8"))
        try:
            audit_case(broken, golden[descriptor["fixture_name"]])
        except ValueError as error:
            message = str(error)
            require(expected_error in message,
                    f"negative fixture {name} failed for unintended reason: {message}")
        else:
            raise ValueError(f"negative fixture {name} was falsely accepted")
        require((source / changed_file).read_bytes() != (broken / changed_file).read_bytes(),
                f"negative fixture {name} did not change its intended CSV")
        (broken.parent / "rejection.txt").write_text(message + "\n", encoding="utf-8")
        rejected.append(dict(name=name, case=case, status="REJECTED", error=message,
                             changed_file=changed_file,
                             good_sha256=hashlib.sha256((source / changed_file).read_bytes()).hexdigest(),
                             broken_sha256=hashlib.sha256((broken / changed_file).read_bytes()).hexdigest(),
                             bad_copy=broken.as_posix()))
    after = hashes()
    require(before == after, "negative tests altered the good simulation/vector evidence")
    for label, values in (("before", before), ("after", after)):
        (scratch / f"good_{label}_sha256.json").write_text(json.dumps(values, indent=2) + "\n", encoding="utf-8")
    digest = hashlib.sha256(json.dumps(before, sort_keys=True).encode("utf-8")).hexdigest()
    result = dict(schema=1, status="PASS", rejected_count=len(rejected),
                  scope="Six corrupted copies of real simulation CSVs; original good evidence remains byte-identical",
                  good_cases_audited=[case["case"] for case in good_cases],
                  good_input_files=len(before), good_manifest_before_sha256=digest,
                  good_manifest_after_sha256=digest, good_inputs_unchanged=True,
                  rejected=rejected, evidence_directory=scratch.as_posix())
    (scratch / "selftest.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, default=ROOT / "build" / "cpu5_s4_branch")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--vectors-only", action="store_true")
    parser.add_argument("--selftest", action="store_true", help="reject six corrupted real-CSV copies without altering good inputs")
    args = parser.parse_args()
    require(not (args.selftest and args.vectors_only), "--selftest and --vectors-only are mutually exclusive")
    report = selftest(args.dir) if args.selftest else analyze(args.dir, args.vectors_only)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
