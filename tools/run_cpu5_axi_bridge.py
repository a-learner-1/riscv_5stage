"""Private CPU5 AXI bridge model verification and specimen runner."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s14_axi_bridge'
TB='tb/cpu5_axi_bridge_tb.v'
from run_cpu5_cache_adapter import RTL as CACHE_RTL
RTL=CACHE_RTL+['rtl/data_mem.v','rtl/dmem_axi_lite_bridge.v','rtl/axi_lite_ram.v','rtl/cpu5_axi_lite_top.v']
COPIES=RTL+['rtl/cpu5_pipeline_types.vh','programs/data_handshake_blank.hex','tb/axi_lite_bridge_tb.v','tb/axi_lite_ram_tb.v',TB]
SOURCES=COPIES+['run_cpu5_axi_bridge.do','tools/run_cpu5_axi_bridge.py','tools/run_cpu5_cache_adapter.py']
DIAGNOSTIC=re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(',re.MULTILINE)
COMPILED='CPU5 AXI BRIDGE CLEAN COMPILE PASS'
PASSED='CPU5 AXI BRIDGE REFERENCE PASS'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def process(vsim,path,script,name):
    p=subprocess.run([str(vsim),'-c','-do',script],cwd=path,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    output=p.stdout+p.stderr;log=path/(name+'_console.log');log.write_text(output,encoding='utf-8',newline='')
    return p.returncode,output,log


def verify_one(vsim,path,spec,originals):
    path.mkdir(parents=True,exist_ok=False)
    for rel in COPIES:
        target=path/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(originals[rel])
    (path/'build/cpu5_s14_axi_bridge').mkdir(parents=True)
    change=None
    if spec and 'changed_file' in spec:
        target=path/spec['changed_file'];source=target.read_text(encoding='utf-8')
        assert source.count(spec['old'])==1,(spec['name'],'anchor count',source.count(spec['old']))
        target.write_text(source.replace(spec['old'],spec['new']),encoding='utf-8',newline='\n')
        change=dict(path=spec['changed_file'],good_sha256=hashlib.sha256(originals[spec['changed_file']]).hexdigest(),bad_sha256=sha(target),old=spec['old'],new=spec['new'])
        assert change['good_sha256']!=change['bad_sha256']
    (path/'compile.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap axi_bridge_work work',
        'vlog -sv +incdir+. -work axi_bridge_work '+' '.join(RTL+['tb/axi_lite_bridge_tb.v','tb/axi_lite_ram_tb.v',TB]),f'echo "{COMPILED}"','quit -code 0 -f','']),encoding='utf-8')
    code,output,compile_log=process(vsim,path,'compile.do','compile')
    assert code==0 and COMPILED in output and not DIAGNOSTIC.search(output),('clean compile',path.name,code,output[-7000:])
    compile_record=dict(status='PASS',exit_code=code,warnings=0,errors=0,console_sha256=sha(compile_log))
    tops=[spec.get('top','axi_lite_bridge_tb')] if spec else ['axi_lite_bridge_tb','axi_lite_ram_tb','cpu5_axi_bridge_tb']
    all_output=[];summaries={}
    for top in tops:
        tail=['quit -code 1 -f'] if spec and spec['kind']=='parameter_guard' else [f'if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 1 -f}}',f'echo "{PASSED}"','quit -code 0 -f']
        fields=(['cpu_requests','cpu_responses','cpu_errors','aw_count','w_count','b_count','ar_count','r_count','paired_writes','invalid_cases','reset_cases','abandoned_requests','order_aw_first','order_w_first','order_same','aw_stalls','w_stalls','ar_stalls','cpu_rsp_stalls'] if top=='axi_lite_bridge_tb' else
                ['aw_count','w_count','b_count','ar_count','r_count','ram_write_edges','ram_read_edges','contention_blocks'] if top=='axi_lite_ram_tb' else [])
        capture=[]
        if not spec and fields:
            capture=['set summary [open '+top+'_summary.json w]', 'puts $summary "\\{'+','.join('\\"'+field+'\\":'+'[examine -radix unsigned sim:/'+top+'/'+field+']' for field in fields)+'\\}"','close $summary']
        script=top+'_simulate.do'
        (path/script).write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file '+top+'_transcript.log','vmap axi_bridge_work work',
            f'vsim -voptargs="+acc" -onfinish stop -wlf {top}.wlf axi_bridge_work.{top}','log -r sim:/*','run -all',*capture,*tail,'']),encoding='utf-8')
        code,output,_=process(vsim,path,script,top)
        all_output.append(output)
        assert not DIAGNOSTIC.search(output),('simulation infrastructure',path.name,top,output[-7000:])
        actual=next((line.strip() for line in output.splitlines() if '** Fatal:' in line),None)
        if spec:
            tokens=spec['expected_assertion'] if isinstance(spec['expected_assertion'],list) else [spec['expected_assertion']]
            assert code!=0 and actual and any(token in actual for token in tokens),('designated semantic assertion',path.name,code,spec['expected_assertion'],output[-10000:])
        else:
            assert code==0 and PASSED in output and not actual,('good reference',top,code,output[-10000:])
            if fields:summaries[top]=json.loads((path/(top+'_summary.json')).read_text())
    simulation_log=path/'simulation_console.log';simulation_log.write_text('\n'.join(all_output),encoding='utf-8',newline='')
    status='REJECTED' if spec else 'PASS'
    record=dict(name=path.name,kind=spec['kind'] if spec else 'good_reference',status=status,directory=path.relative_to(ROOT).as_posix(),compile=compile_record,
                simulation_exit_code=code,expected_assertion=spec['expected_assertion'] if spec else None,actual_assertion=actual,changed_source=change,
                source_sha256={p:sha(path/p) for p in COPIES},simulation_console_sha256=sha(simulation_log),
                retained_artifact_sha256={p.name:sha(p) for p in path.iterdir() if p.is_file() and p.suffix in ('.do','.log','.wlf')})
    if not spec:
        cases=[json.loads((path/f'build/cpu5_s14_axi_bridge/cache{i}_summary.json').read_text()) for i in range(6)]
        for i,c in enumerate(cases):
            assert c['status']=='PASS' and c['case']==i and c['checks']==36 and c['errors']==10 and c['invalid']==3
            assert c['backend_requests']==c['backend_responses']+c['backend_reset_drops'] and c['backend_reset_drops']==1
            assert c['front_requests']==c['front_responses']+c['front_reset_drops'] and c['front_reset_drops']==1
            assert c['aw']==c['w']==c['b']==c['physical_writes'] and c['ar']==c['r']+c['axi_read_reset_drops']
        legacy=summaries['axi_lite_bridge_tb']
        assert legacy['cpu_requests']==36 and legacy['cpu_responses']==30 and legacy['cpu_errors']==13 and legacy['abandoned_requests']==legacy['reset_cases']==6
        assert legacy['aw_count']==legacy['w_count']==12 and legacy['b_count']==10 and legacy['ar_count']==13 and legacy['r_count']==12 and legacy['paired_writes']==11 and legacy['invalid_cases']==9
        record['legacy_bridge']=legacy;record['legacy_ram']=summaries['axi_lite_ram_tb'];record['cases']=cases
        record['summary']={key:sum(c[key] for c in cases) for key in cases[0] if key not in ('status','case','cache','order')}
        record['summary']['configurations']=len(cases)
    (path/'result.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8');print(path.name,status,flush=True)
    return record


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'));args=ap.parse_args()
    before={p:sha(ROOT/p) for p in SOURCES};originals={p:(ROOT/p).read_bytes() for p in SOURCES}
    run_id=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8];run=OUT/'runs'/run_id;run.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=run_id),indent=2)+'\n',encoding='utf-8')
    positive=verify_one(args.vsim,run/'good_reference',None,originals)
    assert before=={p:sha(ROOT/p) for p in SOURCES},'source changed during control verification'
    result=dict(status='PASS',run_id=run_id,source_sha256=before,sources_unchanged=True,positive=positive,compile_zero_warning_error=True,
                **positive['summary'],legacy_bridge=positive['legacy_bridge'],legacy_ram=positive['legacy_ram'],scope='Cache/native/AXI independent ledgers; lawful registered slave responses, 00/01/10/11, byte RAM gold, three write orders; original bridge and real RAM shared reset')
    rendered=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','configurations','checks','backend_requests','backend_responses','backend_reset_drops','front_requests','front_responses','front_reset_drops')}))


if __name__=='__main__':main()
