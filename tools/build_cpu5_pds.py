"""Independent CPU5 MES50HP PDS synthesis/P&R/STA. Never programs hardware."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

import cpu5_board_contract as contract
import build_cpu5_board_images as firmware
from run_cpu5_coremark import RTL
from build_pds_board import read_final_sta_report,read_post_route_timing_report

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19"
PDS=Path(r"D:\pango\PDS_2022.2-SP6.4\bin\pds_shell.exe")
RTL_FILES=list(dict.fromkeys(RTL+["rtl/board_reset.v"]))
SOURCES=sorted(set(RTL_FILES+["rtl/cpu5_pipeline_types.vh",contract.TOP,"pds/board_top.fdc",
    "tools/build_cpu5_pds.py","tools/cpu5_board_contract.py","tools/build_cpu5_board_images.py",
    "tools/build_cpu5_coremark_images.py","tools/build_pds_board.py","tools/run_cpu5_coremark.py",
    "tools/run_cpu5_d0_program.py"]+firmware.SOURCES))


def sha(path):
    h=hashlib.sha256()
    with path.open("rb") as stream:
        while chunk:=stream.read(1024*1024):h.update(chunk)
    return h.hexdigest()


def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,indent=2)+"\n",encoding="utf-8",newline="\n")


def resources(text):
    def number(pattern):
        match=re.search(pattern,text)
        if not match:raise ValueError("Missing synthesis resource: "+pattern)
        return float(match[1]) if "." in match[1] else int(match[1])
    result=dict(luts=number(r"Total LUTs:\s+(\d+)"),registers=number(r"Total Registers:\s+(\d+)"),
                latches=number(r"Total Latches:\s+(\d+)"),drm18k_equivalent=number(r"Total DRM18K =\s+([\d.]+)"),
                apms=number(r"Total APMs =\s+([\d.]+)"))
    if result["latches"]!=0 or result["apms"]!=4:raise ValueError("Unexpected CPU5 latch/multiplier mapping")
    return result


def validate_constraints(text):
    clocks=re.findall(r"(?m)^create_clock .*$",text)
    if clocks!=["create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]"]:raise ValueError("CPU5 50MHz constraint")
    false=re.findall(r"(?m)^set_false_path .*$",text)
    if false!=["set_false_path -from [get_ports {key1_n keys_n[*] uart_rx}]","set_false_path -to [get_ports {led[*] uart_tx}]"]:
        raise ValueError("CPU5 unexpected timing exception")
    if re.search(r"(?m)^\s*(set_multicycle_path|set_max_delay|set_disable_timing|set_clock_groups)\b",text):
        raise ValueError("CPU5 internal timing bypass")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pds",type=Path,default=PDS)
    parser.add_argument("--profile",choices=list(firmware.PROFILES),default="performance")
    parser.add_argument("--stage",choices=("synth","timing"),default="timing")
    parser.add_argument("--seed",type=int,default=1)
    parser.add_argument("--timeout",type=int,default=7200)
    args=parser.parse_args()
    if not str(ROOT).isascii():parser.error("PDS requires an ASCII project directory")
    if args.seed<0:parser.error("seed must be nonnegative")
    fw=firmware.validate_build(args.profile)
    contract.validate_top((ROOT/contract.TOP).read_text(encoding="utf-8"))
    validate_constraints((ROOT/"pds/board_top.fdc").read_text(encoding="utf-8"))
    before={p:sha(ROOT/p) for p in SOURCES}
    rid=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]+"_"+args.profile
    stage=OUT/"runs"/rid;stage.mkdir(parents=True,exist_ok=False)
    for name,expected in before.items():
        target=stage/"tested_sources"/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/name,target)
        if sha(target)!=expected:raise ValueError("CPU5 PDS source snapshot")
    images=stage/"firmware";shutil.copytree(firmware.OUT/args.profile,images)
    generated=contract.bind_top((ROOT/contract.TOP).read_text(encoding="utf-8"),images/"program.hex",images/"program_data.hex")
    (stage/"board_top.sv").write_text(generated,encoding="utf-8",newline="\n")
    quote=lambda path:'"'+path.as_posix()+'"'
    commands=["set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484"]
    commands+=["add_design "+quote(stage/"tested_sources"/name) for name in RTL_FILES]
    commands+=["add_design "+quote(stage/"board_top.sv"),
        "add_constraint -logic -fdc "+quote(stage/"tested_sources/pds/board_top.fdc"),
        "compile -top_module board_top -system_verilog -loop_limit 10000 -include_path {"+(stage/"tested_sources").as_posix()+"}",
        "synthesize -ads -selected_syn_tool_opt 2"]
    if args.stage=="timing":commands+=["dev_map",f"pnr -gplace_seed {args.seed} -groute_seed {args.seed}","report_timing"]
    script=stage/"flow.tcl";script.write_text("\n".join(commands)+"\n",encoding="utf-8",newline="\n")
    command=[str(args.pds),"-file",str(script),"-work_dir",str(stage),"-project_name","cpu5_board"]
    tool_sha=sha(args.pds)
    record=dict(status="RUNNING",run_id=rid,profile=args.profile,requested_stage=args.stage,seed=args.seed,
        directory=stage.relative_to(ROOT).as_posix(),hardware=contract.CONFIG,source_sha256=before,
        source_lf_sha256={p:hashlib.sha256((ROOT/p).read_bytes().replace(b"\r\n",b"\n")).hexdigest() for p in before},
        source_snapshots="tested_sources",sources_unchanged=False,firmware=fw,generated_top_sha256=sha(stage/"board_top.sv"),
        flow_tcl_sha256=sha(script),command=command,pds_shell_sha256=tool_sha,hardware_download_performed=False,
        formal_score_measured=False,bitstream_generated=False)
    def save():write(stage/"build_record.json",record);write(OUT/("pds_"+args.profile+".json"),record)
    save();started=time.time()
    try:
        with (stage/"pds_console.log").open("wb") as output:
            process=subprocess.run(command,cwd=stage,stdout=output,stderr=subprocess.STDOUT,timeout=args.timeout)
        record.update(exit_code=process.returncode,elapsed_seconds=time.time()-started)
        text=(stage/"pds_console.log").read_text(encoding="utf-8",errors="replace")
        if process.returncode or re.search(r"(?m)^\s*E:|Program Error Out",text):raise ValueError("CPU5 PDS process failed")
        if re.search(r"STA-3001|[Cc]ombinational loops? (?:are |were )?found",text):
            raise ValueError("CPU5 combinational loop / automatic timing arc cut")
        record["synthesis_resources"]=resources(text)
        record["warning_lines"]=[line for line in text.splitlines() if re.match(r"^\s*[WC]:",line)]
        record["status"]="SYNTHESIS_VERIFIED"
        if args.stage=="timing":
            router=stage/"place_route/board_top_timing_summary_after_hold_fix.txt"
            final=stage/"report_timing/board_top.rtr"
            record["post_route_timing_rows"]=read_post_route_timing_report(router,started)
            rows,pulse=read_final_sta_report(final,started)
            record.update(status="TIMING_VERIFIED",final_sta_rows=rows,final_sta_pulse_width_rows=pulse,
                          final_sta_report="report_timing/board_top.rtr",final_sta_report_sha256=sha(final),
                          route_sha256=sha(stage/"place_route/board_top_pnr.adf"))
        if before!={p:sha(ROOT/p) for p in SOURCES}:raise ValueError("CPU5 PDS source changed during flow")
        if any(sha(stage/"tested_sources"/p)!=expected for p,expected in before.items()):raise ValueError("CPU5 PDS snapshot changed")
        if sha(args.pds)!=tool_sha:raise ValueError("PDS executable changed")
        record["sources_unchanged"]=True
        retained=["pds_console.log","flow.tcl","board_top.sv","cpu5_board.pds",
                  "compile/board_top_comp.adf","synthesize/board_top_syn.adf","synthesize/board_top_syn.vm",
                  "synthesize/board_top.snr","synthesize/apm_drm_lutram_utilization.log"]
        if args.stage=="timing":retained+=["place_route/board_top_pnr.adf","place_route/board_top_pnr.netlist",
             "place_route/board_top_timing_summary_after_hold_fix.txt","report_timing/board_top.rtr"]
        record["retained_artifact_sha256"]={p:sha(stage/p) for p in retained}
        record["firmware_artifact_sha256"]={p.relative_to(stage).as_posix():sha(p) for p in images.rglob("*") if p.is_file()}
        save()
        print(json.dumps(dict(status=record["status"],profile=args.profile,run_id=rid,
                              resources=record["synthesis_resources"],bitstream_generated=False),indent=2))
    except Exception as error:
        record["status"]="FAILED";record["failure"]=str(error);save();raise


if __name__=="__main__":main()
