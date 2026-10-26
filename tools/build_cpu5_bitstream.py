"""Generate CPU5 SRAM-download files from an independently verified PDS build."""
import argparse
from datetime import datetime,timezone
import json,re,shutil,subprocess,time,uuid
from pathlib import Path
import build_cpu5_pds as board
from build_pds_board import read_bitstream_outputs,verify_post_bitstream_timing
import build_cpu5_board_images as firmware

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19"
sha=board.sha
write=board.write

def validate_input(record):
    if record["status"]!="TIMING_VERIFIED" or not record["sources_unchanged"] or record["bitstream_generated"]:
        raise ValueError("CPU5 bitstream requires a verified timing-only build")
    for p,h in record["source_sha256"].items():
        if sha(ROOT/p)!=h:raise ValueError("CPU5 timing source changed: "+p)
    stage=ROOT/record["directory"]
    for p,h in record["retained_artifact_sha256"].items():
        if sha(stage/p)!=h:raise ValueError("CPU5 timing artifact changed: "+p)
    for p,h in record["firmware_artifact_sha256"].items():
        if sha(stage/p)!=h:raise ValueError("CPU5 timing firmware changed: "+p)
    firmware.validate_build(record["profile"])
    board.read_post_route_timing_report(stage/"place_route/board_top_timing_summary_after_hold_fix.txt",0)
    board.read_final_sta_report(stage/"report_timing/board_top.rtr",0)
    return stage

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--record",type=Path,default=OUT/"pds_performance.json")
    ap.add_argument("--pds",type=Path,default=board.PDS)
    ap.add_argument("--timeout",type=int,default=7200)
    args=ap.parse_args()
    args.record=args.record.absolute()
    timing=json.loads(args.record.read_text());original=validate_input(timing)
    if sha(args.pds)!=timing["pds_shell_sha256"]:raise ValueError("CPU5 PDS tool changed")
    before={**timing["source_sha256"],"tools/build_cpu5_bitstream.py":sha(Path(__file__))}
    rid=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]+"_bitstream_"+timing["profile"]
    stage=OUT/"runs"/rid
    shutil.copytree(original,stage)
    project=stage/"cpu5_board.pds"
    text=project.read_text(encoding="utf-8")
    marker="(_command cmd_gen_bitstream"
    if text.count(marker)!=1 or "(_device PGL50H)" not in text:raise ValueError("CPU5 PDS project format")
    if "(_option create_bin_file " in text or "(_option wake_up_clock " in text:raise ValueError("CPU5 pre-existing bitstream overrides")
    text=text.replace(original.as_posix(),stage.as_posix()).replace(str(original),str(stage))
    text=text.replace(marker,marker+'\n            (_option create_bin_file (_switch ON))\n            (_option wake_up_clock (_string "TCK"))')
    project.write_text(text,encoding="utf-8",newline="\n")
    generated=stage/"board_top.sv"
    top=generated.read_text(encoding="utf-8").replace(original.as_posix(),stage.as_posix())
    generated.write_text(top,encoding="utf-8",newline="\n")
    (stage/"tested_sources/tools/build_cpu5_bitstream.py").write_bytes(Path(__file__).read_bytes())
    command=[str(args.pds),"-project",str(project),"-run","gen_bit_stream"]
    record=dict(status="RUNNING",run_id=rid,profile=timing["profile"],directory=stage.relative_to(ROOT).as_posix(),
        hardware=timing["hardware"],source_sha256=before,sources_unchanged=False,
        timing_input_record=args.record.relative_to(ROOT).as_posix(),timing_input_sha256=sha(args.record),
        timing_input_run_id=timing["run_id"],timing_input_route_sha256=timing["route_sha256"],
        generated_top_sha256=sha(generated),command=command,pds_shell_sha256=sha(args.pds),
        hardware_download_performed=False,formal_score_measured=False,hardware_verified=False,bitstream_generated=False)
    def save():write(stage/"bitstream_record.json",record);write(OUT/("bitstream_"+timing["profile"]+".json"),record)
    save();started=time.time()
    try:
        with (stage/"bitstream_generation.log").open("wb") as stream:
            process=subprocess.run(command,cwd=stage,stdout=stream,stderr=subprocess.STDOUT,timeout=args.timeout)
        record.update(exit_code=process.returncode,elapsed_seconds=time.time()-started)
        log=(stage/"bitstream_generation.log").read_text(encoding="utf-8",errors="replace")
        if process.returncode or re.search(r"(?m)^\s*E:|Program Error Out|STA-3001",log):
            raise ValueError("CPU5 bitstream PDS failed")
        outputs=read_bitstream_outputs(stage,started)
        if set(outputs)!={"generate_bitstream/board_top.sbit","generate_bitstream/board_top.bin"}:
            raise ValueError("CPU5 requires fresh SBIT and BIN")
        router,rows,pulse,route=verify_post_bitstream_timing(stage,started)
        if before!={p:sha(ROOT/p) for p in before}:raise ValueError("CPU5 source changed during bitstream generation")
        if any(sha(stage/"tested_sources"/p)!=h for p,h in before.items()):raise ValueError("CPU5 bitstream snapshot changed")
        if sha(generated)!=record["generated_top_sha256"] or sha(args.pds)!=record["pds_shell_sha256"]:
            raise ValueError("CPU5 generated top/PDS changed")
        validate_input(timing)
        if sha(args.record)!=record["timing_input_sha256"]:raise ValueError("CPU5 timing record changed")
        record.update(status="BITSTREAM_VERIFIED_NOT_DOWNLOADED",bitstream_generated=True,sources_unchanged=True,
            bitstreams=outputs,post_route_timing_rows=router,final_sta_rows=rows,final_sta_pulse_width_rows=pulse,
            route_sha256=route,final_sta_report_sha256=sha(stage/"report_timing/board_top.rtr"),
            final_sta_from_bitstream_flow=True)
        retained=["bitstream_generation.log","cpu5_board.pds","board_top.sv","place_route/board_top_pnr.adf",
            "place_route/board_top_pnr.netlist","place_route/board_top_timing_summary_after_hold_fix.txt","report_timing/board_top.rtr",
            "synthesize/apm_drm_lutram_utilization.log","synthesize/board_top_syn.vm","synthesize/board_top.snr"]
        record["retained_artifact_sha256"]={p:sha(stage/p) for p in retained}
        record["firmware_artifact_sha256"]={p.relative_to(stage).as_posix():sha(p) for p in (stage/"firmware").rglob("*") if p.is_file()}
        save();print(json.dumps({k:record[k] for k in ("status","run_id","bitstreams","final_sta_rows")},indent=2),flush=True)
    except Exception as error:
        record.update(status="FAILED",failure=str(error));save();raise

if __name__=="__main__":main()

