"""Prepare independent CoreMark firmware for AXI Cache and BTB comparisons.

This entry never replaces the existing internal-memory CoreMark images and never
programs hardware. A successful firmware build does not establish a score.
"""
import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys

import build_coremark_images as legacy

ROOT = Path(__file__).resolve().parents[1]
# Both entry points live in the same repository; leave the legacy module intact.
if legacy.ROOT != ROOT:
    raise RuntimeError("CoreMark builders must belong to the same repository")
ROM_WORDS, RAM_WORDS, MIN_STACK_BYTES = (
    legacy.ROM_WORDS, legacy.RAM_WORDS, legacy.MIN_STACK_BYTES)
STATS_BASE, STATS_ID, CACHE_GEOMETRY = 0x30000000, 0x434D4158, 0x02400010
STATS_SCHEMA, BTB_ENTRIES = 2, 64
AXI_RAM_WAITS = {name: 0 for name in ("aw", "w", "ar", "b", "r")}
PROFILES = {
    "performance": (115200, 0, True, "performance"),
    "validation": (115200, 0, True, "validation"),
    "smoke": (5000000, 1, False, "performance"),
    "smoke-validation": (5000000, 1, False, "validation"),
    "formal-short": (5000000, 1, True, "performance"),
}
COMPILE_SOURCES = tuple(
    "software/coremark_port/core_portme_axi.c"
    if name == "software/coremark_port/core_portme.c" else name
    for name in legacy.COMPILE_SOURCES)
AXI_SYMBOL_MACROS = {
    "coremark_axi_stats_valid": "COREMARK_AXI_STATS_VALID_ADDR",
    "coremark_axi_mode_seen": "COREMARK_AXI_MODE_SEEN_ADDR",
    "coremark_axi_btb_mode_seen": "COREMARK_AXI_BTB_MODE_SEEN_ADDR",
    "coremark_axi_platform_failed": "COREMARK_AXI_PLATFORM_FAILED_ADDR",
    "coremark_axi_cycle_delta": "COREMARK_AXI_CYCLE_DELTA_ADDR",
    "coremark_axi_instret_delta": "COREMARK_AXI_INSTRET_DELTA_ADDR",
    "coremark_axi_icache_delta": "COREMARK_AXI_ICACHE_DELTA_ADDR",
    "coremark_axi_dcache_delta": "COREMARK_AXI_DCACHE_DELTA_ADDR",
    "coremark_axi_btb_delta": "COREMARK_AXI_BTB_DELTA_ADDR",
}
AXI_SYMBOL_BYTES = {
    "coremark_axi_stats_valid": 4, "coremark_axi_mode_seen": 4,
    "coremark_axi_btb_mode_seen": 4,
    "coremark_axi_platform_failed": 4,
    "coremark_axi_cycle_delta": 8, "coremark_axi_instret_delta": 8,
    "coremark_axi_icache_delta": 20, "coremark_axi_dcache_delta": 28,
    "coremark_axi_btb_delta": 28,
}
HARDWARE_SOURCES = tuple("rtl/" + name for name in (
    "instr_mem.v", "instr_bus_adapter.v", "branch_predictor.v", "if_stage.v", "regfile.v",
    "decoder.v", "alu.v", "data_mem.v", "data_bus_adapter.v", "uart_tx.v",
    "uart_rx.v", "uart_rx_fifo.v", "uart_rx_mmio.v", "gpio_mmio.v",
    "machine_timer.v", "cpu_top.v", "board_reset.v", "soc_instr_mem.v",
    "dmem_axi_lite_bridge.v", "axi_lite_ram.v", "soc_axi_lite_top.v",
    "instr_cache.v", "data_cache.v", "axi_lite_1x2.v",
    "axi_lite_coremark_stats.v", "soc_coremark_axi_top.v",
    "coremark_axi_board_top.v"))
# The wrapper includes the legacy C port; it must be hashed despite not being
# listed as a separate GCC translation unit. Contract guards can reuse this set.
INPUT_SOURCES = tuple(sorted(set(COMPILE_SOURCES + HARDWARE_SOURCES + (
    "software/coremark_port/core_portme.c",
    "software/coremark_port/core_portme.h",
    "software/coremark_port/coremark_axi_stats.h",
    "software/link.ld", "software/mmio.h", "software/timer.h",
    "tools/build_coremark_images.py", "tools/build_coremark_axi_images.py",
    "tools/coremark_axi_contract.py", "tools/bin_to_hex.py"))))


