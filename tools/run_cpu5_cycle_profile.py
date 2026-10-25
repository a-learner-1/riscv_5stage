"""Private directed CPU5 ten-class observations and real RTL specimen gate."""
import argparse
from datetime import datetime, timezone
import hashlib,json,re,subprocess,uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_cycle_profile'
RTL=['rtl/alu.v','rtl/regfile.v','rtl/rv32m_unit.v','rtl/cpu5_hazard.v',
     'rtl/cpu5_alu_decode.v','rtl/cpu5_branch_unit.v','rtl/cpu5_ram_unit.v',
     'rtl/cpu5_ram_owner.v','rtl/cpu5_csr_unit.v','rtl/cpu5_m_owner.v',
     'rtl/cpu5_irq_ctrl.v','rtl/cpu5_alu_pipeline.v']
TB='tb/cpu5_cycle_profile_tb.v'
COPIES=RTL+['rtl/cpu5_pipeline_types.vh',TB]
SOURCES=COPIES+['tools/run_cpu5_cycle_profile.py','run_cpu5_cycle_profile.do']
BAD=re.compile(r'\*\*\s+(?:Warning|Error)\b|^Traceback \(',re.MULTILINE)

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def specs():
    scenario='profile directed category'
    def m(name,old,new,token=scenario):return dict(name=name,kind='rtl_semantic',old=old,new=new,expected_assertion=token)
    return [
        m('all_events_missing','perf_cycle_events<=perf_cycle_next;','perf_cycle_events<=10\'b0;','profile onehot event missing/multiple'),
        m('multiple_classes','perf_cycle_events<=perf_cycle_next;','perf_cycle_events<=10\'b11;','profile onehot event missing/multiple'),
        m('data_wait_not_counted','wire perf_data_wait=perf_mem_data_wait || perf_fence_data_wait || perf_ex_data_wait;','wire perf_data_wait=1\'b0;'),
        m('local_mmio_counted_as_external','wire perf_data_local=ENABLE_MMIO && perf_data_addr[31:8]==24\'h200000;','wire perf_data_local=1\'b0;'),
        m('store_counted_as_read','wire perf_data_write=perf_mem_data_wait?exmem_q.is_store:','wire perf_data_write=perf_mem_data_wait?1\'b0:'),
        m('wb_masks_ignored','wire perf_mem_open=mem_enable && wb_can_load && !kill_mem &&','wire perf_mem_open=mem_enable && !kill_mem &&'),
        m('mem_pause_ignored','wire perf_mem_open=mem_enable && wb_can_load && !kill_mem &&','wire perf_mem_open=wb_can_load && !kill_mem &&'),
        m('ex_pause_ignored','idex_q.is_m && !idex_q.exception_valid && !kill_ex && ex_enable &&','idex_q.is_m && !idex_q.exception_valid && !kill_ex &&'),
        m('fast_div_busy_only','wire perf_m_wait=ENABLE_RV32M && rst_n && idex_valid_q && idex_supported_q &&','wire perf_m_wait=m_unit_busy && ENABLE_RV32M && rst_n && idex_valid_q && idex_supported_q &&','profile scenario category'),
        m('mul_div_classes_swapped','else if(perf_m_wait && !idex_q.funct3[2])','else if(perf_m_wait && idex_q.funct3[2])'),
        m('load_dependency_lumped','else if(perf_load_use)perf_cycle_next=10\'b0100000000;','else if(perf_load_use)perf_cycle_next=10\'b1000000000;','profile scenario category'),
        m('id_hazard_not_counted','else if(perf_id_wait)perf_cycle_next=10\'b1000000000;','else if(perf_id_wait)perf_cycle_next=10\'b0000000001;','profile scenario category'),
        m('background_m_drain_counted','!flush_valid && !trap_fire && !mret_fire && !irq_take && !mem_fault;','!flush_valid && !trap_fire && !mret_fire && !irq_take && !mem_fault || (m_owner_valid && m_owner_killed);',['profile scenario category','profile background M drain misattributed']),
        m('redirect_interval_missing','if(redirect_valid)perf_redirect_pending<=1\'b1;','if(redirect_valid)perf_redirect_pending<=1\'b0;'),
        m('redirect_interval_never_ends','else if(flush_fire || id_move)perf_redirect_pending<=1\'b0;','else if(flush_fire || id_move)perf_redirect_pending<=perf_redirect_pending;'),
    ]

