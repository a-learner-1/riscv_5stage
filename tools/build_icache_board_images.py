"""Build MES50HP instruction cache hardware and matching fast-heartbeat RAM images."""
import argparse
import json
import re
from pathlib import Path

import build_timer_images as common

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/icache_board_firmware"
HW_BLINK = 25000000
SIM_BLINK = 2000
SOURCES = ["software/start.S", "software/timer_entry.S", "software/icache_board.c",
           "software/icache_workload.S", "software/timer.h", "software/gpio.h", "software/mmio.h", "software/link.ld",
           "tools/build_timer_images.py", "tools/build_icache_board_images.py"]


def build(tool, name, log, c_source="software/timer_irq.c", extra_flags=()):
    stem = BUILD / name
    elf = Path(str(stem) + ".elf")
    flags = ["-march=rv32i_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fno-pic",
             "-msmall-data-limit=0", "-mno-relax", "-ffunction-sections",
             "-fdata-sections", "-Wall", "-Wextra", "-Werror", "-nostdlib",
             "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax",
             "-Wl,-Map," + common.rel(Path(str(stem) + ".map"))]
    common.run([tool + "gcc", *flags, *extra_flags, "software/start.S", "software/timer_entry.S",
         "software/icache_workload.S", c_source, "-lgcc", "-o", common.rel(elf)], log)
    binaries = {}
    for section in ("text", "data"):
        binary = Path(str(stem) + "_" + section + ".bin")
        common.run([tool + "objcopy", "-O", "binary", "-j", "." + section,
             common.rel(elf), common.rel(binary)], log)
        binaries[section] = binary.read_bytes()
    common.run([tool + "objdump", "-d", "-S", common.rel(elf)], log,
        Path(str(stem) + ".dump"))
    output = common.run([tool + "nm", "-n", common.rel(elf)], log,
                 Path(str(stem) + ".symbols"))
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    for name in (*common.SYMBOL_MACROS, "__bss_start", "__bss_end", "__stack_top", "main", "tohost"):
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
    common.BUILD = BUILD
    common.SYMBOL_MACROS = dict(common.SYMBOL_MACROS,
                              timer_irq_blink_cycles="TIMER_IRQ_BLINK_CYCLES",
                              icache_a="ICACHE_A", icache_b="ICACHE_B", icache_c="ICACHE_C",
                              icache_work_result="ICACHE_WORK_RESULT", icache_snapshot="ICACHE_SNAPSHOT")
    source_hashes = {name: common.sha256((ROOT / name).read_bytes()) for name in SOURCES}
    source = (ROOT / "software/icache_board.c").read_text(encoding="utf-8")
    constants = {}
    for name in ("IRQ_COUNT", "IRQ_PERIOD", "WORK_COUNT", "WORK_SEED", "WORK_EXPECT"):
        match = re.search(r"^#define " + name + r" (0x[0-9a-fA-F]+|[0-9]+)u$", source, re.M)
        if not match:
            raise RuntimeError("Missing C constant: " + name)
        constants[name] = int(match.group(1), 0)
    checksum = constants["WORK_SEED"]
    for index in range(constants["WORK_COUNT"]):
        checksum = (((checksum << 5) & 0xffffffff) ^ (checksum >> 2) ^ index) & 0xffffffff
    if checksum != constants["WORK_EXPECT"]:
        raise RuntimeError("Foreground checksum differs from independent calculation")
    tool = common.prefix()
    with (BUILD / "build.log").open("w", encoding="utf-8") as log:
        compiler = common.run([tool + "gcc", "--version"], log).splitlines()[0]
        hardware, symbols = build(tool, "icache_board_hw", log,
            c_source="software/icache_board.c",
            extra_flags=[f"-DICACHE_BOARD_BLINK_CYCLES={HW_BLINK}u"])
        simulation, sim_symbols = build(tool, "icache_board_sim", log,
            c_source="software/icache_board.c",
            extra_flags=[f"-DICACHE_BOARD_BLINK_CYCLES={SIM_BLINK}u"])
        if hardware["text"] != simulation["text"] or symbols != sim_symbols:
            raise RuntimeError("Hardware/simulation instruction binaries or symbols differ")
        addresses=[symbols[name] for name in ('icache_a','icache_b','icache_c')]
        if len({(addr//16)%64 for addr in addresses})!=1 or len({addr//1024 for addr in addresses})!=3:
            raise RuntimeError("Workload functions do not collide in the same cache set")
        offset = symbols["timer_irq_blink_cycles"] - 0x10000
        hw_data, sim_data = bytearray(hardware["data"]), bytearray(simulation["data"])
        if not 0 <= offset <= len(hw_data) - 4:
            raise RuntimeError("Heartbeat period is outside initialized RAM")
        if int.from_bytes(hw_data[offset:offset + 4], "little") != HW_BLINK or \
                int.from_bytes(sim_data[offset:offset + 4], "little") != SIM_BLINK:
            raise RuntimeError("Unexpected heartbeat initialization")
        hw_data[offset:offset + 4] = sim_data[offset:offset + 4] = b"\0" * 4
        if hw_data != sim_data:
            raise RuntimeError("Simulation RAM differs beyond the heartbeat period")
        guard_offset = symbols["timer_irq_guard"] - 0x10000
        if int.from_bytes(hardware["data"][guard_offset:guard_offset + 4], "little") != 0x12345678:
            raise RuntimeError("Wrong initialized RAM guard")
        for name, digest in source_hashes.items():
            if common.sha256((ROOT / name).read_bytes()) != digest:
                raise RuntimeError("Source changed during build: " + name)
        common.image(hardware["text"], ROOT / "programs/icache_board.hex", 8192, 0x13)
        common.image(hardware["data"], ROOT / "programs/icache_board_data.hex", 4096, 0)
        common.image(simulation["data"], ROOT / "programs/icache_board_sim_data.hex", 4096, 0)
        header = ["// Generated by tools/build_icache_board_images.py; do not edit.\n"]
        for name, macro in common.SYMBOL_MACROS.items():
            header.append(f"`define {macro} 32'h{symbols[name]:08x}\n")
        header += [f"`define TIMER_IRQ_EXPECT_COUNT 32'd{constants['IRQ_COUNT']}\n",
                   f"`define TIMER_IRQ_EXPECT_WORK 32'd{constants['WORK_COUNT']}\n",
                   f"`define TIMER_IRQ_EXPECT_CHECKSUM 32'h{checksum:08x}\n",
                   f"`define TIMER_IRQ_PERIOD 32'd{constants['IRQ_PERIOD']}\n"]
        (ROOT / "programs/icache_board_symbols.vh").write_text("".join(header), encoding="ascii")
        images = ["programs/icache_board" + suffix
                  for suffix in (".hex", "_data.hex", "_sim_data.hex", "_symbols.vh")]
        report = {
            "compiler": compiler, "march": "rv32i_zicsr", "mabi": "ilp32", "optimization": "O2",
            "warning_policy": "Wall Wextra Werror", "image_kind": "MES50HP instruction cache board",
            "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
            "requires_ENABLE_ICACHE": 1, "icache_ways": 2, "icache_sets": 64, "icache_line_bytes": 16,
            "clock_hz": 50000000, "uart_baud": 115200, "rom_words": 8192, "ram_words": 4096,
            "text_bytes": len(hardware["text"]), "data_bytes": len(hardware["data"]),
            "expected_irqs": constants["IRQ_COUNT"], "expected_MRET": constants["IRQ_COUNT"],
            "period_ticks": constants["IRQ_PERIOD"], "work_iterations": constants["WORK_COUNT"],
            "work_checksum": f"0x{checksum:08x}", "hardware_blink_cycles": HW_BLINK,
            "simulation_blink_cycles": SIM_BLINK, "instruction_bins_identical": True,
            "ram_images_differ_only_in_blink_cycles": True, "ram_diff_word_index": offset // 4,
            "sources_sha256": source_hashes,
            "images_sha256": {name: common.sha256((ROOT / name).read_bytes()) for name in images},
            "symbols": {name: f"0x{addr:08x}" for name, addr in symbols.items()},
            "pass_uart": "ICACHE PASS\r\n", "pass_uart_bytes": 13,
            "fail_uart": "ICACHE FAIL XXXXXXXX\r\n", "fail_uart_bytes": 22,
            "main_never_returns_or_writes_tohost": True, "hardware_download_performed": False,
        }
        (BUILD / "build_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"I-cache board: {report['text_bytes']} text bytes; 50 MHz / UART115200; ROM32 KiB RAM16 KiB")
    print("Three IRQ/MRET, masked pending, checksum=0x569ea33c; UART: ICACHE PASS")
    print("Hardware/simulation instructions identical; only RAM heartbeat period differs")


if __name__ == "__main__":
    main()
