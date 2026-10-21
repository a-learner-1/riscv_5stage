"""Build separate CoreMark functional checks and formal measurement firmware."""
import argparse
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FALLBACK = Path("D:/Tools/xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64/"
                "xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")
ROM_WORDS, RAM_WORDS, MIN_STACK_BYTES = 8192, 4096, 2048
MEM_LOCATION = ("Static; ROM 32 KiB @0x00000000; RAM 16 KiB @0x00010000; "
                "no cache; core:memory clock=1:1")
PROFILES = {
    "smoke": (100000000, 5000000, 1, False, "performance"),
    "smoke-validation": (100000000, 5000000, 1, False, "validation"),
    "formal-short": (100000000, 5000000, 1, True, "performance"),
    "performance": (50000000, 115200, 0, True, "performance"),
    "validation": (50000000, 115200, 0, True, "validation"),
}
EXPECTED_CRCS = {
    "performance": {"seed": 0xe9f5, "list": 0xe714, "matrix": 0x1fd7, "state": 0x8e3a},
    "validation": {"seed": 0x18f2, "list": 0xe3c1, "matrix": 0x0747, "state": 0x8d84},
}
SYMBOL_MACROS = {
    "start_ticks": "COREMARK_START_TICKS", "stop_ticks": "COREMARK_STOP_TICKS",
    "coremark_elapsed_ticks": "COREMARK_TOTAL_TICKS", "coremark_failed": "COREMARK_FAILED",
    "coremark_actual_iterations": "COREMARK_ACTUAL_ITERATIONS", "tohost": "COREMARK_TOHOST",
}
COMPILE_SOURCES = ["software/coremark_port/start_coremark.S",
                   "software/coremark_port/core_portme.c"] + [
    "benchmarks/coremark/" + name for name in
    ("core_list_join.c", "core_main.c", "core_matrix.c", "core_state.c", "core_util.c")]


@dataclass(frozen=True)
class BuildConfig:
    profile: str
    clock_hz: int
    uart_baud: int
    iterations: int
    formal: bool
    seeds: str
    name: str
    isa: str = field(default="rv32i", kw_only=True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=PROFILES, default="smoke")
    parser.add_argument("--iterations", type=int,
                        help="0 auto-calibrates formal profiles; otherwise 1..2147483647")
    parser.add_argument("--clock-hz", type=int, help="positive signed 32-bit timer/core clock frequency")
    parser.add_argument("--uart-baud", type=int, help="positive signed 32-bit UART baud rate")
    parser.add_argument("--cross", help="RISC-V executable prefix, including the final dash")
    parser.add_argument("--isa", choices=("rv32i", "rv32im"), default="rv32i")
    parser.add_argument("--name", help="distinct output name: ASCII letter then letters/digits/_")
    args = parser.parse_args(argv)
    default_clock, default_baud, iterations, formal, seeds = PROFILES[args.profile]
    clock_hz, uart_baud = default_clock, default_baud
    clock_hz = clock_hz if args.clock_hz is None else args.clock_hz
    uart_baud = uart_baud if args.uart_baud is None else args.uart_baud
    iterations = iterations if args.iterations is None else args.iterations
    for name, value in (("clock-hz", clock_hz), ("uart-baud", uart_baud)):
        if not 1 <= value <= 0x7fffffff:
            parser.error("--" + name + " must be in 1..2147483647 (RTL signed integer range)")
    if uart_baud > clock_hz:
        parser.error("--uart-baud must not exceed --clock-hz")
    if not 0 <= iterations <= 0x7fffffff:
        parser.error("--iterations must fit the nonnegative signed 32-bit seed4")
    if iterations == 0 and not formal:
        parser.error("--iterations=0 is only allowed for formal profiles")
    name = args.name if args.name is not None else (("m_" if args.isa == "rv32im" else "") + args.profile.replace("-", "_"))
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", name):
        parser.error("--name must be an ASCII identifier of at most 64 characters")
    reserved_names = {profile.replace("-", "_"): profile for profile in PROFILES}
    reserved = name.lower()
    if reserved in reserved_names:
        if args.isa != "rv32i":
            parser.error("RV32IM requires a distinct output name")
        if reserved_names[reserved] != args.profile:
            parser.error("--name is reserved for profile " + reserved_names[reserved])
        if name != reserved:
            parser.error("Reserved output names require canonical spelling: " + reserved)
    if args.profile in ("performance", "validation") and (
            clock_hz != default_clock or uart_baud != default_baud):
        if args.name is None or reserved == args.profile:
            parser.error("Nondefault formal clock/baud requires --name with a distinct output name")
    return BuildConfig(args.profile, clock_hz, uart_baud, iterations, formal, seeds, name, isa=args.isa), args.cross


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


