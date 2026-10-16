"""Build the opt-in MES50HP 64-entry BTB board firmware (verification pending)."""
import argparse
import json
import os
from pathlib import Path
import subprocess

import build_coremark_images as isa
import build_timer_images as common

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/btb_board_firmware"
HW_BLINK = 25000000
SIM_BLINK = 2000
SOURCES = [
    "software/start.S", "software/btb_board_cases.S", "software/btb_board.c",
    "software/timer.h", "software/gpio.h", "software/mmio.h", "software/link_btb.ld",
    "tools/build_timer_images.py", "tools/build_coremark_images.py",
    "tools/build_btb_board_images.py", "rtl/btb_board_top.v",
    "rtl/branch_predictor.v", "rtl/if_stage.v", "rtl/cpu_top.v", "rtl/board_reset.v",
]
SYMBOL_MACROS = {
    "btb_board_failed": "BTB_BOARD_FAILED",
    "btb_board_result": "BTB_BOARD_RESULT",
    "btb_board_done": "BTB_BOARD_DONE",
    "btb_board_blink_cycles": "BTB_BOARD_BLINK_CYCLES",
    "btb_board_baseline": "BTB_BOARD_BASELINE",
    "btb_board_snapshot": "BTB_BOARD_SNAPSHOT",
    "btb_board_cases": "BTB_BOARD_CASES",
    "btb_board_trap_entry": "BTB_BOARD_TRAP_ENTRY",
    "btb_conflict_a": "BTB_CONFLICT_A",
    "btb_conflict_b": "BTB_CONFLICT_B",
    "btb_conflict_a_branch": "BTB_CONFLICT_A_BRANCH",
    "btb_conflict_b_branch": "BTB_CONFLICT_B_BRANCH",
    "tohost": "BTB_BOARD_TOHOST",
}


def rel(path):
    return Path(path).relative_to(ROOT).as_posix()


def run(args, log, save=None):
    # Keep the legacy builder's globals intact; this entry owns its log/cwd.
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


def validate_isa(payload):
    """Validate linked RV32I plus the CSR forms used by the fatal trap path."""
    if len(payload) % 4:
        raise RuntimeError("Instruction text is not four-byte aligned")
    ordinary = bytearray(payload)
    for offset in range(0, len(payload), 4):
        word = int.from_bytes(payload[offset:offset + 4], "little")
        if (word & 0x7f) != 0x73:
            continue
        funct3, csr = (word >> 12) & 7, word >> 20
        rs1 = (word >> 15) & 31
        interrupt_mask = funct3 in (1, 3) and csr in (0x300, 0x304)
        install_mtvec = funct3 == 1 and csr == 0x305
        read_trap = funct3 == 2 and rs1 == 0 and csr in (0x341, 0x342, 0x343)
        # CSRRW/CSRRC mask interrupts, CSRRW installs mtvec, and CSRRS with
        # rs1=x0 reads mepc/mcause/mtval. No ECALL/EBREAK/MRET/WFI is expected.
        if not (interrupt_mask or install_mtvec or read_trap):
            raise RuntimeError(f"Unexpected SYSTEM instruction at 0x{offset:08x}")
        ordinary[offset:offset + 4] = (0x00000013).to_bytes(4, "little")
    isa.validate_rv32i(bytes(ordinary))


