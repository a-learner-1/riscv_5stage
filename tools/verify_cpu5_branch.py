"""Reproduce CPU5 integer control flow; RAM/Trap/IRQ are outside this stage."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from verify_cpu5_forward import SOURCES as FORWARD_SOURCES

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s4_verification'
SOURCES=sorted(set(FORWARD_SOURCES+[
    'rtl/cpu5_branch_unit.v','tb/cpu5_branch_unit_tb.v','run_cpu5_branch_unit.do',
    'tb/cpu5_branch_control_tb.v','run_cpu5_branch_control.do',
    'tb/cpu5_branch_top_tb.v','run_cpu5_branch_top.do',
    'tools/generate_cpu5_branch_vectors.py','tools/analyze_cpu5_branch.py',
    'tools/verify_cpu5_branch.py']))

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    if not (ROOT/'modelsim.ini').exists():
        subprocess.run([str(args.vsim.with_name('vmap.exe')),'-c'],cwd=ROOT,check=True)
    before={rel:sha(ROOT/rel) for rel in SOURCES}
    commands=[
        ('reference',[sys.executable,'-B','tools/verify_cpu5_forward.py','--vsim',str(args.vsim)],'"total_retired": 2293'),
        ('unit',[str(args.vsim),'-c','-do','run_cpu5_branch_unit.do'],'CPU5 BRANCH UNIT PASS'),
        ('control',[str(args.vsim),'-c','-do','run_cpu5_branch_control.do'],'CPU5 BRANCH CONTROL PASS'),
        ('top',[str(args.vsim),'-c','-do','run_cpu5_branch_top.do'],'CPU5 BRANCH TOP PASS'),
        ('trace',[sys.executable,'-B','tools/analyze_cpu5_branch.py','--out','build/cpu5_s4_branch/analysis.json'],'"status": "PASS"'),
        ('trace_selftest',[sys.executable,'-B','tools/analyze_cpu5_branch.py','--selftest','--out','build/cpu5_s4_branch/analyzer_selftest.json'],'"rejected_count": 6'),
    ]
    processes=[]
    for name,command,marker in commands:
        p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=100)
        output=p.stdout+p.stderr
        (OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
        assert p.returncode==0 and marker in output,(name,p.returncode,output[-3500:])
        assert not any(line.lstrip().startswith(('# ** Fatal:','# ** Error:','# ** Warning:','Traceback (')) for line in output.splitlines()),name
        processes.append(dict(name=name,exit_code=p.returncode,status='PASS'))
    assert before=={rel:sha(ROOT/rel) for rel in SOURCES},'tests changed sources'
    trace=json.loads((ROOT/'build/cpu5_s4_branch/analysis.json').read_text())
    assert (trace['case_count'],trace['total_retired'],trace['total_wb_packets'])==(48,3064,3064)
    result=dict(status='PARTIAL VERIFIED: RV32I ALU and branch/JAL/JALR control flow',
        source_sha256=before,sources_unchanged=True,processes=processes,
        case_count=48,total_retired=trace['total_retired'],total_wb_packets=trace['total_wb_packets'],
        total_redirects=trace['total_redirects'],total_bp_commits=trace['total_bp_commits'],
        full_3A2='NOT COMPLETE: real LOAD-use integration remains absent',
        RAM_D_M_CSR_Trap_IRQ='NOT IMPLEMENTED',full_A01_A16='NOT RUN',STA='NOT RUN',board='NOT RUN')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({key:result[key] for key in ('status','case_count','total_retired','total_wb_packets','total_redirects','total_bp_commits')}))

if __name__=='__main__':main()