def prefix(cross=None):
    configured = cross or os.environ.get("COREMARK_CROSS") or os.environ.get("BOARD_CROSS")
    if configured:
        return configured
    compiler = shutil.which("riscv-none-elf-gcc")
    if compiler:
        return compiler.rsplit("gcc", 1)[0]
    if Path(str(FALLBACK) + "gcc.exe").is_file():
        return str(FALLBACK)
    raise RuntimeError("RISC-V GCC missing: use --cross, COREMARK_CROSS, or GCC on PATH")


def rel(path):
    return Path(path).relative_to(ROOT).as_posix()


def run(args, log, commands, save=None):
    command = [str(value) for value in args]
    commands.append(command)
    log.write("$ " + subprocess.list2cmdline(command) + "\n")
    log.flush()
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True,
                            encoding="utf-8", errors="replace")
    log.write(result.stdout)
    log.flush()
    if save is not None:
        save.write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError("Command failed; see " + str(log.name))
    return result.stdout


def executable_path(name):
    for candidate in (Path(name), Path(name + ".exe")):
        if candidate.is_file():
            return candidate.resolve()
    found = shutil.which(name)
    if found:
        return Path(found).resolve()
    raise RuntimeError("Cannot resolve executable: " + name)


def image(payload, target, words, fill):
    """Match bin_to_hex.py byte order/tail padding, then fill physical memory."""
    if len(payload) > words * 4:
        raise RuntimeError("Image overflow: " + str(target))
    padded = payload + b"\0" * (-len(payload) % 4)
    data = [int.from_bytes(padded[index:index + 4], "little")
            for index in range(0, len(padded), 4)]
    data += [fill] * (words - len(data))
    target.write_text("".join(f"{word:08x}\n" for word in data), encoding="ascii")


def validate_linked_text(text, isa="rv32i"):
    """Check every linked instruction, including pulled-in libgcc code."""
    if isa not in ("rv32i", "rv32im"):
        raise RuntimeError("Unsupported linked-text ISA: " + str(isa))
    if len(text) % 4:
        raise RuntimeError(isa.upper() + " .text is not a multiple of four bytes")
    allowed = {0x03, 0x0f, 0x13, 0x17, 0x23, 0x33, 0x37, 0x63, 0x67, 0x6f, 0x73}
    for address in range(0, len(text), 4):
        word = int.from_bytes(text[address:address + 4], "little")
        opcode, funct3, funct7 = word & 0x7f, (word >> 12) & 7, word >> 25
        valid = word & 3 == 3 and opcode in allowed
        if opcode == 0x33:
            valid &= (funct7 == 0 or (funct7 == 0x20 and funct3 in (0, 5)) or
                      (isa == "rv32im" and funct7 == 1))
        if opcode == 0x13 and funct3 in (1, 5):
            valid &= funct7 == 0 or (funct3 == 5 and funct7 == 0x20)
        if opcode == 0x03:
            valid &= funct3 in (0, 1, 2, 4, 5)
        if opcode == 0x23:
            valid &= funct3 in (0, 1, 2)
        if opcode == 0x63:
            valid &= funct3 in (0, 1, 4, 5, 6, 7)
        if opcode == 0x67:
            valid &= funct3 == 0
        # The mtime port needs no CSR extension; base RV32I has ECALL/EBREAK.
        if opcode == 0x73:
            valid &= word in (0x00000073, 0x00100073)
        if opcode == 0x0f:
            valid &= funct3 == 0
        if not valid:
            raise RuntimeError(f"Non-{isa.upper()} instruction 0x{word:08x} at 0x{address:08x}")


