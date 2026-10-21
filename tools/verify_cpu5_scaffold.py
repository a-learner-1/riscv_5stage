"""Run only metadata-scaffold tests and three must-fail RTL corruptions."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s1_scaffold'

def run(vsim, script, log):
    p=subprocess.run([str(vsim),'-c','-do',str(script),'-l',str(log)],cwd=ROOT,
                     capture_output=True,text=True,encoding='utf-8',errors='replace')
    (log.parent/(log.stem+'_console.txt')).write_text(p.stdout+p.stderr,encoding='utf-8')
    return p.returncode,p.stdout+p.stderr

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    status,output=run(args.vsim,'run_cpu5_scaffold.do',OUT/'process.log')
    assert status==0 and 'CPU5 METADATA SCAFFOLD VERIFIED' in output,output[-3000:]
    assert '** Warning:' not in output and '** Error:' not in output and '** Fatal:' not in output
    # Independently reconstruct external identity ledger; no stage-ready model.
    queue=[];counts=dict(accepted=0,released=0,age_killed=0,reset_discarded=0)
    with (OUT/'pipeline_trace.csv').open(newline='') as f:
        for row in csv.DictReader(f):
            s=int(row['seq'],16);event=row['event']
            if event=='accept':
                queue.append(s);counts['accepted']+=1
            elif event=='release':
                assert queue and queue.pop(0)==s,('ledger',row)
                assert int(row['pc'],16)==0x1000+(s&0xffff)*4
                assert int(row['instr'],16)==0x12340013^((s&0xffff)<<8)
                counts['released']+=1
            elif event=='flush':
                old=len(queue);queue=[q for q in queue if q<s];counts['age_killed']+=old-len(queue)
            elif event=='reset':
                counts['reset_discarded']+=len(queue);queue=[]
            else:raise ValueError(event)
    assert not queue and counts==dict(accepted=29,released=21,age_killed=5,reset_discarded=3),counts
    results=[{'case':'original','exit_code':status,'status':'PASS','warnings':0}]
    original=(ROOT/'rtl/cpu5_pipeline_skeleton.v').read_text(encoding='utf-8')
    variants={
        'truncated_age': [('idex_q.seq>=flush_cut_seq','idex_q.seq[31:0]>=flush_cut_seq[31:0]'),
                          ('exmem_q.seq>=flush_cut_seq','exmem_q.seq[31:0]>=flush_cut_seq[31:0]'),
                          ('memwb_q.seq>=flush_cut_seq','memwb_q.seq[31:0]>=flush_cut_seq[31:0]')],
        'repeat_wb': [('if(wb_can_load) begin','if(wb_can_load && mem_move) begin')],
        'fault_to_wb': [(' && !exmem_q.exception_valid && mem_enable',' && mem_enable')]
    }
    for name,replacements in variants.items():
        folder=OUT/'mutants'/name;folder.mkdir(parents=True,exist_ok=True)
        text=original
        for a,b in replacements:
            assert text.count(a)==1,(name,a)
            text=text.replace(a,b)
        (folder/'cpu5_pipeline_skeleton.v').write_text(text,encoding='utf-8')
        rel=folder.relative_to(ROOT).as_posix()
        lib='cpu5_scaffold_mutant_'+name
        do=f'''onerror {{quit -code 1 -f}}
catch {{quit -sim}}
if {{![file isdirectory {rel}/work]}} {{vlib {rel}/work}}
vmap {lib} {rel}/work
vlog -sv +incdir+. -work {lib} {rel}/cpu5_pipeline_skeleton.v tb/cpu5_pipeline_skeleton_tb.v
vsim -voptargs="+acc" -onfinish stop {lib}.cpu5_pipeline_skeleton_tb +SCAFFOLD_TRACE_DIR={rel}
run -all
if {{[examine -radix unsigned sim:/cpu5_pipeline_skeleton_tb/test_pass] != 1}} {{error "Must-fail mutated pipeline"}}
quit -code 0 -f
'''
        script=folder/'mutant.do';script.write_text(do,encoding='utf-8')
        status,output=run(args.vsim,script,folder/'process.log')
        assert status!=0 and '** Fatal:' in output and 'Must-fail mutated pipeline' in output,(name,status,output[-2000:])
        results.append({'case':name,'exit_code':status,'status':'REJECTED AS EXPECTED',
                        'fatal_lines':[x for x in output.splitlines() if '** Fatal:' in x]})
    source_files=['rtl/cpu5_pipeline_skeleton.v','rtl/cpu5_pipeline_types.vh','rtl/cpu5_top.v',
                  'rtl/cpu5_if_adapter.v','rtl/cpu5_hazard.v','rtl/if_stage.v',
                  'tb/cpu5_pipeline_skeleton_tb.v','tb/cpu5_top_scaffold_tb.v',
                  'run_cpu5_scaffold.do','tools/verify_cpu5_scaffold.py']
    report={'status':'PARTIAL VERIFIED: metadata scaffold only','processes':results,
            'independent_pipeline_ledger':counts,
            'positive_pipeline_trace_sha256':hashlib.sha256((OUT/'pipeline_trace.csv').read_bytes()).hexdigest(),
            'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in source_files},
            'isa_execution':'NOT IMPLEMENTED','architecture_retirement':'NOT IMPLEMENTED',
            'D_M_CSR_IRQ_Trap':'NOT IMPLEMENTED','STA':'NOT RUN','board':'NOT RUN'}
    (OUT/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()