def build(tool, name, blink_cycles, log):
    stem = BUILD / name
    elf = Path(str(stem) + ".elf")
    flags = ["-march=rv32i_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fno-pic",
             "-msmall-data-limit=0", "-mno-relax", "-ffunction-sections",
             "-fdata-sections", "-Wall", "-Wextra", "-Werror", "-nostdlib",
             "-nostartfiles", "-static", "-Wl,-T,software/link_btb.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax",
             "-Wl,-Map," + rel(Path(str(stem) + ".map")),
             f"-DBTB_BOARD_BLINK_CYCLES={blink_cycles}u"]
    run([tool + "gcc", *flags, "software/start.S", "software/btb_board_cases.S",
         "software/btb_board.c", "-lgcc", "-o", rel(elf)], log)
    binaries = {}
    for section in ("text", "data"):
        binary = Path(str(stem) + "_" + section + ".bin")
        run([tool + "objcopy", "-O", "binary", "-j", "." + section,
             rel(elf), rel(binary)], log)
        binaries[section] = binary.read_bytes()
    validate_isa(binaries["text"])
    run([tool + "objdump", "-d", "-S", rel(elf)], log, Path(str(stem) + ".dump"))
    output = run([tool + "nm", "-n", rel(elf)], log, Path(str(stem) + ".symbols"))
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 3:
            symbols[fields[2]] = int(fields[0], 16)
    for name in (*SYMBOL_MACROS, "__bss_start", "__bss_end", "__stack_top", "main"):
        if name not in symbols:
            raise RuntimeError("Missing symbol: " + name)
    if len(binaries["text"]) > 32768 or len(binaries["data"]) > 16384:
        raise RuntimeError("Firmware exceeds ROM32 KiB / RAM16 KiB")
    if symbols["__bss_end"] > symbols["__stack_top"] - 1024:
        raise RuntimeError("Less than 1024 bytes remain for the stack")
    if symbols["btb_board_trap_entry"] & 3:
        raise RuntimeError("Trap entry must be four-byte aligned")
    for name in ("btb_board_failed", "btb_board_result", "btb_board_done",
                 "btb_board_baseline", "btb_board_snapshot"):
        width = 32 if name.endswith(("baseline", "snapshot")) else 4
        if not symbols["__bss_start"] <= symbols[name] <= symbols["__bss_end"] - width:
            raise RuntimeError(name + " must be cleared by start.S")
    a, b = (symbols["btb_conflict_" + suffix + "_branch"] for suffix in ("a", "b"))
    if (a & 3) or (b & 3) or ((a >> 2) & 63) != ((b >> 2) & 63) or a == b:
        raise RuntimeError("Conflict branches must have different PCs and the same BTB index")
    for branch in (a, b):
        word = int.from_bytes(binaries["text"][branch:branch + 4], "little")
        if (word & 0x707f) != 0x1063:
            raise RuntimeError("Conflict symbol must point to BNE")
    return binaries, symbols


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cross", help="RISC-V GCC executable prefix")
    args = parser.parse_args()
    tool = args.cross or os.environ.get("BTB_CROSS") or common.prefix()
    BUILD.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    hashes = {name: common.sha256((ROOT / name).read_bytes()) for name in SOURCES}
    with (BUILD / "build.log").open("w", encoding="utf-8") as log:
        compiler = run([tool + "gcc", "--version"], log).splitlines()[0]
        hardware, symbols = build(tool, "btb_board_hw", HW_BLINK, log)
        simulation, sim_symbols = build(tool, "btb_board_sim", SIM_BLINK, log)
        if hardware["text"] != simulation["text"] or symbols != sim_symbols:
            raise RuntimeError("Hardware/simulation instruction binaries or symbols differ")
        offset = symbols["btb_board_blink_cycles"] - 0x10000
        hw_data, sim_data = bytearray(hardware["data"]), bytearray(simulation["data"])
        if not 0 <= offset <= len(hw_data) - 4 or len(hw_data) != len(sim_data):
            raise RuntimeError("Heartbeat initialization is outside matching RAM images")
        if int.from_bytes(hw_data[offset:offset + 4], "little") != HW_BLINK or \
                int.from_bytes(sim_data[offset:offset + 4], "little") != SIM_BLINK:
            raise RuntimeError("Unexpected heartbeat initialization")
        hw_data[offset:offset + 4] = sim_data[offset:offset + 4] = b"\0" * 4
        if hw_data != sim_data:
            raise RuntimeError("Simulation RAM differs beyond the heartbeat period")
        for name, digest in hashes.items():
            if common.sha256((ROOT / name).read_bytes()) != digest:
                raise RuntimeError("Source changed during build: " + name)
        common.image(hardware["text"], ROOT / "programs/btb_board.hex", 8192, 0x13)
        common.image(hardware["data"], ROOT / "programs/btb_board_data.hex", 4096, 0)
        common.image(simulation["data"], ROOT / "programs/btb_board_sim_data.hex", 4096, 0)
        header = ["// Generated by tools/build_btb_board_images.py; do not edit.\n"]
        header += [f"`define {macro} 32'h{symbols[name]:08x}\n"
                   for name, macro in SYMBOL_MACROS.items()]
        header += ["`define BTB_BOARD_EXPECT_CONFIG 32'h00400001\n",
                   "`define BTB_BOARD_EXPECT_RESULT 32'h00000000\n"]
        (ROOT / "programs/btb_board_symbols.vh").write_text("".join(header), encoding="ascii")
        images = ["programs/btb_board" + suffix
                  for suffix in (".hex", "_data.hex", "_sim_data.hex", "_symbols.vh")]
        report = {
            "compiler": compiler, "march": "rv32i_zicsr", "mabi": "ilp32",
            "optimization": "O2", "warning_policy": "Wall Wextra Werror",
            "image_kind": "MES50HP BTB board",
            "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
            "requires_ENABLE_BRANCH_PRED": 1, "btb_entries": 64,
            "branch_counter_bits": 2, "btb_index": "PC[7:2]", "cache_enable": 0,
            "external_imem": 0, "external_dmem": 0,
            "clock_hz": 50000000, "uart_baud": 115200,
            "rom_words": 8192, "ram_words": 4096,
            "text_bytes": len(hardware["text"]), "data_bytes": len(hardware["data"]),
            "hardware_blink_cycles": HW_BLINK, "simulation_blink_cycles": SIM_BLINK,
            "instruction_bins_identical": True, "ram_images_differ_only_in_blink_cycles": True,
            "ram_diff_word_index": offset // 4,
            "sources_sha256": hashes,
            "images_sha256": {name: common.sha256((ROOT / name).read_bytes()) for name in images},
            "symbols": {name: f"0x{address:08x}" for name, address in symbols.items()},
            "expected_case_result": "0x00000000", "expected_config": "0x00400001",
            "counters_base": "0x20000070", "counter_reads_atomic": False,
            "counter_order": ["config", "lookup", "hit", "predicted_taken", "resolved",
                              "mispredict", "direction_error", "target_error"],
            "pass_uart": "BTB BOARD PASS\r\n", "pass_uart_bytes": 16,
            "fail_uart": "BTB BOARD FAIL XXXXXXXX XXXXXXXX\r\n", "fail_uart_bytes": 34,
            "main_never_returns_or_writes_tohost": True,
            "timer_interrupts_enabled_by_firmware": False,
            "unexpected_trap_is_fatal": True,
            "verification_status": "pending", "hardware_download_performed": False,
            "formal_score": False,
        }
        (BUILD / "build_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"BTB board firmware built: {report['text_bytes']} text bytes; 50 MHz / 115200 baud")
    print("64-entry BTB / two-bit branch counters; prepared acceptance, no performance score")
    print("Compilation does not establish simulation or physical board acceptance")


if __name__ == "__main__":
    main()
