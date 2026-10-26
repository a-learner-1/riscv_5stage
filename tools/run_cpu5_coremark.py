"""Run CPU5 CoreMark and retain immutable, run-specific raw evidence.

This phase only reports SIMULATED. Independent verify_cpu5_coremark.py must
audit all four cases before any PASS/frozen delivery is possible. One iteration
is never a formal CoreMark score; performance ordering is observational.
"""
import argparse
import gzip
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from build_cpu5_coremark_images import (CASES, EXPECTED_CRCS, OUT as FIRMWARE_OUT,
                                       build_case, source_hashes)
from run_cpu5_d0_program import SOURCES as D0_SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/cpu5_s18_coremark"
BASELINE = "a8bcedf971b172436d9a14adb6d59df5c19c8d9c"
MAPPED_BASELINE = "4299b9ec38520ac480b70250d23bfe2f3be8fad5"
DEFAULT_STORAGE = Path(r"D:\BaiduNetdiskDownload\2026FPGA创新设计竞赛紫光同创杯资料包\cpu5_s18_artifacts")
RTL = list(dict.fromkeys([path for path in D0_SOURCES
                          if path.endswith(".v") and path.startswith("rtl/")] +
                         ["rtl/soc_instr_mem.v", "rtl/axi_lite_1x2.v",
                          "rtl/axi_lite_cpu5_stats.v", "rtl/cpu5_stats_axi_lite_top.v"]))
COPIES = RTL + ["rtl/cpu5_pipeline_types.vh", "tb/cpu5_coremark_tb.v", "tb/cpu5_coremark_harness.v"]
SOURCES = sorted(set(COPIES + list(source_hashes()) + [
    "tools/run_cpu5_coremark.py", "tools/run_cpu5_d0_program.py", "run_cpu5_coremark.do"]))
DIAGNOSTIC = re.compile(r"\*\*\s+(?:Warning|Error|Fatal)\b|^Traceback \(", re.MULTILINE)
CLASSES = ("work_other", "ifetch_wait", "data_read_wait", "data_write_wait",
           "local_mmio_wait", "redirect_wait", "mul_wait", "div_wait", "load_use_wait", "id_hazard_wait")
ICACHE_FIELDS = ("access", "hit", "miss", "refill_words", "errors")
DCACHE_FIELDS = ("access", "hit", "miss", "refill_words", "errors", "write", "bypass")
BP_FIELDS = ("lookup", "hit", "predicted_taken", "resolved", "next_pc_mismatch", "direction_error", "target_error")
CRC_KEYS = {"seed": "seedcrc", "list": "crclist", "matrix": "crcmatrix", "state": "crcstate"}
CLOCK_HZ, UART_BAUD = 50000000, 5000000
CACHE_GEOMETRY = (2 << 24) | (4 << 16) | 16
BP_CONFIG = (16 << 16) | 1
MAX_TICK_GAP = 256
DEFAULT_CROSS = (r"D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64"
                 r"\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-")
DEFAULT_VSIM = Path(r"D:\modeltech64_10.6e\win64\vsim.exe")
CASE_FILES = ("console.txt", "uart_serial.txt", "edges.csv", "retire.csv", "terminal.csv",
              "stats.csv", "triggers.csv", "timer.csv", "native.csv", "actual_ram.hex", "summary.json")


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024): h.update(chunk)
    return h.hexdigest()


def read(path): return json.loads(path.read_text(encoding="utf-8"))
def rel(path): return path.relative_to(ROOT).as_posix()
def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8", newline="\n")


def parse_console(console):
    result = {}
    for line in console.splitlines():
        if not line.startswith("COREMARK ") or "=" not in line: continue
        key, value = line[9:].split("=", 1)
        if key in result: raise ValueError("duplicate COREMARK key: " + key)
        result[key] = value
    return result


def audit_case(directory, number):
    from verify_cpu5_coremark import audit_case_semantics
    return audit_case_semantics(directory, number)


def ensure_storage(storage):
    """Use an ASCII logical path while keeping all large artifacts on D:."""
    storage = storage.absolute()
    OUT.mkdir(parents=True, exist_ok=True)
    logical = OUT / "runs"
    storage.mkdir(parents=True, exist_ok=True)
    if logical.exists():
        if logical.resolve() != storage.resolve():
            raise RuntimeError("runs directory points elsewhere: " + str(logical))
    else:
        quote = lambda path: "'" + str(path).replace("'", "''") + "'"
        command = "New-Item -ItemType Junction -Path " + quote(logical) + " -Target " + quote(storage) + " | Out-Null"
        subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                       check=True, capture_output=True)
    if logical.resolve() != storage.resolve(): raise RuntimeError("artifact storage junction mismatch")
    return logical, storage


