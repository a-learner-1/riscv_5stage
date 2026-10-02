"""Build the new board self-test with one ROM and hardware/simulation RAM images."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FALLBACK = Path("D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/"
                "xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")
BUILD = ROOT / "build" / "axi_control_board_firmware"
HW_BLINK_CYCLES = 25000000
SIM_BLINK_CYCLES = 2000


def find_prefix():
    configured = os.environ.get("AXI_CONTROL_CROSS") or os.environ.get("BOARD_CROSS")
    if configured:
        return configured
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler.rsplit("gcc", 1)[0]
    if Path(str(FALLBACK) + "gcc.exe").is_file():
        return str(FALLBACK)
    raise RuntimeError("RISC-V GCC not found: set AXI_CONTROL_CROSS or add it to PATH")


def relative(path):
    """Keep tool arguments ASCII even when the project directory is not."""
    return Path(path).relative_to(ROOT).as_posix()


def run(args, log, output_file=None):
    command = [str(arg) for arg in args]
    log.write("$ " + subprocess.list2cmdline(command) + "\n")
    log.flush()
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")
    log.write(result.stdout)
    log.flush()
    if output_file is not None:
        output_file.write_text(result.stdout, encoding="utf-8")
    elif result.stdout:
        print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError("Tool failed with exit code " + str(result.returncode) +
                           "; see " + str(BUILD / "build.log"))
    return result.stdout


def image(payload, target, words, fill):
    if len(payload) > words * 4:
        raise RuntimeError("Image exceeds configured memory: " + str(target))
    padded = payload + b"\0" * ((-len(payload)) % 4)
    data = [int.from_bytes(padded[i:i + 4], "little")
            for i in range(0, len(padded), 4)]
    data += [fill] * (words - len(data))
    target.write_text("".join(f"{word:08x}\n" for word in data), encoding="ascii")


def build_variant(prefix, name, blink_cycles, log):
    stem = BUILD / ("axi_control_board_" + name)
    elf = Path(str(stem) + ".elf")
    map_path = Path(str(stem) + ".map")
    flags = ["-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
             "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0", "-mno-relax",
             "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra", "-Werror",
             "-nostdlib", "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax"]
    run([prefix + "gcc", *flags,
         f"-DAXI_BOARD_BLINK_CYCLES={blink_cycles}u",
         "-Wl,-Map," + relative(map_path),
         "software/start.S", "software/axi_control_board.c", "-lgcc",
         "-o", relative(elf)], log)
    binaries = {}
    for section in ["text", "data"]:
        binary = Path(str(stem) + "_" + section + ".bin")
        run([prefix + "objcopy", "-O", "binary", "-j", "." + section,
             relative(elf), relative(binary)], log)
        binaries[section] = binary.read_bytes()
    run([prefix + "objdump", "-d", "-S", relative(elf)], log,
        Path(str(stem) + ".dump"))
    symbols = run([prefix + "nm", "-n", relative(elf)], log,
                  Path(str(stem) + ".symbols"))
    addresses = {}
    for line in symbols.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] in ["blink_cycles", "ram_guard", "observed"]:
            addresses[fields[2]] = int(fields[0], 16)
    if len(addresses) != 3:
        raise RuntimeError("Expected blink_cycles, ram_guard and observed in the ELF")
    return binaries, addresses


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    prefix = find_prefix()
    with (BUILD / "build.log").open("w", encoding="utf-8") as log:
        run([prefix + "gcc", "--version"], log)
        hardware, hw_addresses = build_variant(prefix, "hw", HW_BLINK_CYCLES, log)
        simulation, sim_addresses = build_variant(prefix, "sim", SIM_BLINK_CYCLES, log)
        if hardware["text"] != simulation["text"]:
            raise RuntimeError("Hardware and simulation instruction binaries differ")
        if hw_addresses != sim_addresses:
            raise RuntimeError("Hardware and simulation data symbol addresses differ")
        blink_offset = hw_addresses["blink_cycles"] - 0x10000
        if blink_offset < 0 or blink_offset + 4 > len(hardware["data"]):
            raise RuntimeError("blink_cycles is outside initialized RAM data")
        hw_data_without_blink = bytearray(hardware["data"])
        sim_data_without_blink = bytearray(simulation["data"])
        hw_blink = int.from_bytes(hw_data_without_blink[blink_offset:blink_offset + 4], "little")
        sim_blink = int.from_bytes(sim_data_without_blink[blink_offset:blink_offset + 4], "little")
        hw_data_without_blink[blink_offset:blink_offset + 4] = b"\0" * 4
        sim_data_without_blink[blink_offset:blink_offset + 4] = b"\0" * 4
        if hw_data_without_blink != sim_data_without_blink or \
                hw_blink != HW_BLINK_CYCLES or sim_blink != SIM_BLINK_CYCLES:
            raise RuntimeError("RAM images must differ only in blink_cycles")

        image(hardware["text"], ROOT / "programs/axi_control_board.hex", 8192, 0x13)
        image(hardware["data"], ROOT / "programs/axi_control_board_data.hex", 4096, 0)
        image(simulation["data"], ROOT / "programs/axi_control_board_sim_data.hex", 4096, 0)
        report = {
            "ctrl_base": "0x30000000",
            "rom_words": 8192,
            "ram_words": 4096,
            "text_bytes": len(hardware["text"]),
            "initialized_data_bytes": len(hardware["data"]),
            "hardware_blink_cycles": HW_BLINK_CYCLES,
            "simulation_blink_cycles": SIM_BLINK_CYCLES,
            "instruction_bins_identical": True,
            "ram_images_differ_only_in_blink_cycles": True,
            "text_sha256": hashlib.sha256(hardware["text"]).hexdigest(),
            "hardware_data_sha256": hashlib.sha256(hardware["data"]).hexdigest(),
            "simulation_data_sha256": hashlib.sha256(simulation["data"]).hexdigest(),
            "symbols": {name: f"0x{address:08x}" for name, address in hw_addresses.items()},
            "pass_uart_bytes": len(b"AXI RESULTS 0000002A 00000001 80000000\r\nAXI CTRL PASS\r\n"),
            "images": ["programs/axi_control_board.hex",
                       "programs/axi_control_board_data.hex",
                       "programs/axi_control_board_sim_data.hex"],
        }
        report_text = json.dumps(report, indent=2) + "\n"
        (BUILD / "build_report.json").write_text(report_text, encoding="utf-8")
        log.write(report_text)
    print("AXI board firmware: text=" + str(report["text_bytes"]) +
          " data=" + str(report["initialized_data_bytes"]) + " bytes; ROM8192 RAM4096")
    print("Hardware/simulation instruction binaries are identical; only blink_cycles differs")
    print("PASS UART=55 bytes; guard=" + report["symbols"]["ram_guard"])
    print("Only the three new AXI board HEX images generated")
    print("Build log/report: " + str(BUILD))


if __name__ == "__main__":
    main()
