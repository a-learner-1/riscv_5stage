"""Fresh original CPU5 control tests with explicit unused new observation ports."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid
from verify_cpu5_d0 import SOURCES as BASE_SOURCES

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_stats_compat'
TOPS=['cpu5_top_scaffold_tb','cpu5_if_adapter_tb','cpu5_alu_control_tb','cpu5_forward_control_tb',
      'cpu5_branch_control_tb','cpu5_ram_control_tb','cpu5_trap_control_tb','cpu5_csr_control_tb',
      'cpu5_m_control_tb','cpu5_irq_control_tb','cpu5_mmio_control_tb','cpu5_machine_control_tb',
      'cpu5_fence_control_tb','cpu5_fence_decode_tb','cpu5_cache_control_tb','cpu5_axi_control_tb','cpu5_d0_control_tb']
TB=['tb/'+top+'.v' for top in TOPS]
RTL=[p for p in BASE_SOURCES if p.startswith('rtl/') and p.endswith('.v')]
SOURCES=sorted(set(BASE_SOURCES+['tools/run_cpu5_stats_compat.py','programs/rv32i_regression.hex']))
DIAGNOSTIC=re.compile(r'\*\*\s+(?:Warning|Error)\b|^Traceback \(',re.MULTILINE)


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'));a=ap.parse_args()
    before={p:sha(ROOT/p) for p in SOURCES}
    rid=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8]
    run=OUT/'runs'/rid;private=run/'good_reference';private.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=rid),indent=2)+'\n',encoding='utf-8')
    for rel in SOURCES:
        dest=private/rel;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes((ROOT/rel).read_bytes())
    for rel in TB:
        for folder in re.findall(r'build/[A-Za-z0-9_]+',(ROOT/rel).read_text(encoding='utf-8')):(private/folder).mkdir(parents=True,exist_ok=True)
    def execute(name,lines):
        script=private/(name+'.do');script.write_text('\n'.join(lines)+'\n',encoding='utf-8')
        p=subprocess.run([str(a.vsim),'-c','-do',script.name],cwd=private,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
        output=p.stdout+p.stderr;log=private/(name+'_console.log');log.write_text(output,encoding='utf-8',newline='')
        assert p.returncode==0 and not DIAGNOSTIC.search(output) and '** Fatal:' not in output,(name,p.returncode,output[-12000:])
        return log,output
    compile_log,output=execute('compile',['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap stats_compat_work work',
        'vlog -sv +incdir+. -work stats_compat_work '+' '.join(RTL+TB),'echo "CPU5 STATS COMPAT CLEAN COMPILE PASS"','quit -code 0 -f'])
    assert 'CPU5 STATS COMPAT CLEAN COMPILE PASS' in output
    cases=[];console=[]
    for top in TOPS:
        log,output=execute(top,['onerror {quit -code 1 -f}','transcript file '+top+'_transcript.log','vmap stats_compat_work work',
            f'vsim -voptargs="+acc" -onfinish stop -wlf {top}.wlf stats_compat_work.{top}',
            f'log sim:/{top}/*','run -all',f'if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 1 -f}}',
            'echo "CPU5 STATS COMPAT REFERENCE PASS"','quit -code 0 -f'])
        assert 'CPU5 STATS COMPAT REFERENCE PASS' in output,top
        console.append(output);cases.append(dict(top=top,status='PASS',simulation_exit_code=0,warnings=0,errors=0,console_sha256=sha(log)))
        print(top,'PASS',flush=True)
    combined=private/'simulation_console.log';combined.write_text('\n'.join(console),encoding='utf-8',newline='')
    summaries={p.relative_to(private).as_posix():json.loads(p.read_text()) for p in sorted((private/'build').rglob('*.json'))}
    assert all(r.get('pass',True) is True and r.get('status','PASS')=='PASS' for r in summaries.values())
    assert before=={p:sha(ROOT/p) for p in SOURCES},'compatibility input changed during simulation'
    retained={p.relative_to(private).as_posix():sha(p) for p in private.rglob('*') if p.is_file() and 'work' not in p.relative_to(private).parts and p.suffix in ('.do','.log','.wlf','.ini','.csv','.json')}
    positive=dict(name='good_reference',kind='good_reference',status='PASS',directory=private.relative_to(ROOT).as_posix(),
        compile=dict(status='PASS',exit_code=0,warnings=0,errors=0,console_sha256=sha(compile_log)),simulation_exit_code=0,
        simulation_console_sha256=sha(combined),source_sha256=before,retained_artifact_sha256=retained)
    result=dict(status='PASS',run_id=rid,source_sha256=before,sources_unchanged=True,positive=positive,cases=cases,
                top_count=len(cases),summaries=summaries,scope='Fresh unchanged architectural/control scenarios, original IF/scaffold and S2-S15 control; WLF logs top-level signals, original CSV traces retain semantic observations; not a fresh complete legacy mutation/program chain')
    text=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(text,encoding='utf-8');(OUT/'verification.json').write_text(text,encoding='utf-8')
    print(json.dumps(dict(status='PASS',tops=len(cases),summaries=len(summaries))))


if __name__=='__main__':main()
