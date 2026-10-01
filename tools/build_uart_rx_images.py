"""Build independent RV32I UART RX echo firmware; preserve all old images."""
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
    configured = os.environ.get("UART_RX_CROSS") or os.environ.get("BOARD_CROSS")
    if configured:
        return configured
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler.rsplit("gcc", 1)[0]
    if Path(str(FALLBACK) + "gcc.exe").is_file():
        return str(FALLBACK)
    raise RuntimeError("RISC-V GCC not found: set UART_RX_CROSS/BOARD_CROSS "
                       "or add it to PATH")


def image(binary, target, words, fill):
    payload = binary.read_bytes()
    if len(payload) > words * 4:
        raise RuntimeError(f"{binary.name}: image exceeds configured memory")
    payload += b"\0" * ((-len(payload)) % 4)
    data = [int.from_bytes(payload[index:index + 4], "little")
            for index in range(0, len(payload), 4)]
    data += [fill] * (words - len(data))
    target.write_text("".join(f"{word:08x}\n" for word in data), encoding="ascii")
    return len(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    prefix = find_prefix()
    build = ROOT / "build" / "uart_rx_firmware"
    build.mkdir(parents=True, exist_ok=True)
    programs = ROOT / "programs"
    programs.mkdir(exist_ok=True)
    flags = ["-march=rv32i", "-mabi=ilp32", "-O2", "-ffreestanding",
             "-fno-builtin", "-fno-stack-protector", "-fno-pic",
             "-msmall-data-limit=0", "-mno-relax", "-ffunction-sections",
             "-fdata-sections", "-Wall", "-Wextra", "-nostdlib",
             "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
             "-Wl,--gc-sections", "-Wl,--no-relax"]
    for name, test_bytes in [("uart_rx_echo", 0), ("uart_rx_echo_test", 32)]:
        elf = build / (name + ".elf")
        run([prefix + "gcc", *flags, f"-DUART_RX_TEST_BYTES={test_bytes}",
             "-Wl,-Map," + str(build / (name + ".map")),
             "software/start.S", "software/uart_rx_echo.c", "-lgcc", "-o", elf])
        for section in ["text", "data"]:
            run([prefix + "objcopy", "-O", "binary", "-j", "." + section,
                 elf, build / (name + "_" + section + ".bin")])
        with (build / (name + ".dump")).open("w", encoding="utf-8") as dump:
            subprocess.run([prefix + "objdump", "-d", "-S", str(elf)],
                           cwd=ROOT, stdout=dump, check=True)
        text_bytes = image(build / (name + "_text.bin"),
                           programs / (name + ".hex"), 8192, 0x13)
        data_bytes = image(build / (name + "_data.bin"),
                           programs / (name + "_data.hex"), 4096, 0)
        mode = "infinite board echo" if test_bytes == 0 else "32-byte test"
        print(f"UART RX: {name}: {mode}; payload text={text_bytes} "
              f"bytes data={data_bytes} bytes; ROM=8192 RAM=4096 words")
    print("UART RX: new images only; board_demo/UART TX/GPIO images preserved")


if __name__ == "__main__":
    main()
