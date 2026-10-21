#!/usr/bin/env python3
"""Read-only extraction of an archived PDS final report; never launches PDS.

All path delays are nanoseconds. Data delay includes launch tco, but excludes
launch/capture clock trees; Logic Levels is PDS's count, not a Python estimate.
"""
import argparse
from collections import Counter
from decimal import Decimal as D
import gzip
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def one(pattern, text):
    found = re.findall(pattern, text, re.M)
    if len(found) != 1:
        raise ValueError(f"expected one match: {pattern}: found {len(found)}")
    return found[0]


def close(a, b, tolerance="0.002"):
    if abs(D(str(a)) - D(str(b))) > D(tolerance):
        raise ValueError(f"rounded report values disagree: {a} != {b}")


def extract(text):
    summary = []
    for kind, corner, slack, tns, failing, total in re.findall(
        r"^(Setup|Hold|Recovery|Removal) Summary\((Slow|Fast) Corner\):\s*"
        r".*?^ clk_50m\s+clk_50m\s+([+-]?[\d.]+)\s+([+-]?[\d.]+)\s+(\d+)\s+(\d+)",
        text, re.M | re.S,
    ):
        summary.append(dict(kind=kind.lower(), corner=corner.lower(), slack_ns=float(slack),
                            total_negative_slack_ns=float(tns), failing_endpoints=int(failing),
                            total_endpoints=int(total)))
    if len(summary) != 8:
        raise ValueError(f"expected 8 setup/hold/recovery/removal summary rows, got {len(summary)}")
    starts = list(re.finditer(r"^Startpoint\s*:.*$", text, re.M))
    paths = []
    ranks = Counter()
    for start in starts:
        end = re.search(r"^ Slack \((MET|VIOLATED)\)\s+([+-]?[\d.]+).*?$", text[start.start():], re.M)
        if not end:
            raise ValueError("missing path slack")
        block = text[start.start():start.start() + end.end()]
        mode, corner = one(r"^Path Type\s*:\s*(max|min) \((slow|fast) corner\)", block)
        kind = one(r"^ (Setup|Hold|Recovery|Removal) time\s+", block).lower()
        if (kind in ("setup", "recovery")) != (mode == "max"):
            raise ValueError("wrong path mode/constraint")
        key = (corner, kind)
        ranks[key] += 1
        arrival, levels = one(r"^ Data arrival time\s+([+-]?[\d.]+)\s+Logic Levels:\s*(\d+)", block)
        logic, lpct, route, rpct = one(
            r"Logic:\s*([\d.]+)ns\(([\d.]+)%\), Route:\s*([\d.]+)ns\(([\d.]+)%\)", block)
        launch = one(r"^  Launch Clock Delay\s*:\s*([+-]?[\d.]+)", block)
        capture = one(r"^  Capture Clock Delay\s*:\s*([+-]?[\d.]+)", block)
        pessimism = one(r"^  Clock Pessimism Removal\s*:\s*([+-]?[\d.]+)", block)
        skew = one(r"^Clock Skew\s*:\s*([+-]?[\d.]+)", block)
        uncertainty = one(r"^ clock uncertainty\s+([+-]?[\d.]+)", block)
        constraint = one(r"^ (?:Setup|Hold|Recovery|Removal) time\s+([+-]?[\d.]+)", block)
        requireds = re.findall(r"^ Data required time\s+([+-]?[\d.]+)", block, re.M)
        if len(requireds) != 2 or requireds[0] != requireds[1]:
            raise ValueError("inconsistent repeated required time")
        required = requireds[0]
        data_block = block[re.search(r"^.*\btco\s+[\d.]+\s", block, re.M).start():
                           re.search(r"^ Data arrival time", block, re.M).start()]
        rows = []
        for line in data_block.splitlines():
            row = re.match(r"^(.*?)\s+(tco|td|net \(fanout=\d+\))\s+([+-]?[\d.]+)"
                           r"\s+([+-]?[\d.]+)(?:\s+[rf])?\s*(.*)$", line)
            if row:
                location, typ, incr, cumulative, resource = row.groups()
                rows.append(dict(location=location.strip(), delay_type=typ,
                                 incremental_ns=float(incr), cumulative_ns=float(cumulative),
                                 logical_resource=resource.strip()))
        if not rows or rows[0]["delay_type"] != "tco":
            raise ValueError("data rows must begin with launch tco")
        cell_sum = sum(D(str(row["incremental_ns"])) for row in rows if not row["delay_type"].startswith("net "))
        route_sum = sum(D(str(row["incremental_ns"])) for row in rows if row["delay_type"].startswith("net "))
        close(cell_sum, logic, "0.012")  # each printed arc is rounded to 0.001 ns
        close(route_sum, route, "0.012")
        close(D(arrival) - D(launch), D(logic) + D(route))
        close(D(capture) - D(launch) + D(pessimism), skew)
        slack = end[2]
        close(D(required) - D(arrival) if mode == "max" else D(arrival) - D(required), slack)
        line_no = text[:start.start()].count("\n") + 1
        paths.append(dict(corner=corner, kind=kind, rank=ranks[key], mode=mode,
                          source_line=line_no, source_end_line=line_no + block.count("\n"),
                          startpoint=one(r"^Startpoint\s*:\s*(.+)$", block).strip(),
                          endpoint=one(r"^Endpoint\s*:\s*(.+)$", block).strip(),
                          path_group=one(r"^Path Group\s*:\s*(.+)$", block).strip(),
                          path_class=one(r"^Path Class\s*:\s*(.+)$", block).strip(),
                          slack_ns=float(slack), status=end[1], logic_levels=int(levels),
                          data_delay_ns=float(D(logic) + D(route)), logic_ns=float(logic),
                          route_ns=float(route), logic_percent=float(lpct), route_percent=float(rpct),
                          arrival_ns=float(arrival), required_ns=float(required),
                          launch_clock_delay_ns=float(launch), capture_clock_delay_ns=float(capture),
                          clock_pessimism_removal_ns=float(pessimism), clock_skew_ns=float(skew),
                          signed_clock_uncertainty_ns=float(uncertainty), signed_constraint_ns=float(constraint),
                          summed_rounded_cell_arcs_ns=float(cell_sum), summed_rounded_route_arcs_ns=float(route_sum),
                          data_path_rows=rows))
    if len(paths) != 24 or any(ranks[(c, k)] != 3 for c in ("slow", "fast") for k in ("setup", "hold", "recovery", "removal")):
        raise ValueError(f"report lacks 3 paths per corner/type: {ranks}")
    for entry in summary:
        group = [p for p in paths if (p["corner"], p["kind"]) == (entry["corner"], entry["kind"])]
        close(group[0]["slack_ns"], entry["slack_ns"], "0.000")
        if [p["slack_ns"] for p in group] != sorted(p["slack_ns"] for p in group):
            raise ValueError("path ranking does not follow slack")
    return summary, paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True, help="frozen PDS build directory")
    parser.add_argument("--source-root", type=Path, required=True, help="frozen source root")
    parser.add_argument("--compare-root", type=Path, help="current source; compare after LF normalization")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    manifest_path = args.build / "build_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    report = args.build / manifest["final_sta_report"]
    route = args.build / "place_route/board_top_pnr.adf"
    raw = report.read_bytes()
    report_sha = hashlib.sha256(raw).hexdigest()
    if report_sha != manifest["final_sta_report_sha256"] or sha(route) != manifest["final_sta_route_sha256"]:
        raise ValueError("frozen report/route SHA mismatch")
    if not manifest["final_sta_from_bitstream_flow"] or manifest["clock_hz"] != 50000000:
        raise ValueError("expected 50 MHz final bitstream-flow report")
    text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    period, rise, fall, clock_loads, nonclock_loads = one(
        r"^ clk_50m\s+([\d.]+)\s+\{([\d.]+)\s+([\d.]+)\}\s+Declared\s+(\d+)\s+(\d+)\s+\{clk_50m\}\s*$", text)
    if (D(period), D(rise), D(fall), int(nonclock_loads)) != (D("20"), D("0"), D("10"), 0):
        raise ValueError("expected declared 20 ns 50% clk_50m without non-clock loads")
    summary, paths = extract(text)
    expected_rows = manifest["final_sta_rows"]
    if len(expected_rows) != len(summary):
        raise ValueError("manifest final summary length mismatch")
    for got, expected in zip(summary, expected_rows):
        close(got["slack_ns"], expected[0], "0.000")
        close(got["total_negative_slack_ns"], expected[1], "0.000")
        if [got["failing_endpoints"], got["total_endpoints"]] != [int(expected[2]), int(expected[3])]:
            raise ValueError("manifest final endpoint summary mismatch")
    source_checks = []
    for rel, expected in manifest["sources"].items():
        path = args.source_root / rel
        item = dict(path=rel, frozen_sha256=sha(path), expected_sha256=expected)
        if item["frozen_sha256"] != expected:
            raise ValueError(f"frozen source SHA mismatch: {rel}")
        if args.compare_root:
            other = args.compare_root / rel
            item["compare_raw_sha256"] = sha(other)
            item["canonical_lf_equal"] = path.read_bytes().replace(b"\r\n", b"\n") == other.read_bytes().replace(b"\r\n", b"\n")
            if not item["canonical_lf_equal"]:
                raise ValueError(f"current source differs beyond EOL: {rel}")
        source_checks.append(item)
    args.out.mkdir(parents=True, exist_ok=True)
    report_gz = args.out / "board_top.rtr.gz"
    report_gz.write_bytes(gzip.compress(raw, mtime=0))
    (args.out / "build_manifest.json").write_bytes(manifest_path.read_bytes())
    out = dict(schema=1, extraction_status="PASS", operation="read-only existing final report; no new STA or P&R",
               source=dict(build=str(args.build.resolve()), report=str(report.resolve()), report_sha256=report_sha,
                           report_bytes=len(raw), route=str(route.resolve()), route_sha256=sha(route),
                           manifest=str(manifest_path.resolve()), manifest_sha256=sha(manifest_path)),
               tool=one(r"^\| Tool Version\s*:\s*(.+)$", text).strip(),
               report_date=one(r"^\| Date\s*:\s*(.+)$", text).strip(),
               device=dict(part=manifest["base_target"], firmware=manifest["firmware"], variant=manifest["variant"]),
               clock=dict(name="clk_50m", period_ns=float(period), frequency_hz=50000000,
                          waveform_ns=[float(rise), float(fall)], source_port="clk_50m",
                          clock_loads=int(clock_loads), non_clock_loads=int(nonclock_loads)),
               precision_note="Printed arcs rounded to 0.001 ns; use PDS logic/route summaries for data delay. Launch tco included; clock trees excluded.",
               final_signoff_summary=summary, paths=paths, source_identity=source_checks,
               limitations=["Top-3 report is not exhaustive path coverage; an absent candidate has no extracted WNS.",
                            "The report remains an RV32IM three-stage 50 MHz baseline, not CPU5 timing.",
                            "No timing delta is attributed to M from cross-build WNS values."])
    output = args.out / "routed_timing.json"
    output.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(status="PASS", paths=len(paths), source_checks=len(source_checks),
                          report_sha256=report_sha, output=str(output)), ensure_ascii=False))


if __name__ == "__main__":
    main()