def process(vsim,path,script,name):
    p=subprocess.run([str(vsim),'-c','-do',script],cwd=path,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    output=p.stdout+p.stderr;log=path/(name+'_console.log');log.write_text(output,encoding='utf-8',newline='')
    return p.returncode,output,log

def one(vsim,path,spec,originals):
    path.mkdir(parents=True)
    for rel,data in originals.items():
        target=path/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    (path/'build/cpu5_s16_cycle_profile').mkdir(parents=True)
    change=None
    if spec:
        target=path/'rtl/cpu5_alu_pipeline.v';s=target.read_text();assert s.count(spec['old'])==1,(spec['name'],s.count(spec['old']))
        target.write_text(s.replace(spec['old'],spec['new']),encoding='utf-8',newline='\n')
        change=dict(path='rtl/cpu5_alu_pipeline.v',good_sha256=hashlib.sha256(originals['rtl/cpu5_alu_pipeline.v']).hexdigest(),bad_sha256=sha(target),old=spec['old'],new=spec['new'])
    (path/'compile.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap profile_work work',
        'vlog -sv +incdir+. -work profile_work '+' '.join(RTL+[TB]),'echo "CPU5 PROFILE CLEAN COMPILE PASS"','quit -code 0 -f','']))
    code,output,clog=process(vsim,path,'compile.do','compile')
    assert code==0 and 'CPU5 PROFILE CLEAN COMPILE PASS' in output and not BAD.search(output),('compile',path.name,output[-9000:])
    (path/'simulate.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file simulation_transcript.log','vmap profile_work work',
        'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf profile_work.cpu5_cycle_profile_tb','log -r sim:/*','run -all',
        'if {[examine -radix unsigned sim:/cpu5_cycle_profile_tb/test_pass] != 1} {quit -code 1 -f}',
        'echo "CPU5 PROFILE REFERENCE PASS"','quit -code 0 -f','']))
    code,output,slog=process(vsim,path,'simulate.do','simulation')
    assert not BAD.search(output),('infrastructure',path.name,output[-9000:])
    fatal=next((line.strip() for line in output.splitlines() if '** Fatal:' in line),None)
    if spec:
        tokens=spec['expected_assertion'];tokens=[tokens] if isinstance(tokens,str) else tokens
        assert code!=0 and fatal and any(t in fatal for t in tokens),('semantic',path.name,code,output[-10000:])
    else:assert code==0 and 'CPU5 PROFILE REFERENCE PASS' in output and not fatal,('good',code,output[-12000:])
    retained={p.relative_to(path).as_posix():sha(p) for p in path.rglob('*') if p.is_file() and p.suffix in ('.do','.log','.csv','.json','.wlf','.ini') and 'work' not in p.relative_to(path).parts[:-1]}
    record=dict(name=path.name,kind='rtl_semantic' if spec else 'good_reference',status='REJECTED' if spec else 'PASS',directory=path.relative_to(ROOT).as_posix(),
        compile=dict(status='PASS',exit_code=0,warnings=0,errors=0,console_sha256=sha(clog)),simulation_exit_code=code,simulation_console_sha256=sha(slog),
        source_sha256={rel:sha(path/rel) for rel in originals},retained_artifact_sha256=retained,changed_source=change,
        expected_assertion=spec['expected_assertion'] if spec else None,actual_assertion=fatal)
    if not spec:
        cases=[json.loads((path/f'build/cpu5_s16_cycle_profile/case{i}_summary.json').read_text()) for i in range(4)]
        for i,c in enumerate(cases):
            assert c['status']=='PASS' and c['case']==i and c['retired']==c['wb'] and c['requests']==c['responses']
            assert sum(c['class_counts'])==c['cycles']
            rows=(path/f'build/cpu5_s16_cycle_profile/case{i}.csv').read_text().splitlines()[1:]
            assert len(rows)==c['cycles']
            for cycle,line in enumerate(rows,1):
                values=line.split(',');assert int(values[0])==int(values[1])==cycle
                event=int(values[2],16);assert event and event&(event-1)==0
        record['cases']=cases
        record['summary']={key:sum(c[key] for c in cases) for key in cases[0] if key not in ('status','case','forwarding','id_mode','class_counts')}
        record['summary']['class_counts']=[sum(c['class_counts'][i] for c in cases) for i in range(10)]
        assert all(record['summary']['class_counts'])
    (path/'result.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(path.name,record['status'],flush=True);return record

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reference-only',action='store_true');a=ap.parse_args()
    originals={p:(ROOT/p).read_bytes() for p in SOURCES};before={p:sha(ROOT/p) for p in SOURCES}
    run_id=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8];run=OUT/'runs'/run_id
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=run_id),indent=2)+'\n')
    positive=one(a.vsim,run/'good_reference',None,originals)
    specimens=[] if a.reference_only else [one(a.vsim,run/s['name'],s,originals) for s in specs()]
    assert before=={p:sha(ROOT/p) for p in SOURCES},'profile source changed during test'
    result=dict(status='PASS',run_id=run_id,source_sha256=before,sources_unchanged=True,compile_zero_warning_error=True,positive=positive,
        configurations=4,**positive['summary'],specimens=specimens,rtl_semantic_rejected=len(specimens),reference_only=a.reference_only,
        scope='Ten onehot classes, exact cycles sum, four FWD/ID variants, independent retire/WB, real native endpoint, masked stage/WB causes, killed resource drains, normal and zero-divisor DIV, redirect interval')
    rendered=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','configurations','cycles','retired','checks','rtl_semantic_rejected','class_counts')}))

if __name__=='__main__':main()
