"""Fresh isolated terminal/stop-barrier and timer carry/wrap/hold CPU5 fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid
from datetime import datetime,timezone

import run_cpu5_coremark as runner
from cpu5_coremark_reference import audit_case
from test_cpu5_coremark_harness import transformed
ROOT=Path(__file__).resolve().parents[1]
SOURCES=sorted(set(runner.SOURCES)|{
 "tools/test_cpu5_coremark_probes.py","tools/test_cpu5_coremark_harness.py",
 "tools/cpu5_coremark_reference.py","tb/cpu5_coremark_timer_probe.v"})
PROGRAM="""
.section .text
.globl _start
_start:
    lui s0,0x30000
    lw zero,0(s0)
    lw zero,0(s0)
    lui s1,0x20000
    lw a0,0x44(s1)
    lw a1,0x40(s1)
    lw a2,0x44(s1)
    addi a3,zero,17
    addi a3,a3,3
    lw a0,0x44(s1)
    lw a1,0x40(s1)
    lw a2,0x44(s1)
    lw zero,4(s0)
    lui t0,0x14
    addi t0,t0,-4
    addi t1,zero,1
    sw t1,0(t0)
1:  jal zero,1b
"""


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vsim",type=Path,default=runner.DEFAULT_VSIM)
    parser.add_argument("--cross",default=runner.DEFAULT_CROSS)
    args=parser.parse_args()
    before={p:runner.sha(ROOT/p) for p in SOURCES}
    assert (ROOT/"tb/cpu5_coremark_harness.v").read_text(encoding="utf-8")==transformed()
    logical,_=runner.ensure_storage(runner.DEFAULT_STORAGE)
    rid=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]+"_probes"
    out=logical/rid;stage=out/"stage";stage.mkdir(parents=True)
    for path,expected in before.items():
        target=stage/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/path).read_bytes())
        assert runner.sha(target)==expected
    processes=[]
    def execute(command,name):
        started=time.monotonic()
        process=subprocess.run([str(x) for x in command],cwd=stage,capture_output=True,
                               text=True,encoding="utf-8",errors="replace",timeout=180)
        stdout=stage/(name+"_stdout.log");stderr=stage/(name+"_stderr.log")
        stdout.write_text(process.stdout,encoding="utf-8",newline="")
        stderr.write_text(process.stderr,encoding="utf-8",newline="")
        assert process.returncode==0 and not re.search(r"warning:|error:|\*\* (?:Warning|Error|Fatal)",process.stdout+process.stderr,re.I),(name,process.stdout[-5000:],process.stderr)
        processes.append(dict(name=name,command=[str(x) for x in command],exit_code=0,elapsed_seconds=time.monotonic()-started,
            stdout=runner.rel(stdout),stdout_sha256=runner.sha(stdout),stderr=runner.rel(stderr),stderr_sha256=runner.sha(stderr)))
        return process.stdout
    (stage/"probe.S").write_text(PROGRAM,encoding="ascii",newline="\n")
    execute([args.cross+"gcc","-march=rv32im","-mabi=ilp32","-mno-relax","-nostdlib","-nostartfiles",
             "-Wl,-Ttext=0","-Wl,--no-relax","-o","probe.elf","probe.S"],"gcc")
    execute([args.cross+"objcopy","-O","binary","probe.elf","probe.bin"],"objcopy")
    code=(stage/"probe.bin").read_bytes();assert len(code)%4==0
    rom=[int.from_bytes(code[n:n+4],"little") for n in range(0,len(code),4)]
    rom += [0x13]*(8192-len(rom))
    for n in range(4):
        directory=stage/"firmware"/f"case{n}";directory.mkdir(parents=True)
        (directory/"program.hex").write_text("".join(f"{word:08x}\n" for word in rom),encoding="ascii",newline="\n")
        (directory/"program_data.hex").write_text("00000000\n"*4096,encoding="ascii",newline="\n")
        (stage/"raw"/f"case{n}").mkdir(parents=True)
    compile_lines=["onerror {quit -code 1 -f}","transcript file compile_transcript.log","vmap -c","vlib work",
        "vmap s18_probe work","vlog -sv +incdir+. -work s18_probe "+" ".join(runner.RTL+["tb/cpu5_coremark_tb.v","tb/cpu5_coremark_timer_probe.v"]),
        'echo "CPU5 PROBE CLEAN COMPILE PASS"',"quit -code 0 -f"]
    (stage/"compile.do").write_text("\n".join(compile_lines)+"\n",encoding="ascii",newline="\n")
    execute([args.vsim,"-c","-do","compile.do"],"compile")
    for top,extra in (("cpu5_coremark_tb",f"-gQUICK_PROBE=1 -gFIRMWARE_BASE=firmware +RAW_BASE=raw +RUN_ID={rid}"),
                       ("cpu5_coremark_timer_probe","")):
        script=["onerror {quit -code 1 -f}",f"transcript file {top}_transcript.log",
            f'vsim -voptargs="+acc" -onfinish stop -wlf {top}.wlf s18_probe.{top} {extra}',
            f"log sim:/{top}/test_pass","run -all",
            f"if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 2 -f}}","quit -code 0 -f"]
        (stage/(top+".do")).write_text("\n".join(script)+"\n",encoding="ascii",newline="\n")
        text=execute([args.vsim,"-c","-do",top+".do"],top)
        assert ("CPU5 COREMARK SYSTEM PASS cases=4" if top=="cpu5_coremark_tb" else
            "CPU5 COREMARK TIMER PROBE PASS executions=12 responses=12 holds=23 carries=2 wraps=1") in text
    cases=[audit_case(stage/"raw"/f"case{n}",n,stage/"firmware"/f"case{n}",rid,allow_probe=True) for n in range(4)]
    assert before=={p:runner.sha(ROOT/p) for p in SOURCES}
    artifacts={runner.rel(p):runner.sha(p) for p in stage.rglob("*") if p.is_file()
               and "work" not in p.relative_to(stage).parts and p.relative_to(stage).as_posix() not in before}
    result=dict(status="PASS",scope="short directed fixtures; never substitute for four real CoreMark cases",
        run_id=rid,directory=runner.rel(stage),case_directory=runner.rel(stage/"raw"),
        firmware_directory=runner.rel(stage/"firmware"),source_sha256=before,sources_unchanged=True,
        source_lf_sha256={p:hashlib.sha256((ROOT/p).read_bytes().replace(b"\r\n",b"\n")).hexdigest() for p in SOURCES},
        artifact_sha256=artifacts,processes=processes,cases=cases,
        harness_mechanical_wrapper_transform=True,timer=dict(executions=12,responses=12,holds=23,carries=2,wraps=1))
    runner.write(out/"verification.json",result)
    runner.write(runner.OUT/"probe_verification.json",result)
    print("CPU5 fresh probes PASS: four terminal/drain cases + timer carry/wrap/response hold")


if __name__=="__main__":main()

