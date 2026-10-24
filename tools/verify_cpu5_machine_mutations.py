"""Reject real top/device/synchronizer mutations only after clean compilation."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import uuid
from run_cpu5_machine_control import ROOT, SOURCES as CONTROL_SOURCES, sha, verify_one

OUT=ROOT/'build/cpu5_s11_machine_mutations'
SOURCES=CONTROL_SOURCES+['tools/verify_cpu5_machine_mutations.py']
TOP='rtl/cpu5_top.v';CTRL='rtl/cpu5_irq_ctrl.v';ENDPOINT='rtl/cpu5_machine_endpoint.v'


def mutant(name,path,old,new,token='two-flop old-arm arbitration'):
    tokens=token if isinstance(token,list) else [token]
    return dict(name=name,kind='rtl_semantic',changed_file=path,old=old,new=new,
                expected_assertion=['MACHINE control oracle '+t for t in tokens])


def specimens():
    return [
        mutant('software_irq_drops_device',TOP,'.irq_software(irq_software || machine_software_irq),','.irq_software(irq_software),'),
        mutant('software_irq_drops_raw_pin',TOP,'.irq_software(irq_software || machine_software_irq),','.irq_software(machine_software_irq),'),
        mutant('timer_irq_drops_device',TOP,'.irq_timer(irq_timer || machine_timer_irq),','.irq_timer(irq_timer),'),
        mutant('timer_irq_drops_raw_pin',TOP,'.irq_timer(irq_timer || machine_timer_irq),','.irq_timer(machine_timer_irq),'),
        mutant('software_irq_uses_timer_bank',TOP,'.irq_software(irq_software || machine_software_irq),','.irq_software(irq_software || machine_timer_irq),'),
        mutant('timer_irq_uses_software_bank',TOP,'.irq_timer(irq_timer || machine_timer_irq),','.irq_timer(irq_timer || machine_software_irq),'),
        mutant('software_source_flag_not_propagated',TOP,'.ENABLE_EXTERNAL_IRQ(ENABLE_EXTERNAL_IRQ),.ENABLE_SOFTWARE_IRQ(ENABLE_SOFTWARE_IRQ),','.ENABLE_EXTERNAL_IRQ(ENABLE_EXTERNAL_IRQ),.ENABLE_SOFTWARE_IRQ(0),'),
        mutant('timer_source_flag_not_propagated',TOP,'.ENABLE_TIMER_IRQ(ENABLE_TIMER_IRQ)) u_pipeline(','.ENABLE_TIMER_IRQ(0)) u_pipeline('),
        mutant('software_device_bypasses_second_flop',CTRL,'software_sync_q<=software_meta_q;','software_sync_q<=irq_software;'),
        mutant('timer_device_bypasses_second_flop',CTRL,'timer_sync_q<=timer_meta_q;','timer_sync_q<=irq_timer;'),
        mutant('enable_candidate_uses_old_status',CTRL,'wire next_global=retire_fire?post_commit_global_enable:global_enable;','wire next_global=global_enable;'),
        mutant('software_write_waits_for_response',ENDPOINT,
                'wire software_write_fire=endpoint_fire && access_legal && write_q && software_hit;',
                'wire software_write_fire=rsp_valid && rsp_ready && access_legal && write_q && software_hit;',
                ['unique source-specific machine writes','post-edge machine state and write timing']),
        mutant('timer_write_waits_for_response',ENDPOINT,
                'wire timer_write_fire=endpoint_fire && access_legal && write_q && timer_write_hit;',
                'wire timer_write_fire=rsp_valid && rsp_ready && access_legal && write_q && timer_write_hit;',
                ['unique source-specific machine writes','post-edge machine state and write timing']),
        mutant('timer_compare_is_signed','rtl/machine_timer.v','assign mtip = (mtime >= mtimecmp);','assign mtip = ($signed(mtime) >= $signed(mtimecmp));',
                'device IRQ level independent of CPU source flags'),
        mutant('software_read_implicitly_clears_source',ENDPOINT,
                'if(software_write_fire)software_msip<=wdata_q[0];',
                "if(software_write_fire || (endpoint_fire && !write_q && software_hit))software_msip<=write_q?wdata_q[0]:1'b0;",
                'post-edge machine state and write timing'),
    ]


def guards():
    boolean_tokens=['CPU5 machine router device parameters must be boolean','CPU5 machine device enables must be boolean',
                    'cpu5_top requires external I, 64-bit age and a supported scaffold/ALU-subset mode']
    return [dict(name=name,kind='parameter_guard',top='cpu5_machine_control_guard_tb',generic=f'-gKIND={kind}',
                 expected_assertion=boolean_tokens if kind<2 else [boolean_tokens[-1]])
            for kind,name in enumerate(('timer_device_non_boolean','software_device_non_boolean','device_without_mmio'))]


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--only',action='append');ap.add_argument('--list',action='store_true');a=ap.parse_args()
    all_specs=specimens()+guards()
    if a.list:print('\n'.join(s['name'] for s in all_specs));return
    assert not a.only or set(a.only)<={s['name'] for s in all_specs}
    specs=[s for s in all_specs if not a.only or s['name'] in a.only]
    originals={p:(ROOT/p).read_bytes() for p in SOURCES};before={p:sha(ROOT/p) for p in SOURCES}
    run_id=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8];run=OUT/'runs'/run_id;run.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=run_id,source_sha256=before),indent=2)+'\n',encoding='utf-8')
    positive=verify_one(a.vsim,run/'good_reference',None,originals);records=[];failures=[]
    for spec in specs:
        try:records.append(verify_one(a.vsim,run/spec['name'],spec,originals))
        except AssertionError as error:failures.append(dict(name=spec['name'],error=str(error)));print(spec['name'],'FAILED CHECK',flush=True)
    if failures:(run/'failures.json').write_text(json.dumps(failures,indent=2)+'\n',encoding='utf-8')
    assert not failures,failures
    assert before=={p:sha(ROOT/p) for p in SOURCES},'mutation suite changed good inputs'
    result=dict(status='PARTIAL' if a.only else 'PASS',run_id=run_id,source_sha256=before,good_sources_unchanged=True,
                good_reference=positive,specimens=records,rtl_semantic_rejected=sum(s['kind']=='rtl_semantic' for s in records),
                parameter_guards_rejected=sum(s['kind']=='parameter_guard' for s in records),compile_zero_warning_error=True)
    rendered=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','rtl_semantic_rejected','parameter_guards_rejected','good_sources_unchanged')}))


if __name__=='__main__':main()
