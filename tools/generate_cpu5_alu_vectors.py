"""Deterministic CPU5 3A-1 integer vectors and an encoding-decoding oracle.

The encoder and reference interpreter share no decode/operation tables.  The
interpreter consumes actual machine words, rather than producer-side metadata.
No compiler, RTL hierarchy, simulator, or third-party package is used.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random

ROOT = Path(__file__).resolve().parents[1]
MASK = (1 << 32) - 1
HALT = 0x00002023  # SW x0,0(x0): deliberately unsupported in CPU5 3A-1.
SEED = 0x5A103A1
TRACE_FIELDS = ("pc", "instr", "rd", "value", "writes", "seq", "nextpc")
GENERATED_FILENAMES = (
    "program.hex", "final_gpr.hex", "unsupported.hex", "unsupported_cases.json",
    "if_fault_program.hex", "meta.vh", "oracle_trace.json", "summary.json",
) + tuple(f"{prefix}expected_{field}.hex" for prefix in ("", "if_fault_") for field in TRACE_FIELDS)


def signed(value: int, bits: int = 32) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def r(name: str, rd: int, rs1: int, rs2: int) -> int:
    funct3, funct7 = {
        "ADD": (0, 0), "SUB": (0, 32), "SLL": (1, 0),
        "SLT": (2, 0), "SLTU": (3, 0), "XOR": (4, 0),
        "SRL": (5, 0), "SRA": (5, 32), "OR": (6, 0), "AND": (7, 0),
    }[name]
    assert all(0 <= reg < 32 for reg in (rd, rs1, rs2))
    return funct7 << 25 | rs2 << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | 0x33


def i(name: str, rd: int, rs1: int, imm: int) -> int:
    funct3 = {"ADDI": 0, "SLTI": 2, "SLTIU": 3, "XORI": 4,
              "ORI": 6, "ANDI": 7, "SLLI": 1, "SRLI": 5, "SRAI": 5}[name]
    if name in {"SLLI", "SRLI", "SRAI"}:
        assert 0 <= imm < 32
        imm |= 0x400 if name == "SRAI" else 0
    else:
        assert -2048 <= imm <= 2047
    assert all(0 <= reg < 32 for reg in (rd, rs1))
    return (imm & 4095) << 20 | rs1 << 15 | funct3 << 12 | rd << 7 | 0x13


def u(name: str, rd: int, upper20: int) -> int:
    assert 0 <= rd < 32 and 0 <= upper20 < 1 << 20
    return upper20 << 12 | rd << 7 | {"LUI": 0x37, "AUIPC": 0x17}[name]


def reference_step(word: int, pc: int, regs: list[int]) -> dict:
    """Decode only the 21 authorized instructions; reject every other encoding."""
    opcode = word & 0x7f
    dest = (word >> 7) & 31
    minor = (word >> 12) & 7
    source1 = (word >> 15) & 31
    source2 = (word >> 20) & 31
    high = (word >> 25) & 0x7f
    a, b = regs[source1], regs[source2]
    sources: list[int] = []
    if opcode == 0x37:
        name, value = "LUI", word & 0xfffff000
    elif opcode == 0x17:
        name, value = "AUIPC", pc + (word & 0xfffff000)
    elif opcode == 0x13:
        sources = [source1]
        immediate = signed(word >> 20, 12)
        if minor == 0:
            name, value = "ADDI", a + immediate
        elif minor == 2:
            name, value = "SLTI", int(signed(a) < immediate)
        elif minor == 3:
            name, value = "SLTIU", int(a < (immediate & MASK))
        elif minor == 4:
            name, value = "XORI", a ^ immediate
        elif minor == 6:
            name, value = "ORI", a | immediate
        elif minor == 7:
            name, value = "ANDI", a & immediate
        elif minor == 1 and high == 0:
            name, value = "SLLI", a << source2
        elif minor == 5 and high == 0:
            name, value = "SRLI", a >> source2
        elif minor == 5 and high == 32:
            name, value = "SRAI", signed(a) >> source2
        else:
            raise ValueError(f"unsupported OP-IMM: {word:08x}")
    elif opcode == 0x33:
        sources = [source1, source2]
        shift = b % 32
        if minor == 0 and high == 0:
            name, value = "ADD", a + b
        elif minor == 0 and high == 32:
            name, value = "SUB", a - b
        elif minor == 1 and high == 0:
            name, value = "SLL", a << shift
        elif minor == 2 and high == 0:
            name, value = "SLT", int(signed(a) < signed(b))
        elif minor == 3 and high == 0:
            name, value = "SLTU", int(a < b)
        elif minor == 4 and high == 0:
            name, value = "XOR", a ^ b
        elif minor == 5 and high == 0:
            name, value = "SRL", a >> shift
        elif minor == 5 and high == 32:
            name, value = "SRA", signed(a) >> shift
        elif minor == 6 and high == 0:
            name, value = "OR", a | b
        elif minor == 7 and high == 0:
            name, value = "AND", a & b
        else:
            raise ValueError(f"unsupported OP: {word:08x}")
    else:
        raise ValueError(f"unsupported opcode: {word:08x}")
    value &= MASK
    write = int(dest != 0)
    if write:
        regs[dest] = value
    regs[0] = 0
    # ALU value remains visible for rd=x0; architectural write-enable is false.
    return dict(pc=pc, instr=word, rd=dest, value=value, writes=write,
                nextpc=(pc + 4) & MASK, opcode=name, sources=sources)


def execute(words: list[int]) -> tuple[list[dict], list[int]]:
    regs = [0] * 32
    trace = []
    for index, word in enumerate(words):
        event = reference_step(word, 4 * index, regs)
        event["seq"] = index
        trace.append(event)
    return trace, regs


class Program:
    def __init__(self) -> None:
        self.words: list[int] = []
        self.sections: list[dict] = []

    def emit(self, word: int) -> None:
        assert 0 <= word <= MASK
        self.words.append(word)

    def section(self, name: str) -> None:
        self.sections.append(dict(name=name, first_seq=len(self.words)))

    def constant(self, rd: int, value: int) -> None:
        # Always two instructions, exercising signed lower12 carry into LUI.
        lower = signed(value, 12)
        upper = ((value & MASK) - lower) >> 12 & 0xfffff
        self.emit(u("LUI", rd, upper))
        self.emit(i("ADDI", rd, rd, lower))


def main_program() -> Program:
    p = Program()
    p.section("explicit_register_initialization")
    for reg in range(1, 32):
        p.emit(i("ADDI", reg, 0, 0))

    p.section("boundary_alu_and_signedness")
    for reg, value in enumerate((0x80000000, 0xffffffff, 0x7fffffff,
                                 0x12345678, 0, 1, 31, 32, 63), start=1):
        p.constant(reg, value)
    for name in ("ADD", "SUB", "SLT", "SLTU", "XOR", "OR", "AND"):
        for left, right in ((1, 2), (3, 6), (2, 1), (4, 4), (0, 2)):
            p.emit(r(name, 10, left, right))
    for name in ("SLL", "SRL", "SRA"):
        for left in (1, 2):
            for shiftreg in (5, 6, 7, 8, 9):
                p.emit(r(name, 11, left, shiftreg))
    for name in ("ADDI", "SLTI", "SLTIU", "XORI", "ORI", "ANDI"):
        for immediate in (-2048, -1, 0, 1, 2047):
            p.emit(i(name, 12, 1, immediate))
    for name in ("SLLI", "SRLI", "SRAI"):
        for source in (1, 2):
            for shift in (0, 1, 31):
                p.emit(i(name, 13, source, shift))
    for name in ("LUI", "AUIPC"):
        for value in (0, 1, 0x7ffff, 0x80000, 0xfffff):
            p.emit(u(name, 14, value))

    p.section("latest_writer_raw_and_x0")
    for _ in range(3):
        p.emit(i("ADDI", 15, 0, 17))
        p.emit(i("ADDI", 15, 15, -21))  # same rd, latest writer must win
        p.emit(r("ADD", 16, 15, 15))   # both sources same, D1 RAW
        p.emit(i("ADDI", 17, 16, 5))
        p.emit(i("XORI", 18, 17, -1))
        p.emit(r("SUB", 19, 18, 16))   # sources at differing distances
        p.emit(i("ADDI", 20, 0, 31))
        p.emit(r("ADD", 21, 15, 19))   # old source plus recent source
        p.emit(i("ADDI", 0, 21, 99))  # legal x0 retirement, no GPR write
        p.emit(r("ADD", 22, 0, 21))    # x0 must not depend on prior rd=x0
        p.emit(r("SUB", 23, 0, 0))
        p.emit(u("LUI", 0, 0xfffff))
        p.emit(u("AUIPC", 0, 0x80000))

    p.section("deterministic_mixed_dependencies")
    randomizer = random.Random(SEED)
    names = ["ADD", "SUB", "SLL", "SLT", "SLTU", "XOR", "SRL", "SRA", "OR", "AND",
             "ADDI", "SLTI", "SLTIU", "XORI", "ORI", "ANDI", "SLLI", "SRLI", "SRAI",
             "LUI", "AUIPC"]
    # Fixed seed and operation rotation guarantee every opcode is exercised.
    last_rd = 22
    while len(p.words) < 550:
        count = len(p.words)
        name = names[count % len(names)]
        dest = 0 if count % 13 == 0 else randomizer.randint(1, 31)
        left = last_rd if count % 3 else randomizer.randrange(32)
        right = left if count % 7 == 0 else randomizer.randrange(32)
        if name in names[:10]:
            p.emit(r(name, dest, left, right))
        elif name in {"LUI", "AUIPC"}:
            p.emit(u(name, dest, randomizer.randrange(1 << 20)))
        elif name in {"SLLI", "SRLI", "SRAI"}:
            p.emit(i(name, dest, left, (0, 1, 31)[count % 3]))
        else:
            immediate = randomizer.choice((-2048, -1, 0, 1, 2047,
                                           randomizer.randint(-2048, 2047)))
            p.emit(i(name, dest, left, immediate))
        if dest:
            last_rd = dest
    return p


def unsupported_cases() -> list[dict]:
    cases: list[tuple[str, int]] = []
    for funct3, name in enumerate(("MUL", "MULH", "MULHSU", "MULHU", "DIV", "DIVU", "REM", "REMU")):
        cases.append((name, 1 << 25 | 2 << 20 | 1 << 15 | funct3 << 12 | 3 << 7 | 0x33))
    for funct3, name in ((0, "LB"), (1, "LH"), (2, "LW"), (4, "LBU"), (5, "LHU")):
        cases.append((name, 1 << 15 | funct3 << 12 | 3 << 7 | 3))
    for funct3, name in enumerate(("SB", "SH", "SW")):
        cases.append((name, 2 << 20 | 1 << 15 | funct3 << 12 | 0x23))
    for funct3, name in ((0, "BEQ"), (1, "BNE"), (4, "BLT"), (5, "BGE"), (6, "BLTU"), (7, "BGEU")):
        cases.append((name, 2 << 20 | 1 << 15 | funct3 << 12 | 0x63))
    cases += [("JAL", 0x000001ef), ("JALR", 0x000081e7),
              ("FENCE", 0x0ff0000f), ("FENCE_I", 0x0000100f),
              ("ECALL", 0x00000073), ("EBREAK", 0x00100073),
              ("MRET", 0x30200073), ("WFI", 0x10500073)]
    for funct3, name in ((1, "CSRRW"), (2, "CSRRS"), (3, "CSRRC"),
                         (5, "CSRRWI"), (6, "CSRRSI"), (7, "CSRRCI")):
        cases.append((name, 0x300 << 20 | 1 << 15 | funct3 << 12 | 3 << 7 | 0x73))
    cases += [("illegal_OP_funct7", r("ADD", 3, 1, 2) | 2 << 25),
              ("illegal_SUB_funct3", r("SUB", 3, 1, 2) | 1 << 12),
              ("illegal_SLLI_high", i("SLLI", 3, 1, 1) | 1 << 25),
              ("illegal_SLLI_funct7_32", i("SLLI", 3, 1, 1) | 32 << 25),
              ("illegal_SRLI_high", i("SRLI", 3, 1, 1) | 1 << 25),
              ("illegal_SRAI_high", i("SRAI", 3, 1, 1) | 1 << 25),
              ("zero", 0), ("all_ones", MASK), ("compressed_halfword", 1)]
    return [dict(index=index, name=name, instr=word, instr_hex=f"{word:08x}")
            for index, (name, word) in enumerate(cases)]


def selftest() -> int:
    checks = 0
    # Fixed machine words catch an encoder/decoder that accidentally agrees on
    # the same wrong field layout; these constants are not encoder-generated.
    fixed_encodings = [
        (r("ADD", 3, 1, 2), 0x002081b3), (r("SUB", 3, 1, 2), 0x402081b3),
        (r("SLL", 3, 1, 2), 0x002091b3), (r("SLT", 3, 1, 2), 0x0020a1b3),
        (r("SLTU", 3, 1, 2), 0x0020b1b3), (r("XOR", 3, 1, 2), 0x0020c1b3),
        (r("SRL", 3, 1, 2), 0x0020d1b3), (r("SRA", 3, 1, 2), 0x4020d1b3),
        (r("OR", 3, 1, 2), 0x0020e1b3), (r("AND", 3, 1, 2), 0x0020f1b3),
        (i("ADDI", 3, 1, -1), 0xfff08193), (i("SLTI", 3, 1, -1), 0xfff0a193),
        (i("SLTIU", 3, 1, -1), 0xfff0b193), (i("XORI", 3, 1, -1), 0xfff0c193),
        (i("ORI", 3, 1, -1), 0xfff0e193), (i("ANDI", 3, 1, -1), 0xfff0f193),
        (i("SLLI", 3, 1, 31), 0x01f09193), (i("SRLI", 3, 1, 31), 0x01f0d193),
        (i("SRAI", 3, 1, 31), 0x41f0d193),
        (u("LUI", 3, 0x80000), 0x800001b7), (u("AUIPC", 3, 0x80000), 0x80000197),
    ]
    for actual, wanted in fixed_encodings:
        assert actual == wanted, (f"{actual:08x}", f"{wanted:08x}")
        checks += 1
    # Hand-calculated results, independent from reference-step implementation.
    values = {1: 0x80000000, 2: 0xffffffff, 3: 0x7fffffff,
              4: 32, 5: 63, 6: 1, 7: 0x12345678}
    examples = [
        (r("ADD", 10, 3, 6), 0x80000000),
        (r("ADD", 10, 2, 6), 0), (r("SUB", 10, 1, 6), 0x7fffffff),
        (r("SLT", 10, 1, 3), 1), (r("SLTU", 10, 1, 3), 0),
        (r("XOR", 10, 7, 2), 0xedcba987),
        (r("OR", 10, 7, 1), 0x92345678),
        (r("AND", 10, 7, 2), 0x12345678),
        (r("SLL", 10, 6, 4), 1), (r("SLL", 10, 6, 5), 0x80000000),
        (r("SRL", 10, 1, 5), 1), (r("SRA", 10, 1, 5), MASK),
        (i("ADDI", 10, 1, -1), 0x7fffffff),
        (i("SLTI", 10, 1, -2048), 1), (i("SLTIU", 10, 1, -1), 1),
        (i("SLTIU", 10, 2, -1), 0),
        (i("XORI", 10, 7, -1), 0xedcba987),
        (i("ORI", 10, 7, -2048), 0xfffffe78),
        (i("ANDI", 10, 7, -2048), 0x12345000),
        (i("SLLI", 10, 6, 31), 0x80000000),
        (i("SRLI", 10, 1, 31), 1), (i("SRAI", 10, 1, 31), MASK),
        (u("LUI", 10, 0x80000), 0x80000000),
        (u("AUIPC", 10, 0xfffff), 0xfffff124),
    ]
    for word, wanted in examples:
        regs = [0] * 32
        for register, value in values.items():
            regs[register] = value
        event = reference_step(word, 0x124, regs)
        assert event["value"] == wanted, (f"{word:08x}", event, wanted)
        assert regs[10] == wanted and event["writes"] == 1
        checks += 1
    # Decoder must reject all unsupported encodings, independently of RTL.
    for case in unsupported_cases():
        try:
            reference_step(case["instr"], 0, [0] * 32)
        except ValueError:
            checks += 1
        else:
            raise AssertionError(f"unsupported accepted: {case}")
    regs = [0] * 32
    event = reference_step(i("ADDI", 0, 0, -1), 0, regs)
    assert event["writes"] == 0 and event["value"] == MASK and regs[0] == 0
    return checks + 1


def write_hex(path: Path, values: list[int]) -> None:
    path.write_text("".join(f"{value & MASK:08x}\n" for value in values), encoding="ascii")


def write_trace(out: Path, prefix: str, trace: list[dict]) -> None:
    for field in TRACE_FIELDS:
        write_hex(out / f"{prefix}expected_{field}.hex", [event[field] for event in trace])


def generate(out: Path) -> dict:
    checks = selftest()
    out.mkdir(parents=True, exist_ok=True)
    program = main_program()
    trace, regs = execute(program.words)
    counts = Counter(event["opcode"] for event in trace)
    assert len(counts) == 21 and min(counts.values()) > 0
    write_hex(out / "program.hex", program.words + [HALT])
    write_trace(out, "", trace)
    write_hex(out / "final_gpr.hex", regs)
    cases = unsupported_cases()
    write_hex(out / "unsupported.hex", [case["instr"] for case in cases])
    (out / "unsupported_cases.json").write_text(json.dumps(cases, indent=2) + "\n", encoding="utf-8")

    fault_words = [i("ADDI", 1, 0, 17), i("ADDI", 2, 0, -1),
                   r("ADD", 3, 1, 2), u("AUIPC", 4, 0xfffff),
                   r("XOR", 5, 3, 2), i("SRAI", 6, 5, 31),
                   i("ADDI", 0, 0, 1), r("ADD", 7, 0, 6)]
    fault_trace, _ = execute(fault_words)
    write_hex(out / "if_fault_program.hex", fault_words + [HALT])
    write_trace(out, "if_fault_", fault_trace)
    meta = [
        "// Generated by tools/generate_cpu5_alu_vectors.py; each hex line is 32 bits.",
        f"`define CPU5_ALU_RETIRE_COUNT {len(trace)}",
        f"`define CPU5_ALU_PROGRAM_WORDS {len(trace) + 1}",
        f"`define CPU5_ALU_HALT_PC 32'h{len(trace) * 4:08x}",
        f"`define CPU5_ALU_HALT_INSTR 32'h{HALT:08x}",
        f"`define CPU5_ALU_UNSUPPORTED_COUNT {len(cases)}",
        "`define CPU5_ALU_IF_FAULT_PC 32'h0000000c",
        "`define CPU5_ALU_IF_FAULT_PREFIX_COUNT 3",
        f"`define CPU5_ALU_IF_FAULT_PROGRAM_WORDS {len(fault_words) + 1}",
        f"`define CPU5_ALU_VECTOR_SEED 32'h{SEED:08x}",
    ]
    (out / "meta.vh").write_text("\n".join(meta) + "\n", encoding="ascii")
    # Dependency classification is measured from encoded words, not emit names.
    last_writer: dict[int, int] = {}
    dependency_counts: Counter = Counter()
    x0_read_events = 0
    same_source_events = 0
    for event in trace:
        sources = event["sources"]
        x0_read_events += int(0 in sources)
        same_source_events += int(len(sources) == 2 and sources[0] == sources[1])
        for source in set(sources) - {0}:
            if source in last_writer:
                distance = event["seq"] - last_writer[source]
                dependency_counts[str(distance) if distance < 4 else "4plus"] += 1
        if event["writes"]:
            last_writer[event["rd"]] = event["seq"]
    result = dict(schema=1, seed=SEED, isa_subset="RV32I integer ALU 21 instructions",
                  retire_count=len(trace), program_words=len(trace) + 1,
                  halt_pc=len(trace) * 4, halt_instr=HALT,
                  no_control_flow=True, initial_state="program explicitly clears x1..x31",
                  oracle="decode actual encoded words; independent Python execution",
                  pc_base=0, seq_base=0, seq_rule="one per accepted sequential IF packet; no redirects",
                  value_rule="raw ALU result, including rd=x0; writes is architectural GPR write-enable",
                  opcode_counts=dict(sorted(counts.items())),
                  sections=program.sections, dependency_source_counts=dict(dependency_counts),
                  x0_write_retirements=sum(event["rd"] == 0 for event in trace),
                  x0_source_retirements=x0_read_events,
                  same_source_retirements=same_source_events,
                  unsupported_count=len(cases), selftest_checks=checks,
                  fault_case=dict(fault_pc=12, older_prefix_retire_count=3,
                                  program_words=len(fault_words) + 1,
                                  expected_files="if_fault_expected_* contain all 8 instructions; only prefix before injected fault retires"),
                  final_gpr=[dict(reg=index, value=value, hex=f"{value:08x}")
                             for index, value in enumerate(regs)])
    (out / "oracle_trace.json").write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")
    (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    # A repeat run may share this directory with simulation traces and logs.
    # Hash only the explicitly owned files, never unrelated run artifacts.
    manifest = {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                for name in sorted(GENERATED_FILENAMES)}
    (out / "sha256.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "cpu5_s2_alu")
    parser.add_argument("--selftest", action="store_true", help="validate independent known answers only")
    args = parser.parse_args()
    if args.selftest:
        print(json.dumps(dict(selftest_checks=selftest(), result="PASS")))
    else:
        info = generate(args.out)
        print(json.dumps({key: info[key] for key in ("retire_count", "program_words", "unsupported_count", "selftest_checks", "opcode_counts")}, indent=2))
