"""Verify opt-in CPU5 integer forwarding and retain the stage 3A-1 reference."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from verify_cpu5_alu import SOURCES as ALU_SOURCES

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s3_verification'
SOURCES=sorted(set(ALU_SOURCES+[
    'tb/cpu5_forward_top_tb.v','tb/cpu5_forward_control_tb.v',
    'run_cpu5_forward_top.do','run_cpu5_forward_control.do',
    'tools/analyze_cpu5_forward.py','tools/verify_cpu5_forward.py',
    'tools/analyze_cpu5_alu_trace.py','tools/verify_cpu5_scaffold.py',
    'tools/analyze_cpu5_if_adapter.py','run_cpu5_if_adapter.do',
    'tb/cpu5_if_adapter_tb.v','run_cpu5_scaffold.do',
    'tb/cpu5_pipeline_skeleton_tb.v','tb/cpu5_top_scaffold_tb.v',
]))

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    if not (ROOT/'modelsim.ini').exists():
        subprocess.run([str(args.vsim.with_name('vmap.exe')),'-c'],cwd=ROOT,check=True)
    before={rel:digest(ROOT/rel) for rel in SOURCES}
    commands=[
        ('reference',[sys.executable,'-B','tools/verify_cpu5_alu.py','--vsim',str(args.vsim)],'"total_retired": 1193',0),
        ('forward_top',[str(args.vsim),'-c','-do','run_cpu5_forward_top.do'],'CPU5 FORWARD TOP PASS',0),
        ('forward_control',[str(args.vsim),'-c','-do','run_cpu5_forward_control.do'],'CPU5_FORWARD_CONTROL_PASS',0),
        ('forward_trace',[sys.executable,'-B','tools/analyze_cpu5_forward.py','--selftest'],'"status": "PASS"',0),
        ('if_gates',[str(args.vsim),'-c','-do','run_cpu5_if_adapter.do'],'CPU5 IF EXPECTED SEQUENCE EXHAUSTION REJECT PASS',1),
        ('if_trace',[sys.executable,'-B','tools/analyze_cpu5_if_adapter.py'],'"independent_ledger_checks": 457',0),
        ('scaffold',[sys.executable,'-B','tools/verify_cpu5_scaffold.py','--vsim',str(args.vsim)],'"released": 21',0),
    ]
    processes=[]
    for name,command,marker,expected_fatals in commands:
        p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=90)
        output=p.stdout+p.stderr
        (OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
        assert p.returncode==0 and marker in output,(name,p.returncode,output[-3000:])
        # Nested Python verifiers already assert their deliberately bad RTL
        # exited nonzero. The IF DO separately includes one terminal-age fatal.
        fatal_lines=[line for line in output.splitlines() if line.lstrip().startswith('# ** Fatal:')]
        assert len(fatal_lines)==expected_fatals,(name,fatal_lines)
        assert not any(line.lstrip().startswith(('# ** Warning:','# ** Error:','Traceback (')) for line in output.splitlines()),name
        processes.append(dict(name=name,exit_code=p.returncode,status='PASS',expected_fatals=expected_fatals))
    after={rel:digest(ROOT/rel) for rel in SOURCES}
    assert before==after,'tests changed source files'
    trace=json.loads((ROOT/'build/cpu5_s3_forward/independent_forward_audit.json').read_text())
    control_dir=ROOT/'build/cpu5_s3_control'
    with (control_dir/'control_trace.csv').open(newline='') as f: rows=list(csv.DictReader(f))
    counts=dict(retired=sum(int(r['pre_retire_fire']) for r in rows),
                wb_packets=sum(int(r['pre_wb_fire']) for r in rows),
                gpr_writes=sum(int(r['pre_wb_we']) for r in rows),
                id_accepts=sum(int(r['id_accept']) for r in rows))
    assert counts==dict(retired=44,wb_packets=44,gpr_writes=43,id_accepts=46),counts
    result=dict(status='PARTIAL VERIFIED: stage 3A-2 integer ALU forwarding subset',
        processes=processes,source_sha256=before,sources_unchanged=True,
        case_count=trace['case_count'],total_retired=trace['total_retired'],
        total_wb_packets=trace['total_wb_packets'],total_gpr_writes=trace['total_gpr_writes'],
        ab_comparisons=trace['ab_comparisons'],control=counts,
        full_3A2='NOT COMPLETE: LOAD-use and branch-use integration not implemented',
        full_A01_A16='NOT RUN',branch_D_M_CSR_Trap_IRQ='NOT IMPLEMENTED',STA='NOT RUN',board='NOT RUN')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({key:result[key] for key in ('status','case_count','total_retired','total_wb_packets','total_gpr_writes','control')}))

if __name__=='__main__':main()
