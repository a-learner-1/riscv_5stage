"""Build a real RV32I C RAM fixture and derive gold from its machine words.

The producer never reads RTL.  Both seed binaries are compiled by GCC, decoded
independently here, and checked against the high level C algorithm below.
Retirement indices are architectural order; fetch sequence IDs are not guessed.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MASK = 0xffffffff
RAM_BASE, RAM_BYTES, ROM_WORDS = 0x10000, 16384, 8192
STOP = 0x00100073
FIELDS = ("pc", "instr", "rd", "value", "writes", "nextpc")
MEM_FIELDS = ("index", "addr", "wdata", "wstrb", "size", "is_write", "rdata")
FALLBACK = "D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-"


def sx(value: int, bits: int) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def need(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def execute(words: list[int], initial: bytes, limit: int = 30000) -> dict:
    reg, memory, pc = [0] * 32, bytearray(initial), 0
    trace, accesses, coverage = [], [], Counter()
    for index in range(limit):
        need(pc % 4 == 0 and 0 <= pc < len(words) * 4, f"PC outside ROM {pc:x}")
        word = words[pc // 4]
        if word == STOP:
            return dict(trace=trace, accesses=accesses, registers=reg,
                        memory=bytes(memory), coverage=dict(coverage), halt_pc=pc)
        opcode, f3, f7 = word & 127, (word >> 12) & 7, word >> 25
        rd, a, b = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        left, right, imm = reg[a], reg[b], sx(word >> 20, 12)
        result, following, writes = 0, (pc + 4) & MASK, True
        name = ""
        if opcode in (0x37, 0x17):
            name = "LUI" if opcode == 0x37 else "AUIPC"
            result = (word & 0xfffff000) + (pc if opcode == 0x17 else 0)
        elif opcode in (0x13, 0x33):
            source = imm if opcode == 0x13 else right
            suffix = "I" if opcode == 0x13 else ""
            shift = b if opcode == 0x13 else right & 31
            if f3 == 0:
                need(opcode == 0x13 or f7 in (0, 32), "bad ADD/SUB")
                name = "ADDI" if opcode == 0x13 else "SUB" if f7 == 32 else "ADD"
                result = left - source if name == "SUB" else left + source
            elif f3 == 1:
                need(f7 == 0, "bad SLL")
                name, result = "SLL" + suffix, left << shift
            elif f3 == 2:
                need(opcode == 0x13 or f7 == 0, "bad SLT")
                name, result = "SLT" + suffix, int(sx(left, 32) < sx(source, 32))
            elif f3 == 3:
                need(opcode == 0x13 or f7 == 0, "bad SLTU")
                name, result = "SLTIU" if opcode == 0x13 else "SLTU", int(left < (source & MASK))
            elif f3 == 4:
                need(opcode == 0x13 or f7 == 0, "bad XOR")
                name, result = "XOR" + suffix, left ^ source
            elif f3 == 5:
                need(f7 in (0, 32), "bad right shift")
                name = ("SRA" if f7 == 32 else "SRL") + suffix
                result = sx(left, 32) >> shift if f7 == 32 else left >> shift
            elif f3 == 6:
                need(opcode == 0x13 or f7 == 0, "bad OR")
                name, result = "OR" + suffix, left | source
            else:
                need(opcode == 0x13 or f7 == 0, "bad AND")
                name, result = "AND" + suffix, left & source
        elif opcode in (0x03, 0x23):
            writing = opcode == 0x23
            displacement = sx(((word >> 25) << 5) | ((word >> 7) & 31), 12) if writing else imm
            address = (left + displacement) & MASK
            allowed = {0: (1, "SB"), 1: (2, "SH"), 2: (4, "SW")} if writing else {0: (1, "LB"), 1: (2, "LH"), 2: (4, "LW"), 4: (1, "LBU"), 5: (2, "LHU")}
            need(f3 in allowed, f"bad memory instruction {word:08x}")
            width, name = allowed[f3]
            need(RAM_BASE <= address and address + width <= RAM_BASE + RAM_BYTES, f"outside RAM {address:x}")
            need(address % width == 0, f"unaligned RAM {address:x}")
            offset, lane = address - RAM_BASE, address & 3
            raw = int.from_bytes(memory[offset - lane:offset - lane + 4], "little")
            wdata = ((right & ((1 << (width * 8)) - 1)) << (lane * 8)) & MASK if writing else 0
            strobes = ((1 << width) - 1) << lane if writing else 0
            accesses.append(dict(index=index, addr=address, wdata=wdata, wstrb=strobes,
                                 size={1: 0, 2: 1, 4: 2}[width], is_write=int(writing), rdata=raw))
            if writing:
                memory[offset:offset + width] = (right & ((1 << (width * 8)) - 1)).to_bytes(width, "little")
                rd, writes = 0, False
            else:
                result = int.from_bytes(memory[offset:offset + width], "little")
                if f3 in (0, 1):
                    result = sx(result, width * 8)
        elif opcode == 0x63:
            displacement = sx(((word >> 31) << 12) | (((word >> 7) & 1) << 11) | (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1), 13)
            choices = {0: ("BEQ", left == right), 1: ("BNE", left != right),
                       4: ("BLT", sx(left, 32) < sx(right, 32)), 5: ("BGE", sx(left, 32) >= sx(right, 32)),
                       6: ("BLTU", left < right), 7: ("BGEU", left >= right)}
            need(f3 in choices, "bad branch")
            name, taken = choices[f3]
            following = (pc + displacement) & MASK if taken else following
            need(following % 4 == 0, "misaligned branch target")
            rd, writes = 0, False
        elif opcode == 0x6f:
            displacement = sx(((word >> 31) << 20) | (((word >> 12) & 255) << 12) | (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1), 21)
            name, result, following = "JAL", pc + 4, (pc + displacement) & MASK
            need(following % 4 == 0, "misaligned JAL")
        elif opcode == 0x67:
            need(f3 == 0, "bad JALR")
            name, result, following = "JALR", pc + 4, (left + imm) & 0xfffffffe
            need(following % 4 == 0, "misaligned JALR")
        else:
            raise ValueError(f"unsupported {word:08x} at {pc:x}")
        result &= MASK
        writes = int(writes and rd != 0)
        if writes:
            reg[rd] = result
        trace.append(dict(pc=pc, instr=word, rd=rd, value=result, writes=writes,
                          nextpc=following, operation=name))
        coverage[name] += 1
        reg[0], pc = 0, following
    raise ValueError("reference did not reach EBREAK")


def algorithm(seed: int) -> dict:
    words = [((seed ^ (0x01020304 + (i << 12))) + (i << 1)) & MASK for i in range(16)]
    halves = [(0x8000 ^ (seed >> (i & 7)) ^ (i << 8)) & 65535 for i in range(16)]
    octets = [((seed >> (i & 15)) + i * 7) & 255 for i in range(32)]
    octets[:4], halves[:4] = [128, 127, 255, 0], [32768, 32767, 65535, 0]
    def mix(index: int, value: int) -> int:
        return (((value + index) + (value ^ 0x89abcdef)) & MASK) ^ (value >> 3)
    total = 0x31415926
    for i in range(16):
        a = words[i]
        total = (((total << 5) | (total >> 27)) & MASK) ^ a
        total = (total + sx(halves[i], 16)) & MASK
        total ^= ((sx(octets[2 * i + 1], 8) << 8) | octets[2 * i]) & MASK
        words[i] = (a + total) & MASK
        if words[i] & 1:
            total ^= 0x5a5a5a5a
        total = (total + mix(i, total)) & MASK
    chosen = (seed >> 4) & 15
    words[chosen] ^= total
    total = (total + words[chosen]) & MASK
    results = [total, mix(7, total), 0xffffff80, 0xffff8000, 255, 65535,
               words[chosen], 0x600d0000 | (seed & 65535)]
    return dict(words=words, halves=halves, bytes=octets, result=results,
                cursor=chosen, input_seed=seed)


def selftest() -> int:
    checks = 0
    def check(ok: bool, label: str) -> None:
        nonlocal checks
        need(ok, "selftest: " + label)
        checks += 1
    for value, bits, expected in [(0x80, 8, -128), (0x7f, 8, 127), (0xff, 8, -1),
                                  (0x8000, 16, -32768), (0xffff, 16, -1), (0x80000000, 32, -2147483648)]:
        check(sx(value, bits) == expected, f"signed {value:x}")
    # Fixed instruction encodings and hand-computed extension/lane expectations.
    memory = bytearray(RAM_BYTES)
    memory[:4] = bytes.fromhex("0180ff7f")
    prefix = [0x000100b7]  # LUI x1,0x10: architectural address 0x10000.
    for word, name, expected in [(0x00108103, "LB", 0xffffff80), (0x00208103, "LB", 0xffffffff),
                                 (0x0010c103, "LBU", 128), (0x00009103, "LH", 0xffff8001),
                                 (0x00209103, "LH", 32767), (0x0000d103, "LHU", 32769),
                                 (0x0000a103, "LW", 0x7fff8001), (0x0000a003, "LW", 0x7fff8001)]:
        outcome = execute(prefix + [word, STOP], memory)
        row, access = outcome["trace"][1], outcome["accesses"][0]
        check(row["operation"] == name and row["value"] == expected, f"load {word:x}")
        check(row["writes"] == int(((word >> 7) & 31) != 0), "load x0 semantics")
        check(access["rdata"] == 0x7fff8001, "aligned raw word")
    for word, name, lane, width in [(0x002081a3, "SB", 3, 1), (0x00209123, "SH", 2, 2), (0x0020a023, "SW", 0, 4)]:
        outcome = execute(prefix + [0xfff00113, word, STOP], memory)
        row, access = outcome["trace"][2], outcome["accesses"][0]
        check(row["operation"] == name and row["rd"] == 0 and row["value"] == 0 and row["writes"] == 0, "store retirement")
        check(access["addr"] == RAM_BASE + lane and access["wstrb"] == ((1 << width) - 1) << lane, "store mask")
        check(access["wdata"] == (((1 << (width * 8)) - 1) << (8 * lane)) & MASK, "store lane data")
        check(outcome["memory"][lane:lane + width] == b"\xff" * width, "store final bytes")
    for word in [0x00109103, 0x0020a103, 0x002090a3, 0x0020a123]:
        try:
            execute(prefix + [word, STOP], memory)
        except ValueError as error:
            check("unaligned" in str(error), "reject alignment")
        else:
            raise ValueError("accepted unaligned selftest")
    for word in [0x0000b103, 0x0000e103, 0x0020b023, 0x02000133, 0x0000000f]:
        try:
            execute(prefix + [word, STOP], memory)
        except ValueError:
            check(True, "reject unsupported")
        else:
            raise ValueError("accepted unsupported selftest")
    return checks


def hexfile(path: Path, values: list[int]) -> None:
    path.write_text("".join(f"{x & MASK:08x}\n" for x in values), encoding="ascii")


def bytes_words(payload: bytes) -> list[int]:
    payload += b"\0" * (-len(payload) % 4)
    return [int.from_bytes(payload[i:i + 4], "little") for i in range(0, len(payload), 4)]


def compiler_prefix() -> str:
    if os.environ.get("CPU5_RAM_CROSS"):
        return os.environ["CPU5_RAM_CROSS"]
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler[:-3]
    need(Path(FALLBACK + "gcc.exe").is_file(), "set CPU5_RAM_CROSS to the GNU cross prefix")
    return FALLBACK


def build(output: Path, prefix: str, seed: int, checks: int) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    flags = ["-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
             "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0", "-mno-relax",
             "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra", "-Werror",
             "-nostdlib", "-nostartfiles", "-static", "-Wl,--gc-sections", "-Wl,--no-relax",
             "-Wl,-T,software/cpu5_ram/link.ld", f"-DINPUT_SEED=0x{seed:08x}u"]
    command = [prefix + "gcc", *flags, "software/cpu5_ram/start.S", "software/cpu5_ram/main.c",
               "-Wl,-Map," + str(output / "program.map"), "-o", str(output / "program.elf")]
    subprocess.run(command, check=True, cwd=ROOT)
    for section in ("text", "data"):
        subprocess.run([prefix + "objcopy", "-O", "binary", "-j", "." + section,
                        str(output / "program.elf"), str(output / f"{section}.bin")], check=True)
    dump = subprocess.check_output([prefix + "objdump", "-d", "-S", str(output / "program.elf")], text=True)
    (output / "program.dump").write_text(dump, encoding="utf-8")
    nm = subprocess.check_output([prefix + "nm", "-n", str(output / "program.elf")], text=True)
    symbols = {row.split()[2]: int(row.split()[0], 16) for row in nm.splitlines() if len(row.split()) == 3}
    code, data = (output / "text.bin").read_bytes(), (output / "data.bin").read_bytes()
    need(len(code) <= ROM_WORDS * 4 and len(data) <= RAM_BYTES, "image exceeds ROM/RAM")
    initial = data + bytes(RAM_BYTES - len(data))
    words = bytes_words(code)
    outcome = execute(words, initial)
    need(outcome["halt_pc"] == symbols["cpu5_ram_stop"], "wrong stop endpoint")
    high = algorithm(seed)
    for name, width in [("words", 4), ("halves", 2), ("bytes", 1), ("result", 4)]:
        start = symbols[name] - RAM_BASE
        actual = [int.from_bytes(outcome["memory"][start + i * width:start + (i + 1) * width], "little") for i in range(len(high[name]))]
        need(actual == high[name], f"C machine result disagrees with high level {name}")
    pointer = int.from_bytes(outcome["memory"][symbols["cursor"] - RAM_BASE:symbols["cursor"] - RAM_BASE + 4], "little")
    need(pointer == symbols["words"] + high["cursor"] * 4, "load-derived pointer mismatch")
    hexfile(output / "program.hex", words + [0x13] * (ROM_WORDS - len(words)))
    hexfile(output / "ram_initial.hex", bytes_words(initial))
    hexfile(output / "ram_final.hex", bytes_words(outcome["memory"]))
    hexfile(output / "final_gpr.hex", outcome["registers"])
    for field in FIELDS:
        hexfile(output / f"expected_{field}.hex", [r[field] for r in outcome["trace"]])
    for field in MEM_FIELDS:
        hexfile(output / f"expected_mem_{field}.hex", [r[field] for r in outcome["accesses"]])
    for needed in ("LB", "LH", "LW", "LBU", "LHU", "SB", "SH", "SW", "JALR"):
        need(outcome["coverage"].get(needed, 0) > 0, f"C fixture missed {needed}")
    metadata = dict(seed=f"0x{seed:08x}", flags=flags, compiler=subprocess.check_output([prefix + "gcc", "--version"], text=True).splitlines()[0],
                    code_bytes=len(code), data_bytes=len(data), rom_words=ROM_WORDS,
                    ram_base=RAM_BASE, ram_bytes=RAM_BYTES, symbols=symbols,
                    retire_count=len(outcome["trace"]), mem_access_count=len(outcome["accesses"]),
                    loads=sum(not r["is_write"] for r in outcome["accesses"]),
                    stores=sum(r["is_write"] for r in outcome["accesses"]),
                    halt_pc=outcome["halt_pc"], halt_instr=STOP, coverage=outcome["coverage"],
                    high_level=high, oracle_selftests=checks,
                    notes=["EBREAK is an unimplemented stop, not a Trap implementation", "initial RAM includes zero-filled BSS", "all accesses use natural alignment inside 0x10000..0x13fff", "raw D rdata is the aligned 32-bit word before the access", "MEM request addresses are original byte addresses; store lanes are shifted"])
    (output / "meta.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    (output / "meta.vh").write_text(f"`define CPU5_RAM_RETIRE_COUNT {metadata['retire_count']}\n`define CPU5_RAM_ACCESS_COUNT {metadata['mem_access_count']}\n`define CPU5_RAM_HALT_PC 32'h{metadata['halt_pc']:08x}\n`define CPU5_RAM_HALT_INSTR 32'h{STOP:08x}\n", encoding="ascii")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/cpu5_s5_ram")
    args = parser.parse_args()
    checks, prefix = selftest(), compiler_prefix()
    summaries = []
    for number, seed in enumerate((0x13579bdf, 0x2468ace0)):
        result = build(args.output / f"seed{number}", prefix, seed, checks)
        summaries.append({k: result[k] for k in ("seed", "retire_count", "mem_access_count", "loads", "stores", "code_bytes", "halt_pc", "high_level")})
    (args.output / "oracle_summary.json").write_text(json.dumps(dict(selftests=checks, seeds=summaries), indent=2) + "\n", encoding="utf-8")
    manifest = {str(p.relative_to(args.output)).replace("\\", "/"): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(args.output.glob("seed[01]/*")) if p.is_file()}
    manifest["oracle_summary.json"] = hashlib.sha256((args.output / "oracle_summary.json").read_bytes()).hexdigest()
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(selftests=checks, seeds=[{k: x[k] for k in ("seed", "retire_count", "mem_access_count", "loads", "stores", "code_bytes", "halt_pc")} for x in summaries])))


if __name__ == "__main__":
    main()