def compress_csv(path):
    raw_sha = sha(path); raw_size = path.stat().st_size
    target = path.with_suffix(path.suffix + ".gz")
    with path.open("rb") as source, target.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0, compresslevel=6) as zipped:
            shutil.copyfileobj(source, zipped, 1024 * 1024)
    h = hashlib.sha256(); size = 0
    with gzip.open(target, "rb") as source:
        while chunk := source.read(1024 * 1024): h.update(chunk); size += len(chunk)
    if h.hexdigest() != raw_sha or size != raw_size: raise RuntimeError("gzip verification failed: " + str(path))
    path.unlink()  # Only this run's verified CSV; exact bytes remain in gzip.
    return dict(path=rel(target), sha256=sha(target), raw_sha256=raw_sha, raw_bytes=raw_size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsim", type=Path, default=DEFAULT_VSIM)
    parser.add_argument("--cross", default=DEFAULT_CROSS)
    parser.add_argument("--storage", type=Path, default=DEFAULT_STORAGE)
    parser.add_argument("--firmware-only", action="store_true")
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--reuse-firmware", action="store_true")
    parser.add_argument("--cases", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=10800)
    args = parser.parse_args()
    if not 1 <= args.cases <= 4: parser.error("--cases must be in 1..4")
    before = {p: sha(ROOT / p) for p in SOURCES}
    before_lf = {p: hashlib.sha256((ROOT / p).read_bytes().replace(b"\r\n", b"\n")).hexdigest() for p in SOURCES}
    OUT.mkdir(parents=True, exist_ok=True)
    if args.reuse_firmware:
        firmware = []
        for case in CASES:
            record = read(FIRMWARE_OUT / f"case{case['case']}/build.json")
            if record["sources_sha256"] != source_hashes(): raise RuntimeError("stale firmware source identity")
            for path, expected in record["artifact_sha256"].items():
                if sha(ROOT / path) != expected: raise RuntimeError("stale firmware artifact: " + path)
            firmware.append(record)
    else:
        firmware = [build_case(case, args.cross) for case in CASES]
    if before != {p: sha(ROOT / p) for p in SOURCES}: raise RuntimeError("source changed during firmware build")
    if args.firmware_only:
        write(OUT / "firmware_build.json", dict(status="FIRMWARE BUILT", firmware=firmware, source_sha256=before))
        print("CPU5 CoreMark firmware built: four configurations; no simulation")
        return
    logical, physical = ensure_storage(args.storage)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_") + uuid.uuid4().hex[:8]
    run = logical / run_id; stage = run / "good_reference"; cases = run / "raw/cases"
    stage.mkdir(parents=True)
    for case in CASES[:args.cases]: (cases / f"case{case['case']}").mkdir(parents=True)
    for path, expected in before.items():
        target = stage / path; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / path).read_bytes())
        if sha(target) != expected: raise RuntimeError("source snapshot diverged: " + path)
    staged_firmware = stage / "build/cpu5_s18_coremark/firmware"
    shutil.copytree(FIRMWARE_OUT, staged_firmware)
    simulator_sha = sha(args.vsim)
    version = subprocess.run([str(args.vsim), "-version"], capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=30)
    if version.returncode: raise RuntimeError("simulator version probe failed")
    scripts = {
        "compile.do": ["onerror {quit -code 1 -f}", "transcript file compile_transcript.log", "vmap -c",
                       "vlib work", "vmap cpu5_coremark_work work",
                       "vlog -sv +incdir+. -work cpu5_coremark_work " + " ".join(RTL + ["tb/cpu5_coremark_tb.v"]),
                       'echo "CPU5 COREMARK CLEAN COMPILE PASS"', "quit -code 0 -f"],
        "simulate.do": ["onerror {quit -code 1 -f}", "transcript file simulation_transcript.log",
                        "vmap cpu5_coremark_work work",
                        'vsim -voptargs="+acc" -onfinish stop -gCASES=%d -gQUICK_PROBE=0 -wlf system.wlf '
                        'cpu5_coremark_work.cpu5_coremark_tb +RAW_BASE=%s +RUN_ID=%s' % (args.cases, cases.as_posix(), run_id),
                        "log sim:/cpu5_coremark_tb/test_pass sim:/cpu5_coremark_tb/completed sim:/cpu5_coremark_tb/done",
                        "run -all", "if {[examine -radix unsigned sim:/cpu5_coremark_tb/test_pass] != 1} {quit -code 1 -f}",
                        'echo "CPU5 COREMARK REFERENCE PASS"', "quit -code 0 -f"],
    }
    record = dict(schema=2, status="RUNNING", run_id=run_id, configurations=args.cases,
                  baseline_commit=BASELINE, mapped_baseline_commit=MAPPED_BASELINE,
                  case_directory=rel(cases), firmware_directory=rel(staged_firmware),
                  source_sha256=before, source_lf_sha256=before_lf, sources_unchanged=False,
                  artifact_storage=dict(logical=rel(logical), physical=str(physical)),
                  firmware=firmware, processes=[], compressed_artifacts={},
                  toolchain=dict(python=sys.version, platform=platform.platform(),
                                 simulator=str(args.vsim), simulator_sha256=simulator_sha,
                                 simulator_version=version.stdout + version.stderr),
                  positive=dict(directory=rel(stage), source_sha256=before),
                  metrics_claimed="NONE", formal_score_measured=False, hardware_download_performed=False)
    def save():
        write(run / "verification.json", record); write(OUT / "verification.json", record)
    save()
    try:
        for name, lines in scripts.items():
            (stage / name).write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        for name in scripts:
            log = stage / (name.split(".")[0] + "_console.log")
            started = time.monotonic()
            with log.open("wb") as output:
                result = subprocess.run([str(args.vsim), "-c", "-do", name], cwd=stage,
                                        stdout=output, stderr=subprocess.STDOUT, timeout=args.timeout)
            output = log.read_text(encoding="utf-8", errors="replace")
            marker = "CPU5 COREMARK CLEAN COMPILE PASS" if name == "compile.do" else "CPU5 COREMARK REFERENCE PASS"
            process = dict(name=name, exit_code=result.returncode, elapsed_seconds=time.monotonic()-started,
                           console=rel(log), console_sha256=sha(log), command=[str(args.vsim), "-c", "-do", name])
            record["processes"].append(process); save()
            if result.returncode or DIAGNOSTIC.search(output) or marker not in output:
                raise RuntimeError(name + " failed; see " + str(log) + "\n" + output[-12000:])
            if args.compile_only:
                record["status"]="COMPILE VERIFIED"; break
        if not args.compile_only:
            record["cases"] = []
            for case in CASES[:args.cases]:
                folder = cases / f"case{case['case']}"
                if set(p.name for p in folder.iterdir()) != set(CASE_FILES): raise RuntimeError("case artifact closure")
                summary = read(folder / "summary.json")
                if summary["run_id"] != run_id or summary["quick_probe"] != 0: raise RuntimeError("case run identity")
                record["cases"].append(summary)
                for path in sorted(folder.glob("*.csv")):
                    item = compress_csv(path); record["compressed_artifacts"][rel(path)] = item
            record["status"] = "SIMULATED" if args.cases == 4 else "PARTIAL SIMULATED"
        if before != {p: sha(ROOT / p) for p in SOURCES}: raise RuntimeError("source changed during simulation")
        if any(sha(stage / p) != h for p, h in before.items()): raise RuntimeError("private source snapshot changed")
        if sha(args.vsim) != simulator_sha: raise RuntimeError("simulator changed during run")
        record["sources_unchanged"] = True
        record["raw_artifact_sha256"] = {rel(p):sha(p) for p in cases.rglob("*") if p.is_file()}
        record["firmware_artifact_sha256"] = {rel(p):sha(p) for p in staged_firmware.rglob("*") if p.is_file()}
        names = ["compile.do", "simulate.do", "compile_console.log", "compile_transcript.log", "modelsim.ini"]
        if not args.compile_only: names += ["simulate_console.log", "simulation_transcript.log", "system.wlf"]
        record["positive"]["retained_artifact_sha256"] = {p:sha(stage/p) for p in names}
        record["positive"]["status"] = record["status"]
        save()
        print(json.dumps(dict(status=record["status"], run_id=run_id, configurations=args.cases,
                              record=rel(run/"verification.json"), independent_audit_required=True)))
    except Exception as error:
        record["status"]="FAILED";record["failure"]=str(error);save();raise


if __name__ == "__main__": main()

