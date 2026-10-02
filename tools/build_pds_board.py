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
       "gpio_mmio.v", "cpu_top.v", "board_reset.v"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["synth", "timing", "bitstream"],
                        default="synth")
    parser.add_argument("--firmware", choices=["board_demo", "uart_rx_echo", "axi_control_board"],
                        default=None,
                        help="Default board_demo; axi_control_board variant selects its matching firmware")
    parser.add_argument("--variant", choices=["default", "data_handshake", "fetch_handshake", "soc", "axi_control_board"],
                        default="default",
                        help="Isolate data/fetch handshake, SoC and AXI control board builds")
    args = parser.parse_args()
    if args.firmware is None:
        args.firmware = "axi_control_board" if args.variant == "axi_control_board" else "board_demo"
    if (args.variant == "axi_control_board") != (args.firmware == "axi_control_board"):
        parser.error("axi_control_board firmware and variant must be selected together")
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
            builder = ("build_axi_control_board.bat" if args.firmware == "axi_control_board" else
                       "build_board.bat" if args.firmware == "board_demo" else "build_uart_rx.bat")
            raise RuntimeError(f"Missing {path.name}; run {builder}")
        contents = path.read_text(encoding="ascii").splitlines()
        if len(contents) != words or any(not re.fullmatch("[0-9a-fA-F]{8}", w)
                                         for w in contents):
            raise RuntimeError(f"{path.name}: expected {words} complete hex words")

    build_name = ("pds_axi_control_board" if args.variant == "axi_control_board" else
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
    top_name = ("axi_control_board_top" if args.variant == "axi_control_board" else
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
    source_firmware = "axi_control_board" if args.variant == "axi_control_board" else "board_demo"
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
