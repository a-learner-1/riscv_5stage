"""Independent encoded RV32I branch vectors for the CPU5 control-flow subset.

The small producer below emits machine words using explicit encoding layouts.
The interpreter separately decodes those bytes; it never reads assembler labels,
producer-side operation tags, RTL, or a compiler.  Expected records are ordered
by architectural retirement index, since redirected fetch sequence IDs can have
holes and are deliberately not predicted by this oracle.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MASK = 0xffffffff
HALT = 0x00002023  # SW x0,0(x0): legal RV32I, unimplemented in this partial core.
FIELDS = ("pc", "instr", "rd", "value", "writes", "nextpc")


def sext(value: int, bits: int = 32) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def r(name: str, rd: int, rs1: int, rs2: int) -> int:
    minor, high = {"ADD": (0, 0), "SUB": (0, 32), "SLL": (1, 0),
                   "SLT": (2, 0), "SLTU": (3, 0), "XOR": (4, 0),
                   "SRL": (5, 0), "SRA": (5, 32), "OR": (6, 0),
                   "AND": (7, 0)}[name]
    assert all(0 <= x < 32 for x in (rd, rs1, rs2))
    return high << 25 | rs2 << 20 | rs1 << 15 | minor << 12 | rd << 7 | 0x33


def i(name: str, rd: int, rs1: int, imm: int) -> int:
    minor = {"ADDI": 0, "SLTI": 2, "SLTIU": 3, "XORI": 4, "ORI": 6,
             "ANDI": 7, "SLLI": 1, "SRLI": 5, "SRAI": 5, "JALR": 0}[name]
    if name in ("SLLI", "SRLI", "SRAI"):
        assert 0 <= imm < 32
        imm |= 0x400 if name == "SRAI" else 0
    else:
        assert -2048 <= imm <= 2047
    assert all(0 <= x < 32 for x in (rd, rs1))
    return (imm & 4095) << 20 | rs1 << 15 | minor << 12 | rd << 7 | (0x67 if name == "JALR" else 0x13)


def u(name: str, rd: int, imm: int) -> int:
    assert 0 <= rd < 32 and 0 <= imm < (1 << 20)
    return imm << 12 | rd << 7 | {"LUI": 0x37, "AUIPC": 0x17}[name]


def b(name: str, rs1: int, rs2: int, offset: int) -> int:
    assert -4096 <= offset <= 4094 and offset % 2 == 0
    assert all(0 <= x < 32 for x in (rs1, rs2))
    q = offset & 0x1fff
    minor = {"BEQ": 0, "BNE": 1, "BLT": 4, "BGE": 5, "BLTU": 6, "BGEU": 7}[name]
    return ((q >> 12) & 1) << 31 | ((q >> 5) & 63) << 25 | rs2 << 20 | rs1 << 15 | minor << 12 | ((q >> 1) & 15) << 8 | ((q >> 11) & 1) << 7 | 0x63


def j(rd: int, offset: int) -> int:
    assert 0 <= rd < 32 and -1048576 <= offset <= 1048574 and offset % 2 == 0
    q = offset & 0x1fffff
    return ((q >> 20) & 1) << 31 | ((q >> 1) & 1023) << 21 | ((q >> 11) & 1) << 20 | ((q >> 12) & 255) << 12 | rd << 7 | 0x6f


class Program:
    def __init__(self) -> None:
        self.words: list[int] = []
        self.labels: dict[str, int] = {}
        self.fixups: list[tuple] = []
        self.sections: list[dict] = []

    @property
    def pc(self) -> int:
        return len(self.words) * 4

    def emit(self, word: int) -> None:
        self.words.append(word)

    def label(self, name: str) -> None:
        assert name not in self.labels
        self.labels[name] = self.pc

    def section(self, name: str) -> None:
        self.sections.append(dict(name=name, pc=self.pc))

    def branch(self, name: str, rs1: int, rs2: int, label: str) -> None:
        self.fixups.append((len(self.words), "b", name, rs1, rs2, label))
        self.emit(0)

    def jump(self, rd: int, label: str) -> None:
        self.fixups.append((len(self.words), "j", rd, label))
        self.emit(0)

    def address(self, rd: int, label: str, addend: int = 0) -> None:
        # Materialize a nearby target from PC, independent of program base/size.
        base = self.pc
        self.emit(u("AUIPC", rd, 0))
        self.fixups.append((len(self.words), "a", rd, label, addend, base))
        self.emit(0)

    def finish(self) -> list[int]:
        for fix in self.fixups:
            index, kind, *args = fix
            if kind == "b":
                name, a, c, label = args
                self.words[index] = b(name, a, c, self.labels[label] - index * 4)
            elif kind == "j":
                rd, label = args
                self.words[index] = j(rd, self.labels[label] - index * 4)
            else:
                rd, label, addend, base = args
                self.words[index] = i("ADDI", rd, rd, self.labels[label] + addend - base)
        return self.words


def reference_step(word: int, pc: int, regs: list[int]) -> dict:
    """Interpret encoded bytes, updating GPR only after aligned control checks."""
    opcode = word & 127
    dest, minor = (word >> 7) & 31, (word >> 12) & 7
    src1, src2, high = (word >> 15) & 31, (word >> 20) & 31, word >> 25
    a, c = regs[src1], regs[src2]
    nextpc, taken, target, sources = (pc + 4) & MASK, False, None, []
    if opcode == 0x37:
        name, value = "LUI", word & 0xfffff000
    elif opcode == 0x17:
        name, value = "AUIPC", pc + (word & 0xfffff000)
    elif opcode == 0x13:
        imm = sext(word >> 20, 12)
        sources = [src1]
        if minor == 0:
            name, value = "ADDI", a + imm
        elif minor == 2:
            name, value = "SLTI", int(sext(a) < imm)
        elif minor == 3:
            name, value = "SLTIU", int(a < (imm & MASK))
        elif minor == 4:
            name, value = "XORI", a ^ imm
        elif minor == 6:
            name, value = "ORI", a | imm
        elif minor == 7:
            name, value = "ANDI", a & imm
        elif minor == 1 and high == 0:
            name, value = "SLLI", a << src2
        elif minor == 5 and high == 0:
            name, value = "SRLI", a >> src2
        elif minor == 5 and high == 32:
            name, value = "SRAI", sext(a) >> src2
        else:
            raise ValueError(f"unsupported OP-IMM {word:08x}")
    elif opcode == 0x33:
        sources, shift = [src1, src2], c & 31
        if minor == 0 and high == 0:
            name, value = "ADD", a + c
        elif minor == 0 and high == 32:
            name, value = "SUB", a - c
        elif minor == 1 and high == 0:
            name, value = "SLL", a << shift
        elif minor == 2 and high == 0:
            name, value = "SLT", int(sext(a) < sext(c))
        elif minor == 3 and high == 0:
            name, value = "SLTU", int(a < c)
        elif minor == 4 and high == 0:
            name, value = "XOR", a ^ c
        elif minor == 5 and high == 0:
            name, value = "SRL", a >> shift
        elif minor == 5 and high == 32:
            name, value = "SRA", sext(a) >> shift
        elif minor == 6 and high == 0:
            name, value = "OR", a | c
        elif minor == 7 and high == 0:
            name, value = "AND", a & c
        else:
            raise ValueError(f"unsupported OP {word:08x}")
    elif opcode == 0x63:
        immediate = ((word >> 31) & 1) << 12 | ((word >> 7) & 1) << 11 | ((word >> 25) & 63) << 5 | ((word >> 8) & 15) << 1
        target, sources = (pc + sext(immediate, 13)) & MASK, [src1, src2]
        if minor == 0:
            name, taken = "BEQ", a == c
        elif minor == 1:
            name, taken = "BNE", a != c
        elif minor == 4:
            name, taken = "BLT", sext(a) < sext(c)
        elif minor == 5:
            name, taken = "BGE", sext(a) >= sext(c)
        elif minor == 6:
            name, taken = "BLTU", a < c
        elif minor == 7:
            name, taken = "BGEU", a >= c
        else:
            raise ValueError(f"unsupported BRANCH {word:08x}")
        value, dest = 0, 0  # Branch has no architectural destination.
        if taken:
            nextpc = target
    elif opcode == 0x6f:
        immediate = ((word >> 31) & 1) << 20 | ((word >> 12) & 255) << 12 | ((word >> 20) & 1) << 11 | ((word >> 21) & 1023) << 1
        name, value, taken = "JAL", (pc + 4) & MASK, True
        target = nextpc = (pc + sext(immediate, 21)) & MASK
    elif opcode == 0x67 and minor == 0:
        name, value, taken, sources = "JALR", (pc + 4) & MASK, True, [src1]
        target = nextpc = (a + sext(word >> 20, 12)) & 0xfffffffe
    else:
        raise ValueError(f"unsupported opcode {word:08x}")
    if taken and nextpc & 3:
        raise InstructionAddressMisaligned(pc, nextpc, word)
    value &= MASK
    writes = int(dest != 0)
    event = dict(pc=pc, instr=word, rd=dest, value=value, writes=writes,
                 nextpc=nextpc, opcode=name, taken=int(taken), target=target,
                 sources=sources, source_values=[regs[s] for s in sources])
    if writes:
        regs[dest] = value
    regs[0] = 0
    return event


class InstructionAddressMisaligned(ValueError):
    def __init__(self, pc: int, target: int, word: int) -> None:
        super().__init__(f"misaligned instruction target {target:08x} at {pc:08x}")
        self.pc, self.target, self.word = pc, target, word


def execute(words: list[int], injected_fault_pc: int | None = None) -> tuple[list[dict], list[int], dict]:
    regs, pc, trace = [0] * 32, 0, []
    for _ in range(20000):
        assert pc % 4 == 0 and 0 <= pc < len(words) * 4, f"unmapped pc {pc:08x}"
        word = words[pc // 4]
        if pc == injected_fault_pc:
            return trace, regs, dict(kind="fetch_error", pc=pc, instr=word, target=pc)
        if word == HALT:
            return trace, regs, dict(kind="unsupported", pc=pc, instr=word, target=pc)
        try:
            event = reference_step(word, pc, regs)
        except InstructionAddressMisaligned as error:
            return trace, regs, dict(kind="misaligned", pc=error.pc, instr=error.word, target=error.target)
        event["index"] = len(trace)
        trace.append(event)
        pc = event["nextpc"]
    raise AssertionError("reference exceeded bounded execution; loop does not terminate")


def main_program() -> Program:
    p = Program()
    p.section("initialize_all_gpr")
    for rd in range(1, 32):
        p.emit(i("ADDI", rd, 0, 0))
    # Fixed unsigned/signed boundary sources.
    p.emit(i("ADDI", 1, 0, -1))
    p.emit(u("LUI", 2, 0x80000))
    p.emit(i("ADDI", 3, 2, -1))
    p.emit(i("ADDI", 4, 0, 1))
    p.emit(i("ADDI", 5, 0, 0))
    p.section("all_six_conditions_signed_unsigned_boundaries")
    # Every condition appears taken and not taken; taken paths skip an observable
    # x31 sentinel AND an unsupported SW, so a missing flush cannot silently pass.
    pairs = [(0, 0), (1, 1), (1, 0), (0, 1), (2, 3), (3, 2),
             (2, 1), (1, 2), (4, 5), (5, 4)]
    for name in ("BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"):
        for case, (a, c) in enumerate(pairs):
            label = f"after_{name}_{case}"
            p.branch(name, a, c, label)
            # Non-taken path retires an accumulator update then jumps over SW.
            p.emit(i("ADDI", 20, 20, 1))
            p.jump(0, label)
            p.emit(i("ADDI", 31, 31, 99))
            p.emit(HALT)
            p.label(label)
            p.emit(i("ADDI", 21, 21, 1))
    p.section("backward_loops_and_branch_use")
    for count, cond in ((7, "BNE"), (5, "BLT"), (4, "BLTU")):
        label = f"loop_{cond}"
        p.emit(i("ADDI", 8, 0, 0))
        p.emit(i("ADDI", 9, 0, count))
        p.label(label)
        p.emit(i("ADDI", 8, 8, 1))
        p.emit(i("ADDI", 10, 8, 0))
        p.branch(cond, 10, 9, label)
        p.emit(i("ADDI", 22, 22, count))
    p.section("youngest_writer_and_two_source_hazards")
    for n in range(8):
        p.emit(i("ADDI", 11, 0, n + 1))
        p.emit(i("ADDI", 11, 11, 7))
        p.emit(i("ADDI", 12, 11, 0))
        p.branch("BEQ", 11, 12, f"hazard_{n}")
        p.emit(i("ADDI", 31, 31, 127))
        p.emit(HALT)
        p.label(f"hazard_{n}")
        p.emit(r("ADD", 23, 11, 12))
        # WB-distance reader: two independent ALU packets intervene.
        p.emit(i("ADDI", 13, 0, n + 40))
        p.emit(i("ADDI", 14, 0, n + 50))
        p.emit(i("ADDI", 15, 0, n + 60))
        p.branch("BNE", 13, 14, f"wb_{n}")
        p.emit(HALT)
        p.label(f"wb_{n}")
    p.section("jal_and_jalr_forward_backward_links")
    p.jump(24, "subroutine")
    p.emit(i("ADDI", 25, 24, 0))
    p.jump(0, "after_subroutine")
    p.emit(HALT)
    p.label("subroutine")
    p.emit(i("ADDI", 26, 0, 17))
    p.emit(i("JALR", 0, 24, 0))  # backward return, no link.
    p.emit(i("ADDI", 31, 31, 199))
    p.emit(HALT)
    p.label("after_subroutine")
    p.address(16, "odd_target", 5)
    p.emit(i("JALR", 17, 16, -4))  # (target+5)-4 = target+1; clear bit0.
    p.emit(i("ADDI", 31, 31, 199))
    p.emit(HALT)
    p.label("odd_target")
    p.emit(i("ADDI", 18, 17, 0))
    p.address(19, "same_rd_target", 9)
    p.emit(i("JALR", 19, 19, -8))  # destination aliases base: read old source.
    p.emit(i("ADDI", 31, 31, 199))
    p.emit(HALT)
    p.label("same_rd_target")
    p.emit(i("ADDI", 27, 19, 0))
    p.address(16, "zero_rd_target", 1)
    p.emit(i("JALR", 0, 16, 0))
    p.emit(i("ADDI", 31, 31, 199))
    p.emit(HALT)
    p.label("zero_rd_target")
    p.emit(i("ADDI", 0, 0, 123))
    p.emit(r("ADD", 28, 0, 27))
    p.section("not_taken_misaligned_target_is_legal")
    p.emit(b("BNE", 0, 0, 2))
    p.emit(b("BLT", 0, 0, 2))
    p.emit(b("BLTU", 0, 0, 2))
    p.emit(i("ADDI", 29, 0, 77))
    p.label("halt")
    p.emit(HALT)
    p.finish()
    return p


def fixtures() -> list[dict]:
    prefix = [i("ADDI", 1, 0, 1), i("ADDI", 2, 0, 2), r("ADD", 3, 1, 2)]
    result = []
    for name in ("BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"):
        a, c = {"BEQ": (1, 1), "BNE": (1, 2), "BLT": (1, 2),
                "BGE": (2, 1), "BLTU": (1, 2), "BGEU": (2, 1)}[name]
        result.append(dict(name=f"misalign_{name.lower()}", words=prefix + [b(name, a, c, 2), i("ADDI", 4, 0, 99), HALT]))
    result.append(dict(name="misalign_jal", words=prefix + [j(4, 2), i("ADDI", 4, 0, 99), HALT]))
    result.append(dict(name="misalign_jalr", words=prefix + [i("ADDI", 5, 0, 19), i("JALR", 5, 5, 0), i("ADDI", 4, 0, 99), HALT]))
    # Fault lies at the target of a taken branch; its own machine word must not
    # retire.  A different fixture injects the fault on a sequential packet.
    result.append(dict(name="if_fault_target", words=prefix + [b("BEQ", 1, 1, 12), HALT, HALT, i("ADDI", 4, 0, 55), HALT], injected_fault_pc=24))
    result.append(dict(name="if_fault_sequential", words=prefix + [i("ADDI", 4, 0, 55), HALT], injected_fault_pc=12))
    return result


def selftest() -> int:
    checks = 0
    fixed = [
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
        (b("BEQ", 1, 2, 8), 0x00208463), (b("BNE", 1, 2, 8), 0x00209463),
        (b("BLT", 1, 2, 8), 0x0020c463), (b("BGE", 1, 2, 8), 0x0020d463),
        (b("BLTU", 1, 2, 8), 0x0020e463), (b("BGEU", 1, 2, 8), 0x0020f463),
        (b("BEQ", 1, 2, -4), 0xfe208ee3),
        (j(1, 8), 0x008000ef), (j(0, -4), 0xffdff06f),
        (i("JALR", 1, 2, -4), 0xffc100e7), (i("JALR", 0, 1, 0), 0x00008067),
    ]
    for actual, wanted in fixed:
        assert actual == wanted, (hex(actual), hex(wanted))
        checks += 1
    # Directly decoded fixed words, independently hand-worked target/results.
    for word, av, cv, wanted in [
        (0x00208463, 1, 1, 0x108), (0x00208463, 1, 2, 0x104),
        (0x00209463, 1, 2, 0x108), (0x00209463, 1, 1, 0x104),
        (0x0020c463, 0x80000000, 0x7fffffff, 0x108),
        (0x0020c463, 0x7fffffff, 0x80000000, 0x104),
        (0x0020d463, 0xffffffff, 0x80000000, 0x108),
        (0x0020d463, 0x80000000, 0xffffffff, 0x104),
        (0x0020e463, 0x80000000, 0x7fffffff, 0x104),
        (0x0020e463, 0x7fffffff, 0x80000000, 0x108),
        (0x0020f463, 0x80000000, 0x7fffffff, 0x108),
        (0x0020f463, 0x7fffffff, 0x80000000, 0x104),
        (0xfe208ee3, 7, 7, 0xfc),
    ]:
        regs = [0] * 32
        regs[1], regs[2] = av, cv
        event = reference_step(word, 0x100, regs)
        assert (event["nextpc"], event["rd"], event["value"], event["writes"]) == (wanted, 0, 0, 0)
        assert regs[1] == av and regs[2] == cv
        checks += 1
    for word, base, target, rd in [(0x008000ef, 0, 0x108, 1),
                                    (0xffdff06f, 0, 0xfc, 0),
                                    (0xffc100e7, 0x10d, 0x108, 1),
                                    (0x00008067, 0x109, 0x108, 0)]:
        regs = [0] * 32
        regs[1] = regs[2] = base
        event = reference_step(word, 0x100, regs)
        assert (event["nextpc"], event["rd"], event["value"], event["writes"]) == (target, rd, 0x104, int(rd != 0))
        checks += 1
    # rd==rs1 reads the old base before committing the new link.
    regs = [0] * 32
    regs[1] = 0x109
    event = reference_step(0x000080e7, 0x100, regs)
    assert event["nextpc"] == 0x108 and regs[1] == 0x104
    checks += 1
    # A non-taken branch must ignore the misalignment of its unused target.
    event = reference_step(0x00001163, 0x100, [0] * 32)
    assert event["nextpc"] == 0x104
    checks += 1
    for word in (0x00000163, 0x002000ef):
        try:
            reference_step(word, 0x100, [0] * 32)
        except InstructionAddressMisaligned as error:
            assert error.pc == 0x100 and error.target == 0x102
            checks += 1
        else:
            raise AssertionError("misaligned taken control did not fault")
    for word in (HALT, 0x00002003, 0x02000033, 0x00001067, 0x00002063, 0x00003063):
        try:
            reference_step(word, 0x100, [0] * 32)
        except ValueError:
            checks += 1
        else:
            raise AssertionError(f"unimplemented/invalid instruction accepted {word:08x}")
    return checks


def write_hex(path: Path, values: list[int]) -> None:
    path.write_text("".join(f"{value & MASK:08x}\n" for value in values), encoding="ascii")


def write_trace(out: Path, prefix: str, trace: list[dict]) -> None:
    for field in FIELDS:
        write_hex(out / f"{prefix}expected_{field}.hex", [e[field] for e in trace])


def generate(out: Path) -> dict:
    checks = selftest()
    out.mkdir(parents=True, exist_ok=True)
    owned: list[str] = []
    p = main_program()
    trace, regs, stop = execute(p.words)
    assert stop["kind"] == "unsupported" and stop["pc"] == p.labels["halt"]
    counts = Counter(e["opcode"] for e in trace)
    branch_outcomes = Counter(f'{e["opcode"]}_{"taken" if e["taken"] else "not_taken"}' for e in trace if e["opcode"].startswith("B"))
    for name in ("BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"):
        assert branch_outcomes[f"{name}_taken"] and branch_outcomes[f"{name}_not_taken"]
    assert regs[31] == 0  # All wrong-path sentinel writes must remain unreachable.
    write_hex(out / "program.hex", p.words)
    write_hex(out / "final_gpr.hex", regs)
    write_trace(out, "", trace)
    owned += ["program.hex", "final_gpr.hex"] + [f"expected_{f}.hex" for f in FIELDS]
    (out / "oracle_trace.json").write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")
    owned.append("oracle_trace.json")
    fixture_info = []
    for index, fixture in enumerate(fixtures()):
        name, words = fixture["name"], fixture["words"]
        ftrace, fregs, fstop = execute(words, fixture.get("injected_fault_pc"))
        assert fstop["kind"] == ("fetch_error" if name.startswith("if_fault") else "misaligned")
        write_hex(out / f"{name}_program.hex", words)
        write_hex(out / f"{name}_final_gpr.hex", fregs)
        write_trace(out, name + "_", ftrace)
        owned += [f"{name}_program.hex", f"{name}_final_gpr.hex"] + [f"{name}_expected_{f}.hex" for f in FIELDS]
        fixture_info.append(dict(index=index, name=name, program_words=len(words),
                                 retire_count=len(ftrace), stop=fstop,
                                 initialized_gpr=sorted({0} | {event["rd"] for event in ftrace if event["writes"]}),
                                 final_gpr_rule="Only initialized_gpr are physical final-state assertions; untouched oracle registers use zero placeholders, not a reset guarantee",
                                 injected_fault_pc=fixture.get("injected_fault_pc")))
    meta = ["// Generated branch oracle: no expected fetch sequence IDs.",
            f"`define CPU5_BRANCH_RETIRE_COUNT {len(trace)}",
            f"`define CPU5_BRANCH_PROGRAM_WORDS {len(p.words)}",
            f"`define CPU5_BRANCH_HALT_PC 32'h{stop['pc']:08x}",
            f"`define CPU5_BRANCH_HALT_INSTR 32'h{HALT:08x}",
            f"`define CPU5_BRANCH_FIXTURE_COUNT {len(fixture_info)}"]
    for case in fixture_info:
        prefix = "CPU5_BRANCH_" + case["name"].upper()
        meta += [f"`define {prefix}_WORDS {case['program_words']}",
                 f"`define {prefix}_COUNT {case['retire_count']}",
                 f"`define {prefix}_PC 32'h{case['stop']['pc']:08x}",
                 f"`define {prefix}_TARGET 32'h{case['stop']['target']:08x}",
                 f"`define {prefix}_INSTR 32'h{case['stop']['instr']:08x}"]
    (out / "meta.vh").write_text("\n".join(meta) + "\n", encoding="ascii")
    info = dict(schema=1, subset="RV32I ALU plus six conditional branches and JAL/JALR",
                retire_count=len(trace), program_words=len(p.words), stop=stop,
                initial_gpr="main software initializes x1..x31; fault fixtures initialize only each descriptor's initialized_gpr; x0 is zero",
                reference="actual machine word decode, independent from emit/fixup metadata and RTL",
                seq_rule="expected index is dynamic retirement order, not fetch seq; no seq files",
                branch_trace="rd=0,value=0,writes=0; JAL/JALR rawvalue=pc+4 even for rd0",
                sections=p.sections, opcode_counts=dict(sorted(counts.items())),
                branch_outcomes=dict(sorted(branch_outcomes.items())),
                taken_controls=sum(e["taken"] for e in trace),
                backward_controls=sum(e["taken"] and e["nextpc"] < e["pc"] for e in trace),
                jalr_rd_eq_rs1=sum(e["opcode"] == "JALR" and e["rd"] == e["sources"][0] and e["rd"] != 0 for e in trace),
                wrong_path_sentinel_register=31, wrong_path_sentinel_final=regs[31],
                selftest_checks=checks, known_fixed_encodings=32, fixtures=fixture_info)
    (out / "summary.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    (out / "fixtures.json").write_text(json.dumps(fixture_info, indent=2) + "\n", encoding="utf-8")
    owned += ["meta.vh", "summary.json", "fixtures.json"]
    hashes = {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in sorted(owned)}
    (out / "sha256.json").write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    return info


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "cpu5_s4_branch")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        print(json.dumps(dict(result="PASS", selftest_checks=selftest())))
    else:
        result = generate(args.out)
        print(json.dumps({key: result[key] for key in ("retire_count", "program_words", "selftest_checks", "opcode_counts", "branch_outcomes", "taken_controls", "backward_controls")}, indent=2))