@dataclass(frozen=True)
class BuildConfig(legacy.BuildConfig):
    cache_mode: str
    btb_mode: str = "off"


def output_name(cache_mode, btb_mode, profile):
    return ("axi_cache_" + cache_mode + ("_btb" if btb_mode == "on" else "") +
            "_" + profile.replace("-", "_"))


def bp_config(config):
    return (BTB_ENTRIES << 16) | int(config.btb_mode == "on")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--cache", choices=("off", "on", "both"), default="both")
    parser.add_argument("--btb", choices=("off", "on"), default="off",
                        help="BTB on requires --cache on; the original Cache comparison defaults to BTB off")
    parser.add_argument("--compare", choices=("all",),
                        help="Build Cache off/BTB off, Cache on/BTB off and Cache on/BTB on with identical run options")
    parser.add_argument("--profile", choices=PROFILES, default="performance")
    parser.add_argument("--iterations", type=int,
                        help="0 selects formal automatic calibration; otherwise 1..2147483647")
    parser.add_argument("--cross", help="RISC-V executable prefix, including its final dash")
    tokens = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(tokens)
    if args.compare and any(token.split("=", 1)[0] in {"--cache", "--btb"} for token in tokens):
        parser.error("--compare all owns all three configurations; omit --cache and --btb")
    if not args.compare and args.btb == "on" and args.cache != "on":
        parser.error("--btb on requires --cache on")
    baud, iterations, formal, seeds = PROFILES[args.profile]
    iterations = iterations if args.iterations is None else args.iterations
    if not 0 <= iterations <= 0x7fffffff:
        parser.error("--iterations must fit the nonnegative signed 32-bit seed4")
    if iterations == 0 and not formal:
        parser.error("--iterations=0 is only allowed for formal profiles")
    modes = (("off", "off"), ("on", "off"), ("on", "on")) if args.compare else tuple(
        (mode, args.btb) for mode in (("off", "on") if args.cache == "both" else (args.cache,)))
    configs = [BuildConfig(
        args.profile, 50000000, baud, iterations, formal, seeds,
        output_name(cache_mode, btb_mode, args.profile), cache_mode, btb_mode)
        for cache_mode, btb_mode in modes]
    return configs, args.cross


def source_files(root=ROOT):
    """Return every fixed input and included port/benchmark header for guards."""
    root = Path(root)
    sources = set(INPUT_SOURCES)
    for directory in (root / "benchmarks/coremark", root / "software/coremark_port"):
        sources.update(path.relative_to(root).as_posix() for path in directory.glob("*.h"))
    return tuple(sorted(sources))


def source_hashes(root=ROOT):
    root = Path(root)
    return {name: legacy.sha256((root / name).read_bytes()) for name in source_files(root)}


def platform_name(config):
    return "axi-cache-" + config.cache_mode + ("-btb" if config.btb_mode == "on" else "")


def memory_location(config):
    cache = ("I-cache 2 KiB 2-way 64 sets 16-byte line; "
             "D-cache 2 KiB 2-way 64 sets 16-byte line, write-through/no-write-allocate"
             if config.cache_mode == "on" else "I-cache disabled; D-cache disabled")
    return ("Static; ROM 32 KiB @0x00000000 via request/response; "
            "RAM 16 KiB @0x00010000 via AXI4-Lite; " + cache +
            ("; BTB 64 entries, 2-bit direction counters" if config.btb_mode == "on" else "; BTB disabled") +
            "; AXI AW/W/AR/B/R waits=0/0/0/0/0; core:memory clock=1:1")


