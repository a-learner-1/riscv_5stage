"""Independent public-port ledger for the seven CPU5 IF reuse gates."""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
from pathlib import Path


def analyze(root: Path) -> dict:
    out = root / "build/cpu5_s1_if"
    rows = list(csv.DictReader((out / "events.csv").open(newline="")))
    gates = list(csv.DictReader((out / "gates.csv").open(newline="")))
    assert [int(g["gate"]) for g in gates] == list(range(1, 8))
    assert all(g["result"] == "PASS" for g in gates)
    counters = dict(requests=0, responses=0, transfers=0, fault_transfers=0,
                    redirects=0, bp_updates=0, same_edge=0, stale_responses=0)
    pending = held = packet = None
    epoch = next_seq = 0
    btb = {}
    last_bp = None
    last_gate = 0
    checks = 0

    def require(condition, message):
        nonlocal checks
        checks += 1
        assert condition, message

    def number(row, key):
        return int(row[key], 16 if key in {
            "req_addr", "rsp_data", "ifid_pc", "ifid_instr", "pred_next",
            "fetch_tval", "bp_pc", "bp_target"} else 10)

    for row in rows:
        r = {k: number(row, k) for k in row}
        gate, cycle = r["gate"], r["cycle"]
        if gate != last_gate and gate != 2:
            pending = held = packet = None
            epoch = next_seq = 0
            btb = {}
            last_bp = None
        last_gate = gate
        prefix = f"cycle {cycle}, gate {gate}: "
        require(bool(r["ifid_valid"]) == (packet is not None), prefix + "slot validity")
        if packet:
            for key, value in packet.items():
                require(r[key] == value, prefix + f"packet {key}: {r[key]} != {value}")
        if held:
            require(r["req_valid"] == 1 and r["req_addr"] == held["pc"],
                    prefix + "held request valid/address stability")
        redirect = bool(r["redirect_fire"])
        if redirect:
            counters["redirects"] += 1
            require(r["redirect_kill"] or (r["ifid_valid"] and r["id_ready"]),
                    prefix + "ID-owned redirect requires actual transfer")
        req_fire = r["req_valid"] and r["req_ready"]
        rsp_fire = r["rsp_valid"] and r["rsp_ready"]
        if r["ifid_valid"] and r["id_ready"]:
            counters["transfers"] += 1
            counters["fault_transfers"] += r["fetch_error"]
        # Predict before applying this edge's MEM training, just as synchronous
        # logic does. Metadata is captured on first presentation, not acceptance.
        desc = held
        if r["req_valid"] and not desc:
            pc = r["req_addr"]
            hit = pc in btb and pc % 4 == 0 and 0 <= pc < 8192 * 4
            taken = hit and (btb[pc][1] == 4 or btb[pc][1] >= 2)
            if redirect:
                hit = taken = False
            desc = dict(pc=pc, pred=btb[pc][0] if taken else pc + 4,
                        hit=int(hit), taken=int(taken), epoch=epoch + int(redirect), stale=False)
        drop = bool(pending and pending["stale"]) or redirect
        if redirect or (r["ifid_valid"] and r["id_ready"]):
            packet = None
        if rsp_fire:
            counters["responses"] += 1
            require(pending is not None, prefix + "response owner")
            if drop:
                counters["stale_responses"] += 1
            else:
                error = r["rsp_error"]
                packet = dict(ifid_pc=pending["pc"], ifid_instr=0x13 if error else r["rsp_data"],
                              seq=next_seq, epoch=pending["epoch"], fetch_error=error,
                              fetch_tval=pending["pc"] if error else 0,
                              pred_next=pending["pc"] + 4 if error else pending["pred"],
                              pred_taken=0 if error else pending["taken"],
                              pred_hit=0 if error else pending["hit"])
                next_seq += 1
            pending = None
        elif redirect and pending:
            pending["stale"] = True
        if req_fire:
            counters["requests"] += 1
            require(pending is None, prefix + "single owner unless same-edge old response")
            pending = dict(desc)
            pending["stale"] = bool(held and (held["stale"] or redirect))
            held = None
        elif r["req_valid"]:
            desc["stale"] |= bool(held and redirect)
            held = desc
        if req_fire and rsp_fire:
            counters["same_edge"] += 1
        if redirect:
            epoch += 1
        if r["bp_update_fire"]:
            counters["bp_updates"] += 1
            require(last_bp is None or r["bp_seq"] > last_bp, prefix + "monotonic MEM BP owner")
            last_bp = r["bp_seq"]
            pc, target = r["bp_pc"], r["bp_target"]
            if pc % 4 == 0 and 0 <= pc < 8192 * 4:
                old_state = btb.get(pc, (0, -1))[1]
                for old_pc in list(btb):
                    if (old_pc // 4) % 64 == (pc // 4) % 64:
                        del btb[old_pc]
                if (r["bp_branch"] or r["bp_jal"]) and target % 4 == 0 and 0 <= target < 8192 * 4:
                    if r["bp_jal"]:
                        state = 4
                    elif old_state in (-1, 4):
                        state = 2 if r["bp_taken"] else 1
                    else:
                        state = min(3, old_state + 1) if r["bp_taken"] else max(0, old_state - 1)
                    btb[pc] = target, state
    require(counters == dict(requests=16, responses=16, transfers=5, fault_transfers=1,
                             redirects=7, bp_updates=4, same_edge=1, stale_responses=5), "coverage ledger")
    positive = (out / "modelsim_transcript.log").read_text(errors="replace")
    negative = (out / "sequence_exhaustion_transcript.log").read_text(errors="replace")
    require("CPU5 IF SEVEN GATES PASS" in positive and "** Fatal:" not in positive, "positive transcript")
    require(negative.count("** Fatal: CPU5 IF seq exhausted;") == 1 and
            "CPU5 IF EXPECTED SEQUENCE EXHAUSTION REJECT PASS" in negative, "negative exhaustion assertion")
    names = ["rtl/if_stage.v", "rtl/instr_mem.v", "rtl/instr_bus_adapter.v", "rtl/branch_predictor.v",
             "rtl/cpu5_if_adapter.v", "tb/cpu5_if_adapter_tb.v", "run_cpu5_if_adapter.do",
             "tools/analyze_cpu5_if_adapter.py"]
    evidence = ["events.csv", "gates.csv", "modelsim_transcript.log", "observation.wlf",
                "sequence_exhaustion_transcript.log", "sequence_exhaustion.wlf"]
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    return dict(status="PARTIAL VERIFIED: standalone IF adapter only", gates=7,
                independent_ledger_checks=checks, public_port_edge_rows=len(rows), counters=counters,
                negative_test="PASS: expected seq exhaustion Fatal; response blocked; no return",
                full_cpu5="NOT IMPLEMENTED / NOT RUN", sta="NOT RUN", board="NOT RUN",
                source_sha256={name: sha(root / name) for name in names},
                evidence_sha256={name: sha(out / name) for name in evidence})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    result = analyze(args.root)
    destination = args.root / "build/cpu5_s1_if/analysis.json"
    destination.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ["status", "independent_ledger_checks", "counters"]}))
