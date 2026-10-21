"""Analyze stage-0.5 memory handshakes with independent data/ISA ownership checks."""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import shutil
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

CLASS = {0: "backend", 1: "hit", 2: "miss", 3: "write", 4: "invalid", 5: "bypass"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def word(i):
    return (0xA5000000 ^ (i * 0x10203)) & 0xFFFFFFFF


def read_csv(path):
    result = []
    for row in csv.DictReader(path.open(encoding="ascii")):
        result.append({k: (None if k == "data" and "x" in v.lower() else int(v, 16) if k in {"addr", "data", "pc", "wstrb"} else v if k == "event" else int(v)) for k, v in row.items()})
    return result


def load_transactions(path):
    rows = read_csv(path)
    reqs, rsps, queue = [], [], []
    memory = [word(i) for i in range(4096)]
    last_cycle = -1
    for r in rows:
        require(r["cycle"] >= last_cycle, f"out of order: {path}")
        last_cycle = r["cycle"]
        if r["event"] == "req":
            require(not queue, f"multiple outstanding: {path}, {r}")
            require(r["owner"] == len(reqs), "request owner discontinuity")
            z, a = r["size"], r["addr"]
            align = z == 0 or z == 1 and a % 2 == 0 or z == 2 and a % 4 == 0
            strobe = (1 << (a % 4)) if z == 0 else (3 << (a % 4)) if z == 1 else 15
            legal = align and (not r["write"] or r["wstrb"] == strobe)
            error = not legal or not 0x10000 <= a < 0x14000
            expected = 0
            if not error:
                i = (a - 0x10000) // 4
                if r["write"]:
                    require(r["data"] is not None, "unknown STORE request data")
                    for b in range(4):
                        if r["wstrb"] & (1 << b):
                            memory[i] = (memory[i] & ~(255 << (b * 8))) | (r["data"] & (255 << (b * 8)))
                else:
                    expected = memory[i]
            require(r["error"] == int(error), "TB expected-error disagrees with independent model")
            r.update(expected_error=int(error), expected_data=expected)
            queue.append(r)
            reqs.append(r)
        elif r["event"] == "rsp":
            require(len(queue) == 1, "unsolicited/duplicate response")
            q = queue.pop(0)
            require(all(r[k] == q[k] for k in ("owner", "write", "addr", "size", "wstrb", "class", "pc")), "response changed owner metadata")
            require(r["error"] == q["expected_error"], "actual response error mismatches independent model")
            require(q["write"] or r["data"] == q["expected_data"], "actual read data mismatches independent model")
            q.update(response_cycle=r["cycle"], response_data=r["data"], latency=r["cycle"]-q["cycle"])
            require(q["latency"] >= 1, "zero-cycle endpoint response")
            rsps.append(r)
        else:
            raise ValueError("unknown event")
    require(not queue and len(reqs) == len(rsps), "missing response")
    return reqs, rsps


class CacheModel:
    def __init__(self):
        self.tags = [[None, None] for _ in range(64)]
        self.lru = [0] * 64

    def accept(self, r):
        a, z = r["addr"], r["size"]
        strobe = 1 << (a % 4) if z == 0 else 3 << (a % 4) if z == 1 else 15
        legal = (z == 0 or z == 1 and a % 2 == 0 or z == 2 and a % 4 == 0) and (not r["write"] or r["wstrb"] == strobe)
        if not legal:
            return 4, -1
        if not 0x10000 <= a < 0x14000:
            return 5, -1
        offset = a - 0x10000
        s, tag = (offset // 16) % 64, offset // 1024
        ways = self.tags[s]
        hit = tag in ways
        way = ways.index(tag) if hit else (ways.index(None) if None in ways else self.lru[s])
        if r["write"]:
            if hit:
                self.lru[s] = 1 - way
            return 3, way if hit else -1
        if not hit:
            ways[way] = tag
        self.lru[s] = 1 - way
        return (1 if hit else 2), way


def interpret(path):
    """Decode actual ROM independently of the fixture builder's golden table."""
    regs, memory, retirements, tx = [0] * 32, [word(i) for i in range(4096)], [], []
    for pc, insn in enumerate(int(x, 16) for x in path.read_text().split()):
        pc *= 4
        op, rd, f3, rs1, rs2 = insn & 127, (insn >> 7) & 31, (insn >> 12) & 7, (insn >> 15) & 31, (insn >> 20) & 31
        value, dst, error = 0, 0, False
        if op == 0x37:
            dst, value = rd, insn & 0xFFFFF000
        elif op == 0x13:
            require(f3 == 0, "unexpected arithmetic in fixture")
            imm = insn >> 20
            imm -= 4096 if imm & 2048 else 0
            dst, value = rd, (regs[rs1] + imm) & 0xFFFFFFFF
        elif op in (3, 0x23):
            require(f3 == 2, "fixture must use LW/SW")
            imm = insn >> 20 if op == 3 else ((insn >> 25) << 5) | ((insn >> 7) & 31)
            imm -= 4096 if imm & 2048 else 0
            a = (regs[rs1] + imm) & 0xFFFFFFFF
            wr = int(op == 0x23)
            error = a % 4 != 0 or not 0x10000 <= a < 0x14000
            data = 0
            if not error:
                if wr:
                    memory[(a-0x10000)//4] = regs[rs2]
                    data = regs[rs2]
                else:
                    dst, value = rd, memory[(a-0x10000)//4]
                    data = value
            tx.append(dict(pc=pc, write=wr, addr=a, data=data, error=int(error)))
        else:
            raise ValueError(f"unexpected opcode {op:x}")
        if error:
            return retirements, tx
        retirements.append(dict(pc=pc, rd=dst, write=int(dst != 0), data=value & 0xFFFFFFFF))
        if dst:
            regs[dst] = value & 0xFFFFFFFF
    raise ValueError("fixture missing terminal fault")


def stats(values):
    return {"count": len(values), "min": min(values), "max": max(values), "histogram": dict(sorted(Counter(values).items()))} if values else {"count": 0, "status": "NOT OBSERVED"}


def analyze(directory):
    summary = dict(schema=1, status="PASS", scope="unchanged three-stage RV32IM; deterministic fixtures, not CoreMark score; non-RAM error endpoint is native surrogate, not AXI transport", cases=[])
    all_tx, all_pairs = [], []
    for case in range(4):
        per_boundary, metrics = [], list(csv.DictReader((directory/f"case{case}_metrics.csv").open()))
        for boundary in range(3):
            tx, rsps = load_transactions(directory/f"case{case}_boundary{boundary}.csv")
            per_boundary.append(tx)
            m = {k: int(v) for k, v in metrics[boundary].items()}
            require(m["requests"] == m["responses"] == len(tx), "TB count closure mismatch")
            request_cycles = {r["cycle"] for r in tx}
            simultaneous = sum(r["cycle"] in request_cycles for r in rsps)
            require(m["simultaneous"] == simultaneous, "same-edge count mismatch")
            groups = defaultdict(list)
            pairs = defaultdict(list)
            class_pairs = defaultdict(list)
            for t in tx:
                groups[CLASS[t["class"]]].append(t["latency"])
                all_tx.append(dict(case=case,boundary=boundary,owner=t["owner"],write=t["write"],addr=f"{t['addr']:08x}",pc=f"{t['pc']:08x}",request_cycle=t["cycle"],response_cycle=t["response_cycle"],latency=t["latency"],request_class=CLASS[t["class"]],error=t["expected_error"]))
            for prev, cur in zip(tx, tx[1:]):
                ii = cur["cycle"] - prev["cycle"]
                key = ("SW" if prev["write"] else "LW") + "-" + ("SW" if cur["write"] else "LW")
                pairs[key].append(ii)
                class_pairs[CLASS[prev["class"]]+"->"+CLASS[cur["class"]]].append(ii)
                all_pairs.append(dict(case=case,boundary=boundary,previous_owner=prev["owner"],owner=cur["owner"],pair=key,same_address=int(prev["addr"]==cur["addr"]),previous_class=CLASS[prev["class"]],current_class=CLASS[cur["class"]],ii=ii,response_to_request_gap=cur["cycle"]-prev["response_cycle"]))
            m.update(latency={k: stats(v) for k,v in groups.items()}, initiation_interval={k:stats(v) for k,v in pairs.items()}, class_pair_interval={k:stats(v) for k,v in class_pairs.items()}, minimum_ii=stats([b["cycle"]-a["cycle"] for a,b in zip(tx,tx[1:])]))
            if boundary:
                require(simultaneous == 0, "D0 backend turnover unexpectedly simultaneous")
            summary.setdefault("boundaries", []).append(dict(case=case,**m))
        upper, backend, bram = per_boundary
        model = CacheModel()
        for u in upper:
            expected_class, way = model.accept(u)
            require(u["class"] == expected_class, f"cache classification mismatch case={case} owner={u['owner']}")
            u["reference_way"] = way
            nested = [b for b in backend if u["cycle"] < b["cycle"] <= u["response_cycle"]]
            require(len(nested) == ({1:0,2:4,3:1,4:0,5:1}[expected_class]), f"backend request count/ownership mismatch case={case} owner={u['owner']}")
            if expected_class == 2:
                require([b["addr"] for b in nested] == [(u["addr"] & ~15) + i*4 for i in range(4)], "refill line/beat address mismatch")
            elif expected_class in (3,5):
                require(nested[0]["addr"] == u["addr"] and nested[0]["write"] == u["write"], "forwarded write/bypass descriptor mismatch")
        require(sum(0x10000 <= b["addr"] < 0x14000 for b in backend) == len(bram), "router RAM traffic count mismatch")
        for a,b in zip([x for x in backend if 0x10000<=x["addr"]<0x14000],bram):
            require(all(a[k]==b[k] for k in ("cycle","response_cycle","write","addr","size","wstrb","data","response_data","expected_error")), "D0 router added latency or changed RAM owner")
        same_edge_diff = [(a,b) for a,b in zip(upper,upper[1:]) if a["response_cycle"]==b["cycle"] and a["addr"]!=b["addr"] and not a["write"] and not b["write"] and a["response_data"]!=b["response_data"]]
        c = dict(case=case,mode="stream" if case<2 else "CPU",request_wait=0 if case in (0,2) else 2,response_wait=0 if case in (0,2) else 3,requests=len(upper),backend_requests=len(backend),bram_requests=len(bram),same_edge_different_address_data_load_pairs=len(same_edge_diff),reference_way_counts=dict(Counter(u["reference_way"] for u in upper)),class_counts=dict(Counter(CLASS[u["class"]] for u in upper)))
        if case < 2:
            require(len(upper)==30 and len(same_edge_diff)>=5, "streaming turnover coverage insufficient")
            require({1,2,3,4,5} <= {u["class"] for u in upper}, "missing class coverage")
        else:
            kind = "illegal" if case == 2 else "unaligned"
            retirements, expected_tx = interpret(directory/f"cpu_{kind}.hex")
            observed_retire = read_csv(directory/f"case{case}_retirement.csv")
            require(len(retirements)==len(observed_retire), "retirement count mismatch")
            for expected, actual in zip(retirements,observed_retire):
                require(all(actual[k]==expected[k] for k in ("pc","write")), "ISA retirement pc/write mismatch")
                if expected["write"]:
                    require(actual["rd"]==expected["rd"] and actual["data"]==expected["data"], "ISA retirement register/data mismatch")
            require(len(expected_tx)==len(upper), "ISA D request count mismatch")
            for e,u in zip(expected_tx,upper):
                require(all(e[k]==u[k] for k in ("pc","write","addr","error")), "ISA request descriptor mismatch")
                if u["write"]:
                    require(u["data"]==e["data"], "ISA store data mismatch")
            c["independent_isa_retirements_checked"]=len(retirements)
            ifetch = read_csv(directory/f"case{case}_ifetch.csv")
            supply_gaps=[]
            for a,b in zip(upper,upper[1:]):
                if a["class"]==b["class"]==1 and b["cycle"]-a["cycle"]>2:
                    evidence=[r for r in ifetch if r["event"]=="ireq" and not r["hit"] and r["addr"]==b["pc"] and r["cycle"]<=b["cycle"]]
                    replies=[r for r in ifetch if r["event"]=="irsp" and r["addr"]==b["pc"] and a["response_cycle"]<=r["cycle"]<b["cycle"]]
                    require(evidence and replies, "long hit-hit interval lacks observed I-cache miss evidence")
                    supply_gaps.append(dict(previous_pc=f"{a['pc']:08x}",pc=f"{b['pc']:08x}",ii=b["cycle"]-a["cycle"],observed_ifetch_miss_cycle=evidence[-1]["cycle"],observed_ifetch_response_cycle=replies[0]["cycle"]))
            c["hit_hit_long_intervals_with_ifetch_miss"]=supply_gaps
            require(c["same_edge_different_address_data_load_pairs"]==0, "unexpected CPU same-edge turnover")
        summary["cases"].append(c)
    for name, rows in (("transactions.csv",all_tx),("request_pairs.csv",all_pairs)):
        with (directory/name).open("w",newline="") as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    summary["limitations"]=["CPU fixtures use original I-cache/ROM and D-cache parameters but are directed instruction streams, not a CoreMark-wide II distribution", "non-RAM error endpoint bypasses production AXI transport; AXI regression is outside this measurement", "CPU5 RTL/II and speculative request ownership are NOT IMPLEMENTED / NOT RUN", "latency is response-consumption edge minus request-acceptance edge; response backpressure is included", "II is adjacent accepted-request edge distance, including instruction supply and dependencies; it is not a pure endpoint capacity claim"]
    summary["artifact_sha256"]={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.iterdir()) if p.is_file() and p.suffix in (".csv",".hex",".json",".log") and p.name not in ("summary.json","manifest.json")}
    (directory/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
    return summary


def fault_checks(directory):
    """Corrupt independent evidence copies; original evidence is never mutated."""
    trials=[]
    mutations=("wrong_read_data","wrong_response_owner","missing_response","duplicate_request","wrong_refill_address","wrong_retirement_value")
    for name in mutations:
        with tempfile.TemporaryDirectory(prefix="cpu5_mem_negative_") as temp:
            dest=Path(temp)
            for p in directory.iterdir():
                if p.is_file() and p.suffix in (".csv",".hex",".json"):
                    shutil.copy2(p,dest/p.name)
            target=dest/("case2_retirement.csv" if name=="wrong_retirement_value" else "case0_boundary1.csv" if name=="wrong_refill_address" else "case0_boundary0.csv")
            with target.open(newline="") as f:
                reader=csv.DictReader(f);fields=reader.fieldnames;rows=list(reader)
            if name=="wrong_retirement_value":
                rows[0]["data"]=f"{int(rows[0]['data'],16)^1:08x}"
            elif name=="wrong_refill_address":
                rows[0]["addr"]=f"{int(rows[0]['addr'],16)+4:08x}"
            elif name=="missing_response":
                rows.pop()
            elif name=="duplicate_request":
                rows.insert(1,dict(rows[0]))
            else:
                r=next(r for r in rows if r["event"]=="rsp" and r["write"]=="0" and r["error"]=="0")
                key="data" if name=="wrong_read_data" else "owner"
                r[key]=f"{int(r[key],16)^1:08x}" if key=="data" else str(int(r[key])+1)
            with target.open("w",newline="") as f:
                w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
            try:
                analyze(dest)
            except ValueError as exc:
                trials.append(dict(mutation=name,status="REJECTED",reason=str(exc)))
            else:
                raise ValueError(f"corrupt evidence accepted: {name}")
    (directory/"analyzer_negative_checks.json").write_text(json.dumps(dict(status="PASS",trials=trials),indent=2)+"\n")
    return trials


if __name__ == "__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--directory",type=Path,default=Path("build/cpu5_s05_memory"));parser.add_argument("--negative-checks",action="store_true");args=parser.parse_args()
    if args.negative_checks:
        fault_checks(args.directory)
    result=analyze(args.directory)
    print(json.dumps({"status":result["status"],"cases":result["cases"]},indent=2))
