"""Reproduce the CPU5 fixed-vector synchronous-Trap stage and its references."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
from verify_cpu5_ram import SOURCES as RAM_SOURCES
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s6_verification'
TRAP_SOURCES=['tb/cpu5_trap_control_tb.v','tb/cpu5_trap_top_tb.v','run_cpu5_trap_control.do','run_cpu5_trap_top.do','tools/generate_cpu5_trap_vectors.py','tools/analyze_cpu5_trap.py','tools/verify_cpu5_trap.py']
SOURCES=sorted(set(RAM_SOURCES+TRAP_SOURCES))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
 ap.add_argument('--reuse-reference',action='store_true',help='reuse current RAM reference only when every tested source SHA matches')
 a=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
 before={rel:sha(ROOT/rel) for rel in SOURCES};processes=[]
 if a.reuse_reference:
  ref=read(ROOT/'build/cpu5_s5_verification/verification.json')
  assert ref['sources_unchanged'] and all(p['exit_code']==0 for p in ref['processes'])
  assert all(sha(ROOT/rel)==h for rel,h in ref['source_sha256'].items()),'reference source changed; rerun without --reuse-reference'
  processes.append(dict(name='reference',status='PASS',exit_code=0,reused=True,source_sha_checks=len(ref['source_sha256'])))
  commands=[]
 else:
  commands=[('reference',[sys.executable,'-B','tools/verify_cpu5_ram.py','--vsim',str(a.vsim)],'"total_retired": 23520')]
 for suite in ('control','top'):
  commands.append((suite,[str(a.vsim),'-c','-do',f'run_cpu5_trap_{suite}.do'],f'CPU5 TRAP {suite.upper()}'))
 commands += [('analysis',[sys.executable,'-B','tools/analyze_cpu5_trap.py'],'"status": "PASS"'),('analyzer_selftest',[sys.executable,'-B','tools/analyze_cpu5_trap.py','--selftest'],'"status": "PASS"')]
 for name,command,marker in commands:
  p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
  output=p.stdout+p.stderr;(OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
  assert p.returncode==0 and marker in output,(name,p.returncode,output[-4000:])
  assert not any(line.lstrip().startswith(('# ** Fatal:','# ** Error:','# ** Warning:','Traceback (')) for line in output.splitlines()),name
  processes.append(dict(name=name,status='PASS',exit_code=p.returncode));print(name,'PASS',flush=True)
 assert before=={rel:sha(ROOT/rel) for rel in SOURCES},'test changed source'
 analysis=read(ROOT/'build/cpu5_s6_trap/analysis.json')
 controls=[read(ROOT/f'build/cpu5_s6_trap_control/mode{m}_summary.json') for m in (0,1)]
 assert all(v['pass'] and v['cases']>=24 and v['traps']>=24 and v['retired']==v['wb'] and v['requests']==v['responses'] for v in controls)
 assert analysis['status']=='PASS' and analysis['case_count']==104 and analysis['total_traps']==104
 assert analysis['total_retired']==analysis['total_wb_packets']==1042 and analysis['total_d_requests']==analysis['total_d_responses']==336
 assert analysis['negative_evidence_tests']['rejected_count']==13 and analysis['negative_evidence_tests']['good_inputs_unchanged']
 result=dict(status='PARTIAL VERIFIED: CPU5 fixed-vector synchronous Trap',source_sha256=before,sources_unchanged=True,processes=processes,control=controls,end_to_end=analysis,
  architectural_limit='fixed parameter vector and observable fault registers; no software CSR/MRET/IRQ',M_MMIO_CSR_MRET_IRQ='NOT IMPLEMENTED',cache_AXI_SoC='NOT INTEGRATED',full_A01_A16='NOT RUN',STA='NOT RUN',board='NOT RUN',performance_claim='NONE')
 (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(dict(status=result['status'],directed_cases=sum(v['cases'] for v in controls),directed_traps=sum(v['traps'] for v in controls))))
if __name__=='__main__':main()
