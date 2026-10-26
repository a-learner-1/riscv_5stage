"""Re-run CPU5 board contract guards and the registered-redirect protocol probe."""
import argparse,json,re,shutil,subprocess,sys,time,uuid
from datetime import datetime,timezone
from pathlib import Path
import build_cpu5_pds as board
import cpu5_board_contract as contract
import verify_cpu5_board_build as audit
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19"
IF_RTL=["rtl/instr_mem.v","rtl/instr_bus_adapter.v","rtl/branch_predictor.v","rtl/if_stage.v","rtl/cpu5_if_adapter.v"]
SOURCES=sorted(set(IF_RTL+["tb/cpu5_redirect_timing_tb.v","programs/rv32i_regression.hex",
    "tools/test_cpu5_board_delivery.py","tools/test_build_pds_final_sta_guard.py","tools/verify_cpu5_board_build.py"]+board.SOURCES))

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vsim",type=Path,default=Path(r"D:\modeltech64_10.6e\win64\vsim.exe"))
    args=ap.parse_args()
    before={p:board.sha(ROOT/p) for p in SOURCES}
    rid=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]+"_guards"
    stage=OUT/"runs"/rid;stage.mkdir(parents=True)
    for name in before:
        p=stage/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,p)
    negatives=[]
    def reject(label,call):
        try:call()
        except (ValueError,RuntimeError):negatives.append(label)
        else:raise AssertionError("accepted bad board contract: "+label)
    text=(ROOT/contract.TOP).read_text()
    contract.validate_top(text)
    for name,value in contract.BINDINGS.items():
        mutant=text.replace("."+name+"("+value+")","."+name+"("+("1" if value=="0" else "0")+")",1)
        reject("hardware_"+name,lambda m=mutant:contract.validate_top(m))
    for label,old,new in (("cpu3_top","cpu5_stats_axi_lite_top","soc_coremark_axi_top"),
        ("clock",".clk(clk_50m)",".clk(key1_n)"),("gpio",".gpio_in({keys_n, key1_n})",".gpio_in(8'd0)"),
        ("irq",".irq_external(1'b0)",".irq_external(1'b1)")):
        reject(label,lambda m=text.replace(old,new,1):contract.validate_top(m))
    fdc=(ROOT/"pds/board_top.fdc").read_text();audit.fixed_constraints(fdc)
    for label,m in (("clock_40MHz",fdc.replace("20.000","25.000")),
        ("hidden_false_path",fdc+"\n set_false_path -from [get_cells {*u_pipeline*}]\n"),
        ("multicycle",fdc+"\nset_multicycle_path 2 -from [get_cells {*u_pipeline*}]\n"),
        ("missing_io_exception",fdc.replace("set_false_path -to","remove_false_path -to"))):
        reject(label,lambda m=m:audit.fixed_constraints(m))
    good=stage/"program.hex"
    for label,bad in (("relative_image",Path("program.hex")),("tcl_image",stage/"bad;image.hex"),("quote_image",stage/'bad"image.hex')):
        reject(label,lambda bad=bad:contract.bind_top(text,bad,good))
    reject("missing_source",lambda:audit.sources(ROOT,stage,{},board.SOURCES))
    reject("missing_artifact",lambda:audit.hashes(stage,{"absent.bin":"0"*64}))
    reject("empty_artifacts",lambda:audit.hashes(stage,{}))
    for label,path in (("traversal","../rtl/cpu5_top.v"),("absolute","/tmp/file"),("drive","C:/file")):
        reject(label,lambda path=path:audit.local(ROOT,path))
    command=[sys.executable,"tools/test_build_pds_final_sta_guard.py","-v"]
    p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=60)
    log=p.stdout+p.stderr;(stage/"sta_guard_console.log").write_text(log,encoding="utf-8")
    if p.returncode or not re.search(r"Ran \d+ tests",log) or not log.rstrip().endswith("OK"):
        raise RuntimeError("post-bitstream STA guards failed")
    sta_tests=int(re.search(r"Ran (\d+) tests",log)[1])
    script=stage/"redirect.do"
    lines=["onerror {quit -code 1 -f}","transcript file redirect_console.log","vmap -c","vlib work",
        "vmap redirect_work work","vlog -sv -work redirect_work "+" ".join(IF_RTL+["tb/cpu5_redirect_timing_tb.v"]),
        'vsim -voptargs="+acc=r+/cpu5_redirect_timing_tb+0" -onfinish stop redirect_work.cpu5_redirect_timing_tb',
        "run -all","if {[examine -radix unsigned sim:/cpu5_redirect_timing_tb/test_pass] != 1} {quit -code 1 -f}",
        'echo "CPU5 REDIRECT GUARD PASS"',"quit -code 0 -f"]
    script.write_text("\n".join(lines)+"\n",encoding="utf-8",newline="\n")
    with (stage/"redirect_process.log").open("wb") as stream:
        p=subprocess.run([str(args.vsim),"-c","-do",str(script)],cwd=stage,stdout=stream,stderr=subprocess.STDOUT,timeout=120)
    log=(stage/"redirect_process.log").read_text(errors="replace")
    if p.returncode or "CPU5 REGISTERED REDIRECT PASS checks=11" not in log or "CPU5 REDIRECT GUARD PASS" not in log or re.search(r"\*\*\s+(Warning|Error|Fatal)\b",log):
        raise RuntimeError("registered redirect probe failed: "+log[-5000:])
    if before!={p:board.sha(ROOT/p) for p in before}:raise RuntimeError("board guard source changed")
    if before!={p:board.sha(stage/p) for p in before}:raise RuntimeError("board guard snapshot changed")
    result=dict(status="PASS",run_id=rid,directory=stage.relative_to(ROOT).as_posix(),source_sha256=before,
        sources_unchanged=True,negatives_rejected=negatives,negative_count=len(negatives),
        existing_final_sta_guard_tests=sta_tests,redirect_protocol_checks=11,
        hardware_download_performed=False,formal_score_measured=False)
    result["retained_sha256"]={p.relative_to(stage).as_posix():board.sha(p) for p in stage.rglob("*")
        if p.is_file() and ("work" not in p.relative_to(stage).parts) and p.name!="modelsim.ini"}
    board.write(stage/"verification.json",result);board.write(OUT/"guards.json",result)
    print(json.dumps({k:result[k] for k in ("status","negative_count","existing_final_sta_guard_tests","redirect_protocol_checks")},indent=2))

if __name__=="__main__":main()

