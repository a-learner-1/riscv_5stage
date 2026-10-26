"""Independent CPU5 CoreMark audit plus negative evidence.

Two jobs, neither of which trusts the firmware report or the testbench alone:

1. Re-audit every raw case artifact with the frozen identities. The UART report
   is self-consistent (its ten classes must sum to its own window, and its tick
   gap must be the printed difference), and it must also agree with the
   testbench's independently accumulated event ledger and frozen snapshots.
2. Negative evidence: mutate a good copy of each artifact in one specific way
   and require the same auditor to reject it. An accepted mutation is a hard
   failure, because it would prove the corresponding check is not wired.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import run_cpu5_coremark as runner

ROOT = Path(__file__).resolve().parents[1]
OUT = runner.OUT


def read_lines(path):
    return path.read_text(encoding="utf-8").splitlines(True)


def write_lines(path, lines):
    path.write_text("".join(lines), encoding="utf-8", newline="")


def bump_console(directory, key, delta=1):
    path = directory / "console.txt"
    lines = read_lines(path)
    for index, line in enumerate(lines):
        if line.startswith("COREMARK " + key + "="):
            name, _, value = line.strip().partition("=")
            lines[index] = f"{name}={int(value) + delta}\n"
            write_lines(path, lines)
            return
    raise AssertionError("mutation target missing in console: " + key)


def set_console(directory, key, value):
    path = directory / "console.txt"
    lines = read_lines(path)
    for index, line in enumerate(lines):
        if line.startswith("COREMARK " + key + "="):
            name = line.split("=", 1)[0]
            lines[index] = f"{name}={value}\n"
            write_lines(path, lines)
            return
    raise AssertionError("mutation target missing in console: " + key)


def drop_console(directory, text):
    path = directory / "console.txt"
    lines = read_lines(path)
    kept = [line for line in lines if text not in line]
    if len(kept) == len(lines):
        raise AssertionError("mutation target missing in console: " + text)
    write_lines(path, kept)


def append_console(directory, text):
    path = directory / "console.txt"
    lines = read_lines(path)
    lines.append(text + "\n")
    write_lines(path, lines)


def bump_summary(directory, path, delta=1):
    target = directory / "summary.json"
    record = json.loads(target.read_text(encoding="utf-8"))
    cursor = record
    keys = path.split(".")
    for key in keys[:-1]:
        cursor = cursor[int(key)] if key.isdigit() else cursor[key]
    last = keys[-1]
    if last.isdigit():
        cursor[int(last)] = cursor[int(last)] + delta
    else:
        cursor[last] = cursor[last] + delta
    target.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8", newline="\n")


# (name, mutation, why it must be rejected)
MUTATIONS = (
    ("class_work_other_plus_one", lambda d: bump_console(d, "cycle_work_other"),
     "ten classes no longer partition the frozen window"),
    ("counter_cycles_plus_one", lambda d: bump_console(d, "counter_cycles"),
     "the firmware window no longer matches the frozen snapshots"),
    ("counter_valid_zero", lambda d: set_console(d, "counter_valid", 0),
     "an invalid window must never be reported as valid"),
    ("profile_valid_zero", lambda d: set_console(d, "cycle_profile_valid", 0),
     "a broken class partition must invalidate the window"),
    ("seedcrc_wrong", lambda d: set_console(d, "seedcrc", "0x1234"),
     "the performance-seed CRC is frozen"),
    ("crclist_wrong", lambda d: set_console(d, "crclist", "0x0000"),
     "the list CRC is frozen"),
    ("icache_access_plus_one", lambda d: bump_console(d, "icache_access"),
     "printed cache delta must match the frozen snapshot bank"),
    ("bp_lookup_plus_one", lambda d: bump_console(d, "bp_lookup"),
     "printed BTB delta must match the frozen snapshot bank"),
    ("stats_schema_three", lambda d: set_console(d, "stats_schema", 3),
     "only schema 4 is accepted"),
    ("cache_enable_flip", lambda d: set_console(d, "cache_enable", 1),
     "the observed cache switch identity is frozen"),
    ("tick_gap_plus_one", lambda d: bump_console(d, "window_tick_gap"),
     "the mtime interval must stay inside the statistics interval"),
    ("profile_sum_plus_one", lambda d: bump_console(d, "cycle_profile_sum"),
     "the published class sum is frozen"),
    ("drop_result_line", lambda d: drop_console(d, "COREMARK RESULT: SMOKE PASS"),
     "a run without a result line is not a pass"),
    ("inject_error_text", lambda d: append_console(d, "ERROR: injected"),
     "an error line must fail the run"),
    ("inject_formal_claim", lambda d: append_console(d, "COREMARK RESULT: FORMAL PASS"),
     "a formal score must never be claimed from a one-iteration run"),
    ("summary_window_plus_one", lambda d: bump_summary(d, "window.snapshot_cycle_delta"),
     "the recorded window must equal the live counter difference"),
    ("summary_starts_one", lambda d: bump_summary(d, "raw_starts", -1),
     "the statistics trigger closure is frozen"),
    ("summary_console_bytes_plus_one",
     lambda d: bump_summary(d, "console_bytes"),
     "UART byte count must equal the observed start bits"),
    ("summary_bp_stop_plus_one", lambda d: bump_summary(d, "bp.stop.0"),
     "snapshot banks and printed deltas are cross-checked"),
    ("summary_cache_flag_flip", lambda d: bump_summary(d, "cache"),
     "the case identity is frozen"),
    ("summary_retired_impossible", lambda d: bump_summary(d, "retired", 10 ** 9),
     "a whole-program retirement count above the cycle budget is impossible"),
    ("console_backend_id_wrong", lambda d: set_console(d, "backend_id", 1),
     "the hardware-observed data backend identity is frozen"),
)


def console_self_consistency(console):
    """Checks that use only the firmware's own UART report."""
    values = runner.parse_console(console)
    classes = {name: int(values["cycle_" + name]) for name in runner.CLASSES}
    window = int(values["counter_cycles"])
    retired = int(values["counter_retired"])
    ticks = int(values["raw_ticks"])
    gap = int(values["window_tick_gap"])
    assert sum(classes.values()) == window == int(values["cycle_profile_sum"])
    assert window > 0 and retired > 0 and retired <= window
    assert 0 < ticks <= window
    assert window - ticks == gap <= runner.MAX_TICK_GAP
    for name, value in classes.items():
        assert 0 <= value <= window, name
    return {"window_cycles": window, "window_retired": retired,
            "cycle_classes": classes, "window_tick_gap": gap}


