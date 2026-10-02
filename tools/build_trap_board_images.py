"""Build one trap board ROM and hardware/simulation initialized RAM images."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "trap_board_firmware"
FALLBACK = Path("D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/"
                "xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")
HW_BLINK_CYCLES = 25000000
SIM_BLINK_CYCLES = 2000
RAM_BASE = 0x10000
SYMBOL_MACROS = {
    "trap_entry": "TRAP_BOARD_ENTRY",
    "trap_board_ecall": "TRAP_BOARD_ECALL",
    "trap_board_ebreak": "TRAP_BOARD_EBREAK",
    "trap_board_illegal": "TRAP_BOARD_ILLEGAL",
    "trap_board_badcsr": "TRAP_BOARD_BADCSR",
    "trap_board_count": "TRAP_BOARD_COUNT",
    "trap_board_log": "TRAP_BOARD_LOG",
    "trap_board_resumed": "TRAP_BOARD_RESUMED",
    "ram_guard": "TRAP_BOARD_RAM_GUARD",
    "blink_cycles": "TRAP_BOARD_BLINK_CYCLES",
}
SOURCE_FILES = ["software/start.S", "software/trap_entry.S", "software/trap_board.c",
                "software/gpio.h", "software/mmio.h", "software/link.ld",
                "tools/build_trap_board_images.py"]


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def find_prefix():
    configured = (os.environ.get("TRAP_BOARD_CROSS") or os.environ.get("TRAP_CROSS")
                  or os.environ.get("BOARD_CROSS"))
    if configured:
        return configured
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler.rsplit("gcc", 1)[0]
    if Path(str(FALLBACK) + "gcc.exe").is_file():
        return str(FALLBACK)
    raise RuntimeError("RISC-V GCC missing: set TRAP_BOARD_CROSS or add GCC to PATH")


def rel(path):
    # Relative arguments support a non-ASCII project directory with GCC.
    return Path(path).relative_to(ROOT).as_posix()


def run(args, log, save=None):
    command = [str(value) for value in args]
    log.write("$ " + subprocess.list2cmdline(command) + "\n")
    log.flush()
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")
    log.write(result.stdout)
    log.flush()
    if save is not None:
        save.write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Build failed; see " + str(BUILD / "build.log"))
    return result.stdout


def image(payload, target, words, fill):
    if len(payload) > words * 4:
        raise RuntimeError("Image overflow: " + str(target))
    padded = payload + b"\0" * (-len(payload) % 4)
    data = [int.from_bytes(padded[index:index + 4], "little")
            for index in range(0, len(padded), 4)]
    data += [fill] * (words - len(data))
    target.write_text("".join(f"{word:08x}\n" for word in data), encoding="ascii")


def build_variant(tool, variant, blink, log):
    stem = BUILD / ("trap_board_" + variant)
    elf = Path(str(stem) + ".elf")
    flags = ["-march=rv32i_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fno-pic",
             "-msmall-data-limit=0", "-mno-relax", "-ffunction-sections",
             "-fdata-sections", "-Wall", "-Wextra", "-Werror", "-nostdlib",
             "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax",
             "-Wl,-Map," + rel(Path(str(stem) + ".map"))]
    run([tool + "gcc", *flags, f"-DTRAP_BOARD_BLINK_CYCLES={blink}u",
         "software/start.S", "software/trap_entry.S", "software/trap_board.c",
         "-lgcc", "-o", rel(elf)], log)
    binaries = {}
    for section in ("text", "data"):
        binary = Path(str(stem) + "_" + section + ".bin")
        run([tool + "objcopy", "-O", "binary", "-j", "." + section,
             rel(elf), rel(binary)], log)
        binaries[section] = binary.read_bytes()
    run([tool + "objdump", "-d", "-S", rel(elf)], log,
        Path(str(stem) + ".dump"))
    output = run([tool + "nm", "-n", rel(elf)], log,
                 Path(str(stem) + ".symbols"))
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    for name in (*SYMBOL_MACROS, "__bss_start", "__bss_end", "__stack_top", "main"):
        if name not in symbols:
            raise RuntimeError("Missing symbol: " + name)
    if symbols["trap_entry"] & 3:
        raise RuntimeError("trap_entry must be four-byte aligned")
    if symbols["__bss_end"] > symbols["__stack_top"] - 1024:
        raise RuntimeError("Less than 1024 bytes remain for the main/trap stacks")
    for name in ("trap_board_count", "trap_board_log", "trap_board_resumed"):
        if not symbols["__bss_start"] <= symbols[name] < symbols["__bss_end"]:
            raise RuntimeError(name + " must be cleared by start.S on every reset")
    return binaries, symbols


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    tool = find_prefix()
    source_hashes = {name: sha256((ROOT / name).read_bytes()) for name in SOURCE_FILES}
    with (BUILD / "build.log").open("w", encoding="utf-8") as log:
        compiler_version = run([tool + "gcc", "--version"], log).splitlines()[0]
        hardware, hw_symbols = build_variant(tool, "hw", HW_BLINK_CYCLES, log)
        simulation, sim_symbols = build_variant(tool, "sim", SIM_BLINK_CYCLES, log)
        if hardware["text"] != simulation["text"]:
            raise RuntimeError("Hardware and simulation text binaries differ")
        if hw_symbols != sim_symbols:
            raise RuntimeError("Hardware and simulation ELF symbol addresses differ")
        blink_offset = hw_symbols["blink_cycles"] - RAM_BASE
        if blink_offset < 0 or blink_offset + 4 > len(hardware["data"]):
            raise RuntimeError("blink_cycles is outside initialized RAM")
        hw_data = bytearray(hardware["data"])
        sim_data = bytearray(simulation["data"])
        hw_blink = int.from_bytes(hw_data[blink_offset:blink_offset + 4], "little")
        sim_blink = int.from_bytes(sim_data[blink_offset:blink_offset + 4], "little")
        hw_data[blink_offset:blink_offset + 4] = b"\0" * 4
        sim_data[blink_offset:blink_offset + 4] = b"\0" * 4
        if hw_data != sim_data or hw_blink != HW_BLINK_CYCLES or sim_blink != SIM_BLINK_CYCLES:
            raise RuntimeError("RAM images must differ only in blink_cycles")
        guard_offset = hw_symbols["ram_guard"] - RAM_BASE
        if int.from_bytes(hardware["data"][guard_offset:guard_offset + 4], "little") != 0x12345678:
            raise RuntimeError("ram_guard initialization is wrong")
        for name in SOURCE_FILES:
            if sha256((ROOT / name).read_bytes()) != source_hashes[name]:
                raise RuntimeError("Build source changed during compilation: " + name)

        image(hardware["text"], ROOT / "programs/trap_board.hex", 8192, 0x13)
        image(hardware["data"], ROOT / "programs/trap_board_data.hex", 4096, 0)
        image(simulation["data"], ROOT / "programs/trap_board_sim_data.hex", 4096, 0)
        header = ["// Generated by tools/build_trap_board_images.py; do not edit.\n"]
        for name, macro in SYMBOL_MACROS.items():
            header.append(f"`define {macro} 32'h{hw_symbols[name]:08x}\n")
        (ROOT / "programs/trap_board_symbols.vh").write_text("".join(header), encoding="ascii")
        images = ["programs/trap_board.hex", "programs/trap_board_data.hex",
                  "programs/trap_board_sim_data.hex", "programs/trap_board_symbols.vh"]
        report = {
            "compiler": compiler_version,
            "march": "rv32i_zicsr", "mabi": "ilp32", "optimization": "O2",
            "warning_policy": "Wall Wextra Werror",
            "requires_ENABLE_TRAPS": 1,
            "clock_hz": 50000000, "uart_baud": 115200,
            "rom_words": 8192, "ram_words": 4096, "ram_base": "0x00010000",
            "text_bytes": len(hardware["text"]),
            "initialized_data_bytes": len(hardware["data"]),
            "hardware_blink_cycles": HW_BLINK_CYCLES,
            "simulation_blink_cycles": SIM_BLINK_CYCLES,
            "instruction_bins_identical": True,
            "ram_images_differ_only_in_blink_cycles": True,
            "ram_diff_word_index": blink_offset // 4,
            "text_sha256": sha256(hardware["text"]),
            "hardware_data_sha256": sha256(hardware["data"]),
            "simulation_data_sha256": sha256(simulation["data"]),
            "sources_sha256": source_hashes,
            "images_sha256": {name: sha256((ROOT / name).read_bytes()) for name in images},
            "symbols": {name: f"0x{address:08x}" for name, address in hw_symbols.items()},
            "pass_uart": "TRAP BOARD PASS\r\n", "pass_uart_bytes": 17,
            "fail_uart": "TRAP BOARD FAIL XXXXXXXX\r\n", "fail_uart_bytes": 26,
            "expected_traps": 4, "expected_MRET": 4,
            "reset_clears_software_bss": True,
            "main_never_returns_or_writes_tohost": True,
            "hardware_download_performed": False,
        }
        report_text = json.dumps(report, indent=2) + "\n"
        (BUILD / "build_report.json").write_text(report_text, encoding="utf-8")
        log.write(report_text)
    print("Trap board firmware:", report["text_bytes"], "text bytes,",
          report["initialized_data_bytes"], "data bytes; ROM8192 RAM4096")
    print("Hardware/simulation text identical; only RAM blink_cycles differs")
    print("PASS UART=17 bytes; four synchronous exceptions and four MRET")
    print("Build log/report:", BUILD)


if __name__ == "__main__":
    main()
