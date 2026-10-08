"""Bind dedicated AXI CoreMark firmware metadata to current sources and images."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {"performance", "validation", "smoke", "smoke-validation", "formal-short"}
REQUIRED_SOURCES = {
    "tools/build_coremark_images.py", "tools/build_coremark_axi_images.py",
    "tools/coremark_axi_contract.py", "software/coremark_port/core_portme.c",
    "software/coremark_port/core_portme_axi.c", "software/coremark_port/coremark_axi_stats.h",
    "rtl/axi_lite_coremark_stats.v", "rtl/soc_coremark_axi_top.v",
    "rtl/coremark_axi_board_top.v", "rtl/instr_cache.v", "rtl/data_cache.v",
    "rtl/cpu_top.v", "rtl/soc_axi_lite_top.v", "rtl/soc_instr_mem.v",
    "rtl/dmem_axi_lite_bridge.v", "rtl/axi_lite_ram.v", "rtl/axi_lite_1x2.v",
    "rtl/instr_mem.v", "rtl/instr_bus_adapter.v", "rtl/if_stage.v",
    "rtl/regfile.v", "rtl/decoder.v", "rtl/alu.v", "rtl/data_mem.v",
    "rtl/data_bus_adapter.v", "rtl/uart_tx.v", "rtl/uart_rx.v",
    "rtl/uart_rx_fifo.v", "rtl/uart_rx_mmio.v", "rtl/gpio_mmio.v",
    "rtl/machine_timer.v", "rtl/board_reset.v",
}


def number(text, macro):
    match = re.search(r"(?m)^`define\s+" + re.escape(macro) +
                      r"\s+((?:\d+'[dh])?[0-9a-fA-F]+)\s*$", text)
    if not match:
        raise RuntimeError("Missing or invalid firmware macro " + macro)
    value = match.group(1)
    if "'" in value:
        value = value.split("'", 1)[1]
        return int(value[1:], 16 if value[0] == "h" else 10)
    return int(value, 10)


def checked_hashes(root, mapping, required, label):
    if not isinstance(mapping, dict) or not required.issubset(mapping):
        raise RuntimeError("AXI CoreMark report is missing " + label + " hashes")
    for name, expected in mapping.items():
        if not isinstance(name, str) or not isinstance(expected, str):
            raise RuntimeError("Invalid " + label + " hash entry")
        path = (root / name).resolve()
        if not path.is_relative_to(root.resolve()) or not path.is_file():
            raise RuntimeError("Missing or unsafe " + label + " path: " + name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Stale AXI CoreMark " + label + ": " + name)


def validate_coremark_axi_firmware(firmware, cache_mode, root=ROOT, simulation=False):
    if cache_mode not in {"off", "on"}:
        raise RuntimeError("Select one AXI Cache mode: off or on")
    prefix = "coremark_axi_cache_" + cache_mode + "_"
    if not firmware.startswith(prefix):
        raise RuntimeError("AXI CoreMark firmware does not match the hardware Cache mode")
    profile = firmware[len(prefix):].replace("_", "-")
    allowed = {"smoke", "smoke-validation"} if simulation else {"performance", "validation"}
    if profile not in allowed:
        raise RuntimeError("Select a supported " + ("short simulation" if simulation else "formal board") + " profile")
    name = firmware.removeprefix("coremark_")
    config = root / "programs" / (firmware + "_config.vh")
    report_path = root / "build/coremark" / name / "build_report.json"
    if not config.is_file() or not report_path.is_file():
        raise RuntimeError("Run build_coremark_axi.bat --cache " + cache_mode + " --profile " + profile + " first")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (UnicodeError, ValueError) as error:
        raise RuntimeError("Invalid AXI CoreMark build report") from error
    enabled = int(cache_mode == "on")
    seeds = "validation" if "validation" in profile else "performance"
    expected = {
        "profile": profile, "output_name": name, "cache_mode": cache_mode,
        "platform": "axi-cache-" + cache_mode, "formal": not simulation,
        "clock_hz": 50000000, "tick_hz": 50000000,
        "uart_baud": 5000000 if simulation else 115200,
        "seed_profile": seeds, "rom_bytes": 32768, "ram_bytes": 16384,
        "march": "rv32i", "mabi": "ilp32",
        "optimization": "O2", "contexts": 1, "total_data_size": 2000,
        "timer_source": "64-bit mtime", "core_memory_clock_ratio": "1:1",
        "all_linked_text_checked_rv32i": True,
        "enable_icache": enabled, "enable_dcache": enabled,
        "external_imem": 1, "external_dmem": 1,
        "stats_base": "0x30000000", "stats_id": "0x434d4158",
        "stats_geometry": "0x02400010",
        "axi_ram_waits": {"aw": 0, "w": 0, "ar": 0, "b": 0, "r": 0},
        "cache_policy": "write-through,no-write-allocate",
        "counter_window": "start-before-mtime,stop-after-mtime",
    }
    if not isinstance(report, dict) or any(report.get(k) != v for k, v in expected.items()):
        raise RuntimeError("Incompatible AXI CoreMark clock/profile/Cache/memory metadata")
    text = config.read_text(encoding="ascii")
    for macro, value in {
        "COREMARK_CLOCK_HZ": 50000000,
        "COREMARK_UART_BAUD": expected["uart_baud"],
        "COREMARK_FORMAL": int(not simulation), "COREMARK_CACHE_FLAGS": enabled * 3,
        "COREMARK_TOTAL_DATA_SIZE": 2000,
        "COREMARK_AXI_STATS_BASE": 0x30000000, "COREMARK_AXI_STATS_ID": 0x434d4158,
        "COREMARK_AXI_CACHE_GEOMETRY": 0x02400010,
    }.items():
        if number(text, macro) != value:
            raise RuntimeError("AXI CoreMark firmware macro mismatch: " + macro)
    iterations = number(text, "COREMARK_ITERATIONS")
    if iterations != report.get("configured_iterations") or (simulation and iterations != 1):
        raise RuntimeError("AXI CoreMark iteration metadata mismatch (short self-check needs one iteration)")
    required_sources = REQUIRED_SOURCES | {
        "build/coremark/" + name + "/coremark_build_config.h",
        "software/coremark_port/start_coremark.S", "software/coremark_port/core_portme.h",
        "software/link.ld", "software/mmio.h", "software/timer.h", "tools/bin_to_hex.py",
        "benchmarks/coremark/core_main.c", "benchmarks/coremark/core_list_join.c",
        "benchmarks/coremark/core_matrix.c", "benchmarks/coremark/core_state.c",
        "benchmarks/coremark/core_util.c",
    }
    from build_coremark_axi_images import source_files
    required_sources.update(source_files(root))
    checked_hashes(root, report.get("sources_sha256"), required_sources, "source")
    checked_hashes(root, report.get("images_sha256"), {
        "programs/" + firmware + suffix for suffix in (".hex", "_data.hex", "_config.vh")
    }, "image")
    return config, report_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", required=True)
    parser.add_argument("--cache", choices=["off", "on"], required=True)
    parser.add_argument("--simulation", action="store_true")
    args = parser.parse_args()
    _, report = validate_coremark_axi_firmware(args.firmware, args.cache, simulation=args.simulation)
    print("AXI CoreMark firmware metadata matched: " + str(report))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
