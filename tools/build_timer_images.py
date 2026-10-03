"""Build the opt-in machine timer IRQ C demonstration and symbol contract."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "timer_firmware"
FALLBACK = Path("D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/"
                "xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")
SYMBOL_MACROS = {
    "timer_entry": "TIMER_IRQ_ENTRY",
    "timer_irq_handler": "TIMER_IRQ_HANDLER",
    "timer_irq_mret": "TIMER_IRQ_MRET",
    "timer_irq_count": "TIMER_IRQ_COUNT",
    "timer_irq_log": "TIMER_IRQ_LOG",
    "timer_irq_when": "TIMER_IRQ_WHEN",
    "timer_irq_checksum": "TIMER_IRQ_CHECKSUM",
    "timer_irq_work": "TIMER_IRQ_WORK",
    "timer_irq_mask_checks": "TIMER_IRQ_MASK_CHECKS",
    "timer_irq_fail_code": "TIMER_IRQ_FAIL_CODE",
    "timer_irq_guard": "TIMER_IRQ_GUARD",
    "timer_irq_pass": "TIMER_IRQ_PASS",
    "timer_irq_work_begin": "TIMER_IRQ_WORK_BEGIN",
    "timer_irq_work_end": "TIMER_IRQ_WORK_END",
}
SOURCES = ["software/start.S", "software/timer_entry.S", "software/timer_irq.c",
           "software/timer.h", "software/mmio.h", "software/link.ld",
           "tools/build_timer_images.py"]


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def prefix():
    configured = (os.environ.get("TIMER_CROSS") or os.environ.get("TRAP_CROSS")
                  or os.environ.get("BOARD_CROSS"))
    if configured:
        return configured
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler.rsplit("gcc", 1)[0]
    if Path(str(FALLBACK) + "gcc.exe").is_file():
        return str(FALLBACK)
    raise RuntimeError("RISC-V GCC missing: set TIMER_CROSS or add GCC to PATH")


def rel(path):
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


def build(tool, name, log, c_source="software/timer_irq.c", extra_flags=()):
    stem = BUILD / name
    elf = Path(str(stem) + ".elf")
    flags = ["-march=rv32i_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fno-pic",
             "-msmall-data-limit=0", "-mno-relax", "-ffunction-sections",
             "-fdata-sections", "-Wall", "-Wextra", "-Werror", "-nostdlib",
             "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax",
             "-Wl,-Map," + rel(Path(str(stem) + ".map"))]
    run([tool + "gcc", *flags, *extra_flags, "software/start.S", "software/timer_entry.S",
         c_source, "-lgcc", "-o", rel(elf)], log)
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
    for name in (*SYMBOL_MACROS, "__bss_start", "__bss_end", "__stack_top", "main", "tohost"):
        if name not in symbols:
            raise RuntimeError("Missing expected symbol: " + name)
    if symbols["timer_entry"] & 3 or symbols["timer_irq_mret"] & 3:
        raise RuntimeError("Timer entry/MRET must be four-byte aligned")
    if symbols["__bss_end"] > symbols["__stack_top"] - 1024:
        raise RuntimeError("Less than 1024 bytes remain for main and ISR stacks")
    for name in ("timer_irq_count", "timer_irq_log", "timer_irq_when", "timer_irq_checksum",
                 "timer_irq_work", "timer_irq_mask_checks", "timer_irq_fail_code"):
        if not symbols["__bss_start"] <= symbols[name] < symbols["__bss_end"]:
            raise RuntimeError(name + " must be cleared by start.S")
    words = [int.from_bytes(binaries["text"][i:i + 4], "little")
             for i in range(0, len(binaries["text"]), 4)]
    if words[symbols["timer_irq_mret"] // 4] != 0x30200073:
        raise RuntimeError("Timer MRET symbol does not identify MRET")
    if 0x10500073 in words:
        raise RuntimeError("This timer demonstration must not use WFI")
    return binaries, symbols


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    tool = prefix()
    sources_sha = {name: sha256((ROOT / name).read_bytes()) for name in SOURCES}
    c_source = (ROOT / "software/timer_irq.c").read_text(encoding="utf-8")
    constants = {}
    for name in ("IRQ_COUNT", "IRQ_PERIOD", "WORK_COUNT", "WORK_SEED", "WORK_EXPECT"):
        match = re.search(r"^#define " + name + r" (0x[0-9a-fA-F]+|[0-9]+)u$", c_source, re.M)
        if not match:
            raise RuntimeError("Missing plain C constant " + name)
        constants[name] = int(match.group(1), 0)
    checksum = constants["WORK_SEED"]
    for index in range(constants["WORK_COUNT"]):
        checksum = (((checksum << 5) & 0xffffffff) ^ (checksum >> 2) ^ index) & 0xffffffff
    if checksum != constants["WORK_EXPECT"]:
        raise RuntimeError("C checksum expectation differs from independent calculation")
    with (BUILD / "build.log").open("w", encoding="utf-8") as log:
        compiler = run([tool + "gcc", "--version"], log).splitlines()[0]
        binaries, symbols = build(tool, "timer_irq", log)
        repeated, repeated_symbols = build(tool, "timer_irq_determinism", log)
        if binaries != repeated or symbols != repeated_symbols:
            raise RuntimeError("Identical input did not produce identical instruction/data binaries")
        for name, digest in sources_sha.items():
            if sha256((ROOT / name).read_bytes()) != digest:
                raise RuntimeError("Build source changed during compilation: " + name)
        guard_offset = symbols["timer_irq_guard"] - 0x10000
        if int.from_bytes(binaries["data"][guard_offset:guard_offset + 4], "little") != 0x12345678:
            raise RuntimeError("Timer RAM guard initialization is wrong")
        image(binaries["text"], ROOT / "programs/timer_irq.hex", 8192, 0x13)
        image(binaries["data"], ROOT / "programs/timer_irq_data.hex", 4096, 0)
        header = ["// Generated by tools/build_timer_images.py; do not edit.\n"]
        for name, macro in SYMBOL_MACROS.items():
            header.append(f"`define {macro} 32'h{symbols[name]:08x}\n")
        header += [f"`define TIMER_IRQ_EXPECT_COUNT 32'd{constants['IRQ_COUNT']}\n",
                   f"`define TIMER_IRQ_EXPECT_WORK 32'd{constants['WORK_COUNT']}\n",
                   f"`define TIMER_IRQ_EXPECT_CHECKSUM 32'h{checksum:08x}\n",
                   f"`define TIMER_IRQ_PERIOD 32'd{constants['IRQ_PERIOD']}\n",
                   f"`define TIMER_IRQ_TOHOST 32'h{symbols['tohost']:08x}\n"]
        (ROOT / "programs/timer_irq_symbols.vh").write_text("".join(header), encoding="ascii")
        images = ["programs/timer_irq.hex", "programs/timer_irq_data.hex",
                  "programs/timer_irq_symbols.vh"]
        report = {
            "compiler": compiler, "march": "rv32i_zicsr", "mabi": "ilp32",
            "optimization": "O2", "warning_policy": "Wall Wextra Werror",
            "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
            "clock_hz": 100000000, "uart_baud": 5000000,
            "image_kind": "RTL simulation firmware; not the physical board acceptance image",
            "rom_words": 8192, "ram_words": 4096,
            "text_bytes": len(binaries["text"]), "data_bytes": len(binaries["data"]),
            "same_input_two_builds_identical": True,
            "text_sha256": sha256(binaries["text"]),
            "data_sha256": sha256(binaries["data"]),
            "sources_sha256": sources_sha,
            "images_sha256": {name: sha256((ROOT / name).read_bytes()) for name in images},
            "symbols": {name: f"0x{address:08x}" for name, address in symbols.items()},
            "expected_irqs": constants["IRQ_COUNT"], "expected_MRET": constants["IRQ_COUNT"],
            "period_ticks": constants["IRQ_PERIOD"], "work_iterations": constants["WORK_COUNT"],
            "work_checksum": f"0x{checksum:08x}",
            "pass_uart": "TIMER IRQ PASS\r\n", "pass_uart_bytes": 16,
            "handler_returns_original_mepc": True,
            "handler_same_stack_no_nesting": True,
            "timer_compare_write_order": "LO=ffffffff, HI, LO",
            "timer_read_order": "HI, LO, HI; retry if high differs",
            "hardware_download_performed": False,
        }
        report_text = json.dumps(report, indent=2) + "\n"
        (BUILD / "build_report.json").write_text(report_text, encoding="utf-8")
        log.write(report_text)
    print("Timer IRQ demo:", report["text_bytes"], "text bytes,", report["data_bytes"], "data bytes")
    print("ROM8192 RAM4096; two builds identical; checksum", report["work_checksum"])
    print("Three timer IRQ/MRET; PASS UART=16 bytes; both opt-in flags required")


if __name__ == "__main__":
    main()
