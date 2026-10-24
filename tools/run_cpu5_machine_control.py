"""Private real-top machine-device directed verification and shared specimen runner."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s11_machine_control'
TB='tb/cpu5_machine_control_tb.v'
RTL=['rtl/instr_mem.v','rtl/instr_bus_adapter.v','rtl/branch_predictor.v','rtl/if_stage.v',
     'rtl/alu.v','rtl/regfile.v','rtl/rv32m_unit.v','rtl/cpu5_if_adapter.v','rtl/cpu5_hazard.v',
     'rtl/cpu5_pipeline_skeleton.v','rtl/cpu5_alu_decode.v','rtl/cpu5_branch_unit.v',
     'rtl/cpu5_ram_unit.v','rtl/cpu5_ram_owner.v','rtl/cpu5_csr_unit.v','rtl/cpu5_m_owner.v',
     'rtl/cpu5_irq_ctrl.v','rtl/cpu5_alu_pipeline.v','rtl/cpu5_top.v',
     'rtl/cpu5_mmio_endpoint.v','rtl/cpu5_mmio_router.v','rtl/gpio_mmio.v','rtl/uart_tx.v',
     'rtl/uart_rx.v','rtl/uart_rx_fifo.v','rtl/uart_rx_mmio.v','rtl/machine_timer.v',
     'rtl/cpu5_machine_endpoint.v','rtl/cpu5_machine_router.v']
COPIES=RTL+['rtl/cpu5_pipeline_types.vh','programs/data_handshake_blank.hex',TB]
SOURCES=COPIES+['run_cpu5_machine_control.do','tools/run_cpu5_machine_control.py']
DIAGNOSTIC=re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(',re.MULTILINE)
COMPILED='CPU5 MACHINE CONTROL CLEAN COMPILE PASS'
PASSED='CPU5 MACHINE CONTROL REFERENCE PASS'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def process(vsim,path,script,name):
    p=subprocess.run([str(vsim),'-c','-do',script],cwd=path,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    output=p.stdout+p.stderr;log=path/(name+'_console.log');log.write_text(output,encoding='utf-8',newline='')
    return p.returncode,output,log


def verify_one(vsim,path,spec,originals):
    path.mkdir(parents=True,exist_ok=False)
    for rel in COPIES:
        target=path/rel;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(originals[rel])
    (path/'build/cpu5_s11_machine_control').mkdir(parents=True)
    change=None
    if spec and 'changed_file' in spec:
        target=path/spec['changed_file'];source=target.read_text(encoding='utf-8')
        assert source.count(spec['old'])==1,(spec['name'],'anchor count',source.count(spec['old']))
        target.write_text(source.replace(spec['old'],spec['new']),encoding='utf-8',newline='\n')
        change=dict(path=spec['changed_file'],good_sha256=hashlib.sha256(originals[spec['changed_file']]).hexdigest(),bad_sha256=sha(target),old=spec['old'],new=spec['new'])
        assert change['good_sha256']!=change['bad_sha256']
    (path/'compile.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap machine_control_work work',
        'vlog -sv +incdir+. -work machine_control_work '+' '.join(RTL+[TB]),f'echo "{COMPILED}"','quit -code 0 -f','']),encoding='utf-8')
    top=spec.get('top','cpu5_machine_control_tb') if spec else 'cpu5_machine_control_tb'
    generic=spec.get('generic','') if spec else ''
    tail=['quit -code 1 -f'] if spec and spec['kind']=='parameter_guard' else [f'if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 1 -f}}',f'echo "{PASSED}"','quit -code 0 -f']
    (path/'simulate.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file simulation_transcript.log','vmap machine_control_work work',
        f'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf {generic} machine_control_work.{top}','log -r sim:/*','run -all',*tail,'']),encoding='utf-8')
    code,output,compile_log=process(vsim,path,'compile.do','compile')
    assert code==0 and COMPILED in output and not DIAGNOSTIC.search(output),('clean compile',path.name,code,output[-6000:])
    compile_record=dict(status='PASS',exit_code=code,warnings=0,errors=0,console_sha256=sha(compile_log))
    code,output,simulation_log=process(vsim,path,'simulate.do','simulation')
    assert not DIAGNOSTIC.search(output),('simulation infrastructure',path.name,output[-6000:])
    actual=next((line.strip() for line in output.splitlines() if '** Fatal:' in line),None)
    if spec:
        tokens=spec['expected_assertion'] if isinstance(spec['expected_assertion'],list) else [spec['expected_assertion']]
        assert code!=0 and actual and any(token in actual for token in tokens),('designated semantic assertion',path.name,code,spec['expected_assertion'],output[-9000:])
        status='REJECTED'
    else:
        assert code==0 and PASSED in output and not actual,('good reference',code,output[-9000:])
        status='PASS'
    record=dict(name=path.name,kind=spec['kind'] if spec else 'good_reference',status=status,directory=path.relative_to(ROOT).as_posix(),compile=compile_record,
                simulation_exit_code=code,expected_assertion=spec['expected_assertion'] if spec else None,actual_assertion=actual,changed_source=change,
                source_sha256={p:sha(path/p) for p in COPIES},simulation_console_sha256=sha(simulation_log),
                retained_artifact_sha256={p.name:sha(p) for p in path.iterdir() if p.is_file() and p.suffix in ('.do','.log','.wlf')})
    if not spec:
        cases=[json.loads((path/f'build/cpu5_s11_machine_control/case{c}_summary.json').read_text()) for c in range(18)]
        assert all(c['pass'] and c['case']==i and c['requests']==c['responses'] and c['retired']==c['wb'] for i,c in enumerate(cases))
        assert sum(c['irqs'] for c in cases)==10 and sum(c['traps'] for c in cases)==24
        assert all(c['natural_wait_edges']>100 and c['natural_irq_time']>=250 for c in cases if c['scenario']==8)
        record['cases']=cases
        record['summary']={key:sum(c[key] for c in cases) for key in ('checks','retired','wb','irqs','traps','requests','responses','executions','software_writes','timer_writes','natural_wait_edges')}
        record['summary']['cases']=18
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
                **positive['summary'],scope='real CPU5 top, four device maps with IRQs disabled, raw/bank IRQ OR, exact two-stage/arm/CSR/PC model')
    rendered=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','cases','retired','irqs','traps','requests','responses','checks')}))


if __name__=='__main__':main()
