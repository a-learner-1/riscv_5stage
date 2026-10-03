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
RTL = ["instr_mem.v", "instr_bus_adapter.v", "if_stage.v", "regfile.v", "decoder.v", "alu.v",
       "data_mem.v", "data_bus_adapter.v", "uart_tx.v", "uart_rx.v", "uart_rx_fifo.v", "uart_rx_mmio.v",
       "gpio_mmio.v", "machine_timer.v", "cpu_top.v", "board_reset.v"]


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["synth", "timing", "bitstream"],
                        default="synth")
    parser.add_argument("--firmware", choices=["board_demo", "uart_rx_echo", "axi_control_board", "trap_board", "timer_irq_board",
                                              "coremark_performance", "coremark_validation"],
                        default=None,
                        help="Default board_demo; dedicated variants select matching firmware")
    parser.add_argument("--variant", choices=["default", "data_handshake", "fetch_handshake", "soc", "axi_control_board", "trap_board", "timer_irq_board", "coremark_board"],
                        default="default",
                        help="Isolate data/fetch handshake, SoC, AXI control, trap and timer IRQ board builds")
    args = parser.parse_args()
    if args.firmware is None:
        args.firmware = ("coremark_performance" if args.variant == "coremark_board" else
                         args.variant if args.variant in {"axi_control_board", "trap_board", "timer_irq_board"} else "board_demo")
    for dedicated in ("axi_control_board", "trap_board", "timer_irq_board"):
        if (args.variant == dedicated) != (args.firmware == dedicated):
            parser.error(dedicated + " firmware and variant must be selected together")
    if (args.variant == "coremark_board") != args.firmware.startswith("coremark_"):
        parser.error("CoreMark firmware requires --variant coremark_board and a formal performance/validation image")
    coremark_config = None
    coremark_report = None
    if args.variant == "coremark_board":
        # Prevent loading a 100 MHz simulation image into the fixed 50 MHz top.
        coremark_config, coremark_report = validate_coremark_board_firmware(args.firmware)
    timer_irq_report = (validate_timer_irq_board_firmware()
                        if args.variant == "timer_irq_board" else None)
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
            builder = ("build_coremark.bat --profile " + args.firmware.removeprefix("coremark_")
                       if args.variant == "coremark_board" else
                       "build_timer_irq_board.bat" if args.firmware == "timer_irq_board" else
                       "build_trap_board.bat" if args.firmware == "trap_board" else
                       "build_axi_control_board.bat" if args.firmware == "axi_control_board" else
                       "build_board.bat" if args.firmware == "board_demo" else "build_uart_rx.bat")
            raise RuntimeError(f"Missing {path.name}; run {builder}")
        contents = path.read_text(encoding="ascii").splitlines()
        if len(contents) != words or any(not re.fullmatch("[0-9a-fA-F]{8}", w)
                                         for w in contents):
            raise RuntimeError(f"{path.name}: expected {words} complete hex words")

    build_name = ("pds_" + args.firmware if args.variant == "coremark_board" else
                  "pds_timer_irq_board" if args.variant == "timer_irq_board" else
                  "pds_trap_board" if args.variant == "trap_board" else
                  "pds_axi_control_board" if args.variant == "axi_control_board" else
                  "pds_soc" if args.variant == "soc" else
                  "pds_fetch_handshake" if args.variant == "fetch_handshake" else
                  "pds_data_handshake" if args.variant == "data_handshake" else
                  "pds_board" if args.firmware == "board_demo" else "pds_uart_rx")
    build = ROOT / "build" / build_name
    build.mkdir(parents=True, exist_ok=True)
    # Generated synthesis-only copy: absolute memory-file paths avoid relying
    # on PDS's working directory. The checked-in RTL stays portable.
    rtl_names = RTL + (["soc_instr_mem.v", "soc_data_mem.v", "soc_top.v"]
                       if args.variant == "soc" else [])
    if args.variant == "axi_control_board":
        rtl_names += ["soc_instr_mem.v", "dmem_axi_lite_bridge.v", "axi_lite_ram.v",
                      "soc_axi_lite_top.v", "axi_lite_1x2.v", "axi_lite_ctrl.v",
                      "soc_axi_control_top.v"]
    if args.variant in {"trap_board", "timer_irq_board"}:
        rtl_names += ["soc_instr_mem.v", "dmem_axi_lite_bridge.v", "axi_lite_ram.v",
                      "soc_axi_lite_top.v"]
    top_name = ("coremark_board_top" if args.variant == "coremark_board" else
                "timer_irq_board_top" if args.variant == "timer_irq_board" else
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
    source_firmware = ("coremark_performance" if args.variant == "coremark_board" else
                       args.variant if args.variant in {"axi_control_board", "trap_board", "timer_irq_board"} else "board_demo")
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
        if (not timing_report.is_file() or
                timing_report.stat().st_mtime < flow_started - 2):
            raise RuntimeError("Missing post-route timing summary")
        timing_text = timing_report.read_text(encoding="utf-8", errors="replace")
        timing_rows = re.findall(
            r"clk_50m\s+clk_50m\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)",
            timing_text)
        if ("Design Summary : All Constraints Met." not in timing_text or
                len(timing_rows) < 4 or
                any(float(row[0]) < 0 or int(row[2]) != 0 or int(row[3]) == 0
                    for row in timing_rows)):
            raise RuntimeError("Post-route timing failed/incomplete; bitstream not generated")
        # The router summary and the independent STA report have distinct
        # values. Require both, and record the final report separately.
        final_report = build / "report_timing/board_top.rtr"
        if not final_report.is_file() or final_report.stat().st_mtime < flow_started - 2:
            raise RuntimeError("Missing final independent STA report")
        final_text = final_report.read_text(encoding="utf-8", errors="replace")
        final_timing_rows = re.findall(
            r"clk_50m\s+clk_50m\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)",
            final_text)
        pulse_width_rows = re.findall(
            r"(?m)^\s*clk_50m\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$",
            final_text)
        if ("Design Summary : All Constraints Met." not in final_text or
                len(final_timing_rows) != 8 or len(pulse_width_rows) != 2 or
                any(float(row[0]) < 0 or int(row[2]) != 0 or int(row[3]) == 0
                    for row in final_timing_rows + pulse_width_rows)):
            raise RuntimeError("Final STA failed/incomplete; bitstream not generated")
        print("50MHz router and final STA setup/hold/recovery/removal/pulse-width checks passed.")
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
        if not any(path.stat().st_mtime >= bit_started - 2
                   for path in build.rglob("*.sbit")):
            raise RuntimeError("PDS did not produce a bitstream")
    manifest = {
        "base_target": "PGL50H-6IFBG484", "clock_hz": 50000000,
        "requested_stage": args.stage, "pds_returncode": result.returncode,
        "firmware": args.firmware,
        "variant": args.variant,
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
    if args.variant in {"trap_board", "timer_irq_board"}:
        manifest.update({
            "enable_traps": 1,
            "pds_shell": str(exe.resolve()),
            "build_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "bitstreams": {
                p.relative_to(build).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((build / "generate_bitstream").glob("board_top.*"))
                if p.suffix in {".sbit", ".bin"} and args.stage == "bitstream"
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