def cross_configuration(analysed):
    """Invariants that follow from running one compiled image family on four
    memory configurations. These are derived from the recorded artifacts only;
    they are not testbench or firmware claims."""
    by_case = {(case["d0"], case["cache"]): case for case in analysed}
    # 1. One instruction stream: every configuration retires the same count.
    retired = {case["window_retired"] for case in analysed}
    assert len(retired) == 1, retired
    # 2. Purely CPU-internal classes do not depend on the data backend or cache.
    for name in ("mul_wait", "local_mmio_wait"):
        values = {case["cycle_classes"][name] for case in analysed}
        assert len(values) == 1, (name, values)
    # Resolved branches, next-PC mismatches and direction errors describe the
    # committed control flow, so they are identical in every configuration;
    # only the fetch-side lookups/hits/taken may move.
    for index in (3, 4, 5):
        values = {case["bp_delta"][index] for case in analysed}
        assert len(values) == 1, (index, values)
    # work_other may absorb re-attributed stall cycles; a wide band catches an
    # implausible re-attribution without encoding a performance expectation.
    work = [case["cycle_classes"]["work_other"] for case in analysed]
    assert max(work) - min(work) <= max(work) // 100, work
    # 3. Fetch wait exists only when an instruction cache is in the path: the
    # frozen IMEM endpoint itself has no wait states.
    for case in analysed:
        wait = case["cycle_classes"]["ifetch_wait"]
        if case["cache"] == 0:
            assert wait == 0, case
        else:
            assert wait > 0, case
    # 4. Backend and cache cycle effects are REPORTED, never asserted: a faster
    # D0 path or a better cache would legitimately invert them.
    deltas, wait_reduction = {}, {}
    for cache in (0, 3):
        if (0, cache) not in by_case or (1, cache) not in by_case:
            continue
        axi, d0 = by_case[(0, cache)], by_case[(1, cache)]
        deltas[str(cache)] = axi["window_cycles"] - d0["window_cycles"]
        for name in ("data_read_wait", "data_write_wait"):
            wait_reduction[f"{name}@{cache}"] = (axi["cycle_classes"][name] -
                                                 d0["cycle_classes"][name])
    # 5. The cached configurations must see the same data-access stream.
    if (0, 3) in by_case and (1, 3) in by_case:
        axi_cache, d0_cache = by_case[(0, 3)], by_case[(1, 3)]
        assert axi_cache["dcache_delta"][0] == d0_cache["dcache_delta"][0]
        assert axi_cache["dcache_delta"][5] == d0_cache["dcache_delta"][5]
    return {"retired_identical": next(iter(retired)),
            "mul_wait_identical": analysed[0]["cycle_classes"]["mul_wait"],
            "local_mmio_wait_identical": analysed[0]["cycle_classes"]["local_mmio_wait"],
            "bp_resolved_identical": analysed[0]["bp_delta"][3],
            "bp_next_pc_mismatch_identical": analysed[0]["bp_delta"][4],
            "bp_direction_error_identical": analysed[0]["bp_delta"][5],
            "work_other_spread": max(work) - min(work),
            "observations_only": {"d0_window_saving": deltas,
                                  "d0_data_wait_reduction": wait_reduction},
            "dcache_access_identical": by_case.get((0, 3), {}).get("dcache_delta", [None])[0],
            "dcache_write_identical": by_case.get((0, 3), {}).get("dcache_delta", [None] * 6)[5]}


