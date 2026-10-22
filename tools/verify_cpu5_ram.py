"""Verify the opt-in CPU5 ordinary RAM stage and previous CPU5 references."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_branch import SOURCES as BRANCH_SOURCES

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s5_verification'
RAM_SOURCES=[
 'rtl/cpu5_ram_unit.v','rtl/cpu5_ram_owner.v',
 'tb/cpu5_ram_unit_tb.v','tb/cpu5_ram_owner_tb.v','tb/cpu5_ram_control_tb.v','tb/cpu5_ram_top_tb.v',
 'run_cpu5_ram_unit.do','run_cpu5_ram_owner.do','run_cpu5_ram_control.do','run_cpu5_ram_top.do',
 'tools/generate_cpu5_ram_vectors.py','tools/analyze_cpu5_ram.py','tools/verify_cpu5_ram.py',
 'software/cpu5_ram/start.S','software/cpu5_ram/main.c','software/cpu5_ram/link.ld','software/cpu5_ram/README.md']
SOURCES=sorted(set(BRANCH_SOURCES+RAM_SOURCES))
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
 args=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
 before={rel:sha(ROOT/rel) for rel in SOURCES}
 commands=[('reference',[sys.executable,'-B','tools/verify_cpu5_branch.py','--vsim',str(args.vsim)],'"total_retired": 3064')]
 for suite in ('unit','owner','control','top'):
  commands.append((suite,[str(args.vsim),'-c','-do',f'run_cpu5_ram_{suite}.do'],f'CPU5 RAM {suite.upper()}'))
 commands += [('analysis',[sys.executable,'-B','tools/analyze_cpu5_ram.py'],'"status": "PASS"'),
              ('analyzer_selftest',[sys.executable,'-B','tools/analyze_cpu5_ram.py','--selftest'],'"rejected": 10')]
 processes=[]
 for name,command,marker in commands:
  p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
  output=p.stdout+p.stderr
  (OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
  assert p.returncode==0 and marker in output,(name,p.returncode,output[-4000:])
  assert not any(line.lstrip().startswith(('# ** Fatal:','# ** Error:','# ** Warning:','Traceback (')) for line in output.splitlines()),name
  processes.append(dict(name=name,exit_code=p.returncode,status='PASS'))
  print(name,'PASS',flush=True)
 assert before=={rel:sha(ROOT/rel) for rel in SOURCES},'tests changed source files'
 trace=json.loads((ROOT/'build/cpu5_s5_ram/analysis.json').read_text())
 assert (trace['case_count'],trace['total_retired'],trace['total_wb_packets'],trace['total_d_requests'],trace['total_d_responses'])==(16,23520,23520,5744,5744)
 control=[json.loads((ROOT/f'build/cpu5_s5_ram_control/mode{mode}_summary.json').read_text()) for mode in (0,1)]
 assert all(c['pass'] and c['cases']==25 and c['requests']==c['responses'] and c['retired']==c['wb'] for c in control)
 unit=json.loads((ROOT/'build/cpu5_s5_ram_unit/summary.json').read_text())
 owner=json.loads((ROOT/'build/cpu5_s5_ram_owner/summary.json').read_text())
 result=dict(status='PARTIAL VERIFIED: CPU5 integer ALU/control flow/ordinary RAM',
   source_sha256=before,sources_unchanged=True,processes=processes,
   case_count=16,total_retired=23520,total_wb_packets=23520,total_d_requests=5744,total_d_responses=5744,
   directed_control=control,unit=unit,owner=owner,
   RAM_native_protocol='VERIFIED',MMIO_M_CSR_Trap_IRQ='NOT IMPLEMENTED',full_A01_A16='NOT RUN',
   cache_AXI_SoC='NOT INTEGRATED',STA='NOT RUN',board='NOT RUN',performance_claim='NONE')
 (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({k:result[k] for k in ('status','case_count','total_retired','total_wb_packets','total_d_requests','total_d_responses')}))
if __name__=='__main__':main()
