"""Validate the isolated machine IRQ images before simulation or PDS use."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def validate_machine_irq_board_top(text, module_name="machine_irq_board_top"):
    """Check the literal board configuration recorded in the firmware report."""
    header = re.search(r"\bmodule\s+" + re.escape(module_name) + r"\s*#\(\n(.*?)\n\)\s*\(\n", text, re.S)
    if not header:
        raise RuntimeError("Unexpected machine IRQ board module declaration")
    parameters = header.group(1)
    if set(re.findall(r"\bparameter\s+(?:integer\s+)?(\w+)\s*=", parameters)) != {
            "PROGRAM_FILE", "DATA_FILE", "RESET_HOLD_CYCLES"}:
        raise RuntimeError("Machine IRQ board may expose only images and reset delay")
    for name, value in (("PROGRAM_FILE", '"programs/machine_irq_board.hex"'),
                        ("DATA_FILE", '"programs/machine_irq_board_data.hex"'),
                        ("RESET_HOLD_CYCLES", "50000")):
        if len(re.findall(r"\b" + name + r"\s*=\s*" + re.escape(value) + r"(?=\s*(?:,|$))", parameters)) != 1:
            raise RuntimeError("Unexpected machine IRQ board default: " + name)
    instances = {
        "u_soc": ("soc_axi_lite_top", {
            "PROGRAM_FILE": "PROGRAM_FILE", "DATA_FILE": "DATA_FILE",
            "IMEM_WORDS": "8192", "DMEM_WORDS": "4096", "DMEM_BASE_ADDR": "32'h00010000",
            "ENABLE_TRAPS": "1", "ENABLE_TIMER_IRQ": "1", "ENABLE_EXTERNAL_IRQ": "1",
            "ENABLE_SOFTWARE_IRQ": "1", "ENABLE_ICACHE": "0", "ENABLE_DCACHE": "0",
            "ENABLE_BRANCH_PRED": "0", "UART_CLOCK_HZ": "50000000", "UART_BAUD": "115200",
            "SIM_CONSOLE_ECHO": "0",
        }),
        "u_router": ("axi_lite_1x2", {"M0_BASE_ADDR": "32'h00010000", "M0_SIZE_BYTES": "16384",
                                     "M1_BASE_ADDR": "32'h30000000", "M1_SIZE_BYTES": "32'h100"}),
        "u_ram": ("axi_lite_ram", {"WORDS": "4096", "BASE_ADDR": "32'h00010000", "INIT_FILE": "DATA_FILE"}),
        "u_irq_source": ("axi_lite_irq_demo", {"BASE_ADDR": "32'h30000000"}),
        "u_reset": ("board_reset", {"HOLD_CYCLES": "RESET_HOLD_CYCLES"}),
    }
    for instance, (kind, expected) in instances.items():
        matches = re.findall(r"\b" + kind + r"\s*#\((.*?)\)\s+" + instance + r"\s*\(", text, re.S)
        if len(matches) != 1:
            raise RuntimeError("Missing/ambiguous machine IRQ hardware instance: " + instance)
        declared = re.findall(r"\.(\w+)\s*\(\s*([^()]+?)\s*\)", matches[0])
        if len(declared) != len(expected) or dict(declared) != expected:
            raise RuntimeError("Machine IRQ board literal parameter mismatch: " + instance)
    for connection in (r"\.irq\s*\(\s*irq_external\s*\)",
                       r"\.irq_external\s*\(\s*irq_external\s*\)"):
        if len(re.findall(connection, text)) != 1:
            raise RuntimeError("Machine IRQ source/CPU level connection mismatch")


def checked_words(path, count):
    words = path.read_text(encoding="ascii").splitlines()
    if len(words) != count or any(not re.fullmatch(r"[0-9a-fA-F]{8}", word) for word in words):
        raise RuntimeError(path.name + ": expected " + str(count) + " complete hex words")
    return [int(word, 16) for word in words]


def validate_machine_irq_board_firmware(root=ROOT, simulation=False):
    from build_machine_irq_board_images import SOURCES, SYMBOL_MACROS
    root = Path(root).resolve()
    report_path = root / "build/machine_irq_board_firmware/build_report.json"
    if not report_path.is_file():
        raise RuntimeError("Missing machine IRQ firmware metadata; run build_machine_irq_board.bat")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise RuntimeError("Invalid machine IRQ build report") from error
    required = {
        "image_kind": "MES50HP machine IRQ board", "march": "rv32i_zicsr", "mabi": "ilp32",
        "optimization": "O2", "all_linked_text_checked": True,
        "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
        "requires_ENABLE_EXTERNAL_IRQ": 1, "requires_ENABLE_SOFTWARE_IRQ": 1,
        "requires_ENABLE_ICACHE": 0, "requires_ENABLE_DCACHE": 0, "requires_ENABLE_BRANCH_PRED": 0,
        "external_imem": 1, "external_dmem": 1, "clock_hz": 50000000, "uart_baud": 115200,
        "rom_words": 8192, "ram_words": 4096, "reset_hold_cycles": 50000, "hardware_blink_cycles": 25000000,
        "simulation_blink_cycles": 2000, "instruction_bins_identical": True,
        "ram_images_differ_only_in_blink_cycles": True,
        "msip_address": "0x20000050", "external_source_base": "0x30000000",
        "external_source_id": "0x49525131", "external_sync_flops": 2,
        "irq_priority": [11, 3, 7], "expected_order": [11, 3, 7, 11, 3, 11, 3, 7],
        "expected_external_count": 3, "expected_software_count": 3, "expected_timer_count": 2,
        "expected_work": 2048, "expected_checksum": "0x569ea33c", "expected_mask_checks": 3,
        "pass_uart": "MACHINE IRQ PASS\r\n", "pass_uart_bytes": 18,
        "fail_uart": "MACHINE IRQ FAIL XXXXXXXX\r\n", "fail_uart_bytes": 27,
        "main_never_returns": True, "unexpected_trap_is_fatal": True,
        "verification_status": "pending", "hardware_download_performed": False, "formal_score": False,
    }
    if not isinstance(report, dict) or any(type(report.get(k)) is not type(v) or report[k] != v
                                           for k, v in required.items()):
        raise RuntimeError("Machine IRQ report has incompatible IRQ/clock/memory/ISA/heartbeat metadata")
    for key, maximum in (("text_bytes", 32768), ("data_bytes", 16384)):
        if type(report.get(key)) is not int or not 0 < report[key] <= maximum:
            raise RuntimeError("Machine IRQ report has invalid " + key)
    source_hashes, image_hashes = report.get("sources_sha256"), report.get("images_sha256")
    images = ["programs/machine_irq_board" + suffix
              for suffix in (".hex", "_data.hex", "_sim_data.hex", "_symbols.vh")]
    for mapping, expected_names in ((source_hashes, SOURCES), (image_hashes, images)):
        if not isinstance(mapping, dict) or set(mapping) != set(expected_names):
            raise RuntimeError("Machine IRQ report is missing the exact source/image hash set")
        for name in expected_names:
            digest = mapping[name]
            path = (root / name).resolve()
            if not path.is_relative_to(root) or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise RuntimeError("Invalid machine IRQ source/image identity: " + name)
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise RuntimeError("Stale machine IRQ source/image; rebuild firmware: " + name)
    validate_machine_irq_board_top((root / "rtl/machine_irq_board_top.v").read_text(encoding="utf-8"))

    symbols = report.get("symbols")
    if not isinstance(symbols, dict):
        raise RuntimeError("Machine IRQ report is missing ELF symbols")
    addresses = {}
    for name in (*SYMBOL_MACROS, "__bss_start", "__bss_end", "__stack_top", "main"):
        value = symbols.get(name)
        if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{8}", value):
            raise RuntimeError("Missing/invalid machine IRQ ELF symbol: " + name)
        addresses[name] = int(value, 16)
    code_symbols = {"machine_irq_entry", "machine_irq_mret", "machine_irq_work_begin",
                    "machine_irq_work_end", "machine_irq_pass"}
    for name in SYMBOL_MACROS:
        address = addresses[name]
        width = 32 if name == "machine_irq_order" else 128 if name == "machine_irq_log" else 4
        if address & 3 or (name in code_symbols and not 0 <= address < report["text_bytes"]) or \
                (name not in code_symbols and not 0x10000 <= address <= 0x14000 - width):
            raise RuntimeError("Machine IRQ symbol is outside its memory region: " + name)
    if not addresses["machine_irq_work_begin"] < addresses["machine_irq_work_end"]:
        raise RuntimeError("Invalid foreground observation range")
    if not 0x10000 <= addresses["__bss_start"] <= addresses["__bss_end"] <= addresses["__stack_top"] <= 0x14000 or \
            addresses["__stack_top"] - addresses["__bss_end"] < 2048:
        raise RuntimeError("Invalid machine IRQ RAM/stack layout")

    header = (root / images[3]).read_text(encoding="ascii")
    for name, macro in SYMBOL_MACROS.items():
        matches = re.findall(r"(?m)^`define\s+" + macro + r"\s+32'h([0-9a-fA-F]{8})\s*$", header)
        if len(matches) != 1 or int(matches[0], 16) != addresses[name]:
            raise RuntimeError("Machine IRQ symbol header does not match ELF: " + macro)
    for macro, representation in (("MACHINE_IRQ_EXPECT_COUNT", "32'd8"),
                                  ("MACHINE_IRQ_EXPECT_CHECKSUM", "32'h569ea33c")):
        if len(re.findall(r"(?m)^`define\s+" + macro + r"\s+" + re.escape(representation) + r"\s*$", header)) != 1:
            raise RuntimeError("Machine IRQ observation constant mismatch: " + macro)
    checked_words(root / images[0], 8192)
    hardware = checked_words(root / images[1], 4096)
    simulated = checked_words(root / images[2], 4096)
    index = (addresses["machine_irq_blink_cycles"] - 0x10000) // 4
    if type(report.get("ram_diff_word_index")) is not int or report["ram_diff_word_index"] != index or \
            hardware[index] != 25000000 or simulated[index] != 2000:
        raise RuntimeError("Machine IRQ heartbeat RAM initialization mismatch")
    if any(a != b for i, (a, b) in enumerate(zip(hardware, simulated)) if i != index):
        raise RuntimeError("Machine IRQ simulation RAM differs beyond the heartbeat word")
    selected = simulated if simulation else hardware
    expected_blink = 2000 if simulation else 25000000
    if selected[index] != expected_blink:
        raise RuntimeError("Machine IRQ hardware/simulation RAM selection mismatch")
    return report_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulation", action="store_true", help="Check the fast-heartbeat RAM variant")
    args = parser.parse_args()
    report = validate_machine_irq_board_firmware(simulation=args.simulation)
    print("Machine IRQ firmware contract matched: " + str(report))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, UnicodeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
