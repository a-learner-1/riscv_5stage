"""Build CPU5 CoreMark firmware and run the schema4/profile2 system self-check.

The runner compiles four frozen (D0 backend x I/D cache) configurations, runs
them in one ModelSim process, then audits the UART report against the testbench
snapshot record and the frozen CoreMark CRC set. Nothing here claims a formal
CoreMark score, a timing closure or a board result.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

from build_cpu5_coremark_images import (CASES, EXPECTED_CRCS, OUT as FIRMWARE_OUT,
                                       build_case, source_hashes)
from run_cpu5_d0_program import SOURCES as D0_SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/cpu5_s17_coremark"
RTL = list(dict.fromkeys([path for path in D0_SOURCES
                          if path.endswith(".v") and path.startswith("rtl/")] +
                         ["rtl/soc_instr_mem.v", "rtl/axi_lite_1x2.v",
                          "rtl/axi_lite_cpu5_stats.v", "rtl/cpu5_stats_axi_lite_top.v"]))
COPIES = RTL + ["rtl/cpu5_pipeline_types.vh", "tb/cpu5_coremark_tb.v"]
FIRMWARE = ["software/cpu5_coremark/" + name
            for name in ("coremark_cpu5_stats.h", "core_portme_cpu5.c", "start.S", "link.ld")]
SHARED = ["software/coremark_port/core_portme.c", "software/coremark_port/core_portme.h",
          "software/mmio.h", "software/timer.h",
          "benchmarks/coremark/coremark.h"] + [
    "benchmarks/coremark/" + name for name in
    ("core_list_join.c", "core_main.c", "core_matrix.c", "core_state.c", "core_util.c")]
SOURCES = sorted(set(COPIES + FIRMWARE + SHARED + [
    "tools/run_cpu5_coremark.py", "tools/build_cpu5_coremark_images.py",
    "run_cpu5_coremark.do"]))
DIAGNOSTIC = re.compile(r"\*\*\s+(?:Warning|Error)\b|^Traceback \(", re.MULTILINE)
CLASSES = ("work_other", "ifetch_wait", "data_read_wait", "data_write_wait",
           "local_mmio_wait", "redirect_wait", "mul_wait", "div_wait",
           "load_use_wait", "id_hazard_wait")
# Classes this platform must always exercise. ifetch_wait is zero because the
# frozen IMEM endpoint has no wait states; div_wait, load_use_wait and
# id_hazard_wait are reported as measured and are not required to be nonzero
# here: the CoreMark window performs no DIV, and every memory wait it does
# perform is attributed to the data-read/write classes by the S16 contract.
STRUCTURAL_CLASSES = ("work_other", "data_read_wait", "data_write_wait",
                      "local_mmio_wait", "redirect_wait", "mul_wait")
ICACHE_FIELDS = ("access", "hit", "miss", "refill_words", "errors")
DCACHE_FIELDS = ("access", "hit", "miss", "refill_words", "errors", "write", "bypass")
BP_FIELDS = ("lookup", "hit", "predicted_taken", "resolved", "next_pc_mismatch",
             "direction_error", "target_error")
FORBIDDEN_TEXT = ("COREMARK RESULT: FORMAL", "SMOKE FAIL", "Cannot validate operation",
                  "ERROR:", "ERROR! list", "ERROR! matrix", "ERROR! state")
# Upstream report keys are not uniform: the seed CRC is "seedcrc" while the
# per-algorithm CRCs are printed as "crclist"/"crcmatrix"/"crcstate".
CRC_KEYS = {"seed": "seedcrc", "list": "crclist",
            "matrix": "crcmatrix", "state": "crcstate"}
CLOCK_HZ, UART_BAUD = 50000000, 5000000
CACHE_GEOMETRY = (2 << 24) | (4 << 16) | (4 * 4)
BP_CONFIG = (16 << 16) | 1
MAX_TICK_GAP = 256
DEFAULT_CROSS = (r"D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64"
                 r"\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-")
DEFAULT_VSIM = Path(r"D:\modeltech64_10.6e\win64\vsim.exe")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8", newline="\n")


def parse_console(text):
    """Collect the structured COREMARK key=value report lines."""
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("COREMARK "):
            continue
        key, separator, value = line[len("COREMARK "):].partition("=")
        if separator:
            values[key] = value
    return values


def audit_case(directory, number):
    summary = read(directory / "summary.json")
    console = (directory / "console.txt").read_text(encoding="utf-8", errors="replace")
    values = parse_console(console)
    d0 = 1 if number >= 2 else 0
    cache = 3 if number % 2 else 0
    assert summary["status"] == "PASS" and summary["case"] == number
    assert summary["d0"] == d0 and summary["cache"] == cache
    window, profile = summary["window"], summary["profile"]
    assert 0 < window["snapshot_cycle_delta"] < 2 ** 32
    assert window["stop_cycle"] - window["start_cycle"] == window["snapshot_cycle_delta"]
    assert window["stop_instret"] - window["start_instret"] == window["snapshot_instret_delta"] > 0
    # Write-back trails retirement by at most the pipeline depth; no write-back
    # may ever be newer than a retirement.
    assert summary["retired"] > 0
    assert 0 <= summary["retired"] - summary["writebacks"] <= 4
    # A retirement consumes at least one cycle, so an impossible whole-program
    # count must be rejected instead of merely being large.
    assert summary["retired"] <= summary["compute_cycles"], (summary["retired"],
                                                             summary["compute_cycles"])
    assert summary["window"]["snapshot_instret_delta"] <= summary["retired"]
    assert summary["window"]["snapshot_cycle_delta"] <= summary["compute_cycles"]
    # The terminal store must be bound to its own completion, retirement and
    # write-back, not just to a matching number of counters.
    tohost = summary["tohost"]
    assert tohost["requests"] == 1 and tohost["responses"] == 1
    assert tohost["completions"] == 1 and tohost["retired"] == 1
    assert tohost["retire_index"] >= 0
    assert tohost["writebacks"] >= tohost["retire_index"] + 1
    assert summary["raw_starts"] == 2 and summary["stops"] == 1
    assert summary["console_bytes"] > 0
    assert summary["uart_frames"] == summary["console_bytes"]
    assert summary["uart_data_mismatch"] == 0 and summary["uart_stop_errors"] == 0
    delta = profile["delta"]
    assert len(delta) == 10
    for index, name in enumerate(CLASSES):
        assert delta[index] == profile["stop"][index] - profile["start"][index]
        assert delta[index] <= window["snapshot_cycle_delta"]
        assert values["cycle_" + name] == str(delta[index]), (number, name)
    assert sum(delta) == window["snapshot_cycle_delta"]
    assert values["counter_valid"] == "1" and values["cycle_profile_valid"] == "1"
    assert values["counter_cycles"] == str(window["snapshot_cycle_delta"])
    assert values["counter_retired"] == str(window["snapshot_instret_delta"])
    assert values["cycle_profile_sum"] == str(sum(delta))
    assert values["stats_schema"] == "4" and values["cycle_profile_schema"] == "2"
    assert values["platform"] == "cpu5" and values["isa"] == "rv32im"
    assert values["data_backend"] == ("bram" if d0 else "axi")
    # Hardware-observed backend id: an AXI image on D0 hardware (or the reverse)
    # must be rejected by the firmware AND by this audit.
    assert values["backend_id"] == str(d0)
    assert values["cache_enable"] == str(cache)
    assert values["cache_geometry"] == str(CACHE_GEOMETRY)
    assert values["branch_pred_enable"] == "1"
    assert values["btb_entries"] == "16" and values["btb_config"] == str(BP_CONFIG)
    for index, name in enumerate(ICACHE_FIELDS):
        assert values["icache_" + name] == str(summary["icache"]["stop"][index] -
                                              summary["icache"]["start"][index])
    for index, name in enumerate(DCACHE_FIELDS):
        assert values["dcache_" + name] == str(summary["dcache"]["stop"][index] -
                                              summary["dcache"]["start"][index])
    for index, name in enumerate(BP_FIELDS):
        assert values["bp_" + name] == str(summary["bp"]["stop"][index] -
                                          summary["bp"]["start"][index])
    if cache:
        for index in range(4):
            assert summary["icache"]["stop"][index] > summary["icache"]["start"][index]
            assert summary["dcache"]["stop"][index] > summary["dcache"]["start"][index]
    else:
        assert not any(summary["icache"]["start"] + summary["icache"]["stop"])
        assert not any(summary["dcache"]["start"] + summary["dcache"]["stop"])
    for index in range(4):
        assert summary["bp"]["stop"][index] > summary["bp"]["start"][index]
    ticks = int(values["raw_ticks"])
    gap = int(values["window_tick_gap"])
    assert 0 < ticks <= window["snapshot_cycle_delta"]
    assert window["snapshot_cycle_delta"] - ticks == gap <= MAX_TICK_GAP
    assert values["iterations"] == "1" and values["iterations_requested"] == "1"
    assert values["mode"] == "smoke" and values["run"] == "performance"
    assert values["profile"] == "cpu5-smoke"
    assert values["cpu_hz"] == str(CLOCK_HZ) and values["uart_baud"] == str(UART_BAUD)
    for key, crc in EXPECTED_CRCS.items():
        assert values[CRC_KEYS[key]] == f"0x{crc:04x}", (number, key)
    assert f"seedcrc          : 0x{EXPECTED_CRCS['seed']:04x}" in console
    assert f"[0]crclist       : 0x{EXPECTED_CRCS['list']:04x}" in console
    assert f"[0]crcmatrix     : 0x{EXPECTED_CRCS['matrix']:04x}" in console
    assert f"[0]crcstate      : 0x{EXPECTED_CRCS['state']:04x}" in console
    assert "COREMARK RESULT: SMOKE PASS" in console
    assert "ERROR! Must execute for at least 10 secs" in console
    assert ("NOTE: smoke timing is a functional observation; "
            "it is not a formal score.") in console
    for text in FORBIDDEN_TEXT:
        assert text not in console, (number, text)
    for name in STRUCTURAL_CLASSES:
        assert values["cycle_" + name] not in ("", None) and int(values["cycle_" + name]) > 0
    return {
        "case": number, "d0": d0, "cache": cache,
        "compute_cycles": summary["compute_cycles"], "retired": summary["retired"],
        "writebacks": summary["writebacks"],
        "window_cycles": window["snapshot_cycle_delta"],
        "window_retired": window["snapshot_instret_delta"],
        "raw_ticks": ticks, "window_tick_gap": gap,
        "console_bytes": summary["console_bytes"],
        "stats_triggers": {"start": summary["raw_starts"], "stop": summary["stops"]},
        "cycle_classes": dict(zip(CLASSES, delta)),
        "icache_delta": [summary["icache"]["stop"][index] - summary["icache"]["start"][index]
                         for index in range(5)],
        "dcache_delta": [summary["dcache"]["stop"][index] - summary["dcache"]["start"][index]
                         for index in range(7)],
        "bp_delta": [summary["bp"]["stop"][index] - summary["bp"]["start"][index]
                     for index in range(7)],
        "console_sha256": hashlib.sha256(
            (directory / "console.txt").read_bytes()).hexdigest(),
    }


def analyze(directory, count=None):
    count = len(CASES) if count is None else count
    records = [audit_case(directory / "cases" / f"case{number}", number)
               for number in range(count)]
    by_case = {record["case"]: record["window_cycles"] for record in records}
    # Cycle counts are recorded as observations, never asserted: a faster cache,
    # a different backend latency or a later code change would legitimately
    # change these relations, and a correctness gate must not fail because a
    # future optimisation succeeded.
    observations = {"window_cycles_by_case": {str(case): cycles
                                              for case, cycles in sorted(by_case.items())},
                    "cache_cycle_cost": {}, "d0_cycle_saving": {}}
    for axi, cached in ((0, 1), (2, 3)):
        if axi in by_case and cached in by_case:
            observations["cache_cycle_cost"][f"{axi}->{cached}"] = by_case[cached] - by_case[axi]
    for axi, d0 in ((0, 2), (1, 3)):
        if axi in by_case and d0 in by_case:
            observations["d0_cycle_saving"][f"{axi}->{d0}"] = by_case[axi] - by_case[d0]
    return {
        "status": "PASS", "configurations": count, "cases": records,
        "total_window_cycles": sum(record["window_cycles"] for record in records),
        "total_retired": sum(record["window_retired"] for record in records),
        "total_console_bytes": sum(record["console_bytes"] for record in records),
        "cycle_class_totals": {name: sum(record["cycle_classes"][name] for record in records)
                               for name in CLASSES},
        "observations": observations,
        "metrics_claimed": "NONE",
        "scope": ("Real compiled RV32IM CoreMark (one iteration, performance seed) on the "
                  "CPU5 schema4 system: D0 backend x coupled I/D cache; ten-class cycle "
                  "window, Cache and BTB deltas cross-checked against independent testbench "
                  "ledgers. Not a formal CoreMark score, not 10 seconds, no UART-received "
                  "score, not P&R/STA, not a board result, not full A01-A16 sign-off."),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsim", type=Path, default=DEFAULT_VSIM)
    parser.add_argument("--cross", default=DEFAULT_CROSS)
    parser.add_argument("--firmware-only", action="store_true")
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--reuse-firmware", action="store_true")
    parser.add_argument("--cases", type=int, default=len(CASES),
                        help="number of leading frozen configurations to simulate")
    parser.add_argument("--timeout", type=int, default=10800)
    arguments = parser.parse_args()
    if not 1 <= arguments.cases <= len(CASES):
        parser.error("--cases must be in 1..%d" % len(CASES))
    OUT.mkdir(parents=True, exist_ok=True)
    before = {path: sha(ROOT / path) for path in SOURCES}
    if arguments.reuse_firmware:
        firmware = [read(FIRMWARE_OUT / f"case{case['case']}" / "build.json") for case in CASES]
        current = source_hashes()
        for record in firmware:
            assert record["sources_sha256"] == current, "stale CPU5 CoreMark firmware images"
    else:
        firmware = [build_case(case, arguments.cross) for case in CASES]
        assert before == {path: sha(ROOT / path) for path in SOURCES}, \
            "CPU5 CoreMark sources changed during the firmware build"
    if arguments.firmware_only:
        print(json.dumps({"status": "FIRMWARE BUILT", "cases": len(firmware)}))
        return
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_") + uuid.uuid4().hex[:8]
    run = OUT / "runs" / run_id
    stage = run / "good_reference"
    stage.mkdir(parents=True)
    write(OUT / "verification.json", {"status": "RUNNING", "run_id": run_id,
                                      "source_sha256": before})
    for name in SOURCES:
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / name).read_bytes())
    staged = stage / "build/cpu5_s17_coremark"
    staged.mkdir(parents=True)
    shutil.copytree(FIRMWARE_OUT, staged / "firmware")
    (staged / "firmware/cases").mkdir(exist_ok=True)
    for case in CASES:
        (staged / "firmware/cases" / f"case{case['case']}").mkdir(exist_ok=True)
    scripts = {
        "compile.do": ["onerror {quit -code 1 -f}", "transcript file compile_transcript.log",
                       "vmap -c", "vlib work", "vmap cpu5_coremark_work work",
                       "vlog -sv +incdir+. -work cpu5_coremark_work "
                       + " ".join(RTL + ["tb/cpu5_coremark_tb.v"]),
                       'echo "CPU5 COREMARK CLEAN COMPILE PASS"', "quit -code 0 -f"],
        "simulate.do": ["onerror {quit -code 1 -f}", "transcript file simulation_transcript.log",
                        "vmap cpu5_coremark_work work",
                        'vsim -voptargs="+acc" -onfinish stop -gCASES=%d -wlf system.wlf '
                        "cpu5_coremark_work.cpu5_coremark_tb" % arguments.cases,
                        "log -r sim:/cpu5_coremark_tb/*", "run -all",
                        "if {[examine -radix unsigned sim:/cpu5_coremark_tb/test_pass] != 1} "
                        "{quit -code 1 -f}",
                        'echo "CPU5 COREMARK REFERENCE PASS"', "quit -code 0 -f"],
    }
    logs = {}
    for name, lines in scripts.items():
        (stage / name).write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = subprocess.run([str(arguments.vsim), "-c", "-do", name], cwd=stage,
                                capture_output=True, text=True, encoding="utf-8",
                                errors="replace", timeout=arguments.timeout)
        output = result.stdout + result.stderr
        log = stage / (name.split(".")[0] + "_console.log")
        log.write_text(output, encoding="utf-8", newline="")
        logs[name] = log
        assert result.returncode == 0 and not DIAGNOSTIC.search(output) \
            and "** Fatal:" not in output, (name, result.returncode, output[-16000:])
        if arguments.compile_only and name == "compile.do":
            print(json.dumps({"status": "COMPILE PASS",
                              "console_sha256": sha(log)}))
            return
    for case in CASES[:arguments.cases]:
        shutil.copytree(staged / "firmware/cases" / f"case{case['case']}",
                        OUT / "cases" / f"case{case['case']}", dirs_exist_ok=True)
    result = analyze(OUT, arguments.cases)
    assert before == {path: sha(ROOT / path) for path in SOURCES}, \
        "CPU5 CoreMark sources changed during the run"
    raw_artifacts = {path.relative_to(ROOT).as_posix(): sha(path)
                     for folder in (OUT / "cases", FIRMWARE_OUT)
                     for path in folder.rglob("*") if path.is_file()}
    for folder in ("cases", "firmware"):
        duplicate = staged / folder
        assert not duplicate.exists() or duplicate.resolve().is_relative_to(stage.resolve())
    positive = {
        "name": "good_reference", "kind": "good_reference", "status": "PASS",
        "directory": stage.relative_to(ROOT).as_posix(),
        "compile": {"status": "PASS", "exit_code": 0, "warnings": 0, "errors": 0,
                    "console_sha256": sha(logs["compile.do"])},
        "simulation_exit_code": 0, "source_sha256": before,
        "simulation_console_sha256": sha(logs["simulate.do"]),
    }
    result.update(run_id=run_id, source_sha256=before, sources_unchanged=True,
                  positive=positive, firmware=firmware, raw_artifact_sha256=raw_artifacts,
                  compile_zero_warning_error=True,
                  processes=[{"name": "firmware", "status": "PASS", "exit_code": 0},
                             {"name": "simulation", "status": "PASS", "exit_code": 0}])
    write(run / "verification.json", result)
    write(OUT / "verification.json", result)
    print(json.dumps({key: result[key] for key in
                      ("status", "configurations", "total_window_cycles", "total_retired",
                       "total_console_bytes")}))


if __name__ == "__main__":
    main()
