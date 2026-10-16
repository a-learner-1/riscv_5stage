"""Create/run an isolated MES50HP PDS project; never program any hardware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RTL = ["instr_mem.v", "instr_bus_adapter.v", "branch_predictor.v", "if_stage.v", "regfile.v", "decoder.v", "alu.v",
       "data_mem.v", "data_bus_adapter.v", "uart_tx.v", "uart_rx.v", "uart_rx_fifo.v", "uart_rx_mmio.v",
       "gpio_mmio.v", "machine_timer.v", "cpu_top.v", "board_reset.v"]
COREMARK_AXI_VARIANTS = {"coremark_axi_off": "off", "coremark_axi_on": "on",
                         "coremark_axi_btb": "on"}


def coremark_axi_btb_mode(variant):
    return "on" if variant == "coremark_axi_btb" else "off"


def coremark_axi_firmware_name(variant, profile):
    return ("coremark_axi_cache_" + COREMARK_AXI_VARIANTS[variant] +
            ("_btb" if coremark_axi_btb_mode(variant) == "on" else "") + "_" + profile)


COREMARK_AXI_FIRMWARE = {
    coremark_axi_firmware_name(variant, profile)
    for variant in COREMARK_AXI_VARIANTS for profile in ("performance", "validation")
}


def read_final_sta_report(report, not_before, mtime_tolerance=2):
    """Require a fresh, complete multi-corner STA result."""
    if not report.is_file() or report.stat().st_mtime < not_before - mtime_tolerance:
        raise RuntimeError("Missing or stale final independent STA report")
    final_text = report.read_text(encoding="utf-8", errors="replace")
    timing_rows = re.findall(
        r"clk_50m\s+clk_50m\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)",
        final_text)
    pulse_width_rows = re.findall(
        r"(?m)^\s*clk_50m\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$",
        final_text)
    if ("Design Summary : All Constraints Met." not in final_text or
            len(timing_rows) != 8 or len(pulse_width_rows) != 2 or
            any(float(row[0]) < 0 or float(row[1]) != 0 or
                int(row[2]) != 0 or int(row[3]) == 0
                for row in timing_rows + pulse_width_rows)):
        raise RuntimeError("Final STA failed/incomplete; bitstream not accepted")
    return timing_rows, pulse_width_rows


def read_post_route_timing_report(report, not_before, mtime_tolerance=2):
    """Preserve the router timing gate for either implementation flow."""
    if not report.is_file() or report.stat().st_mtime < not_before - mtime_tolerance:
        raise RuntimeError("Missing or stale post-route timing summary")
    timing_text = report.read_text(encoding="utf-8", errors="replace")
    timing_rows = re.findall(
        r"clk_50m\s+clk_50m\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)",
        timing_text)
    if ("Design Summary : All Constraints Met." not in timing_text or
            len(timing_rows) < 4 or
            any(float(row[0]) < 0 or int(row[2]) != 0 or int(row[3]) == 0
                for row in timing_rows)):
        raise RuntimeError("Post-route timing failed/incomplete; bitstream not accepted")
    return timing_rows


def verify_post_bitstream_timing(build, bit_started):
    """Certify only reports produced by the bitstream generation flow."""
    # -project/-run gen_bit_stream can rerun PNR and STA. Do not reuse the
    # earlier flow's PASS or start another run which might reroute once more.
    router_rows = read_post_route_timing_report(
        build / "place_route/board_top_timing_summary_after_hold_fix.txt", bit_started,
        mtime_tolerance=0)
    try:
        rows, pulse_rows = read_final_sta_report(
            build / "report_timing/board_top.rtr", bit_started, mtime_tolerance=0)
    except RuntimeError as error:
        raise RuntimeError(str(error) +
                           "; require final STA for the bitstream flow before accepting it") from error
    route = build / "place_route/board_top_pnr.adf"
    if not route.is_file() or route.stat().st_mtime < bit_started:
        raise RuntimeError("Missing or stale bitstream route database")
    route_hash = hashlib.sha256(route.read_bytes()).hexdigest()
    return router_rows, rows, pulse_rows, route_hash


def read_bitstream_outputs(build, bit_started):
    """Hash only fresh outputs; never pair an old BIN with a new SBIT."""
    paths = sorted(path for path in (build / "generate_bitstream").glob("board_top.*")
                   if path.suffix in {".sbit", ".bin"})
    if build / "generate_bitstream/board_top.sbit" not in paths:
        raise RuntimeError("PDS did not produce a bitstream")
    if any(path.stat().st_mtime < bit_started for path in paths):
        raise RuntimeError("PDS left a stale bitstream output; bitstream not accepted")
    return {path.relative_to(build).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths}


def bind_machine_irq_board_parameters(top):
    """Fix image/reset parameters; reject changing the dedicated IRQ platform."""
    from machine_irq_contract import validate_machine_irq_board_top
    validate_machine_irq_board_top(top, module_name="board_top")
    match = re.search(r"module board_top #\(\n(.*?)\n\) \(\n", top, re.S)
    if not match:
        raise RuntimeError("Unexpected machine IRQ board parameter declaration")
    parameters = re.sub(r",\n(?=\s*parameter\b)", ";\n", match.group(1))
    parameters = re.sub(r"\bparameter\b", "localparam", parameters) + ";"
    top = top[:match.start()] + "module board_top (\n" + top[match.end():]
    port_end = top.find("\n);\n", match.start())
    if port_end < 0:
        raise RuntimeError("Unexpected machine IRQ board port declaration")
    port_end += len("\n);\n")
    return top[:port_end] + parameters + "\n" + top[port_end:]


def bind_coremark_axi_board_parameters(top, cache_mode, btb_mode="off"):
    """Fix the generated hardware to the verified firmware contract.

    The portable source keeps parameters for simulation. The synthesis copy
    uses localparams so a later PDS parameter override cannot silently turn an
    off/on comparison into a different clock, cache or AXI wait configuration.
    """
    if cache_mode not in {"off", "on"}:
        raise RuntimeError("Unknown CoreMark AXI cache mode: " + str(cache_mode))
    if btb_mode not in {"off", "on"} or (btb_mode == "on" and cache_mode != "on"):
        raise RuntimeError("BTB on requires the Cache on AXI hardware platform")
    match = re.search(r"module board_top #\(\n(.*?)\n\) \(\n", top, re.S)
    if not match:
        raise RuntimeError("Unexpected CoreMark AXI board parameter declaration")
    parameters = match.group(1)
    expected = {
        "ENABLE_ICACHE": 1, "ENABLE_DCACHE": 1,
        "ENABLE_BRANCH_PRED": 0, "BTB_ENTRIES": 64,
        "UART_CLOCK_HZ": 50000000, "UART_BAUD": 115200,
        "RESET_HOLD_CYCLES": 50000,
        "IMEM_REQ_WAIT_CYCLES": 0, "IMEM_RSP_WAIT_CYCLES": 0,
        "MMIO_REQ_WAIT_CYCLES": 0, "MMIO_RSP_WAIT_CYCLES": 0,
        "RAM_AW_WAIT_CYCLES": 0, "RAM_W_WAIT_CYCLES": 0,
        "RAM_AR_WAIT_CYCLES": 0, "RAM_B_WAIT_CYCLES": 0,
        "RAM_R_WAIT_CYCLES": 0,
    }
    for name, default in expected.items():
        value = re.search(r"\b" + name + r"\s*=\s*(\d+)\b", parameters)
        if not value or int(value.group(1)) != default:
            raise RuntimeError("Unexpected CoreMark AXI board default: " + name)
    enable = 1 if cache_mode == "on" else 0
    for name, value in (("ENABLE_ICACHE", enable), ("ENABLE_DCACHE", enable),
                        ("ENABLE_BRANCH_PRED", int(btb_mode == "on")), ("BTB_ENTRIES", 64)):
        parameters, count = re.subn(r"(\b" + name + r"\s*=\s*)\d+\b",
                                   lambda m: m.group(1) + str(value), parameters)
        if count != 1:
            raise RuntimeError("Could not bind CoreMark AXI hardware parameter: " + name)
    # Original header declarations are comma-separated parameter groups.
    # Local declarations require semicolons between those groups.
    parameters = re.sub(r",\n(?=\s*parameter\b)", ";\n", parameters)
    parameters = re.sub(r"\bparameter\b", "localparam", parameters) + ";"
    top = top[:match.start()] + "module board_top (\n" + top[match.end():]
    port_end = top.find("\n);\n", match.start())
    if port_end < 0:
        raise RuntimeError("Unexpected CoreMark AXI board port declaration")
    port_end += len("\n);\n")
    return top[:port_end] + parameters + "\n" + top[port_end:]


def validate_coremark_board_firmware(firmware, root=ROOT):
    """Check clock/mode metadata and bind ROM, RAM and config to one ELF build."""
    profile = firmware.removeprefix("coremark_")
    if profile not in {"performance", "validation"}:
        raise RuntimeError("CoreMark board requires a formal performance/validation image")
    config = root / "programs" / (firmware + "_config.vh")
    report_path = root / "build/coremark" / profile / "build_report.json"
    if not config.is_file() or not report_path.is_file():
        raise RuntimeError("Missing CoreMark build metadata; run build_coremark.bat --profile " + profile)
    config_text = config.read_text(encoding="ascii")
    for macro, expected in (("COREMARK_CLOCK_HZ", 50000000),
                            ("COREMARK_UART_BAUD", 115200), ("COREMARK_FORMAL", 1)):
        match = re.search(r"`define\s+" + macro + r"\s+(?:32'd)?(\d+)\b", config_text)
        if not match or int(match.group(1)) != expected:
            raise RuntimeError("CoreMark board requires " + macro + "=" + str(expected))
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise RuntimeError("Invalid CoreMark build report") from error
    required = {"profile": profile, "output_name": profile, "formal": True,
                "clock_hz": 50000000, "tick_hz": 50000000, "uart_baud": 115200,
                "seed_profile": profile, "rom_bytes": 32768, "ram_bytes": 16384,
                "march": "rv32i", "mabi": "ilp32"}
    if not isinstance(report, dict) or any(report.get(k) != v for k, v in required.items()):
        raise RuntimeError("CoreMark board build report has incompatible clock/mode/memory/profile")
    hashes = report.get("images_sha256", {})
    if not isinstance(hashes, dict):
        raise RuntimeError("CoreMark build report is missing image hashes")
    for path in [root / "programs" / (firmware + suffix) for suffix in (".hex", "_data.hex", "_config.vh")]:
        expected_hash = hashes.get(path.relative_to(root).as_posix())
        if not path.is_file() or not isinstance(expected_hash, str) or \
                hashlib.sha256(path.read_bytes()).hexdigest() != expected_hash:
            raise RuntimeError("CoreMark image/config does not match its ELF build report: " + path.name)
    return config, report_path


def validate_timer_irq_board_firmware(root=ROOT):
    """Reject simulation RAM, wrong opt-in metadata and stale compiled sources."""
    report_path = root / "build/timer_irq_board_firmware/build_report.json"
    if not report_path.is_file():
        raise RuntimeError("Missing timer IRQ board metadata; run build_timer_irq_board.bat")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError) as error:
        raise RuntimeError("Invalid timer IRQ board build report") from error
    required = {"image_kind": "MES50HP timer IRQ board", "clock_hz": 50000000,
                "uart_baud": 115200, "requires_ENABLE_TRAPS": 1,
                "requires_ENABLE_TIMER_IRQ": 1, "rom_words": 8192, "ram_words": 4096,
                "hardware_blink_cycles": 25000000, "march": "rv32i_zicsr", "mabi": "ilp32"}
    if not isinstance(report, dict) or any(report.get(k) != v for k, v in required.items()):
        raise RuntimeError("Timer IRQ board report has incompatible clock/mode/memory")
    hashes = report.get("images_sha256", {})
    sources = report.get("sources_sha256", {})
    if not isinstance(hashes, dict) or not isinstance(sources, dict) or not sources:
        raise RuntimeError("Timer IRQ board report is missing image/source hashes")
    for name in ("programs/timer_irq_board.hex", "programs/timer_irq_board_data.hex"):
        path = root / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != hashes.get(name):
            raise RuntimeError("Timer IRQ board image does not match its ELF build: " + name)
    for name, digest in sources.items():
        path = root / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("Stale timer IRQ board firmware source: " + name)
    return report_path


def validate_icache_board_firmware(root=ROOT):
    from build_icache_board_images import SOURCES
    path=root/'build/icache_board_firmware/build_report.json'
    if not path.is_file():
        raise RuntimeError('Run build_icache_board.bat first')
    report=json.loads(path.read_text(encoding='utf-8'))
    required={'image_kind':'MES50HP instruction cache board','clock_hz':50000000,
              'uart_baud':115200,'requires_ENABLE_ICACHE':1,'requires_ENABLE_TRAPS':1,
              'requires_ENABLE_TIMER_IRQ':1,'icache_ways':2,'icache_sets':64,'icache_line_bytes':16,
              'rom_words':8192,'ram_words':4096,'hardware_blink_cycles':25000000,
              'march':'rv32i_zicsr','mabi':'ilp32'}
    if any(report.get(k)!=v for k,v in required.items()):
        raise RuntimeError('Incompatible I-cache board firmware metadata')
    for name in [*SOURCES,'programs/icache_board.hex','programs/icache_board_data.hex',
                 'programs/icache_board_sim_data.hex','programs/icache_board_symbols.vh']:
        digest=report.get('sources_sha256' if name in SOURCES else 'images_sha256',{}).get(name)
        if not digest or not (root/name).is_file() or hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
            raise RuntimeError('Stale I-cache firmware source/image: '+name)
    return path


def validate_dcache_board_firmware(root=ROOT):
    from build_dcache_board_images import SOURCES
    path=root/'build/dcache_board_firmware/build_report.json'
    if not path.is_file():
        raise RuntimeError('Run build_dcache_board.bat first')
    report=json.loads(path.read_text(encoding='utf-8'))
    required={'image_kind':'MES50HP instruction and data cache board','clock_hz':50000000,
              'uart_baud':115200,'requires_ENABLE_ICACHE':1,'requires_ENABLE_DCACHE':1,
              'requires_ENABLE_TRAPS':1,'requires_ENABLE_TIMER_IRQ':1,
              'icache_ways':2,'icache_sets':64,'icache_line_bytes':16,
              'dcache_ways':2,'dcache_sets':64,'dcache_line_bytes':16,
              'dcache_policy':'write-through/no-write-allocate','rom_words':8192,'ram_words':4096,
              'hardware_blink_cycles':25000000,'march':'rv32i_zicsr','mabi':'ilp32'}
    if any(report.get(k)!=v for k,v in required.items()):
        raise RuntimeError('Incompatible I/D-cache board firmware metadata')
    for name in [*SOURCES,'programs/dcache_board.hex','programs/dcache_board_data.hex',
                 'programs/dcache_board_sim_data.hex','programs/dcache_board_symbols.vh']:
        digest=report.get('sources_sha256' if name in SOURCES else 'images_sha256',{}).get(name)
        if not digest or not (root/name).is_file() or hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
            raise RuntimeError('Stale D-cache firmware source/image: '+name)
    return path

def validate_btb_board_firmware(root=ROOT):
    from build_btb_board_images import SOURCES
    path = root / "build/btb_board_firmware/build_report.json"
    if not path.is_file():
        raise RuntimeError("Run build_btb_board.bat first")
    report = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "image_kind": "MES50HP BTB board", "clock_hz": 50000000, "uart_baud": 115200,
        "requires_ENABLE_BRANCH_PRED": 1, "btb_entries": 64,
        "requires_ENABLE_TRAPS": 1, "requires_ENABLE_TIMER_IRQ": 1,
        "rom_words": 8192, "ram_words": 4096, "hardware_blink_cycles": 25000000,
        "march": "rv32i_zicsr", "mabi": "ilp32",
    }
    if not isinstance(report, dict) or any(report.get(k) != v for k, v in required.items()):
        raise RuntimeError("Incompatible BTB board firmware metadata")
    for name in [*SOURCES, "programs/btb_board.hex", "programs/btb_board_data.hex",
                 "programs/btb_board_sim_data.hex", "programs/btb_board_symbols.vh"]:
        mapping = report.get("sources_sha256" if name in SOURCES else "images_sha256", {})
        if not isinstance(mapping, dict):
            raise RuntimeError("BTB board report is missing source/image hashes")
        source = root / name
        if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != mapping.get(name):
            raise RuntimeError("Stale BTB board source/image: " + name)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["synth", "timing", "bitstream"],
                        default="synth")
    parser.add_argument("--firmware", choices=["board_demo", "uart_rx_echo", "axi_control_board", "trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board", "btb_board",
                                              "coremark_performance", "coremark_validation",
                                              *sorted(COREMARK_AXI_FIRMWARE)],
                        default=None,
                        help="Default board_demo; dedicated variants select matching firmware")
    parser.add_argument("--variant", choices=["default", "data_handshake", "fetch_handshake", "soc", "axi_control_board", "trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board", "btb_board", "coremark_board",
                                             *COREMARK_AXI_VARIANTS],
                        default="default",
                        help="Isolate data/fetch handshake, SoC, AXI control, trap and timer IRQ board builds")
    args = parser.parse_args()
    if args.firmware is None:
        args.firmware = (coremark_axi_firmware_name(args.variant, "performance")
                         if args.variant in COREMARK_AXI_VARIANTS else
                         "coremark_performance" if args.variant == "coremark_board" else
                         args.variant if args.variant in {"axi_control_board", "trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board", "btb_board"} else "board_demo")
    for dedicated in ("axi_control_board", "trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board", "btb_board"):
        if (args.variant == dedicated) != (args.firmware == dedicated):
            parser.error(dedicated + " firmware and variant must be selected together")
    if (args.variant == "coremark_board") != (args.firmware in {"coremark_performance", "coremark_validation"}):
        parser.error("CoreMark firmware requires --variant coremark_board and a formal performance/validation image")
    if (args.variant in COREMARK_AXI_VARIANTS) != (args.firmware in COREMARK_AXI_FIRMWARE):
        parser.error("CoreMark AXI firmware requires --variant coremark_axi_off/on/btb and matching formal firmware")
    if args.variant in COREMARK_AXI_VARIANTS and args.firmware not in {
            coremark_axi_firmware_name(args.variant, profile) for profile in ("performance", "validation")}:
        parser.error("CoreMark AXI Cache/BTB mode does not match the selected firmware")
    coremark_config = None
    coremark_report = None
    if args.variant == "coremark_board":
        # Prevent loading a 100 MHz simulation image into the fixed 50 MHz top.
        coremark_config, coremark_report = validate_coremark_board_firmware(args.firmware)
    if args.variant in COREMARK_AXI_VARIANTS:
        from coremark_axi_contract import validate_coremark_axi_firmware
        coremark_config, coremark_report = validate_coremark_axi_firmware(
            args.firmware, COREMARK_AXI_VARIANTS[args.variant], root=ROOT,
            btb_mode=coremark_axi_btb_mode(args.variant))
    timer_irq_report = (validate_timer_irq_board_firmware()
                        if args.variant == "timer_irq_board" else None)
    icache_report = validate_icache_board_firmware() if args.variant == "icache_board" else None
    dcache_report = validate_dcache_board_firmware() if args.variant == "dcache_board" else None
    btb_report = validate_btb_board_firmware() if args.variant == "btb_board" else None
    machine_irq_report = None
    if args.variant == "machine_irq_board":
        from machine_irq_contract import validate_machine_irq_board_firmware
        machine_irq_report = validate_machine_irq_board_firmware(root=ROOT)
    if not str(ROOT).isascii():
        raise RuntimeError("Use an ASCII project path, e.g. D:/FPGA/riscv_3stage")
    configured = os.environ.get("PDS_SHELL")
    found = configured or shutil.which("pds_shell")
    fallback = Path("D:/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe")
    exe = Path(found) if found else fallback
    if not exe.is_file():
        raise RuntimeError("PDS shell not found; set PDS_SHELL to pds_shell.exe")

    images = [ROOT / "programs" / name for name in
              [args.firmware + ".hex", args.firmware + "_data.hex"]]
    for path, words in zip(images, [8192, 4096]):
        if not path.is_file():
            builder = ("build_coremark_axi.bat --cache " + COREMARK_AXI_VARIANTS[args.variant] +
                       " --btb " + coremark_axi_btb_mode(args.variant) +
                       " --profile " + args.firmware.rsplit("_", 1)[1]
                       if args.variant in COREMARK_AXI_VARIANTS else
                       "build_coremark.bat --profile " + args.firmware.removeprefix("coremark_")
                       if args.variant == "coremark_board" else
                       "build_btb_board.bat" if args.firmware == "btb_board" else
                       "build_dcache_board.bat" if args.firmware == "dcache_board" else
                       "build_icache_board.bat" if args.firmware == "icache_board" else
                       "build_timer_irq_board.bat" if args.firmware == "timer_irq_board" else
                       "build_machine_irq_board.bat" if args.firmware == "machine_irq_board" else
                       "build_trap_board.bat" if args.firmware == "trap_board" else
                       "build_axi_control_board.bat" if args.firmware == "axi_control_board" else
                       "build_board.bat" if args.firmware == "board_demo" else "build_uart_rx.bat")
            raise RuntimeError(f"Missing {path.name}; run {builder}")
        contents = path.read_text(encoding="ascii").splitlines()
        if len(contents) != words or any(not re.fullmatch("[0-9a-fA-F]{8}", w)
                                         for w in contents):
            raise RuntimeError(f"{path.name}: expected {words} complete hex words")

    build_name = ("pds_" + args.firmware if args.variant == "coremark_board" or args.variant in COREMARK_AXI_VARIANTS else
                  "pds_machine_irq_board" if args.variant == "machine_irq_board" else
                  "pds_btb_board" if args.variant == "btb_board" else
                  "pds_dcache_board" if args.variant == "dcache_board" else
                  "pds_icache_board" if args.variant == "icache_board" else
                  "pds_timer_irq_board" if args.variant == "timer_irq_board" else
                  "pds_trap_board" if args.variant == "trap_board" else
                  "pds_axi_control_board" if args.variant == "axi_control_board" else
                  "pds_soc" if args.variant == "soc" else
                  "pds_fetch_handshake" if args.variant == "fetch_handshake" else
                  "pds_data_handshake" if args.variant == "data_handshake" else
                  "pds_board" if args.firmware == "board_demo" else "pds_uart_rx")
    build = ROOT / "build" / build_name
    build.mkdir(parents=True, exist_ok=True)
    # A failed rebuild must not leave an earlier successful manifest in place.
    (build / "build_manifest.json").unlink(missing_ok=True)
    # Generated synthesis-only copy: absolute memory-file paths avoid relying
    # on PDS's working directory. The checked-in RTL stays portable.
    rtl_names = RTL + (["soc_instr_mem.v", "soc_data_mem.v", "soc_top.v"]
                       if args.variant == "soc" else [])
    if args.variant == "axi_control_board":
        rtl_names += ["soc_instr_mem.v", "dmem_axi_lite_bridge.v", "axi_lite_ram.v",
                      "soc_axi_lite_top.v", "axi_lite_1x2.v", "axi_lite_ctrl.v",
                      "soc_axi_control_top.v"]
    if args.variant in {"trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board"} or args.variant in COREMARK_AXI_VARIANTS:
        rtl_names += ["soc_instr_mem.v", "dmem_axi_lite_bridge.v", "axi_lite_ram.v",
                      "soc_axi_lite_top.v"]
    if args.variant == "machine_irq_board":
        rtl_names += ["instr_cache.v", "data_cache.v", "axi_lite_1x2.v", "axi_lite_irq_demo.v"]
    if args.variant == "icache_board":
        rtl_names += ["instr_cache.v", "axi_lite_icache_stats.v", "axi_lite_1x2.v", "soc_icache_stats_top.v"]
    if args.variant == "dcache_board":
        rtl_names += ["instr_cache.v", "data_cache.v", "axi_lite_dcache_stats.v", "axi_lite_1x2.v", "soc_dcache_stats_top.v"]
    if args.variant in COREMARK_AXI_VARIANTS:
        rtl_names += ["instr_cache.v", "data_cache.v", "axi_lite_coremark_stats.v",
                      "axi_lite_1x2.v", "soc_coremark_axi_top.v"]
    top_name = ("coremark_axi_board_top" if args.variant in COREMARK_AXI_VARIANTS else
                "coremark_board_top" if args.variant == "coremark_board" else
                "btb_board_top" if args.variant == "btb_board" else
                "dcache_board_top" if args.variant == "dcache_board" else
                "icache_board_top" if args.variant == "icache_board" else
                "timer_irq_board_top" if args.variant == "timer_irq_board" else
                "machine_irq_board_top" if args.variant == "machine_irq_board" else
                "trap_board_top" if args.variant == "trap_board" else
                "axi_control_board_top" if args.variant == "axi_control_board" else
                "soc_board_top" if args.variant == "soc" else "board_top")
    top_source = ROOT / "rtl" / (top_name + ".v")
    top = top_source.read_text(encoding="utf-8")
    if top_name != "board_top":
        # Keep the PDS root/artifact name board_top for existing pin constraints
        # and the IO-only functional-netlist test. Rename only this build copy.
        marker = "module " + top_name + " #("
        if top.count(marker) != 1:
            raise RuntimeError("Unexpected " + top_name + " module declaration")
        top = top.replace(marker, "module board_top #(")
    if args.variant in COREMARK_AXI_VARIANTS:
        top = bind_coremark_axi_board_parameters(top, COREMARK_AXI_VARIANTS[args.variant],
                                                 coremark_axi_btb_mode(args.variant))
    if args.variant == "machine_irq_board":
        top = bind_machine_irq_board_parameters(top)
    source_firmware = ("coremark_axi_cache_on_performance" if args.variant in COREMARK_AXI_VARIANTS else
                       "coremark_performance" if args.variant == "coremark_board" else
                       args.variant if args.variant in {"axi_control_board", "trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board", "btb_board"} else "board_demo")
    for original, image in zip(
            ["programs/" + source_firmware + ".hex", "programs/" + source_firmware + "_data.hex"], images):
        if top.count(original) != 1:
            raise RuntimeError("Unexpected board_top initialization-file default")
        top = top.replace(original, image.as_posix())
    generated_top = build / "board_top_init_paths.v"
    generated_top.write_text(top, encoding="utf-8")

    def quoted(path):
        return '"' + path.as_posix() + '"'

    commands = ["set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484"]
    commands += ["add_design " + quoted(ROOT / "rtl" / name) for name in rtl_names]
    commands += ["add_design " + quoted(generated_top),
                 "add_constraint -logic -fdc " + quoted(ROOT / "pds/board_top.fdc"),
                 "compile -top_module board_top -loop_limit 10000",
                 # PDS 2022.2-SP6.4 rejects -top_module on this command.
                 # Only synthesizable RTL is added; board_top is the sole root.
                 "synthesize -ads -selected_syn_tool_opt 2"]
    if args.stage in ["timing", "bitstream"]:
        commands += ["dev_map", "pnr", "report_timing"]
    script = build / "board_generated.tcl"
    script.write_text("\n".join(commands) + "\n", encoding="utf-8")
    command = [str(exe), "-file", str(script), "-work_dir", str(build),
               "-project_name", "board_demo"]
    print("PDS target: PGL50H / -6 / FBG484; stage=" + args.stage, flush=True)
    flow_started = time.time()
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    output = result.stdout.decode("utf-8", errors="replace")
    (build / (args.stage + ".log")).write_bytes(result.stdout)
    # Keep full diagnostics on disk; large ADS logs can overwhelm a terminal.
    print("\n".join(output.splitlines()[-45:]))
    if result.returncode != 0 or re.search(r"(?m)^\s*E:\s", output):
        raise RuntimeError(f"PDS failed; inspect {build / (args.stage + '.log')}")
    project = build / "board_demo.pds"
    synthesis_db = build / "synthesize/board_top_syn.adf"
    if (not project.is_file() or not synthesis_db.is_file() or
            synthesis_db.stat().st_mtime < flow_started - 2):
        raise RuntimeError("PDS did not produce the expected project/synthesis database")
    timing_rows = []
    final_timing_rows = []
    pulse_width_rows = []
    if args.stage != "synth":
        timing_report = build / "place_route/board_top_timing_summary_after_hold_fix.txt"
        timing_rows = read_post_route_timing_report(timing_report, flow_started)
        # The router summary and the independent STA report have distinct
        # values. Require both, and record the final report separately.
        final_report = build / "report_timing/board_top.rtr"
        final_timing_rows, pulse_width_rows = read_final_sta_report(final_report, flow_started)
        print("50MHz router and independent STA setup/hold/recovery/removal/pulse-width checks passed.")
    if args.stage == "bitstream":
        # Generate only after verifying timing; this command never downloads.
        # -file starts a NEW project in PDS; a second -file call would discard
        # route state. Set the observed PDS configuration fields in this
        # generated project, then use the documented -project/-run entry point.
        project_text = project.read_text(encoding="utf-8")
        marker = "(_command cmd_gen_bitstream"
        if project_text.count(marker) != 1 or "(_device PGL50H)" not in project_text:
            raise RuntimeError("Unexpected PDS project format/target")
        project_text = project_text.replace(
            marker, marker + "\n"
            "            (_option create_bin_file (_switch ON))\n"
            "            (_option wake_up_clock (_string \"TCK\"))")
        project.write_text(project_text, encoding="utf-8")
        bit_started = time.time()
        bit_result = subprocess.run(
            [str(exe), "-project", str(project), "-run", "gen_bit_stream"],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        bit_output = bit_result.stdout.decode("utf-8", errors="replace")
        (build / "bitstream_generation.log").write_bytes(bit_result.stdout)
        print("\n".join(bit_output.splitlines()[-30:]))
        if bit_result.returncode or re.search(r"(?m)^\s*E:\s", bit_output):
            raise RuntimeError("Bitstream generation failed; inspect its log")
        bitstream_outputs = read_bitstream_outputs(build, bit_started)
        timing_rows, final_timing_rows, pulse_width_rows, final_route_hash = \
            verify_post_bitstream_timing(build, bit_started)
        print("Bitstream-flow router and final independent STA checks passed.")
    manifest = {
        "base_target": "PGL50H-6IFBG484", "clock_hz": 50000000,
        "requested_stage": args.stage, "pds_returncode": result.returncode,
        "firmware": args.firmware,
        "variant": args.variant,
        "enable_branch_pred": 1 if args.variant == "btb_board" else 0,
        "source_top": top_source.relative_to(ROOT).as_posix(),
        "generated_top_module": "board_top",
        "hardware_verified": False,
        "post_route_timing_rows": timing_rows,
        "final_sta_report": "report_timing/board_top.rtr",
        "final_sta_rows": final_timing_rows,
        "final_sta_pulse_width_rows": pulse_width_rows,
        "initialization_files": {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in images
        },
        "sources": {
            p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in [*[ROOT / "rtl" / name for name in rtl_names],
                      top_source, ROOT / "pds/board_top.fdc"]
        },
    }
    if args.stage == "bitstream":
        manifest.update({
            "final_sta_log": "bitstream_generation.log",
            "final_sta_report_sha256": hashlib.sha256(final_report.read_bytes()).hexdigest(),
            "final_sta_route_sha256": final_route_hash,
            "final_sta_from_bitstream_flow": True,
        })
    if args.variant in {"trap_board", "timer_irq_board", "machine_irq_board", "icache_board", "dcache_board", "btb_board"} or args.variant in COREMARK_AXI_VARIANTS:
        manifest.update({
            "enable_traps": 1,
            "pds_shell": str(exe.resolve()),
            "build_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "bitstreams": bitstream_outputs if args.stage == "bitstream" else {},
        })
    if args.variant == "machine_irq_board":
        manifest.update({
            "enable_timer_irq": 1, "enable_external_irq": 1, "enable_software_irq": 1,
            "enable_icache": 0, "enable_dcache": 0, "enable_branch_pred": 0,
            "external_imem": 1, "external_dmem": 1,
            "uart_baud": 115200, "timer_tick_hz": 50000000, "reset_hold_cycles": 50000,
            "instruction_memory_bytes": 32768, "data_memory_bytes": 16384,
            "msip_address": "0x20000050", "external_source_base": "0x30000000",
            "external_source_id": "0x49525131", "external_sync_flops": 2,
            "irq_priority": [11, 3, 7], "expected_irqs": 8, "expected_MRET": 8,
            "expected_external_count": 3, "expected_software_count": 3, "expected_timer_count": 2,
            "expected_order": [11, 3, 7, 11, 3, 11, 3, 7], "expected_mask_checks": 3,
            "pass_uart": "MACHINE IRQ PASS\r\n", "unexpected_trap_is_fatal": True,
            "formal_score_measured": False, "hardware_download_performed": False,
            "verification_status": "pending",
            "generated_top_sha256": hashlib.sha256(generated_top.read_bytes()).hexdigest(),
            "contract_script_sha256": hashlib.sha256((ROOT / "tools/machine_irq_contract.py").read_bytes()).hexdigest(),
            "firmware_build_report": {
                machine_irq_report.relative_to(ROOT).as_posix():
                    hashlib.sha256(machine_irq_report.read_bytes()).hexdigest()
            },
        })
    if args.variant == "btb_board":
        manifest.update({
            "enable_branch_pred": 1, "btb_entries": 64, "direction_counter_bits": 2,
            "predicted_controls": ["conditional branch", "JAL"], "jalr_predicted": False,
            "enable_timer_irq": 1, "software_irq_masked": True,
            "uart_baud": 115200, "timer_tick_hz": 50000000,
            "instruction_memory_bytes": 32768, "data_memory_bytes": 16384,
            "external_imem": 0, "external_dmem": 0, "enable_icache": 0, "enable_dcache": 0,
            "predictor_stats_base": "0x20000070", "predictor_stats_counter_bits": 32,
            "formal_score_measured": False,
            "generated_top_sha256": hashlib.sha256(generated_top.read_bytes()).hexdigest(),
            "firmware_build_report": {
                btb_report.relative_to(ROOT).as_posix(): hashlib.sha256(btb_report.read_bytes()).hexdigest()
            },
        })
    if args.variant == "timer_irq_board":
        manifest.update({
            "enable_timer_irq": 1, "uart_baud": 115200, "timer_tick_hz": 50000000,
            "instruction_memory_bytes": 32768, "data_memory_bytes": 16384,
            "expected_irqs": 3, "expected_MRET": 3,
            "firmware_build_report": {
                timer_irq_report.relative_to(ROOT).as_posix():
                    hashlib.sha256(timer_irq_report.read_bytes()).hexdigest()
            },
        })
    if args.variant == "icache_board":
        manifest.update({
            "enable_timer_irq":1,"enable_icache":1,"uart_baud":115200,
            "icache_ways":2,"icache_sets":64,"icache_line_bytes":16,"icache_bytes":2048,
            "instruction_memory_bytes":32768,"data_memory_bytes":16384,
            "firmware_build_report":{icache_report.relative_to(ROOT).as_posix():
                                      hashlib.sha256(icache_report.read_bytes()).hexdigest()},
        })
    if args.variant == "dcache_board":
        manifest.update({
            "enable_timer_irq":1,"enable_icache":1,"enable_dcache":1,"uart_baud":115200,
            "dcache_ways":2,"dcache_sets":64,"dcache_line_bytes":16,"dcache_bytes":2048,
            "dcache_policy":"write-through/no-write-allocate",
            "instruction_memory_bytes":32768,"data_memory_bytes":16384,
            "firmware_build_report":{dcache_report.relative_to(ROOT).as_posix():
                                      hashlib.sha256(dcache_report.read_bytes()).hexdigest()},
        })
    if args.variant == "coremark_board":
        manifest.update({
            "enable_traps": 1, "enable_timer_irq": 1, "software_irq_masked": True,
            "uart_baud": 115200, "timer_tick_hz": 50000000,
            "instruction_memory_bytes": 32768, "data_memory_bytes": 16384,
            "external_imem": 0, "external_dmem": 0,
            "formal_score_measured": False,
            "firmware_config": {
                coremark_config.name: hashlib.sha256(coremark_config.read_bytes()).hexdigest()
            },
            "firmware_build_report": {
                coremark_report.relative_to(ROOT).as_posix(): hashlib.sha256(coremark_report.read_bytes()).hexdigest()
            },
        })
    if args.variant in COREMARK_AXI_VARIANTS:
        enable = 1 if COREMARK_AXI_VARIANTS[args.variant] == "on" else 0
        pred_enable = int(coremark_axi_btb_mode(args.variant) == "on")
        manifest.update({
            "coremark_platform": "axi-cache-" + COREMARK_AXI_VARIANTS[args.variant] + ("-btb" if pred_enable else ""),
            "enable_timer_irq": 1, "software_irq_masked": True,
            "uart_baud": 115200, "timer_tick_hz": 50000000,
            "instruction_memory_bytes": 32768, "data_memory_bytes": 16384,
            "external_imem": 1, "external_dmem": 1,
            "enable_icache": enable, "enable_dcache": enable,
            "enable_branch_pred": pred_enable, "btb_entries": 64,
            "btb_mode": coremark_axi_btb_mode(args.variant), "stats_schema": 3,
            "cycle_profile_schema": 1,
            "cycle_profile_fields": ["work_other", "ifetch_wait", "data_read_wait",
                                     "data_write_wait", "local_mmio_wait", "redirect_wait"],
            "cycle_profile_counter_bits": 64,
            "cycle_profile_start_bank_offset": "0x100",
            "cycle_profile_stop_bank_offset": "0x140", "stats_window_bytes": 512,
            "bp_config": f"0x{((64 << 16) | pred_enable):08x}",
            "btb_direction_counter_bits": 2, "btb_counter_bits": 32,
            "btb_snapshot_words_per_bank": 7,
            "btb_start_bank_offset": "0xc0", "btb_stop_bank_offset": "0xe0",
            "bp_config_offset": "0x14", "stats_schema_offset": "0x18",
            "icache_ways": 2, "icache_sets": 64, "icache_line_bytes": 16, "icache_bytes": 2048,
            "dcache_ways": 2, "dcache_sets": 64, "dcache_line_bytes": 16, "dcache_bytes": 2048,
            "dcache_policy": "write-through/no-write-allocate",
            "cacheable_ram_base": "0x00010000", "cacheable_ram_bytes": 16384,
            "cache_stats_base": "0x30000000", "cache_stats_id": "0x434d4158",
            "counter_window": "START-before-mtime;STOP-after-mtime;includes-boundary-overhead",
            "btb_counter_window": "frozen with the existing I/D/CPU START/STOP snapshots",
            "cpu_counter_bits": 64, "cache_counter_bits": 32, "mtime_bits": 64,
            "counter_snapshot_words_per_bank": 16,
            "counter_start_trigger_offset": "0x00", "counter_stop_trigger_offset": "0x04",
            "counter_start_bank_offset": "0x40", "counter_stop_bank_offset": "0x80",
            "axi_wait_cycles": {"imem_req": 0, "imem_rsp": 0, "mmio_req": 0, "mmio_rsp": 0,
                                "ram_aw": 0, "ram_w": 0, "ram_ar": 0, "ram_b": 0, "ram_r": 0},
            "formal_score_measured": False,
            "firmware_config": {
                coremark_config.name: hashlib.sha256(coremark_config.read_bytes()).hexdigest()
            },
            "firmware_build_report": {
                coremark_report.relative_to(ROOT).as_posix(): hashlib.sha256(coremark_report.read_bytes()).hexdigest()
            },
            "contract_script_sha256": hashlib.sha256((ROOT / "tools/coremark_axi_contract.py").read_bytes()).hexdigest(),
            "generated_top_sha256": hashlib.sha256(generated_top.read_bytes()).hexdigest(),
        })
    (build / "build_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("PDS project: " + str(project))
    print("No FPGA download or Flash programming was performed.")
    if args.stage != "synth":
        print("Review post-route setup/hold timing before any hardware download.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