def source_identity_chain():
    """Anchor the measured sources to the local commit.

    The repository keeps a CRLF working tree for its older files while Git
    stores canonical LF blobs, so the chain is checked in two steps: the current
    working-tree bytes must still hash to the value recorded at run time, and
    the LF-normalized bytes must equal the committed blob."""
    verification = json.loads((OUT / "verification.json").read_text(encoding="utf-8"))
    sources = verification["source_sha256"]
    drift, uncommitted, anchored = [], [], 0
    for path, expected in sorted(sources.items()):
        data = (ROOT / path).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            drift.append(path)
            continue
        blob = subprocess.run(["git", "cat-file", "-p", ":" + path], cwd=ROOT,
                              capture_output=True)
        if blob.returncode != 0:
            # Not staged yet: fall back to the committed tree.
            blob = subprocess.run(["git", "cat-file", "-p", "HEAD:" + path], cwd=ROOT,
                                  capture_output=True)
        if blob.returncode != 0:
            uncommitted.append(path)
            continue
        if hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest() != \
                hashlib.sha256(blob.stdout).hexdigest():
            uncommitted.append(path)
            continue
        anchored += 1
    assert not drift, "sources changed after the measured run: " + json.dumps(drift[:5])
    assert not uncommitted, ("sources are not in the local commit: "
                             + json.dumps(uncommitted[:5]))
    return {"sources": len(sources),
            "working_tree_matches_recorded_raw_sha256": len(sources),
            "canonical_lf_sha256_matches_committed_blob": anchored}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=int, default=len(runner.CASES))
    arguments = parser.parse_args()
    # An empty selection must never produce a PASS: there would be nothing to
    # audit and the mutation sweep would be the only work performed.
    if not 1 <= arguments.cases <= len(runner.CASES):
        parser.error("--cases must be in 1..%d" % len(runner.CASES))
    report = {}
    analysed = []
    for number in range(arguments.cases):
        directory = OUT / "cases" / f"case{number}"
        record = runner.audit_case(directory, number)
        selfcheck = console_self_consistency(
            (directory / "console.txt").read_text(encoding="utf-8", errors="replace"))
        assert selfcheck["window_cycles"] == record["window_cycles"]
        assert selfcheck["window_retired"] == record["window_retired"]
        assert selfcheck["cycle_classes"] == record["cycle_classes"]
        assert selfcheck["window_tick_gap"] == record["window_tick_gap"]
        analysed.append({"case": number, "d0": record["d0"], "cache": record["cache"],
                         "window_cycles": record["window_cycles"],
                         "window_retired": record["window_retired"],
                         "cycle_classes": record["cycle_classes"],
                         "dcache_delta": record["dcache_delta"],
                         "bp_delta": record["bp_delta"],
                         "console_self_consistent": True,
                         "independent_snapshot_agreement": True})
    conservation = cross_configuration(analysed) if len(analysed) > 1 else {}
    rejected, accepted = [], []
    for name, mutate, reason in MUTATIONS:
        with tempfile.TemporaryDirectory(dir=OUT) as scratch:
            directory = Path(scratch) / "case"
            shutil.copytree(OUT / "cases" / "case0", directory)
            mutate(directory)
            try:
                runner.audit_case(directory, 0)
            except AssertionError as error:
                text = str(error).strip()
                first = text.splitlines()[0] if text else type(error).__name__
                rejected.append({"name": name, "reason": reason,
                                 "rejection": first[:200]})
            else:
                accepted.append({"name": name, "reason": reason})
    if accepted:
        raise AssertionError("accepted negative-evidence mutations: "
                            + json.dumps(accepted, indent=2))
    report = {
        "status": "PASS", "cases": analysed,
        "cross_configuration": conservation,
        "source_identity_chain": source_identity_chain(),
        "mutation_total": len(MUTATIONS), "mutation_rejected": len(rejected),
        "mutations": rejected,
        "independent_sources": [
            "testbench event ledger accumulated from CPU5 perf_cycle_events pins",
            "frozen schema4 START/STOP snapshot banks (sixteen ordinary words each)",
            "frozen schema4 ten-class 64-bit snapshot banks",
            "live cycle_count/instret_count sampled at the statistics trigger edges",
            "real uart_tx start-bit edges versus MMIO transmit edges",
            "upstream CoreMark performance-seed CRC set 0xe9f5/0xe714/0x1fd7/0x8e3a",
        ],
        "scope": ("Audits the recorded one-iteration CPU5 CoreMark simulation artifacts. "
                  "It does not re-run ModelSim, does not measure a formal benchmark score, "
                  "and says nothing about P&R, timing closure or any board result."),
    }
    (OUT / "audit.json").write_text(json.dumps(report, indent=2) + "\n",
                                   encoding="utf-8", newline="\n")
    print(json.dumps({"status": report["status"],
                      "cases": len(analysed),
                      "mutations_rejected": len(rejected),
                      "mutation_total": len(MUTATIONS)}))


if __name__ == "__main__":
    main()
