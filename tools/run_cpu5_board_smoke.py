"""Exercise the actual CPU5 board geometry, reset and 115200-baud TX pins."""
import argparse
from datetime import datetime,timezone
import hashlib,json,re,shutil,subprocess,time,uuid
from pathlib import Path
import build_cpu5_pds as board
import build_cpu5_board_images as firmware
import cpu5_board_contract as contract
from cpu5_coremark_reference import parse_console
from run_cpu5_coremark import CLASSES,DEFAULT_VSIM

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19"
PROFILES=("smoke","smoke-validation")
SOURCES=sorted(set(board.SOURCES+["tb/cpu5_board_smoke_tb.v","tools/run_cpu5_board_smoke.py","tools/cpu5_coremark_reference.py"]))
sha=board.sha
write=board.write

def audit_case(directory,profile):
    summary=json.loads((directory/"summary.json").read_text())
    raw=(directory/"console.txt").read_bytes()
    serial=(directory/"uart_serial.txt").read_bytes()
    console=raw.replace(b"\r\n",b"\n")
    if raw!=serial or raw not in (console,console.replace(b"\n",b"\r\n")):
        raise ValueError("board UART pin/endpoint serialization")
    values=parse_console(console.decode("ascii"))
    validation=profile=="smoke-validation"
    expected=dict(platform="cpu5",isa="rv32im",data_backend="bram",backend_id="1",cache_enable="3",
        cache_geometry=str(contract.CACHE_GEOMETRY),branch_pred_enable="1",btb_entries="64",
        btb_config=str(contract.BP_CONFIG),stats_schema="4",cycle_profile_schema="2",
        profile="cpu5-board-"+profile,mode="smoke",run="validation" if validation else "performance",
        cpu_hz="50000000",uart_baud="115200",iterations="1",iterations_requested="1",
        counter_valid="1",cycle_profile_valid="1",counter_cycles=str(summary["window_cycles"]),
        counter_retired=str(summary["window_retired"]),cycle_profile_sum=str(sum(summary["profile_delta"])),
        seed1="0x3415" if validation else "0x0000",seed2="0x3415" if validation else "0x0000",seed3="0x0066")
    crcs=("0x18f2","0xe3c1","0x0747","0x8d84") if validation else ("0xe9f5","0xe714","0x1fd7","0x8e3a")
    expected.update(zip(("seedcrc","crclist","crcmatrix","crcstate"),crcs))
    expected.update({"cycle_"+name:str(value) for name,value in zip(CLASSES,summary["profile_delta"])})
    for key,value in expected.items():
        if values.get(key)!=value:raise ValueError("board console "+key+": "+str(values.get(key))+" != "+value)
    if not summary["pass"] or not summary["reset_during_accepted_store"] or summary["ram_words_checked"]!=4096:
        raise ValueError("board reset/RAM closure")
    if summary["uart_bit_cycles"]!=434 or not len(console)==summary["console_bytes"]==summary["uart_frames"]:
        raise ValueError("board UART baud/frames")
    if summary["requests"]!=summary["responses"] or not 0<summary["window_retired"]<=summary["window_cycles"]==sum(summary["profile_delta"]):
        raise ValueError("board native/profile closure")
    if len(summary["profile_delta"])!=10 or any(v<0 for v in summary["profile_delta"]):
        raise ValueError("board ten-class values")
    if any(values.get(name)!="0" for name in ("icache_errors","dcache_errors")):
        raise ValueError("board cache errors")
    gap=summary["window_cycles"]-int(values["raw_ticks"])
    if int(values["window_tick_gap"])!=gap or not 0<=gap<=256:
        raise ValueError("board timer boundary")
    for name,value in zip(("seedcrc","crclist","crcmatrix","crcstate"),crcs):
        label={"seedcrc":"seedcrc          ","crclist":"[0]crclist       ","crcmatrix":"[0]crcmatrix     ","crcstate":"[0]crcstate      "}[name]
        if label+": "+value not in console.decode():raise ValueError("board upstream CRC "+name)
    if "not a formal score." not in console.decode():raise ValueError("board smoke scope")
    return dict(profile=profile,summary=summary,console_values=values,formal_score_measured=False)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vsim",type=Path,default=DEFAULT_VSIM)
    ap.add_argument("--timeout",type=int,default=10800)
    args=ap.parse_args()
    fw={p:firmware.validate_build(p) for p in PROFILES}
    before={p:sha(ROOT/p) for p in SOURCES}
    rid=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]+"_board_smoke"
    stage=OUT/"runs"/rid
    stage.mkdir(parents=True,exist_ok=False)
    for name,expected in before.items():
        dst=stage/"tested_sources"/name;dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/name,dst)
        if sha(dst)!=expected:raise ValueError("board smoke snapshot")
    for profile in PROFILES:
        shutil.copytree(firmware.OUT/profile,stage/"firmware"/profile)
        (stage/"raw"/profile).mkdir(parents=True)
    rtl=board.RTL_FILES+[contract.TOP,"tb/cpu5_board_smoke_tb.v"]
    source=stage/"tested_sources"
    compile_do=["onerror {quit -code 1 -f}","transcript file compile_transcript.log","vmap -c","vlib work",
        "vmap cpu5_board_work work","vlog -sv +incdir+"+source.as_posix()+" -work cpu5_board_work "+
        " ".join((source/p).as_posix() for p in rtl),'echo "CPU5 BOARD COMPILE PASS"',"quit -code 0 -f"]
    sim_do=["onerror {quit -code 1 -f}","transcript file simulation_transcript.log","vmap cpu5_board_work work",
        'vsim -voptargs="+acc=r+/cpu5_board_smoke_tb+0" -onfinish stop -gBASE='+ (stage/"firmware").as_posix()+
        ' -gRAW='+(stage/"raw").as_posix()+' -wlf system.wlf cpu5_board_work.cpu5_board_smoke_tb',
        "log sim:/cpu5_board_smoke_tb/test_pass","run -all",
        "if {[examine -radix unsigned sim:/cpu5_board_smoke_tb/test_pass] != 1} {quit -code 1 -f}",
        'echo "CPU5 BOARD REFERENCE PASS"',"quit -code 0 -f"]
    record=dict(status="RUNNING",run_id=rid,directory=stage.relative_to(ROOT).as_posix(),hardware=contract.CONFIG,
        source_sha256=before,firmware=fw,simulator_sha256=sha(args.vsim),sources_unchanged=False,
        hardware_download_performed=False,formal_score_measured=False)
    def save():write(stage/"verification.json",record);write(OUT/"board_smoke.json",record)
    save()
    try:
        for name,lines,marker in (("compile",compile_do,"CPU5 BOARD COMPILE PASS"),("simulate",sim_do,"CPU5 BOARD REFERENCE PASS")):
            script=stage/(name+".do");script.write_text("\n".join(lines)+"\n",encoding="utf-8",newline="\n")
            command=[str(args.vsim),"-c","-do",str(script)]
            started=time.time()
            with (stage/(name+"_console.log")).open("wb") as stream:
                process=subprocess.run(command,cwd=stage,stdout=stream,stderr=subprocess.STDOUT,timeout=args.timeout)
            log=(stage/(name+"_console.log")).read_text(encoding="utf-8",errors="replace")
            if process.returncode or marker not in log or re.search(r"\*\*\s+(?:Warning|Error|Fatal)\b",log):
                raise ValueError("CPU5 board "+name+" failed: "+log[-6000:])
            record[name+"_seconds"]=time.time()-started
            print("CPU5 board "+name+" PASS",flush=True)
        record["cases"]=[audit_case(stage/"raw"/p,p) for p in PROFILES]
        if before!={p:sha(ROOT/p) for p in SOURCES}:raise ValueError("board smoke source changed")
        if any(sha(source/p)!=v for p,v in before.items()):raise ValueError("board smoke snapshot changed")
        if sha(args.vsim)!=record["simulator_sha256"]:raise ValueError("board simulator changed")
        record.update(status="PASS",sources_unchanged=True)
        record["retained_sha256"]={p.relative_to(stage).as_posix():sha(p) for p in stage.rglob("*")
            if p.is_file() and ("raw" in p.relative_to(stage).parts or p.suffix in (".do",".log"))}
        save();print("CPU5 BOARD TWO SEEDS / REAL UART / RESET PASS",flush=True)
    except Exception as error:
        record.update(status="FAILED",failure=str(error));save();raise

if __name__=="__main__":main()

