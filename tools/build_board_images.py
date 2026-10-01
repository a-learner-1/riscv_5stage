"""Build RV32I board firmware and full-depth ROM/RAM initialization images."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FALLBACK = Path("D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/"
                "xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")


def run(args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def find_prefix():
    configured = os.environ.get("BOARD_CROSS")
    if configured:
        return configured
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler.rsplit("gcc", 1)[0]
    if Path(str(FALLBACK) + "gcc.exe").is_file():
        return str(FALLBACK)
    raise RuntimeError("RISC-V GCC not found: set BOARD_CROSS or add it to PATH")


def image(binary, target, words, fill):
    payload = binary.read_bytes()
    if len(payload) > words * 4:
        raise RuntimeError(f"{binary.name}: image exceeds configured memory")
    payload += b"\0" * ((-len(payload)) % 4)
    data = [int.from_bytes(payload[i:i + 4], "little")
            for i in range(0, len(payload), 4)]
    data += [fill] * (words - len(data))
    target.write_text("".join(f"{word:08x}\n" for word in data), encoding="ascii")
    return len(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.parse_args()
    prefix = find_prefix()
    build = ROOT / "build" / "board_firmware"
    build.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    flags = ["-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fno-pic",
             "-msmall-data-limit=0", "-mno-relax", "-ffunction-sections",
             "-fdata-sections", "-Wall", "-Wextra", "-nostdlib",
             "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax"]
    for name, cycles in [("board_demo", 25000000), ("board_demo_sim", 2000)]:
        elf = build / (name + ".elf")
        run([prefix + "gcc", *flags, f"-DBOARD_BLINK_CYCLES={cycles}u",
             "-Wl,-Map," + str(build / (name + ".map")),
             "software/start.S", "software/board_demo.c", "-lgcc", "-o", elf])
        for section in ["text", "data"]:
            run([prefix + "objcopy", "-O", "binary", "-j", "." + section,
                 elf, build / (name + "_" + section + ".bin")])
        with (build / (name + ".dump")).open("w", encoding="utf-8") as dump:
            subprocess.run([prefix + "objdump", "-d", "-S", str(elf)],
                           cwd=ROOT, stdout=dump, check=True)
    hardware_text = build / "board_demo_text.bin"
    simulation_text = build / "board_demo_sim_text.bin"
    if hardware_text.read_bytes() != simulation_text.read_bytes():
        raise RuntimeError("Simulation must use exactly the hardware instruction image")
    text_bytes = image(hardware_text, ROOT / "programs/board_demo.hex", 8192, 0x13)
    data_bytes = image(build / "board_demo_data.bin",
                       ROOT / "programs/board_demo_data.hex", 4096, 0)
    image(build / "board_demo_sim_data.bin",
          ROOT / "programs/board_demo_sim_data.hex", 4096, 0)
    print(f"BOARD: ROM=8192 words, RAM=4096 words; payload text={text_bytes} "
          f"bytes data={data_bytes} bytes")
    print("BOARD: hardware blink=25000000 cycles; simulation blink=2000 cycles")
    print("BOARD: hardware and simulation instruction images are identical")


if __name__ == "__main__":
    main()