def validate_rv32i(text):
    """Compatibility entry point: legacy builders must never accept M."""
    validate_linked_text(text, "rv32i")


def validate_multilib(isa, selected, available):
    """Reject a fallback library with C, CSR, floating-point or another ABI."""
    if isa not in ("rv32i", "rv32im"):
        raise RuntimeError("Unsupported compiler ISA: " + str(isa))
    entry = next((line for line in available.splitlines() if line.split(";")[0] == selected), "")
    switches = set(entry.split(";", 1)[1].split("@")) if ";" in entry else set()
    if switches != {"", "march=" + isa, "mabi=ilp32"}:
        raise RuntimeError("GCC must select an explicit " + isa + "/ilp32 multilib; selected " + selected)
    return entry


def compiler_flags(config, build_dir):
    seed_flag = "-D" + config.seeds.upper() + "_RUN=1"
    return ["-march=" + config.isa, "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin",
            "-fno-stack-protector", "-fno-pic", "-msmall-data-limit=0", "-mno-relax",
            "-ffunction-sections", "-fdata-sections", "-Wall", "-Wextra",
            "-Wno-maybe-uninitialized", f"-DITERATIONS={config.iterations}", seed_flag,
            "-DTOTAL_DATA_SIZE=2000", "-I" + rel(build_dir), "-Ibenchmarks/coremark",
            "-Isoftware/coremark_port", "-Isoftware"]


def linker_flags(build_dir):
    return ["-nostdlib", "-nostartfiles", "-static", "-Wl,-T,software/link.ld",
            "-Wl,--gc-sections", "-Wl,--no-relax",
            "-Wl,-Map," + rel(build_dir / "coremark.map")]


def write_config_header(config, build_dir, version, cflags, ldflags):
    lines = ["/* Generated by tools/build_coremark_images.py; do not edit. */",
             "#ifndef COREMARK_BUILD_CONFIG_H", "#define COREMARK_BUILD_CONFIG_H",
             f"#define COREMARK_CLOCK_HZ {config.clock_hz}u",
             f"#define COREMARK_UART_BAUD {config.uart_baud}u",
             f"#define COREMARK_FORMAL {int(config.formal)}",
             f"#define COREMARK_BUILD_ITERATIONS {config.iterations}u",
             "#define COREMARK_PROFILE_NAME " + json.dumps(config.profile),
             "#define COREMARK_BUILD_PROFILE COREMARK_PROFILE_NAME",
             "#define COMPILER_VERSION " + json.dumps(version),
             "#define COMPILER_FLAGS " + json.dumps(" ".join(cflags + ldflags + ["-lgcc"])),
             "#define MEM_LOCATION " + json.dumps(MEM_LOCATION), "#endif", ""]
    (build_dir / "coremark_build_config.h").write_text("\n".join(lines), encoding="ascii")


def write_verilog_config(config, symbols):
    stem = "coremark_" + config.name
    lines = ["// Generated by tools/build_coremark_images.py; do not edit.\n",
             f'`define COREMARK_PROFILE "{config.profile}"\n',
             f'`define COREMARK_ROM_FILE "programs/{stem}.hex"\n',
             f'`define COREMARK_RAM_FILE "programs/{stem}_data.hex"\n',
             f"`define COREMARK_CLOCK_HZ 32'd{config.clock_hz}\n",
             f"`define COREMARK_UART_BAUD 32'd{config.uart_baud}\n",
             f"`define COREMARK_ITERATIONS 32'd{config.iterations}\n",
             f"`define COREMARK_FORMAL {int(config.formal)}\n",
             f"`define COREMARK_ENABLE_M {int(config.isa == 'rv32im')}\n",
             "`define COREMARK_TOTAL_DATA_SIZE 32'd2000\n",
             "`define COREMARK_SUCCESS 32'd1\n", "`define COREMARK_REJECTED 32'd2\n"]
    for name, macro in SYMBOL_MACROS.items():
        lines.append(f"`define {macro} 32'h{symbols[name]:08x}\n")
    for name, value in EXPECTED_CRCS[config.seeds].items():
        lines.append(f"`define COREMARK_{name.upper()}_CRC 16'h{value:04x}\n")
    path = ROOT / "programs" / (stem + "_config.vh")
    path.write_text("".join(lines), encoding="ascii")
    return path