def write_config_header(config, build_dir, version, cflags, ldflags):
    enabled = int(config.cache_mode == "on")
    lines = ["/* Generated by tools/build_coremark_axi_images.py; do not edit. */",
             "#ifndef COREMARK_BUILD_CONFIG_H", "#define COREMARK_BUILD_CONFIG_H",
             f"#define COREMARK_CLOCK_HZ {config.clock_hz}u",
             f"#define COREMARK_UART_BAUD {config.uart_baud}u",
             f"#define COREMARK_FORMAL {int(config.formal)}",
             f"#define COREMARK_BUILD_ITERATIONS {config.iterations}u",
             "#define COREMARK_PROFILE_NAME " + json.dumps(config.profile),
             "#define COREMARK_BUILD_PROFILE COREMARK_PROFILE_NAME",
             "#define COREMARK_PLATFORM_NAME " + json.dumps(platform_name(config)),
             f"#define COREMARK_ENABLE_ICACHE {enabled}",
             f"#define COREMARK_ENABLE_DCACHE {enabled}",
             f"#define COREMARK_ENABLE_BRANCH_PRED {int(config.btb_mode == 'on')}",
             f"#define COREMARK_BTB_ENTRIES {BTB_ENTRIES}",
             f"#define COREMARK_AXI_BP_CONFIG 0x{bp_config(config):08x}u",
             f"#define COREMARK_AXI_STATS_SCHEMA {STATS_SCHEMA}",
             f"#define COREMARK_AXI_STATS_BASE 0x{STATS_BASE:08x}u",
             f"#define COREMARK_AXI_STATS_ID 0x{STATS_ID:08x}u",
             f"#define COREMARK_AXI_CACHE_GEOMETRY 0x{CACHE_GEOMETRY:08x}u",
             "#define COMPILER_VERSION " + json.dumps(version),
             "#define COMPILER_FLAGS " + json.dumps(" ".join(cflags + ldflags + ["-lgcc"])),
             "#define MEM_LOCATION " + json.dumps(memory_location(config)),
             "#endif", ""]
    (build_dir / "coremark_build_config.h").write_text("\n".join(lines), encoding="ascii")


def write_verilog_config(config, symbols):
    # Keep the legacy observation macros/CRC table and add AXI-only symbols.
    path = legacy.write_verilog_config(config, symbols)
    text = path.read_text(encoding="ascii").replace(
        "Generated by tools/build_coremark_images.py", "Generated by tools/build_coremark_axi_images.py", 1)
    enabled = int(config.cache_mode == "on")
    lines = [text,
             f'`define COREMARK_PLATFORM "{platform_name(config)}"\n',
             f"`define COREMARK_CACHE_FLAGS 32'd{3 if enabled else 0}\n",
             f"`define COREMARK_ENABLE_BRANCH_PRED {int(config.btb_mode == 'on')}\n",
             f"`define COREMARK_BTB_ENTRIES {BTB_ENTRIES}\n",
             f"`define COREMARK_AXI_BP_CONFIG 32'h{bp_config(config):08x}\n",
             f"`define COREMARK_AXI_STATS_SCHEMA 32'd{STATS_SCHEMA}\n",
             f"`define COREMARK_AXI_STATS_BASE 32'h{STATS_BASE:08x}\n",
             f"`define COREMARK_AXI_STATS_ID 32'h{STATS_ID:08x}\n",
             f"`define COREMARK_AXI_CACHE_GEOMETRY 32'h{CACHE_GEOMETRY:08x}\n"]
    for name, macro in AXI_SYMBOL_MACROS.items():
        lines.append(f"`define {macro} 32'h{symbols[name]:08x}\n")
    path.write_text("".join(lines), encoding="ascii")
    return path


