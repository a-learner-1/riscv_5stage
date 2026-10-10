"""Prepare isolated MES50HP machine IRQ firmware; never program hardware."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import build_coremark_images as isa
import build_timer_images as common

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/machine_irq_board_firmware"
HW_BLINK, SIM_BLINK = 25000000, 2000
COMPILE_SOURCES = ["software/start.S", "software/machine_irq_entry.S", "software/machine_irq_board.c"]
SOURCES = COMPILE_SOURCES + [
    "software/machine_irq.h", "software/timer.h", "software/gpio.h", "software/mmio.h", "software/link.ld",
    "tools/build_machine_irq_board_images.py", "tools/machine_irq_contract.py",
    "tools/build_timer_images.py", "tools/build_coremark_images.py", "tools/bin_to_hex.py",
] + ["rtl/" + name for name in (
    "machine_irq_board_top.v", "axi_lite_irq_demo.v", "axi_lite_1x2.v", "axi_lite_ram.v",
    "soc_axi_lite_top.v", "soc_instr_mem.v", "dmem_axi_lite_bridge.v", "board_reset.v",
    "instr_mem.v", "instr_bus_adapter.v", "branch_predictor.v", "if_stage.v", "regfile.v",
    "decoder.v", "alu.v", "data_mem.v", "data_bus_adapter.v", "uart_tx.v", "uart_rx.v",
    "uart_rx_fifo.v", "uart_rx_mmio.v", "gpio_mmio.v", "machine_timer.v", "cpu_top.v",
    "instr_cache.v", "data_cache.v",
)]
SYMBOL_MACROS = {
    "machine_irq_done": "MACHINE_IRQ_DONE", "machine_irq_failed": "MACHINE_IRQ_FAILED",
    "machine_irq_external_count": "MACHINE_IRQ_EXTERNAL_COUNT",
    "machine_irq_software_count": "MACHINE_IRQ_SOFTWARE_COUNT",
    "machine_irq_timer_count": "MACHINE_IRQ_TIMER_COUNT",
    "machine_irq_order": "MACHINE_IRQ_ORDER", "machine_irq_order_count": "MACHINE_IRQ_ORDER_COUNT",
    "machine_irq_log": "MACHINE_IRQ_LOG", "machine_irq_checksum": "MACHINE_IRQ_CHECKSUM",
    "machine_irq_work": "MACHINE_IRQ_WORK", "machine_irq_mask_checks": "MACHINE_IRQ_MASK_CHECKS",
    "machine_irq_blink_cycles": "MACHINE_IRQ_BLINK_CYCLES", "machine_irq_guard": "MACHINE_IRQ_GUARD",
    "machine_irq_entry": "MACHINE_IRQ_ENTRY", "machine_irq_mret": "MACHINE_IRQ_MRET",
    "machine_irq_work_begin": "MACHINE_IRQ_WORK_BEGIN", "machine_irq_work_end": "MACHINE_IRQ_WORK_END",
    "machine_irq_pass": "MACHINE_IRQ_PASS", "tohost": "MACHINE_IRQ_TOHOST",
}


def rel(path):
    return Path(path).relative_to(ROOT).as_posix()


def run(args, log, save=None):
    command = [str(value) for value in args]
    log.write("$ " + subprocess.list2cmdline(command) + "\n")
    log.flush()
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace")
    log.write(result.stdout)
    log.flush()
    if save is not None:
        save.write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Build failed; see " + str(BUILD / "build.log"))
    return result.stdout


def validate_isa(payload):
    """Only supported RV32I/Zicsr CSR forms and MRET may extend base RV32I."""
    if len(payload) % 4:
        raise RuntimeError("Instruction text is not four-byte aligned")
    ordinary = bytearray(payload)
    for offset in range(0, len(payload), 4):
        word = int.from_bytes(payload[offset:offset + 4], "little")
        if (word & 0x7f) != 0x73:
            continue
        funct3, csr = (word >> 12) & 7, word >> 20
        if word != 0x30200073 and not (
                funct3 in (1, 2, 3, 5, 6, 7) and csr in (0x300, 0x304, 0x305, 0x341, 0x342, 0x343, 0x344)):
            raise RuntimeError(f"Unexpected SYSTEM instruction at 0x{offset:08x}")
        ordinary[offset:offset + 4] = (0x00000013).to_bytes(4, "little")
    isa.validate_rv32i(bytes(ordinary))


def build(tool, name, blink_cycles, log):
    stem = BUILD / name
    elf = Path(str(stem) + ".elf")
    flags = ["-march=rv32i_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
             "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0", "-mno-relax",
             "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra", "-Werror",
             "-nostdlib", "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax", "-Wl,-Map," + rel(Path(str(stem) + ".map")),
             f"-DMACHINE_IRQ_BOARD_BLINK_CYCLES={blink_cycles}u"]
    run([tool + "gcc", *flags, *COMPILE_SOURCES, "-lgcc", "-o", rel(elf)], log)
    binaries = {}
    for section in ("text", "data"):
        binary = Path(str(stem) + "_" + section + ".bin")
        run([tool + "objcopy", "-O", "binary", "-j", "." + section, rel(elf), rel(binary)], log)
        binaries[section] = binary.read_bytes()
    validate_isa(binaries["text"])
    run([tool + "objdump", "-d", "-S", rel(elf)], log, Path(str(stem) + ".dump"))
    output = run([tool + "nm", "-n", rel(elf)], log, Path(str(stem) + ".symbols"))
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3 and re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
            symbols[fields[2]] = int(fields[0], 16)
    for symbol in (*SYMBOL_MACROS, "__bss_start", "__bss_end", "__stack_top", "main"):
        if symbol not in symbols:
            raise RuntimeError("Missing symbol: " + symbol)
    if len(binaries["text"]) > 32768 or len(binaries["data"]) > 16384:
        raise RuntimeError("Firmware exceeds ROM32 KiB / RAM16 KiB")
    if symbols["__stack_top"] - symbols["__bss_end"] < 2048:
        raise RuntimeError("Less than 2048 bytes remain for the ISR/foreground stack")
    if symbols["machine_irq_entry"] & 3 or symbols["machine_irq_mret"] & 3:
        raise RuntimeError("Interrupt entry/MRET must be four-byte aligned")
    for symbol in SYMBOL_MACROS:
        if symbol.startswith("machine_irq_") and symbol not in {
                "machine_irq_entry", "machine_irq_mret", "machine_irq_work_begin", "machine_irq_work_end", "machine_irq_pass"}:
            width = 32 if symbol == "machine_irq_order" else 128 if symbol == "machine_irq_log" else 4
            if symbols[symbol] & 3 or not 0x10000 <= symbols[symbol] <= 0x14000 - width:
                raise RuntimeError("Observation symbol is outside/aligned incorrectly in RAM: " + symbol)
    if symbols["tohost"] & 3 or not 0x10000 <= symbols["tohost"] <= 0x13ffc:
        raise RuntimeError("tohost must occupy an aligned RAM word")
    return binaries, symbols


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cross", help="RISC-V GCC executable prefix")
    args = parser.parse_args()
    from machine_irq_contract import validate_machine_irq_board_top
    validate_machine_irq_board_top((ROOT / "rtl/machine_irq_board_top.v").read_text(encoding="utf-8"))
    tool = args.cross or os.environ.get("MACHINE_IRQ_CROSS") or common.prefix()
    BUILD.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    hashes = {name: common.sha256((ROOT / name).read_bytes()) for name in SOURCES}
    with (BUILD / "build.log").open("w", encoding="utf-8") as log:
        compiler = run([tool + "gcc", "--version"], log).splitlines()[0]
        options = ["-march=rv32i_zicsr", "-mabi=ilp32"]
        selected = run([tool + "gcc", *options, "-print-multi-directory"], log).strip()
        available = run([tool + "gcc", "-print-multi-lib"], log).strip()
        entry = next((line for line in available.splitlines() if line.split(";")[0] == selected), "")
        switches = set(entry.split(";", 1)[1].split("@")) if ";" in entry else set()
        if switches not in ({"", "march=rv32i", "mabi=ilp32"}, {"", "march=rv32i_zicsr", "mabi=ilp32"}):
            raise RuntimeError("Machine IRQ requires an explicit RV32I(/Zicsr) ILP32 multilib")
        libgcc = Path(run([tool + "gcc", *options, "-print-libgcc-file-name"], log).strip()).resolve()
        if not libgcc.is_file():
            raise RuntimeError("Selected libgcc does not exist")
        hardware, symbols = build(tool, "machine_irq_board_hw", HW_BLINK, log)
        simulation, sim_symbols = build(tool, "machine_irq_board_sim", SIM_BLINK, log)
        if hardware["text"] != simulation["text"] or symbols != sim_symbols:
            raise RuntimeError("Hardware/simulation instruction binaries or symbols differ")
        offset = symbols["machine_irq_blink_cycles"] - 0x10000
        hw_data, sim_data = bytearray(hardware["data"]), bytearray(simulation["data"])
        if not 0 <= offset <= len(hw_data) - 4 or len(hw_data) != len(sim_data):
            raise RuntimeError("Heartbeat initialization is outside matching RAM images")
        if int.from_bytes(hw_data[offset:offset + 4], "little") != HW_BLINK or \
                int.from_bytes(sim_data[offset:offset + 4], "little") != SIM_BLINK:
            raise RuntimeError("Unexpected heartbeat initialization")
        hw_data[offset:offset + 4] = sim_data[offset:offset + 4] = bytes(4)
        if hw_data != sim_data:
            raise RuntimeError("Simulation RAM differs beyond the heartbeat period")
        for name, digest in hashes.items():
            if common.sha256((ROOT / name).read_bytes()) != digest:
                raise RuntimeError("Source changed during build: " + name)
        common.image(hardware["text"], ROOT / "programs/machine_irq_board.hex", 8192, 0x13)
        common.image(hardware["data"], ROOT / "programs/machine_irq_board_data.hex", 4096, 0)
        common.image(simulation["data"], ROOT / "programs/machine_irq_board_sim_data.hex", 4096, 0)
        header = ["// Generated by tools/build_machine_irq_board_images.py; do not edit.\n"]
        header += [f"`define {macro} 32'h{symbols[name]:08x}\n" for name, macro in SYMBOL_MACROS.items()]
        header += ["`define MACHINE_IRQ_EXPECT_COUNT 32'd8\n",
                   "`define MACHINE_IRQ_EXPECT_CHECKSUM 32'h569ea33c\n"]
        (ROOT / "programs/machine_irq_board_symbols.vh").write_text("".join(header), encoding="ascii")
        images = ["programs/machine_irq_board" + suffix for suffix in (".hex", "_data.hex", "_sim_data.hex", "_symbols.vh")]
        report = {
            "image_kind": "MES50HP machine IRQ board", "compiler": compiler,
            "march": "rv32i_zicsr", "mabi": "ilp32", "optimization": "O2",
            "all_linked_text_checked": True, "multilib_selected": selected, "multilib_entry": entry,
            "libgcc_path": str(libgcc), "libgcc_sha256": common.sha256(libgcc.read_bytes()),
            "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
            "requires_ENABLE_EXTERNAL_IRQ": 1, "requires_ENABLE_SOFTWARE_IRQ": 1,
            "requires_ENABLE_ICACHE": 0, "requires_ENABLE_DCACHE": 0, "requires_ENABLE_BRANCH_PRED": 0,
            "external_imem": 1, "external_dmem": 1,
            "clock_hz": 50000000, "uart_baud": 115200, "rom_words": 8192, "ram_words": 4096,
            "reset_hold_cycles": 50000,
            "msip_address": "0x20000050", "external_source_base": "0x30000000",
            "external_source_id": "0x49525131", "external_sync_flops": 2,
            "irq_priority": [11, 3, 7], "expected_order": [11, 3, 7, 11, 3, 11, 3, 7],
            "expected_external_count": 3, "expected_software_count": 3, "expected_timer_count": 2,
            "expected_work": 2048, "expected_checksum": "0x569ea33c", "expected_mask_checks": 3,
            "text_bytes": len(hardware["text"]), "data_bytes": len(hardware["data"]),
            "hardware_blink_cycles": HW_BLINK, "simulation_blink_cycles": SIM_BLINK,
            "instruction_bins_identical": True, "ram_images_differ_only_in_blink_cycles": True,
            "ram_diff_word_index": offset // 4, "sources_sha256": hashes,
            "images_sha256": {name: common.sha256((ROOT / name).read_bytes()) for name in images},
            "symbols": {name: f"0x{value:08x}" for name, value in symbols.items()},
            "pass_uart": "MACHINE IRQ PASS\r\n", "pass_uart_bytes": 18,
            "fail_uart": "MACHINE IRQ FAIL XXXXXXXX\r\n", "fail_uart_bytes": 27,
            "main_never_returns": True, "unexpected_trap_is_fatal": True,
            "verification_status": "pending", "hardware_download_performed": False, "formal_score": False,
        }
        (BUILD / "build_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("Machine IRQ firmware prepared: 50 MHz / 115200, external/software/timer counts 3/3/2")
    print("Compilation does not establish simulation, timing or physical board acceptance")


if __name__ == "__main__":
    main()