def source_hashes():
    sources = set(COMPILE_SOURCES)
    for directory in (ROOT / "benchmarks/coremark", ROOT / "software/coremark_port"):
        sources.update(rel(path) for path in directory.glob("*.h"))
    sources.update(("software/link.ld", "software/mmio.h", "software/timer.h",
                    "tools/build_coremark_images.py", "tools/bin_to_hex.py"))
    return {name: sha256((ROOT / name).read_bytes()) for name in sorted(sources)}


def build(config, cross=None):
    build_dir = ROOT / "build/coremark" / config.name
    build_dir.mkdir(parents=True, exist_ok=True)
    (ROOT / "programs").mkdir(exist_ok=True)
    tool = prefix(cross)
    commands, inputs = [], source_hashes()
    with (build_dir / "build.log").open("w", encoding="utf-8") as log:
        version = run([tool + "gcc", "--version"], log, commands).strip()
        options = ["-march=" + config.isa, "-mabi=ilp32"]
        selected = run([tool + "gcc", *options, "-print-multi-directory"], log, commands).strip()
        available = run([tool + "gcc", "-print-multi-lib"], log, commands).strip()
        entry = validate_multilib(config.isa, selected, available)
        libgcc = Path(run([tool + "gcc", *options, "-print-libgcc-file-name"], log, commands).strip()).resolve()
        if not libgcc.is_file():
            raise RuntimeError("Selected libgcc does not exist: " + str(libgcc))
        tool_files = {name: executable_path(tool + name) for name in ("gcc", "objcopy", "objdump", "nm", "size")}
        for name in ("cc1", "as", "ld"):
            path = run([tool + "gcc", "-print-prog-name=" + name], log, commands).strip()
            tool_files[name] = executable_path(path)
        cflags, ldflags = compiler_flags(config, build_dir), linker_flags(build_dir)
        write_config_header(config, build_dir, version.splitlines()[0], cflags, ldflags)
        header = build_dir / "coremark_build_config.h"
        inputs[rel(header)] = sha256(header.read_bytes())
        elf = build_dir / "coremark.elf"
        run([tool + "gcc", *cflags, *ldflags, *COMPILE_SOURCES, "-lgcc", "-o", rel(elf)], log, commands)
        binaries = {}
        for section in ("text", "data"):
            target = build_dir / ("coremark_" + section + ".bin")
            run([tool + "objcopy", "-O", "binary", "-j", "." + section, rel(elf), rel(target)], log, commands)
            binaries[section] = target.read_bytes()
        run([tool + "objdump", "-d", "-S", rel(elf)], log, commands, build_dir / "coremark.dump")
        size_output = run([tool + "size", rel(elf)], log, commands)
        output = run([tool + "nm", "-n", rel(elf)], log, commands, build_dir / "coremark.symbols")
        symbols = {}
        for line in output.splitlines():
            fields = line.split()
            if len(fields) == 3 and re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
                symbols[fields[2]] = int(fields[0], 16)
        for name in (*SYMBOL_MACROS, "_start", "main", "__bss_start", "__bss_end", "__stack_top"):
            if name not in symbols:
                raise RuntimeError("Missing expected symbol: " + name)
        headroom = symbols["__stack_top"] - symbols["__bss_end"]
        if headroom < MIN_STACK_BYTES:
            raise RuntimeError(f"Only {headroom} bytes of stack headroom; require {MIN_STACK_BYTES}")
        if len(binaries["text"]) > ROM_WORDS * 4 or len(binaries["data"]) > RAM_WORDS * 4:
            raise RuntimeError("CoreMark image exceeds physical ROM/RAM")
        for name in SYMBOL_MACROS:
            if not 0x10000 <= symbols[name] < 0x14000:
                raise RuntimeError("Observation symbol is outside RAM: " + name)
        validate_linked_text(binaries["text"], config.isa)
        for name, digest in inputs.items():
            if sha256((ROOT / name).read_bytes()) != digest:
                raise RuntimeError("Build input changed during compilation: " + name)
        stem = "coremark_" + config.name
        images = [ROOT / "programs" / (stem + ".hex"), ROOT / "programs" / (stem + "_data.hex")]
        image(binaries["text"], images[0], ROM_WORDS, 0x13)
        image(binaries["data"], images[1], RAM_WORDS, 0)
        images.append(write_verilog_config(config, symbols))
        if config.profile == "smoke" and config.name == "smoke":
            for original, alias in zip(images[:2], ("coremark.hex", "coremark_data.hex")):
                target = ROOT / "programs" / alias
                target.write_bytes(original.read_bytes())
                images.append(target)
        report = {
            "profile": config.profile, "output_name": config.name, "formal": config.formal,
            "configured_iterations": config.iterations, "automatic_iterations": config.iterations == 0,
            "seed_profile": config.seeds, "total_data_size": 2000, "contexts": 1,
            "clock_hz": config.clock_hz, "tick_hz": config.clock_hz, "uart_baud": config.uart_baud,
            "compiler": version.splitlines()[0], "compiler_version_full": version,
            "compiler_flags": cflags, "linker_flags": ldflags, "linked_libraries": ["-lgcc"],
            "march": config.isa, "enable_m": int(config.isa == "rv32im"), "mabi": "ilp32", "optimization": "O2",
            "multilib_selected": selected, "multilib_entry": entry, "multilib_available": available,
            "libgcc_path": str(libgcc), "libgcc_sha256": sha256(libgcc.read_bytes()),
            "tools": {name: {"path": str(path), "sha256": sha256(path.read_bytes())}
                      for name, path in tool_files.items()},
            "memory_location": MEM_LOCATION, "rom_bytes": ROM_WORDS * 4, "ram_bytes": RAM_WORDS * 4,
            "cache": False, "core_memory_clock_ratio": "1:1", "timer_source": "64-bit mtime",
            "text_bytes": len(binaries["text"]), "data_bytes": len(binaries["data"]),
            "bss_bytes": symbols["__bss_end"] - symbols["__bss_start"],
            "stack_headroom_bytes": headroom, "minimum_stack_headroom_bytes": MIN_STACK_BYTES,
            "all_linked_text_checked_rv32i": config.isa == "rv32i",
            "all_linked_text_checked_rv32im": config.isa == "rv32im", "size_output": size_output.strip(),
            "text_sha256": sha256(binaries["text"]), "data_sha256": sha256(binaries["data"]),
            "sources_sha256": inputs, "images_sha256": {rel(path): sha256(path.read_bytes()) for path in images},
            "elf_sha256": sha256(elf.read_bytes()), "map_sha256": sha256((build_dir / "coremark.map").read_bytes()),
            "symbols": {name: f"0x{address:08x}" for name, address in sorted(symbols.items())},
            "expected_crc": {name: f"0x{value:04x}" for name, value in EXPECTED_CRCS[config.seeds].items()},
            "commands": commands, "working_directory": str(ROOT),
            "hardware_download_performed": False, "formal_score_measured": False,
        }
        report_text = json.dumps(report, indent=2) + "\n"
        (build_dir / "build_report.json").write_text(report_text, encoding="utf-8")
        log.write(report_text)
    return report


def main(argv=None):
    config, cross = parse_args(argv)
    report = build(config, cross)
    print(f"CoreMark {config.profile}: {report['text_bytes']} text bytes, "
          f"{report['data_bytes']} data bytes, {report['stack_headroom_bytes']} stack headroom")
    print(f"{config.clock_hz} Hz / UART {config.uart_baud}; "
          f"iterations={config.iterations}; formal={int(config.formal)}")
    print("Generated programs/coremark_" + config.name + ".hex and matching data/config")
    print("Build prepares firmware; no hardware score has been measured.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
