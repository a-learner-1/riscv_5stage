"""Fresh targeted CPU5 control regressions for the S19 ownership-path change."""
import argparse
import hashlib
import importlib
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid
from datetime import datetime,timezone

import build_cpu5_pds as board
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19"
DIRECT=(
 ("ram","run_cpu5_ram_control.do","tb/cpu5_ram_control_tb.v","cpu5_s5_ram_control","CPU5 RAM CONTROL DIRECTED TEST PASS"),
 ("trap","run_cpu5_trap_control.do","tb/cpu5_trap_control_tb.v","cpu5_s6_trap_control","CPU5 TRAP CONTROL DIRECTED TEST PASS"))
HELPERS=("run_cpu5_csr_control","run_cpu5_irq_control","run_cpu5_m_control","run_cpu5_fence_control")
SOURCES=sorted(set(board.SOURCES)|{"tools/run_cpu5_board_regressions.py"}|
 {p for row in DIRECT for p in row[1:3]}|
 set().union(*[set(importlib.import_module(name).SOURCES) for name in HELPERS]))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsim",type=Path,default=Path(r"D:\modeltech64_10.6e\win64\vsim.exe"))
    args=parser.parse_args();before={p:board.sha(ROOT/p) for p in SOURCES}
    rid=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]+"_controls"
    stage=OUT/"runs"/rid;stage.mkdir(parents=True)
    for p,expected in before.items():
        target=stage/"tested_sources"/p;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/p).read_bytes())
        assert board.sha(target)==expected
    physical=(OUT/"runs").resolve()/"control_outputs";physical.mkdir(exist_ok=True)
    def output_link(logical):
        target=physical/logical.name
        if logical.exists():
            assert logical.resolve().is_relative_to((OUT/"runs").resolve()),"unsafe existing control output"
            return logical
        target.mkdir(exist_ok=True)
        quote=lambda p:"'"+str(p).replace("'","''")+"'"
        subprocess.run(["powershell.exe","-NoProfile","-NonInteractive","-Command",
                        "New-Item -ItemType Junction -Path "+quote(logical)+" -Target "+quote(target)+" | Out-Null"],
                       check=True,capture_output=True)
        assert logical.resolve()==target.resolve()
        return logical
    results=[]
    def execute(name,command):
        p=subprocess.run([str(x) for x in command],cwd=ROOT,capture_output=True,text=True,
                         encoding="utf-8",errors="replace",timeout=600)
        log=stage/(name+"_console.log");log.write_text(p.stdout+p.stderr,encoding="utf-8",newline="")
        assert p.returncode==0 and not re.search(r"\*\*\s+(Warning|Error|Fatal)\b|^Traceback",p.stdout+p.stderr,re.M),(name,p.stdout[-5000:],p.stderr)
        return p,log
    for name,script,tb,out_name,marker in DIRECT:
        directory=output_link(ROOT/"build"/out_name)
        for m in (0,1):(directory/f"mode{m}_summary.json").unlink(missing_ok=True)
        process,log=execute(name,[args.vsim,"-c","-do",script])
        assert marker in process.stdout
        modes=[json.loads((directory/f"mode{m}_summary.json").read_text()) for m in (0,1)]
        for m,s in enumerate(modes):
            assert s["pass"] and s["mode"]==m and s["retired"]==s["wb"] and s["requests"]==s["responses"]
            assert s["killed_error_responses"]>0
        results.append(dict(name=name,status="PASS",command=[str(args.vsim),"-c","-do",script],console_sha256=board.sha(log),
                            modes=modes,directory=directory.relative_to(ROOT).as_posix()))
        print(name+" PASS",flush=True)
    for name in HELPERS:
        module=importlib.import_module(name);directory=output_link(module.OUT)
        process,log=execute(name,[sys.executable,"tools/"+name+".py","--vsim",args.vsim])
        r=json.loads((directory/"verification.json").read_text(encoding="utf-8"))
        assert r["status"]=="PASS" and r["sources_unchanged"]
        for p,expected in r["source_sha256"].items():assert board.sha(ROOT/p)==expected
        results.append(dict(name=name,status="PASS",verification=directory.relative_to(ROOT).as_posix()+"/verification.json",
                            verification_sha256=board.sha(directory/"verification.json"),console_sha256=board.sha(log),
                            cases=r.get("cases"),directory=directory.relative_to(ROOT).as_posix()))
        print(name+" PASS",flush=True)
    assert before=={p:board.sha(ROOT/p) for p in SOURCES}
    data=dict(status="PASS",run_id=rid,directory=stage.relative_to(ROOT).as_posix(),source_sha256=before,
              sources_unchanged=True,groups=results,scope="RAM, trap, CSR/MRET, IRQ, M-owner, FENCE control; not a new full historical signoff")
    data["retained_artifact_sha256"]={p.relative_to(ROOT).as_posix():board.sha(p) for p in stage.rglob("*") if p.is_file()}
    board.write(stage/"verification.json",data);board.write(OUT/"control_regressions.json",data)
    print("CPU5 S19 control regressions PASS: six groups")


if __name__=="__main__":main()
