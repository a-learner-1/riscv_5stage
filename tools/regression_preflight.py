"""Read-only firmware prerequisites for the unified regression entry.

This helper never builds firmware, invokes PDS or launches a simulator.
Missing/stale inputs are rejected so the runner can report BLOCKED.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

# Importing existing local guard modules must not create __pycache__ files.
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
HINTS = {
    "icache": "build_icache_board.bat",
    "dcache": "build_dcache_board.bat",
    "coremark-prepare": ("build_coremark.bat --profile smoke; "
                         "build_coremark.bat --profile smoke-validation; "
                         "build_coremark.bat --profile formal-short; "
                         "build_coremark.bat --profile performance; "
                         "python tools/build_coremark_port_tests.py"),
}


def read_report(path):
    if not path.is_file():
        raise RuntimeError("Missing firmware report: " + path.relative_to(ROOT).as_posix())
    report = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(report, dict):
        raise RuntimeError("Firmware report must contain an object: " + path.name)
    return report


def require_fields(report, expected, label):
    for key, value in expected.items():
        if type(report.get(key)) is not type(value) or report[key] != value:
            raise RuntimeError(label + ": incompatible metadata " + key)


def verify_hashes(mapping, expected_names, label):
    if not isinstance(mapping, dict) or set(mapping) != set(expected_names):
        raise RuntimeError(label + ": missing/extra source or image hash identity")
    for name in expected_names:
        path = (ROOT / name).resolve()
        digest = mapping[name]
        if not path.is_relative_to(ROOT.resolve()) or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RuntimeError(label + ": invalid hashed path/digest " + name)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(label + ": missing/stale source or image " + name)


def hex_payload(path, words):
    lines = path.read_text(encoding="ascii").splitlines()
    if len(lines) != words or any(not re.fullmatch(r"[0-9a-fA-F]{8}", line) for line in lines):
        raise RuntimeError(path.name + ": expected " + str(words) + " complete hex words")
    return b"".join(int(line, 16).to_bytes(4, "little") for line in lines)


def macro_values(path):
    values = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"\s*`define\s+([A-Z0-9_]+)\s+(.+?)\s*", line)
        if match:
            if match.group(1) in values:
                raise RuntimeError(path.name + ": duplicate macro " + match.group(1))
            values[match.group(1)] = match.group(2)
    return values


def check_coremark_profile(name):
    # The existing builder has no work at import time; only __main__ calls build.
    import build_coremark_images as original
    profile = {"smoke_validation": "smoke-validation", "formal_short": "formal-short"}.get(name, name)
    clock, baud, _, formal, seeds = original.PROFILES[profile]
    build = ROOT / "build/coremark" / name
    report = read_report(build / "build_report.json")
    require_fields(report, {
        "profile": profile, "output_name": name, "formal": formal, "seed_profile": seeds,
        "clock_hz": clock, "tick_hz": clock, "uart_baud": baud,
        "total_data_size": 2000, "contexts": 1, "march": "rv32i", "mabi": "ilp32",
        "rom_bytes": 32768, "ram_bytes": 16384, "cache": False,
        "core_memory_clock_ratio": "1:1", "timer_source": "64-bit mtime",
        "all_linked_text_checked_rv32i": True, "minimum_stack_headroom_bytes": 2048,
    }, name)
    iterations = report.get("configured_iterations")
    if type(iterations) is not int or not 0 <= iterations <= 0x7fffffff or (name != "performance" and iterations != 1):
        raise RuntimeError(name + ": incompatible iteration count for the selected test")
    require_fields(report, {"automatic_iterations": iterations == 0}, name)
    if type(report.get("stack_headroom_bytes")) is not int or report["stack_headroom_bytes"] < 2048:
        raise RuntimeError(name + ": insufficient/unknown stack headroom")
    sources = set(original.COMPILE_SOURCES)
    for directory in (ROOT / "benchmarks/coremark", ROOT / "software/coremark_port"):
        sources.update(path.relative_to(ROOT).as_posix() for path in directory.glob("*.h"))
    sources.update(("software/link.ld", "software/mmio.h", "software/timer.h",
                    "tools/build_coremark_images.py", "tools/bin_to_hex.py",
                    (build / "coremark_build_config.h").relative_to(ROOT).as_posix()))
    verify_hashes(report.get("sources_sha256"), sources, name)
    stem = "coremark_" + name
    images = ["programs/" + stem + suffix for suffix in (".hex", "_data.hex", "_config.vh")]
    if name == "smoke":
        images += ["programs/coremark.hex", "programs/coremark_data.hex"]
    verify_hashes(report.get("images_sha256"), images, name)
    for key, maximum in (("text_bytes", 32768), ("data_bytes", 16384)):
        if type(report.get(key)) is not int or not 0 < report[key] <= maximum:
            raise RuntimeError(name + ": invalid " + key)
    for image, words, count_key, digest_key, fill in (
            (images[0], 8192, "text_bytes", "text_sha256", b"\x13\0\0\0"),
            (images[1], 4096, "data_bytes", "data_sha256", bytes(4))):
        payload = hex_payload(ROOT / image, words)
        count = report[count_key]
        if hashlib.sha256(payload[:count]).hexdigest() != report.get(digest_key):
            raise RuntimeError(name + ": HEX payload does not match linked binary hash")
        padded = (count + 3) // 4 * 4
        if payload[count:padded] != bytes(padded - count) or payload[padded:] != fill * ((len(payload) - padded) // 4):
            raise RuntimeError(name + ": inconsistent physical memory padding")
    symbols = report.get("symbols")
    if not isinstance(symbols, dict):
        raise RuntimeError(name + ": missing ELF observation symbols")
    expected_macros = {
        "COREMARK_PROFILE": json.dumps(profile), "COREMARK_ROM_FILE": json.dumps(images[0]),
        "COREMARK_RAM_FILE": json.dumps(images[1]), "COREMARK_CLOCK_HZ": "32'd" + str(clock),
        "COREMARK_UART_BAUD": "32'd" + str(baud), "COREMARK_ITERATIONS": "32'd" + str(iterations),
        "COREMARK_FORMAL": str(int(formal)), "COREMARK_TOTAL_DATA_SIZE": "32'd2000",
        "COREMARK_ENABLE_M": "0",
        "COREMARK_SUCCESS": "32'd1", "COREMARK_REJECTED": "32'd2",
    }
    for symbol, macro in original.SYMBOL_MACROS.items():
        value = symbols.get(symbol)
        width = 8 if symbol in {"start_ticks", "stop_ticks", "coremark_elapsed_ticks"} else 4
        if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-f]{8}", value) or \
                int(value, 16) & 3 or not 0x10000 <= int(value, 16) <= 0x14000 - width:
            raise RuntimeError(name + ": invalid RAM observation symbol " + symbol)
        expected_macros[macro] = "32'h" + value[2:]
    expected_crcs = {key: f"0x{value:04x}" for key, value in original.EXPECTED_CRCS[seeds].items()}
    require_fields(report, {"expected_crc": expected_crcs}, name)
    for key, value in original.EXPECTED_CRCS[seeds].items():
        expected_macros["COREMARK_" + key.upper() + "_CRC"] = f"16'h{value:04x}"
    if macro_values(ROOT / images[2]) != expected_macros:
        raise RuntimeError(name + ": generated VH differs from profile/report/ELF symbols")


def check_port_math():
    names = ["coremark_math_" + str(hz) + "_" + mode for hz in (50, 100) for mode in ("smoke", "formal")]
    report = read_report(ROOT / "build/coremark_port_tests/build_report.json")
    if set(report) != set(names):
        raise RuntimeError("Port math report is missing the exact four fixtures")
    header = macro_values(ROOT / "programs/coremark_math_symbols.vh")
    expected_macros = {}
    for name in names:
        fixture = report[name]
        if not isinstance(fixture, dict):
            raise RuntimeError("Invalid port math fixture report: " + name)
        require_fields(fixture, {"clock_hz": 50000000 if "_50_" in name else 100000000,
                                 "formal": int(name.endswith("_formal")), "mock_timing": True, "cases": 13}, name)
        verify_hashes(fixture.get("sources"), ["software/coremark_port/start_coremark.S",
                      "software/coremark_port/core_portme.c", "tests/coremark_port_math.c"], name)
        symbols = fixture.get("symbols")
        if not isinstance(symbols, dict) or set(symbols) != {"coremark_math_cases", "coremark_math_failure"}:
            raise RuntimeError(name + ": missing port math observation symbols")
        for symbol, label in (("coremark_math_cases", "CASES"), ("coremark_math_failure", "FAILURE")):
            value = symbols[symbol]
            if type(value) is not int or value & 3 or not 0x10000 <= value <= 0x13ffc:
                raise RuntimeError(name + ": invalid port math RAM symbol " + symbol)
            expected_macros[name.upper() + "_" + label] = f"32'h{value:08x}"
        build = ROOT / "build/coremark_port_tests" / name
        # This legacy report predates image hashes. Compare its generated HEX
        # to retained section binaries; do not claim a stronger ELF hash guard.
        for suffix, words in (("", 8192), ("_data", 4096)):
            binary = (build / (name + suffix + ".bin")).read_bytes()
            if len(binary) > words * 4 or (suffix == "" and len(binary) != fixture.get("text_bytes")):
                raise RuntimeError(name + ": invalid retained section binary size")
            payload = hex_payload(ROOT / "programs" / (name + suffix + ".hex"), words)
            if payload != binary + bytes(words * 4 - len(binary)):
                raise RuntimeError(name + ": HEX differs from retained port math section binary")
    if header != expected_macros:
        raise RuntimeError("Port math generated VH differs from its report symbols")


def preflight(kind):
    from build_pds_board import (validate_coremark_board_firmware,
                                 validate_icache_board_firmware, validate_dcache_board_firmware)
    if kind == "icache":
        validate_icache_board_firmware()
    elif kind == "dcache":
        validate_dcache_board_firmware()
    else:
        validate_coremark_board_firmware("coremark_performance")
        for name in ("smoke", "smoke_validation", "formal_short", "performance"):
            check_coremark_profile(name)
        check_port_math()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", required=True, choices=HINTS)
    args = parser.parse_args()
    try:
        preflight(args.kind)
    except (OSError, ValueError, RuntimeError, TypeError, AttributeError, ImportError) as error:
        print("BLOCKED: " + args.kind + ": " + str(error), file=sys.stderr)
        print("Rebuild inputs manually when verification is authorized: " + HINTS[args.kind], file=sys.stderr)
        return 2
    print("Firmware prerequisites matched: " + args.kind + " (read-only check; no simulation result)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
