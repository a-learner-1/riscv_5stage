"""Reject FENCE semantic mutations only after private clean compilation."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import uuid
from run_cpu5_fence_control import ROOT, SOURCES as CONTROL_SOURCES, sha, verify_one

OUT=ROOT/'build/cpu5_s12_fence_mutations'
SOURCES=CONTROL_SOURCES+['tools/verify_cpu5_fence_mutations.py']
CORE='rtl/cpu5_alu_pipeline.v';TOP='rtl/cpu5_top.v'


def mutant(name,old,new,token,path=CORE):
    return dict(name=name,kind='rtl_semantic',changed_file=path,old=old,new=new,
                expected_assertion=token)


def specimens():
    return [
        mutant('skip_owner_drain', "(!ram_owner_valid && exmem_q.result_ready)", 'exmem_q.result_ready', ['CPU5 FENCE retired before data drain', 'FENCE retired before pre-edge D owner drained']),
        mutant('retire_on_response_edge', "(!ram_owner_valid && exmem_q.result_ready)", '((!ram_owner_valid || ram_rsp_fire) && exmem_q.result_ready)', ['CPU5 FENCE retired before data drain', 'FENCE retired before pre-edge D owner drained']),
        mutant('skip_ex_barrier', 'wire ex_base_move=rst_n && idex_valid_q && !kill_ex && !trap_fire && !mret_fire && ex_enable && mem_can_load &&\n        !irq_take && !mem_fence_barrier &&', 'wire ex_base_move=rst_n && idex_valid_q && !kill_ex && !trap_fire && !mret_fire && ex_enable && mem_can_load &&\n        !irq_take &&', ['CPU5 FENCE leaked younger execution or issue', 'FENCE younger action crossed live MEM barrier']),
        mutant('skip_m_barrier', 'assign m_issue_valid=ENABLE_RV32M && rst_n && idex_valid_q && idex_q.is_m &&\n        !irq_take && !mem_fence_barrier &&', 'assign m_issue_valid=ENABLE_RV32M && rst_n && idex_valid_q && idex_q.is_m &&\n        !irq_take &&', ['CPU5 FENCE leaked younger execution or issue', 'FENCE younger action crossed live MEM barrier']),
        mutant('allow_retirement_edge_turnover', '&& exmem_q.fence_op && !kill_mem;', '&& exmem_q.fence_op && !kill_mem && !retire_fire;', ['CPU5 FENCE leaked younger execution or issue', 'FENCE younger action crossed live MEM barrier']),
        mutant('wait_killed_m_owner', '(!ram_owner_valid && exmem_q.result_ready)', '(!ram_owner_valid && !m_owner_valid && exmem_q.result_ready)', 'FENCE unnecessarily waited killed DIV'),
        mutant('lose_idex_fence', 'idex_next.is_fence=id_fence;', "idex_next.is_fence=1'b0;", ['FENCE retirement payload', 'FENCE younger action crossed live MEM barrier', 'FENCE retire timeout']),
        mutant('lose_mem_fence', 'exmem_next.fence_op=idex_q.is_fence;', "exmem_next.fence_op=1'b0;", ['FENCE younger action crossed live MEM barrier', 'FENCE retired before pre-edge D owner drained']),
        mutant('decode_reserved_rs1', "assign rs1=id_fence?5'd0:", 'assign rs1=id_fence?in_instr[19:15]:', 'CPU5 FENCE reserved fields created operands'),
        mutant('decode_reserved_rd', "assign rd=id_fence?5'd0:", 'assign rd=id_fence?in_instr[11:7]:', 'CPU5 FENCE reserved fields created operands'),
        mutant('decode_reserved_uses', "id_fence?3'b000:", "id_fence?3'b110:", ['CPU5 FENCE reserved fields created operands', 'FENCE reserved operands caused RAW wait', 'FENCE reserved operand metadata']),
        mutant('decode_fence_write', "id_fence?3'b000:", "id_fence?3'b001:", 'CPU5 FENCE reserved fields created operands'),
        mutant('no_id_mode_ex_prediction_repair', '|| idex_q.is_csr || idex_q.is_fence) &&', '|| idex_q.is_csr) &&', 'FENCE stale BTB prediction was not repaired'),
        mutant('repair_fence_in_id', '!id_csr && !id_mret && !id_fence &&', '!id_csr && !id_mret &&', 'FENCE stale BTB correction/EX ownership'),
        mutant('wrong_fence_arch_next_pc', 'exmem_next.link_pc4=idex_q.pc+32\'d4;exmem_next.actual_next_pc=ex_actual_next;', 'exmem_next.link_pc4=idex_q.pc+32\'d4;exmem_next.actual_next_pc=idex_q.is_fence?idex_q.pc+32\'d8:ex_actual_next;', 'FENCE instret/arch-next-PC'),
    ]


def guards():
    return [dict(name='core_fence_non_boolean',kind='parameter_guard',top='cpu5_fence_control_guard_core_tb',
                 expected_assertion='CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode'),
            dict(name='top_fence_skeleton',kind='parameter_guard',top='cpu5_fence_control_guard_top_tb',
                 expected_assertion='cpu5_top requires external I, 64-bit age and a supported scaffold/ALU-subset mode')]


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