def build(config, cross=None):
    if config.cache_mode not in ("off", "on"):
        raise RuntimeError("One firmware build requires cache_mode off or on")
    if config.btb_mode not in ("off", "on") or (config.btb_mode == "on" and config.cache_mode != "on"):
        raise RuntimeError("BTB on is supported only by the Cache on comparison platform")
    expected_name = output_name(config.cache_mode, config.btb_mode, config.profile)
    if config.profile not in PROFILES or config.name != expected_name or config.clock_hz != 50000000:
        raise RuntimeError("CoreMark AXI output name/profile/clock violates the fixed comparison contract")
    expected_baud, _, expected_formal, expected_seeds = PROFILES[config.profile]
    if (config.uart_baud != expected_baud or config.formal != expected_formal or
            config.seeds != expected_seeds or not 0 <= config.iterations <= 0x7fffffff or
            (config.iterations == 0 and not config.formal)):
        raise RuntimeError("CoreMark AXI mode/baud/seed/iterations violate the comparison contract")
    build_dir = ROOT / "build/coremark" / config.name
    build_dir.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    tool = legacy.prefix(cross)
    commands, inputs = [], source_hashes()
    with (build_dir / "build.log").open("w", encoding="utf-8") as log:
        version = legacy.run([tool + "gcc", "--version"], log, commands).strip()
        options = ["-march=rv32i", "-mabi=ilp32"]
        selected = legacy.run([tool + "gcc", *options, "-print-multi-directory"], log, commands).strip()
        available = legacy.run([tool + "gcc", "-print-multi-lib"], log, commands).strip()
        entry = next((line for line in available.splitlines() if line.split(";")[0] == selected), "")
        switches = set(entry.split(";", 1)[1].split("@")) if ";" in entry else set()
        if switches != {"", "march=rv32i", "mabi=ilp32"}:
            raise RuntimeError("GCC must select an explicit rv32i/ilp32 multilib; selected " + selected)
        libgcc = Path(legacy.run([tool + "gcc", *options, "-print-libgcc-file-name"],
                                 log, commands).strip()).resolve()
        if not libgcc.is_file():
            raise RuntimeError("Selected libgcc does not exist: " + str(libgcc))
        tool_files = {name: legacy.executable_path(tool + name)
                      for name in ("gcc", "objcopy", "objdump", "nm", "size")}
        for name in ("cc1", "as", "ld"):
            path = legacy.run([tool + "gcc", "-print-prog-name=" + name], log, commands).strip()
            tool_files[name] = legacy.executable_path(path)
        cflags, ldflags = legacy.compiler_flags(config, build_dir), legacy.linker_flags(build_dir)
        write_config_header(config, build_dir, version.splitlines()[0], cflags, ldflags)
        header = build_dir / "coremark_build_config.h"
        inputs[legacy.rel(header)] = legacy.sha256(header.read_bytes())
        elf = build_dir / "coremark.elf"
        legacy.run([tool + "gcc", *cflags, *ldflags, *COMPILE_SOURCES,
                    "-lgcc", "-o", legacy.rel(elf)], log, commands)
        binaries = {}
        for section in ("text", "data"):
            target = build_dir / ("coremark_" + section + ".bin")
            legacy.run([tool + "objcopy", "-O", "binary", "-j", "." + section,
                        legacy.rel(elf), legacy.rel(target)], log, commands)
            binaries[section] = target.read_bytes()
        legacy.run([tool + "objdump", "-d", "-S", legacy.rel(elf)],
                   log, commands, build_dir / "coremark.dump")
        size_output = legacy.run([tool + "size", legacy.rel(elf)], log, commands)
        output = legacy.run([tool + "nm", "-n", legacy.rel(elf)],
                            log, commands, build_dir / "coremark.symbols")
        symbols = {}
        for line in output.splitlines():
            fields = line.split()
            if len(fields) == 3 and re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
                symbols[fields[2]] = int(fields[0], 16)
        for name in (*legacy.SYMBOL_MACROS, *AXI_SYMBOL_MACROS,
                     "_start", "main", "__bss_start", "__bss_end", "__stack_top"):
            if name not in symbols:
                raise RuntimeError("Missing expected symbol: " + name)
        headroom = symbols["__stack_top"] - symbols["__bss_end"]
        if headroom < MIN_STACK_BYTES:
            raise RuntimeError(f"Only {headroom} bytes of stack headroom; require {MIN_STACK_BYTES}")
        if len(binaries["text"]) > ROM_WORDS * 4 or len(binaries["data"]) > RAM_WORDS * 4:
            raise RuntimeError("CoreMark AXI image exceeds physical ROM/RAM")
        for name in legacy.SYMBOL_MACROS:
            width = 8 if name in ("start_ticks", "stop_ticks", "coremark_elapsed_ticks") else 4
            if symbols[name] % 4 or not 0x10000 <= symbols[name] <= 0x14000 - width:
                raise RuntimeError("Observation symbol is outside/aligned incorrectly in RAM: " + name)
        for name, width in AXI_SYMBOL_BYTES.items():
            if symbols[name] % 4 or not 0x10000 <= symbols[name] <= 0x14000 - width:
                raise RuntimeError("AXI observation symbol is outside/aligned incorrectly in RAM: " + name)
        legacy.validate_rv32i(binaries["text"])
        for name, digest in inputs.items():
            if legacy.sha256((ROOT / name).read_bytes()) != digest:
                raise RuntimeError("Build input changed during compilation: " + name)
        stem = "coremark_" + config.name
        images = [ROOT / "programs" / (stem + ".hex"),
                  ROOT / "programs" / (stem + "_data.hex")]
        legacy.image(binaries["text"], images[0], ROM_WORDS, 0x13)
        legacy.image(binaries["data"], images[1], RAM_WORDS, 0)
        images.append(write_verilog_config(config, symbols))
        enabled = int(config.cache_mode == "on")
        report = {
            "profile": config.profile, "output_name": config.name, "formal": config.formal,
            "configured_iterations": config.iterations, "automatic_iterations": config.iterations == 0,
            "seed_profile": config.seeds, "total_data_size": 2000, "contexts": 1,
            "clock_hz": config.clock_hz, "tick_hz": config.clock_hz, "uart_baud": config.uart_baud,
            "compiler": version.splitlines()[0], "compiler_version_full": version,
            "compiler_flags": cflags, "linker_flags": ldflags, "linked_libraries": ["-lgcc"],
            "march": "rv32i", "mabi": "ilp32", "optimization": "O2",
            "multilib_selected": selected, "multilib_entry": entry, "multilib_available": available,
            "libgcc_path": str(libgcc), "libgcc_sha256": legacy.sha256(libgcc.read_bytes()),
            "tools": {name: {"path": str(path), "sha256": legacy.sha256(path.read_bytes())}
                      for name, path in tool_files.items()},
            "memory_location": memory_location(config),
            "rom_bytes": ROM_WORDS * 4, "ram_bytes": RAM_WORDS * 4,
            "cache": bool(enabled), "core_memory_clock_ratio": "1:1", "timer_source": "64-bit mtime",
            "platform": platform_name(config), "cache_mode": config.cache_mode,
            "enable_icache": enabled, "enable_dcache": enabled,
            "enable_branch_pred": int(config.btb_mode == "on"), "btb_entries": BTB_ENTRIES,
            "btb_mode": config.btb_mode, "stats_schema": STATS_SCHEMA,
            "bp_config": f"0x{bp_config(config):08x}",
            "btb_direction_counter_bits": 2,
            "btb_counter_bits": 32, "btb_snapshot_words_per_bank": 7,
            "btb_start_bank_offset": "0xc0", "btb_stop_bank_offset": "0xe0",
            "external_imem": 1, "external_dmem": 1,
            "axi_ram_waits": dict(AXI_RAM_WAITS),
            "stats_base": f"0x{STATS_BASE:08x}", "stats_id": f"0x{STATS_ID:08x}",
            "stats_geometry": f"0x{CACHE_GEOMETRY:08x}",
            "cache_policy": "write-through,no-write-allocate",
            "counter_window": "start-before-mtime,stop-after-mtime",
            "counter_snapshot_source": "64-bit CPU cycle_count/instret_count; 32-bit I/D/BTB counters frozen by the same START/STOP read",
            "text_bytes": len(binaries["text"]), "data_bytes": len(binaries["data"]),
            "bss_bytes": symbols["__bss_end"] - symbols["__bss_start"],
            "stack_headroom_bytes": headroom, "minimum_stack_headroom_bytes": MIN_STACK_BYTES,
            "all_linked_text_checked_rv32i": True, "size_output": size_output.strip(),
            "text_sha256": legacy.sha256(binaries["text"]), "data_sha256": legacy.sha256(binaries["data"]),
            "sources_sha256": inputs,
            "images_sha256": {legacy.rel(path): legacy.sha256(path.read_bytes()) for path in images},
            "elf_sha256": legacy.sha256(elf.read_bytes()),
            "map_sha256": legacy.sha256((build_dir / "coremark.map").read_bytes()),
            "symbols": {name: f"0x{address:08x}" for name, address in sorted(symbols.items())},
            "expected_crc": {name: f"0x{value:04x}" for name, value in legacy.EXPECTED_CRCS[config.seeds].items()},
            "commands": commands, "working_directory": str(ROOT),
            "hardware_download_performed": False, "formal_score_measured": False,
        }
        report_text = json.dumps(report, indent=2) + "\n"
        (build_dir / "build_report.json").write_text(report_text, encoding="utf-8")
        log.write(report_text)
    return report


def main(argv=None):
    configs, cross = parse_args(argv)
    for config in configs:
        report = build(config, cross)
        print(f"CoreMark AXI Cache {config.cache_mode}, BTB {config.btb_mode}, {config.profile}: "
              f"{report['text_bytes']} text bytes, {report['data_bytes']} data bytes, "
              f"{report['stack_headroom_bytes']} stack headroom")
        print(f"{config.clock_hz} Hz / UART {config.uart_baud}; "
              f"iterations={config.iterations}; formal={int(config.formal)}")
        print("Generated programs/coremark_" + config.name + ".hex and matching data/config")
    print("Firmware compiled only; no simulation, PDS, board acceptance or score has been performed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
