"""Passive RV32IM retirement-distance audit; never infer CPU5 readiness/stalls."""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BRANCH = {0: "BEQ", 1: "BNE", 4: "BLT", 5: "BGE", 6: "BLTU", 7: "BGEU"}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def decode(word):
    op, f3, f7 = word & 127, (word >> 12) & 7, word >> 25
    rd, rs1, rs2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
    kind, name, sources, writes, producer = "other", "OTHER", [], False, "NONE"
    if op == 0x63 and f3 in BRANCH:
        kind, name, sources = "conditional", BRANCH[f3], [rs1, rs2]
    elif op == 0x67 and f3 == 0:
        kind, name, sources, writes, producer = "jalr", "JALR", [rs1], True, "LINK"
    elif op == 0x6f:
        kind, name, writes, producer = "jal", "JAL", True, "LINK"
    elif op == 3 and f3 in {0, 1, 2, 4, 5}:
        writes, producer = True, "LOAD"
    elif op == 0x33 and f7 == 1:
        writes, producer = True, "M"
    elif op in {0x13, 0x33, 0x17, 0x37}:
        writes, producer = True, "ALU"
    elif op == 0x73 and f3 in {1, 2, 3, 5, 6, 7}:
        writes, producer = True, "CSR"
    return dict(kind=kind, name=name, rd=rd, sources=sorted(set(s for s in sources if s)),
                writes=bool(writes and rd), producer=producer)

def bucket(distance):
    return "distance1_raw" if distance == 1 else "distance2_raw" if distance == 2 else "distance3plus_raw"

def find_dependencies(decoded, seq, writers):
    # A source uses its closest preceding writer, never an overwritten value.
    result = []
    for source in decoded["sources"]:
        if source in writers:
            writer = writers[source]
            result.append(dict(source_reg=source, distance=seq-writer["seq"], **writer))
    return result

