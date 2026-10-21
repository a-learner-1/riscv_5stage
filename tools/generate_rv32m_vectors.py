"""Deterministic RV32M oracle vectors and CPU programs; Python integers are the oracle.

No compiler, CPU decoder, DUT function, or software multiply helper is used to
calculate expected results.  Division truncates toward zero explicitly.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import random

MASK = (1 << 32) - 1


def signed(value: int) -> int:
    return value - (1 << 32) if value & (1 << 31) else value


def oracle(op: int, a: int, b: int) -> int:
    sa, sb = signed(a), signed(b)
    if op == 0:
        value = a * b
    elif op == 1:
        value = (sa * sb) >> 32
    elif op == 2:
        value = (sa * b) >> 32
    elif op == 3:
        value = (a * b) >> 32
    elif b == 0:
        value = MASK if op in (4, 5) else a
    elif op in (5, 7):
        value = a // b if op == 5 else a % b
    else:
        quotient = abs(sa) // abs(sb)
        if (sa < 0) != (sb < 0):
            quotient = -quotient
        value = quotient if op == 4 else sa - quotient * sb
    return value & MASK


class Program:
    def __init__(self) -> None:
        self.words = [0x13] * 2048
        self.trace: list[tuple[int, int, int, int]] = []
        self.cursor = 0
        self.regs = [0] * 32
        self.memory: dict[int, int] = {}
        self.store_count = 0

    def emit(self, instruction: int, rd: int = 0, value: int = 0, flags: int = 0) -> int:
        index = self.cursor
        self.words[index] = instruction
        self.trace.append((index * 4, rd, value & MASK, flags | int(rd != 0)))
        if rd:
            self.regs[rd] = value & MASK
        self.cursor += 1
        return index * 4

    def li(self, rd: int, value: int) -> None:
        value &= MASK
        upper = ((value + 0x800) >> 12) & 0xFFFFF
        lower = value & 0xFFF
        self.emit((upper << 12) | (rd << 7) | 0x37, rd, upper << 12)
        self.addi(rd, rd, lower - 0x1000 if lower & 0x800 else lower)

    def addi(self, rd: int, rs: int, imm: int) -> None:
        self.emit(((imm & 0xFFF) << 20) | (rs << 15) | (rd << 7) | 0x13,
                  rd, self.regs[rs] + imm)

    def m(self, op: int, rd: int, rs1: int, rs2: int) -> int:
        return self.emit((1 << 25) | (rs2 << 20) | (rs1 << 15) | (op << 12) | (rd << 7) | 0x33,
                         rd, oracle(op, self.regs[rs1], self.regs[rs2]), 4)

    def store(self, rs: int, addr: int) -> None:
        self.emit(((addr >> 5) << 25) | (rs << 20) | (2 << 12) | ((addr & 31) << 7) | 0x23,
                  0, self.regs[rs], 2)
        self.memory[addr] = self.regs[rs]
        self.store_count += 1

    def load(self, rd: int, addr: int) -> None:
        self.emit((addr << 20) | (2 << 12) | (rd << 7) | 3, rd, self.memory[addr])


def generate(output: Path, random_per_op: int) -> None:
    output.mkdir(parents=True, exist_ok=True)
    rng = random.Random(0x525633324D)
    boundary = [0, 1, 2, 3, 7, 15, 16, 31, 32, 0xFFFF, 0x10000,
                0x7FFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001,
                0xFFFFFFFD, 0xFFFFFFFE, MASK, 0x55555555, 0xAAAAAAAA]
    vectors = []
    for op in range(8):
        pairs = [(a, b) for a in boundary for b in boundary]
        pairs += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(random_per_op)]
        # Every bit position is exercised as a dividend and divisor.
        pairs += [(1 << bit, (1 << bit) - 1) for bit in range(32)]
        pairs += [(MASK ^ (1 << bit), 1 << bit) for bit in range(32)]
        vectors.extend((op, a, b, oracle(op, a, b)) for a, b in pairs)
    (output / "rv32m_vectors.txt").write_text(
        "".join(f"{op:x} {a:08x} {b:08x} {value:08x}\n" for op, a, b, value in vectors), encoding="ascii")

    p = Program()
    handler_pc = 1800 * 4
    p.emit((0x301 << 20) | (2 << 12) | (22 << 7) | 0x73, 22, 0x40001100)
    p.li(24, handler_pc)
    p.emit((0x305 << 20) | (24 << 15) | (1 << 12) | 0x73)  # csrw mtvec,x24
    p.li(23, 0x800)
    p.emit((0x304 << 20) | (23 << 15) | (1 << 12) | 0x73)  # csrw mie,x23
    p.li(1, 0x80000001)
    p.li(2, 3)
    p.emit((0x300 << 20) | (8 << 15) | (6 << 12) | 0x73)   # csrsi mstatus,8 immediately before DIV
    irq_pc = p.m(4, 3, 1, 2)
    p.addi(4, 3, 7)

    corners = [(0, 0), (MASK, 0), (0x80000000, MASK), (0x80000000, 1),
               (MASK, 3), (3, MASK), (0x80000001, 7), (0x7FFFFFFF, 0x80000000)]
    operations = 1
    for op in range(8):
        pairs = corners + [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(4)]
        for index, (a, b) in enumerate(pairs):
            p.li(1, a)
            p.li(2, b)
            p.m(op, 3, 1, 2)
            p.m((op + 3) % 8, 3, 3, 2)  # rd=rs1 and M->M RAW dependency
            p.addi(4, 3, 1)             # M->ALU forwarding
            p.store(4, 256)             # M/ALU->store and precise single side effect
            p.load(5, 256)
            p.m(0, 5, 5, 1)             # load->M, rd=rs1
            p.m(3, 2, 1, 2)             # rd=rs2
            operations += 4
        p.m(op, 0, 1, 2)                # x0 must stay zero, still retires once
        p.addi(8, 0, 77)
        operations += 1

    # Branch skips a wrong-path multiply, divide and store. All three PCs are
    # deliberately absent from the retirement oracle.
    p.emit((8 << 8) | 0x63)             # beq x0,x0,+16
    p.words[p.cursor] = 0x02100CB3      # mul x25,x0,x1
    p.words[p.cursor + 1] = 0x02104D33  # div x26,x0,x1
    p.words[p.cursor + 2] = 0x00102023  # sw x1,0(x0)
    p.cursor += 3
    p.load(9, 256)
    terminal_pc = p.cursor * 4
    p.addi(10, 0, 1)
    p.words[p.cursor] = 0x0000006F
    assert p.cursor < 1800
    p.words[1800] = (0x341 << 20) | (2 << 12) | (26 << 7) | 0x73  # csrr x26,mepc
    p.words[1801] = 0x00100D93                                  # addi x27,x0,1
    p.words[1802] = 0x30200073                                  # mret
    (output / "rv32m_cpu_program.hex").write_text("".join(f"{word:08x}\n" for word in p.words), encoding="ascii")
    (output / "rv32m_cpu_trace.txt").write_text(
        "".join(f"{pc:08x} {rd:02x} {value:08x} {flags:x}\n" for pc, rd, value, flags in p.trace), encoding="ascii")
    (output / "rv32m_cpu_meta.vh").write_text(
        f"localparam integer TERMINAL_PC = {terminal_pc};\n"
        f"localparam integer IRQ_PC = {irq_pc};\n"
        f"localparam integer HANDLER_PC = {handler_pc};\n"
        f"localparam integer EXPECT_STORES = {p.store_count};\n"
        f"localparam integer EXPECT_M_OPS = {operations};\n"
        f"localparam integer EXPECT_MAIN_RETIRED = {len(p.trace)};\n", encoding="ascii")
    (output / "rv32m_vectors_manifest.json").write_text(json.dumps({
        "oracle": "Python arbitrary precision integers; signed division truncates toward zero",
        "seed": "0x525633324d", "vectors": len(vectors), "per_op": len(vectors) // 8,
        "random_per_op": random_per_op, "cpu_instructions": len(p.trace),
        "cpu_m_ops": operations, "cpu_stores": p.store_count,
    }, indent=2) + "\n", encoding="ascii")
    print(f"RV32M oracle generated: {len(vectors)} unit vectors, {len(p.trace)} CPU instructions, {operations} M operations")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/rv32m"))
    parser.add_argument("--random-per-op", type=int, default=1024)
    args = parser.parse_args()
    generate(args.output, args.random_per_op)
