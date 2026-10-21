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
    "rtl/instr_mem.v", "rtl/instr_bus_adapter.v", "rtl/branch_predictor.v", "rtl/if_stage.v",
    "rtl/regfile.v", "rtl/decoder.v", "rtl/alu.v", "rtl/rv32m_unit.v", "rtl/data_mem.v",
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


def validate_coremark_axi_firmware(firmware, cache_mode, root=ROOT, simulation=False, btb_mode="off", backend="axi", isa="rv32i"):
    if isa not in {"rv32i", "rv32im"}:
        raise RuntimeError("Select a known CoreMark instruction set")
    if backend not in {"axi", "bram"}:
        raise RuntimeError("Select a known CoreMark data backend")
    if cache_mode not in {"off", "on"}:
        raise RuntimeError("Select one AXI Cache mode: off or on")
    if btb_mode not in {"off", "on"} or (btb_mode == "on" and cache_mode != "on"):
        raise RuntimeError("BTB on requires the Cache on AXI comparison platform")
    prefix = "coremark_" + ("d0" if backend == "bram" else "axi") + ("_m" if isa == "rv32im" else "") + "_cache_" + cache_mode + ("_btb" if btb_mode == "on" else "") + "_"
    if not firmware.startswith(prefix):
        raise RuntimeError("AXI CoreMark firmware does not match the hardware ISA/Cache/BTB modes")
    profile = firmware[len(prefix):].replace("_", "-")
    allowed = {"smoke", "smoke-validation"} if simulation else {"performance", "validation"}
    if profile not in allowed:
        raise RuntimeError("Select a supported " + ("short simulation" if simulation else "formal board") + " profile")
    name = firmware.removeprefix("coremark_")
    config = root / "programs" / (firmware + "_config.vh")
    report_path = root / "build/coremark" / name / "build_report.json"
    if not config.is_file() or not report_path.is_file():
        raise RuntimeError("Run build_coremark_axi.bat --cache " + cache_mode + " --btb " + btb_mode + " --profile " + profile + " first")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (UnicodeError, ValueError) as error:
        raise RuntimeError("Invalid AXI CoreMark build report") from error
    enabled = int(cache_mode == "on")
    pred_enabled = int(btb_mode == "on")
    predictor_config = (64 << 16) | pred_enabled
    seeds = "validation" if "validation" in profile else "performance"
    expected = {
        "profile": profile, "output_name": name, "cache_mode": cache_mode,
        "platform": ("d0" if backend == "bram" else "axi") + ("-m" if isa == "rv32im" else "") + "-cache-" + cache_mode + ("-btb" if pred_enabled else ""), "formal": not simulation,
        "data_backend": backend, "enable_d0_bram": int(backend == "bram"),
        "data_backend_id": int(backend == "bram"),
        "local_ram_base": "0x00010000", "local_ram_bytes": 16384 if backend == "bram" else 0,
        "clock_hz": 50000000, "tick_hz": 50000000,
        "uart_baud": 5000000 if simulation else 115200,
        "seed_profile": seeds, "rom_bytes": 32768, "ram_bytes": 16384,
        "march": isa, "enable_m": int(isa == "rv32im"), "mabi": "ilp32",
        "optimization": "O2", "contexts": 1, "total_data_size": 2000,
        "timer_source": "64-bit mtime", "core_memory_clock_ratio": "1:1",
        "all_linked_text_checked_rv32i": isa == "rv32i",
        "all_linked_text_checked_rv32im": isa == "rv32im",
        "enable_icache": enabled, "enable_dcache": enabled,
        "enable_branch_pred": pred_enabled, "btb_entries": 64, "btb_mode": btb_mode,
        "stats_schema": 3, "bp_config": f"0x{predictor_config:08x}",
        "cycle_profile_schema": 1,
        "cycle_profile_fields": ["work_other", "ifetch_wait", "data_read_wait",
                                 "data_write_wait", "local_mmio_wait", "redirect_wait"],
        "cycle_profile_counter_bits": 64,
        "cycle_profile_start_bank_offset": "0x100",
        "cycle_profile_stop_bank_offset": "0x140", "stats_window_bytes": 512,
        "btb_direction_counter_bits": 2, "btb_counter_bits": 32,
        "btb_snapshot_words_per_bank": 7,
        "btb_start_bank_offset": "0xc0", "btb_stop_bank_offset": "0xe0",
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
        "COREMARK_ENABLE_M": int(isa == "rv32im"),
        "COREMARK_ENABLE_D0_BRAM": int(backend == "bram"),
        "COREMARK_DATA_BACKEND_ID": int(backend == "bram"),
        "COREMARK_CLOCK_HZ": 50000000,
        "COREMARK_UART_BAUD": expected["uart_baud"],
        "COREMARK_FORMAL": int(not simulation), "COREMARK_CACHE_FLAGS": enabled * 3,
        "COREMARK_TOTAL_DATA_SIZE": 2000,
        "COREMARK_AXI_STATS_BASE": 0x30000000, "COREMARK_AXI_STATS_ID": 0x434d4158,
        "COREMARK_AXI_CACHE_GEOMETRY": 0x02400010,
        "COREMARK_ENABLE_BRANCH_PRED": pred_enabled, "COREMARK_BTB_ENTRIES": 64,
        "COREMARK_AXI_BP_CONFIG": predictor_config, "COREMARK_AXI_STATS_SCHEMA": 3,
        "COREMARK_AXI_CYCLE_PROFILE_SCHEMA": 1, "COREMARK_AXI_CYCLE_PROFILE_FIELDS": 6,
        "COREMARK_AXI_CYCLE_PROFILE_BITS": 64,
        "COREMARK_AXI_CYCLE_PROFILE_START_BANK": 0x100,
        "COREMARK_AXI_CYCLE_PROFILE_STOP_BANK": 0x140,
        "COREMARK_AXI_STATS_WINDOW_BYTES": 512,
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
    parser.add_argument("--btb", choices=["off", "on"], default="off")
    parser.add_argument("--backend", choices=["axi", "bram"], default="axi")
    parser.add_argument("--isa", choices=["rv32i", "rv32im"], default="rv32i")
    parser.add_argument("--simulation", action="store_true")
    args = parser.parse_args()
    _, report = validate_coremark_axi_firmware(args.firmware, args.cache,
                                             simulation=args.simulation, btb_mode=args.btb, backend=args.backend, isa=args.isa)
    print("AXI CoreMark firmware metadata matched: " + str(report))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