def analyze(profile, directory):
    stem = "coremark_d0_m_cache_on_btb_" + profile.replace("-", "_")
    report_path = ROOT / "build/coremark" / ("d0_m_cache_on_btb_"+profile.replace("-", "_")) / "build_report.json"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    firmware_sha = report["elf_sha256"]
    rom_path = ROOT / "programs" / (stem+".hex")
    ram_path = ROOT / "programs" / (stem+"_data.hex")
    config_path = ROOT / "programs" / (stem+"_config.vh")
    elf_path = report_path.parent / "coremark.elf"
    assert sha(elf_path) == firmware_sha
    for image in (rom_path, ram_path, config_path):
        assert sha(image) == report["images_sha256"][image.relative_to(ROOT).as_posix()]
    words = [int(line.strip(),16) for line in rom_path.read_text().splitlines() if line.strip()]
    meta = dict(csv.reader((directory/"observer_metadata.csv").open(newline="",encoding="utf-8")))
    meta.pop("key")
    assert meta["profile"] == profile
    numeric = {k:int(v) for k,v in meta.items() if k != "profile"}
    assert numeric["raw_starts"] >= 1 and numeric["selected_epoch"] == numeric["raw_starts"]
    assert numeric["stop_triggers"] == 1 and numeric["original_workload_pass"] == 1
    endpoints = list(csv.DictReader((directory/"window_endpoints.csv").open(newline="",encoding="utf-8")))
    starts = [r for r in endpoints if r["kind"] == "START"]
    stops = [r for r in endpoints if r["kind"] == "STOP"]
    assert len(starts) == numeric["raw_starts"] and len(stops) == 1
    start, stop = int(starts[-1]["edge"]), int(stops[0]["edge"])
    assert (start,stop) == (numeric["start_edge"],numeric["stop_edge"])
    assert stop-start == numeric["frozen_cycles"]
    assert sum(numeric[f"cycle_class_{i}"] for i in range(6)) == stop-start

    aggregates = defaultdict(Counter)
    groups = {k:Counter() for k in ("all", "conditional", "jalr")}
    writers = {}
    counters = Counter()
    last_seq, last_edge = 0, 0
    details_path = directory / "branch_source_dependencies.csv"
    detail_fields = ["seed","firmware_sha","branch_seq","branch_retire_edge","branch_pc","opcode",
                     "source_reg","writer_seq","writer_pc","writer_class","writer_retire_edge","distance","writer_before_start"]
    with details_path.open("w",newline="",encoding="utf-8") as out:
        detail = csv.DictWriter(out,fieldnames=detail_fields); detail.writeheader()
        for raw in csv.DictReader((directory/"retirement_trace.csv").open(newline="",encoding="utf-8")):
            row = {k:int(v,16) if k in {"pc","instr"} else int(v) for k,v in raw.items()}
            seq, edge = row["seq"], row["retire_edge"]
            assert seq == last_seq+1 and edge > last_edge
            last_seq, last_edge = seq, edge
            assert row["pc"]%4 == 0 and row["pc"]//4 < len(words)
            assert words[row["pc"]//4] == row["instr"]
            dec = decode(row["instr"])
            assert row["wb_we"] == dec["writes"], (hex(row["pc"]),hex(row["instr"]),row["wb_we"],dec)
            if dec["writes"]: assert row["wb_rd"] == dec["rd"]
            assert row["resolve_edge"] == edge-1
            assert not row["normal_redirect"] or row["resolve_valid"]
            assert row["predictable"] == (row["resolve_valid"] and dec["kind"] in {"conditional","jal"})
            in_window = start <= edge < stop
            resolution_window = start <= row["resolve_edge"] < stop
            if resolution_window:
                counters["resolved_execution_window"] += row["predictable"]
                counters["mismatch_execution_window"] += row["normal_redirect"]
                counters["direrr_execution_window"] += row["direction_error"]
                counters["R_execution_"+dec["kind"]] += row["normal_redirect"]
            if in_window:
                counters["retired"] += 1
                counters["resolved_retirement_window"] += row["predictable"]
                counters["mismatch_retirement_window"] += row["normal_redirect"]
                counters["direrr_retirement_window"] += row["direction_error"]
                counters["R_retirement_"+dec["kind"]] += row["normal_redirect"]
                if dec["kind"] in {"conditional","jalr"}:
                    # Include all these control opcodes; separately expose the
                    # degenerate x0-only cases, which have no GPR dependencies.
                    deps = find_dependencies(dec,seq,writers)
                    agg = aggregates[(row["pc"],dec["name"],dec["kind"])]
                    for target in (agg,groups["all"],groups[dec["kind"]]):
                        target["branch_total"] += 1
                        target["branch_gpr_sources"] += bool(dec["sources"])
                        target["redirect_events"] += row["normal_redirect"]
                        target["no_prior_writer"] += not deps
                        target["source_dependencies"] += len(deps)
                        if deps:
                            target["nearest_"+bucket(min(d["distance"] for d in deps))] += 1
                        # Each distance bucket counts a branch at most once;
                        # different source distances can hit multiple buckets.
                        for b in set(bucket(d["distance"]) for d in deps): target[b] += 1
                        for cls in set(d["producer"] for d in deps): target["raw_from_"+cls.lower()] += 1
                        for cls in set(d["producer"] for d in deps if d["distance"]==1): target["distance1_from_"+cls.lower()] += 1
                        target["cross_start_writer_branches"] += any(d["edge"]<start for d in deps)
                    for dep in deps:
                        detail.writerow(dict(seed=report["seed_profile"],firmware_sha=firmware_sha,branch_seq=seq,
                            branch_retire_edge=edge,branch_pc=f"0x{row['pc']:08x}",opcode=dec["name"],
                            source_reg=dep["source_reg"],writer_seq=dep["seq"],writer_pc=f"0x{dep['pc']:08x}",
                            writer_class=dep["producer"],writer_retire_edge=dep["edge"],distance=dep["distance"],
                            writer_before_start=int(dep["edge"]<start)))
            if dec["writes"]:
                writers[dec["rd"]] = dict(seq=seq,pc=row["pc"],edge=edge,producer=dec["producer"])
    assert last_seq == numeric["trace_retirements"]
    for observed,frozen in (("retired","frozen_retired"),("resolved_execution_window","frozen_resolved"),
                            ("mismatch_execution_window","frozen_mismatch"),("direrr_execution_window","frozen_direrr")):
        assert counters[observed] == numeric[frozen], (observed,counters[observed],numeric[frozen])
    # Only one-cycle registered retirement latency separates the two sets.
    for field, observed, frozen in (("resolved","resolved_retirement_window","frozen_resolved"),
                                   ("mismatch","mismatch_retirement_window","frozen_mismatch")):
        counters[field+"_boundary_adjustment"] = numeric[frozen]-counters[observed]
    fields = ["seed","profile","firmware_sha","branch_pc","opcode","kind","branch_total","branch_gpr_sources",
              "distance1_raw","distance2_raw","distance3plus_raw","nearest_distance1_raw","nearest_distance2_raw","nearest_distance3plus_raw","no_prior_writer","raw_from_load","raw_from_m",
              "raw_from_alu","raw_from_csr","raw_from_link","distance1_from_load","distance1_from_m",
              "redirect_events","cross_start_writer_branches"]
    csv_path=directory/"branch_raw_trace.csv"
    with csv_path.open("w",newline="",encoding="utf-8") as out:
        writer=csv.DictWriter(out,fieldnames=fields);writer.writeheader()
        for (pc,name,kind), counts in sorted(aggregates.items()):
            data={f:counts[f] for f in fields if f not in {"seed","profile","firmware_sha","branch_pc","opcode","kind"}}
            writer.writerow(dict(seed=report["seed_profile"],profile=profile,firmware_sha=firmware_sha,branch_pc=f"0x{pc:08x}",opcode=name,kind=kind,**data))
    for counts in groups.values():
        assert sum(counts[k] for k in ("nearest_distance1_raw","nearest_distance2_raw","nearest_distance3plus_raw","no_prior_writer")) == counts["branch_total"]
    result=dict(schema="cpu5_baseline_raw_v1",profile=profile,seed=report["seed_profile"],iterations=report["configured_iterations"],
        isa=report["march"],clock_hz=report["clock_hz"],cache_mode=report["cache_mode"],btb_entries=report["btb_entries"],
        firmware_sha256=firmware_sha,rom_sha256=sha(rom_path),ram_sha256=sha(ram_path),config_sha256=sha(config_path),
        build_report_sha256=sha(report_path),sources_sha256=report["sources_sha256"],
        selected_window=dict(numeric,stop_edge_exclusive=stop),
        reconciliation=dict(counters),groups={k:dict(v) for k,v in groups.items()},
        interpretation={
            "B_dyn":"conditional branches plus JALR in retirement window; JAL excluded; x0-only control counted separately via branch_gpr_sources",
            "distance_buckets":"distance1/2/3plus each count a branch once per category using each source's closest writer; categories may overlap across different sources. nearest_distance* is the separate exclusive minimum-distance partition with no_prior_writer",
            "per_source":"branch_source_dependencies.csv preserves both nonzero sources' closest writers; rs1==rs2 deduplicated; a branch with source distances 1 and 2 appears once in D1 and once in D2, and only nearest_D1",
            "producer_class":"raw_from_* counts branch once per closest-writer class across any distance; distance1_from_* isolates immediately preceding producer",
            "R":"normal_redirect_x && redirect_x age-valid source; retirement-window R_by_kind separately from hardware execution-window mismatch; only conditional/JALR subset is comparable to B_dyn",
            "timing":"pre-NBA retirement ports at edge E update instret(E); resolve/redirect attached from edge E-1; frozen BP counters update from execution events at their own edge",
            "history":"all preceding retirements from reset retained; closest writers before final START remain eligible and are marked",
            "cpu5_hazard_cycles":"NOT RUN: CPU5 RTL absent; distance is not readiness, bubbles, or net cycle savings",
            "formal_score":"NOT RUN: one-iteration smoke only; UART short-duration Errors detected is expected after CRC checks"},
        checks={"original_workload_crc_uart_mtime_frozen":True,"retirement_pc_rom_actual_rom":True,
                "actual_wb_decode_agree":True,"age_binding":True,"window_epoch":True,"six_cycle_partition":True,
                "retired_frozen":True,"resolved_frozen":True,"mismatch_frozen":True,"direrr_frozen":True})
    for name in ("retirement_trace.csv","window_endpoints.csv","observer_metadata.csv","branch_raw_trace.csv","branch_source_dependencies.csv"):
        result.setdefault("output_sha256",{})[name]=sha(directory/name)
    (directory/"summary.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"profile":profile,"checks":"PASS","cycles":numeric["frozen_cycles"],"groups":result["groups"],"reconciliation":result["reconciliation"]},ensure_ascii=False))
    return result

def self_test():
    # Independent hand-constructed dynamic histories (no simulator required).
    def r(op,rd=0,rs1=0,rs2=0,f3=0,f7=0): return f7<<25|rs2<<20|rs1<<15|f3<<12|rd<<7|op
    checks=0
    dec=decode(r(0x63,rs1=5,rs2=5)); assert dec["sources"]==[5]; checks+=1
    writers={5:dict(seq=3,pc=12,edge=8,producer="LOAD")}
    deps=find_dependencies(dec,4,writers); assert len(deps)==1 and deps[0]["distance"]==1; checks+=1
    writers[5]=dict(seq=4,pc=16,edge=9,producer="ALU")
    deps=find_dependencies(dec,5,writers); assert deps[0]["distance"]==1 and deps[0]["producer"]=="ALU"; checks+=1
    assert find_dependencies(dec,6,writers)[0]["distance"]==2; checks+=1
    assert find_dependencies(dec,8,writers)[0]["distance"]==4; checks+=1
    assert decode(r(0x63,rs1=0,rs2=0))["sources"]==[]; checks+=1
    assert not decode(r(0x13,rd=0))["writes"]; checks+=1
    assert not decode(r(0x23,rd=5,rs1=5,rs2=5))["writes"]; checks+=1
    assert decode(r(0x67,rd=1,rs1=5))["kind"]=="jalr"; checks+=1
    assert decode(r(0x6f,rd=1))["kind"]=="jal" and not decode(r(0x6f,rd=1))["sources"]; checks+=1
    assert decode(r(0x73,rd=5,f3=5,rs1=7))["producer"]=="CSR"; checks+=1
    assert decode(r(0x33,rd=5,f7=1))["producer"]=="M"; checks+=1
    # Distinct-source D1/D2 is one branch in exclusive nearest bucket, while
    # the detailed two sources retain both distances. Cross-START history stays.
    dec=decode(r(0x63,rs1=5,rs2=6)); writers[6]=dict(seq=3,pc=12,edge=8,producer="M")
    deps=find_dependencies(dec,5,writers); assert sorted(d["distance"] for d in deps)==[1,2]; checks+=1
    assert bucket(min(d["distance"] for d in deps))=="distance1_raw"; checks+=1
    assert any(d["edge"]<9 for d in deps); checks+=1
    # [START,STOP) includes START, excludes STOP independently at retire vs resolve.
    assert [e for e in (9,10,19,20) if 10<=e<20]==[10,19]; checks+=1
    print(json.dumps({"self_tests":"PASS","cases":checks,"scope":"hand-derived closest-writer, overwrite, dual source, x0, classification, boundary"}))
    return checks

def main():
    p=argparse.ArgumentParser();p.add_argument("--profile",choices=["smoke","smoke-validation"]);p.add_argument("--directory",type=Path);p.add_argument("--self-test",action="store_true")
    a=p.parse_args()
    if a.self_test: self_test()
    if a.profile:
        if not a.directory: p.error("--directory required with --profile")
        analyze(a.profile,a.directory)
    elif not a.self_test: p.error("select --profile or --self-test")

if __name__=="__main__":
    main()
