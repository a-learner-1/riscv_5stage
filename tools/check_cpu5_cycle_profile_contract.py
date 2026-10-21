#!/usr/bin/env python3
"""Static CPU5 ABI checks only. Does not claim CPU5 RTL/firmware verification."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess

NAMES = ["work_other", "ifetch_wait", "data_read_wait", "data_write_wait",
         "local_mmio_wait", "redirect_wait", "mul_wait", "div_wait",
         "load_use_wait", "id_hazard_wait"]
PRIORITY = ["local_mmio_wait", "data_write_wait", "data_read_wait", "mul_wait",
            "div_wait", "load_use_wait", "id_hazard_wait", "redirect_wait",
            "ifetch_wait", "work_other"]
KEYS = ["start_low", "start_high", "stop_low", "stop_high"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(contract, legacy, soc, header):
    require(contract["status"] == "DESIGN CONTRACT ONLY; CPU5 RTL NOT IMPLEMENTED / NOT RUN", "implementation status")
    require((contract["hardware_schema"], contract["cycle_profile_schema"],
             contract["event_width"], contract["counter_bits"]) == (4, 2, 10, 64), "version/width")
    require((int(contract["stats_base"], 0), contract["stats_window_bytes"]) == (0x30000000, 0x200), "window")
    require(contract["priority_order"] == PRIORITY, "priority")
    require([c["name"] for c in contract["classes"]] == NAMES, "class names/order")
    require([c["bit"] for c in contract["classes"]] == list(range(10)), "event bits")
    require([int(contract[k], 0) for k in ("start_trigger", "stop_trigger", "schema_register")] == [0, 4, 0x18], "trigger/schema offsets")
    # Match explicit case labels in the actual old decoder, including metadata.
    case_text = legacy.split("case (offset)", 1)[1].split("endcase", 1)[0]
    old_offsets = {int(x, 16) for x in re.findall(r"32'h([0-9a-fA-F]+)\s*:", case_text)}
    expected_old = set(range(0, 0x20, 4)) | set(range(0x40, 0x80, 4)) | set(range(0x80, 0xc0, 4)) | set(range(0xc0, 0xdc, 4)) | set(range(0xe0, 0xfc, 4)) | set(range(0x100, 0x130, 4)) | set(range(0x140, 0x170, 4))
    require(old_offsets == expected_old, "unexpected legacy decoder; audit map again")
    require("default: begin" in case_text and "s_axi_rresp <= 2'b10" in case_text.split("default:", 1)[1], "legacy reserved SLVERR")
    require("input wire [5:0] perf_cycle_events" in legacy and "32'h18: s_axi_rdata <= 32'd3;" in legacy, "legacy schema/width")
    require(".M1_SIZE_BYTES(32'h200)" in soc, "actual SoC window override")
    require("COREMARK_AXI_STATS_SCHEMA != 3" in header and "COREMARK_AXI_CYCLE_PROFILE_SCHEMA != 1" in header and "COREMARK_AXI_CYCLE_PROFILE_FIELDS != 6" in header, "legacy firmware rejects new ABI")
    all_offsets = []
    for i, c in enumerate(contract["classes"]):
        a = [int(c[k], 0) for k in KEYS]
        require(all(0 <= x < 0x200 and x % 4 == 0 for x in a), "address range/alignment")
        expected = ([0x100 + i * 8, 0x104 + i * 8, 0x140 + i * 8, 0x144 + i * 8]
                    if i < 6 else [0x180 + (i-6)*8, 0x184 + (i-6)*8, 0x1c0 + (i-6)*8, 0x1c4 + (i-6)*8])
        require(a == expected, "snapshot address contract")
        require((set(a) <= old_offsets) if i < 6 else set(a).isdisjoint(old_offsets), "legacy collision")
        if i < 6:
            for offset, bank, bits in zip(a, ["start", "start", "stop", "stop"], ["31:0", "63:32", "31:0", "63:32"]):
                require(f"32'h{offset:x}: s_axi_rdata <= cycle_{bank}_snapshot[{i}][{bits}];" in legacy, "legacy field mapping")
        all_offsets += a
    require(len(set(all_offsets)) == 40, "duplicate profile word")
    return {"profile_words": 40, "preserved_legacy_profile_words": 24,
            "new_words_in_old_reserved_space": 16, "legacy_decode_offsets": len(old_offsets),
            "new_rtl": "NOT IMPLEMENTED", "new_rtl_snapshot_and_onehot_tests": "NOT RUN"}


def self_test(contract, sources):
    mutations = [
        lambda c: c.update(hardware_schema=3),
        lambda c: c.update(cycle_profile_schema=1),
        lambda c: c.update(event_width=6),
        lambda c: c.update(stats_window_bytes=256),
        lambda c: c["classes"][6].update(start_low="0x130"),
        lambda c: c["classes"][6].update(start_low="0x140"),
        lambda c: c["classes"][9].update(stop_high="0x200"),
        lambda c: c["classes"][9].update(stop_high="0x1db"),
        lambda c: c["classes"][6].update(bit=5),
        lambda c: c["classes"][0].update(name="retired"),
        lambda c: c.update(priority_order=list(reversed(PRIORITY))),
        lambda c: c.update(status="IMPLEMENTATION PASS"),
    ]
    validate(contract, *sources)
    for i, change in enumerate(mutations):
        bad = copy.deepcopy(contract)
        change(bad)
        try:
            validate(bad, *sources)
        except ValueError:
            continue
        raise AssertionError(f"invalid contract mutation accepted: {i}")
    return {"valid_contract": "PASS", "negative_contract_cases_rejected": len(mutations)}


def legacy_guard(cc, config, header):
    cases = [("old_abi", {}, 0), ("new_hardware_schema", {"COREMARK_AXI_STATS_SCHEMA":4}, 1),
             ("new_profile_schema", {"COREMARK_AXI_CYCLE_PROFILE_SCHEMA":2}, 1),
             ("ten_fields", {"COREMARK_AXI_CYCLE_PROFILE_FIELDS":10}, 1),
             ("cpu5_abi", {"COREMARK_AXI_STATS_SCHEMA":4, "COREMARK_AXI_CYCLE_PROFILE_SCHEMA":2,
                           "COREMARK_AXI_CYCLE_PROFILE_FIELDS":10}, 1)]
    records = []
    for name, overrides, expected in cases:
        source = f'#include "{config.resolve().as_posix()}"\n'
        for key, value in overrides.items():
            source += f"#undef {key}\n#define {key} {value}\n"
        source += f'#include "{header.resolve().as_posix()}"\n'
        process = subprocess.run([str(cc), "-E", "-x", "c", "-"], input=source,
                                 encoding="utf-8", capture_output=True, check=False)
        require(process.returncode == expected, f"legacy preprocess guard {name}: {process.returncode}")
        if expected:
            require("#error" in process.stderr, f"guard must reject deliberately: {name}")
        records.append({"case": name, "exit_code": process.returncode,
                        "expected_exit_code": expected, "stderr": process.stderr})
    return {"compiler": str(cc), "config_sha256": hashlib.sha256(config.read_bytes()).hexdigest(),
            "cases": records, "scope": "Old C compile guards only; new CPU5 firmware is NOT IMPLEMENTED / NOT RUN"}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--contract", type=Path)
    ap.add_argument("--output", type=Path)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--cc", type=Path, help="Optional RISC-V GCC for real old-header preprocess guard tests")
    ap.add_argument("--legacy-config", type=Path, help="Existing generated schema3/profile1 C build config")
    args = ap.parse_args()
    path = args.contract or args.root / "docs/cpu5_cycle_profile_contract.json"
    paths = [args.root / p for p in ["rtl/axi_lite_coremark_stats.v", "rtl/soc_coremark_axi_top.v", "software/coremark_port/coremark_axi_stats.h"]]
    sources = [p.read_text(encoding="utf-8-sig") for p in paths]
    contract = json.loads(path.read_text(encoding="utf-8-sig"))
    result = {"status": "PASS (static design contract only)", "checks": validate(contract, *sources),
              "inputs": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in [path, *paths]]}
    if args.self_test:
        result["self_test"] = self_test(contract, sources)
    require(bool(args.cc) == bool(args.legacy_config), "--cc and --legacy-config must be supplied together")
    if args.cc:
        result["legacy_compile_guards"] = legacy_guard(args.cc, args.legacy_config, paths[2])
    text = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    main()
