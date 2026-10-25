"""Private CPU5 D0 backend verification against independent native/AXI/RAM gold."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

from run_cpu5_cache_adapter import RTL as CACHE_RTL

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s15_d0_backend'
TB='tb/cpu5_d0_backend_tb.v'
RTL=list(dict.fromkeys(CACHE_RTL+['rtl/data_mem.v','rtl/data_bus_adapter.v','rtl/soc_instr_mem.v',
    'rtl/soc_data_mem.v','rtl/dmem_region_router.v','rtl/dmem_axi_lite_bridge.v',
    'rtl/cpu5_d0_backend.v','rtl/cpu5_d0_axi_lite_top.v']))
TESTS=['tb/d0_native_backend_tb.v','tb/soc_memory_tb.v',TB]
COPIES=RTL+['rtl/cpu5_pipeline_types.vh','programs/data_handshake_blank.hex']+TESTS
SOURCES=COPIES+['run_cpu5_d0_backend.do','tools/run_cpu5_d0_backend.py','tools/run_cpu5_cache_adapter.py','tools/verify_cpu5_d0_mutations.py']
DIAGNOSTIC=re.compile(r'\*\*\s+(?:Warning|Error)\b|^Traceback \(',re.MULTILINE)
COMPILED='CPU5 D0 BACKEND CLEAN COMPILE PASS'
PASSED='CPU5 D0 BACKEND REFERENCE PASS'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def process(vsim,path,script,name):
    p=subprocess.run([str(vsim),'-c','-do',script],cwd=path,capture_output=True,text=True,
                     encoding='utf-8',errors='replace',timeout=240)
    output=p.stdout+p.stderr;log=path/(name+'_console.log')
    log.write_text(output,encoding='utf-8',newline='')
    return p.returncode,output,log


def verify_one(vsim,path,spec,originals):
    path.mkdir(parents=True,exist_ok=False)
    for rel,content in originals.items():
        target=path/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(content)
    (path/'build/cpu5_s15_d0_backend').mkdir(parents=True)
    change=None
    if spec and 'changed_file' in spec:
        target=path/spec['changed_file'];source=target.read_text(encoding='utf-8')
        assert source.count(spec['old'])==1,(spec['name'],'anchor count',source.count(spec['old']))
        target.write_text(source.replace(spec['old'],spec['new']),encoding='utf-8',newline='\n')
        change=dict(path=spec['changed_file'],good_sha256=hashlib.sha256(originals[spec['changed_file']]).hexdigest(),
                    bad_sha256=sha(target),old=spec['old'],new=spec['new'])
        assert change['good_sha256']!=change['bad_sha256']
    (path/'compile.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file compile_transcript.log',
        'vmap -c','vlib work','vmap d0_backend_work work',
        'vlog -sv +incdir+. -work d0_backend_work '+' '.join(RTL+TESTS),f'echo "{COMPILED}"','quit -code 0 -f','']),encoding='utf-8')
    code,output,compile_log=process(vsim,path,'compile.do','compile')
    assert code==0 and COMPILED in output and not DIAGNOSTIC.search(output),('clean compile',path.name,code,output[-9000:])
    compile_record=dict(status='PASS',exit_code=code,warnings=0,errors=0,console_sha256=sha(compile_log))
    tops=[spec.get('top','cpu5_d0_backend_tb')] if spec else ['d0_native_backend_tb','soc_memory_tb','cpu5_d0_backend_tb']
    all_output=[];summaries={};actual=None
    for top in tops:
        tail=['quit -code 1 -f'] if spec and spec['kind']=='parameter_guard' else [
            f'if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 1 -f}}',
            f'echo "{PASSED}"','quit -code 0 -f']
        fields=['checks','r0','r1','c0','c1'] if top=='d0_native_backend_tb' else []
        capture=[]
        if not spec and fields:
            capture=['set summary [open '+top+'_summary.json w]', 'puts $summary "\\{'+','.join(
                '\\"'+field+'\\":'+'[examine -radix unsigned sim:/'+top+'/'+field+']' for field in fields)+'\\}"','close $summary']
        script=top+'_simulate.do'
        (path/script).write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file '+top+'_transcript.log',
            'vmap d0_backend_work work',f'vsim -voptargs="+acc" -onfinish stop -wlf {top}.wlf d0_backend_work.{top}',
            'log -r sim:/*','run -all',*capture,*tail,'']),encoding='utf-8')
        code,output,_=process(vsim,path,script,top);all_output.append(output)
        assert not DIAGNOSTIC.search(output),('simulation infrastructure',path.name,top,output[-9000:])
        actual=next((line.strip() for line in output.splitlines() if '** Fatal:' in line),None)
        if spec:
            tokens=spec['expected_assertion'] if isinstance(spec['expected_assertion'],list) else [spec['expected_assertion']]
            assert code!=0 and actual and any(token in actual for token in tokens),(
                'designated semantic assertion',path.name,code,spec['expected_assertion'],output[-10000:])
        else:
            assert code==0 and PASSED in output and not actual,('good reference',top,code,output[-10000:])
            if fields:summaries[top]=json.loads((path/(top+'_summary.json')).read_text())
    simulation_log=path/'simulation_console.log';simulation_log.write_text('\n'.join(all_output),encoding='utf-8',newline='')
    record=dict(name=path.name,kind=spec['kind'] if spec else 'good_reference',status='REJECTED' if spec else 'PASS',
        directory=path.relative_to(ROOT).as_posix(),compile=compile_record,simulation_exit_code=code,
        expected_assertion=spec['expected_assertion'] if spec else None,actual_assertion=actual,changed_source=change,
        source_sha256={p:sha(path/p) for p in originals},simulation_console_sha256=sha(simulation_log),
        retained_artifact_sha256={p.name:sha(p) for p in path.iterdir() if p.is_file() and p.suffix in ('.do','.log','.wlf','.ini')})
    if not spec:
        cases=[json.loads((path/f'build/cpu5_s15_d0_backend/case{i}_summary.json').read_text()) for i in range(6)]
        for i,c in enumerate(cases):
            assert c['status']=='PASS' and c['case']==i and c['checks']==(45 if i<4 else 33) and c['invalid']==6 and c['errors']==12
            assert c['accepted']==c['responses']+c['reset_drops'] and c['reset_drops']==3
            assert c['aw']==c['w']==c['b']==c['paired_writes'] and c['ar']==c['r']+c['axi_reset_reads'] and c['axi_reset_reads']==1
            assert c['side_reads']==5 and c['io_writes']==2
            assert (c['local_ops']==0 and c['axi_ram_writes']==6) if c['d0']==0 else (c['local_ops']>0 and c['local_writes']==6 and c['axi_ram_writes']==0)
        legacy=summaries['d0_native_backend_tb']
        assert legacy==dict(checks=19,r0=16,r1=3,c0=15,c1=3),legacy
        record['legacy_native']=legacy;record['legacy_memory']='PASS';record['cases']=cases
        record['summary']={key:sum(c[key] for c in cases) for key in cases[0] if key not in ('status','case','d0','wait','upper')}
        record['summary']['configurations']=len(cases)
    (path/'result.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(path.name,record['status'],flush=True)
    return record


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reference-only',action='store_true',help='run only the development positive control; full gate requires default mode')
    args=ap.parse_args()
    before={p:sha(ROOT/p) for p in SOURCES};originals={p:(ROOT/p).read_bytes() for p in SOURCES}
    run_id=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8]
    run=OUT/'runs'/run_id;run.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=run_id,source_sha256=before),indent=2)+'\n',encoding='utf-8')
    positive=verify_one(args.vsim,run/'good_reference',None,originals)
    assert before=={p:sha(ROOT/p) for p in SOURCES},'source changed during control verification'
    result=dict(status='PASS',run_id=run_id,source_sha256=before,sources_unchanged=True,positive=positive,
        compile_zero_warning_error=True,**positive['summary'],legacy_native=positive['legacy_native'],legacy_memory=positive['legacy_memory'],
        scope='True new CPU5 D0 backend + real synchronous RAM + independent AXI slave/byte gold; D0 enable/waits/4-GiB endpoint, all AXI response codes, holds/reset, physical authorization; separate old native-router and RAM fixtures')
    (OUT/'good_reference.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    if not args.reference_only:
        proc=subprocess.run([sys.executable,'-B','tools/verify_cpu5_d0_mutations.py','--vsim',str(args.vsim)],cwd=ROOT,
            capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=900)
        output=proc.stdout+proc.stderr;(run/'mutations_console.log').write_text(output,encoding='utf-8',newline='')
        assert proc.returncode==0,('mutation suite',output[-14000:])
        mutation_path=ROOT/'build/cpu5_s15_d0_mutations/verification.json';mutations=json.loads(mutation_path.read_text())
        assert mutations['status']=='PASS' and mutations['source_sha256']==before and mutations['good_sources_unchanged']
        result.update(specimens=mutations['specimens'],rtl_semantic_rejected=mutations['rtl_semantic_rejected'],
            parameter_guards_rejected=mutations['parameter_guards_rejected'],mutation_run_id=mutations['run_id'],
            mutation_verification=mutation_path.relative_to(ROOT).as_posix(),mutation_verification_sha256=sha(mutation_path))
    else:result['scope_phase']='REFERENCE_ONLY'
    assert before=={p:sha(ROOT/p) for p in SOURCES},'source changed during complete backend verification'
    rendered=json.dumps(result,indent=2)+'\n'
    (run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','configurations','checks','accepted','responses','reset_drops')}))


if __name__=='__main__':main()
