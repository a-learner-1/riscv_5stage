"""Build only the new RV32I AXI control demo and full-depth HEX images."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FALLBACK = Path("D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/"
                "xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")


def run(args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


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


def image(binary, target, words, fill):
    payload = binary.read_bytes()
    if len(payload) > words * 4:
        raise RuntimeError("Image exceeds configured memory: " + str(binary))
    padded = payload + b"\0" * ((-len(payload)) % 4)
    data = [int.from_bytes(padded[i:i + 4], "little") for i in range(0, len(padded), 4)]
    data += [fill] * (words - len(data))
    target.write_text("".join(f"{word:08x}\n" for word in data), encoding="ascii")
    return len(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ctrl-base", type=lambda x: int(x, 0), default=0x30000000,
                        help="Temporary demo-device base; HDL must use the same address")
    args = parser.parse_args()
    if args.ctrl_base <= 0 or args.ctrl_base > 0xffffff00 or args.ctrl_base % 4:
        parser.error("Control base must be nonzero, aligned and leave room for the 256-byte window")
    if args.ctrl_base < 0x20010000 and args.ctrl_base + 0x100 > 0x20000000:
        parser.error("Control window overlaps CPU-local 0x2000xxxx MMIO")
    if args.ctrl_base < 0x14000 and args.ctrl_base + 0x100 > 0x10000:
        parser.error("Control window overlaps the fixed demo RAM")
    prefix = find_prefix()
    build = ROOT / "build" / "axi_control_firmware"
    build.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    elf = build / "axi_control_demo.elf"
    flags = ["-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
             "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0", "-mno-relax",
             "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra", "-Werror",
             "-nostdlib", "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax"]
    run([prefix + "gcc", *flags, f"-DAXI_CTRL_BASE=0x{args.ctrl_base:08x}u",
         "-Wl,-Map," + str(build / "axi_control_demo.map"),
         "software/start.S", "software/axi_control_demo.c", "-lgcc", "-o", elf])
    for section in ["text", "data"]:
        run([prefix + "objcopy", "-O", "binary", "-j", "." + section, elf,
             build / ("axi_control_demo_" + section + ".bin")])
    with (build / "axi_control_demo.dump").open("w", encoding="utf-8") as dump:
        subprocess.run([prefix + "objdump", "-d", "-S", str(elf)], cwd=ROOT, stdout=dump, check=True)
    text_bytes = image(build / "axi_control_demo_text.bin", ROOT / "programs/axi_control_demo.hex", 8192, 0x13)
    data_bytes = image(build / "axi_control_demo_data.bin", ROOT / "programs/axi_control_demo_data.hex", 4096, 0)
    print(f"AXI control demo: base=0x{args.ctrl_base:08x}; text={text_bytes} data={data_bytes} bytes; ROM8192 RAM4096")
    print("Only new AXI control images generated; existing firmware unchanged")


if __name__ == "__main__":
    main()
