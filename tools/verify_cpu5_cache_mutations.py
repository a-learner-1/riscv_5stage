"""Clean-compile real private cache adapter/legacy-cache semantic mutations."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import uuid
from run_cpu5_cache_adapter import ROOT, SOURCES as ADAPTER_SOURCES, sha, verify_one

OUT=ROOT/'build/cpu5_s13_cache_mutations'
SOURCES=ADAPTER_SOURCES+['tools/verify_cpu5_cache_mutations.py']
ADAPTER='rtl/cpu5_cache_adapter.v'


def mutant(name,old,new,token,path=ADAPTER):
    return dict(name=name,kind='rtl_semantic',changed_file=path,old=old,new=new,expected_assertion=token)


def specimens():
    instruction=['Cache data/error','CPU5 pair I architectural data/error']
    data=['Data cache ','CPU5 pair D architectural data/error']
    return [
        mutant('cached_i_address_wrong_word','.req_addr(cpu_imem_req_addr)','.req_addr(cpu_imem_req_addr ^ 32\'d4)',instruction),
        mutant('cached_i_backend_data_corrupt','.mem_rsp_rdata(mem_imem_rsp_rdata)','.mem_rsp_rdata(mem_imem_rsp_rdata ^ 32\'d1)',instruction),
        mutant('cached_i_error_swallowed','.mem_rsp_error(mem_imem_rsp_error)',".mem_rsp_error(1'b0)",instruction),
        mutant('cached_d_address_wrong_word','.req_addr(cpu_dmem_req_addr)','.req_addr(cpu_dmem_req_addr ^ 32\'d4)',data),
        mutant('cached_d_write_becomes_read','.req_write(cpu_dmem_req_write)',".req_write(1'b0)",data),
        mutant('cached_d_size_fixed_word','.req_size(cpu_dmem_req_size)',".req_size(2'd2)",data),
        mutant('cached_d_write_data_corrupt','.req_wdata(cpu_dmem_req_wdata)','.req_wdata(cpu_dmem_req_wdata ^ 32\'d1)',data),
        mutant('cached_d_write_strobes_lost','.req_wstrb(cpu_dmem_req_wstrb)',".req_wstrb(4'd0)",data),
        mutant('cached_d_error_swallowed','.mem_rsp_error(mem_dmem_rsp_error)',".mem_rsp_error(1'b0)",data),
        mutant('bypass_i_error_swallowed','assign cpu_imem_rsp_error=mem_imem_rsp_error;',"assign cpu_imem_rsp_error=1'b0;",'CPU5 pair I architectural data/error'),
        mutant('bypass_d_wide_strobes','assign mem_dmem_req_wstrb=cpu_dmem_req_wstrb;',"assign mem_dmem_req_wstrb=4'b1111;",'CPU5 pair D architectural data/error'),
        mutant('ignore_i_disable_switch','generate if(ENABLE_ICACHE)begin:g_icache',"generate if(1'b1)begin:g_icache",'CPU5 disabled I counters nonzero'),
        mutant('bypass_d_error_swallowed','assign cpu_dmem_rsp_error=mem_dmem_rsp_error;',"assign cpu_dmem_rsp_error=1'b0;",'CPU5 pair D architectural data/error'),
        mutant('bypass_i_wrong_word','assign mem_imem_req_addr=cpu_imem_req_addr;','assign mem_imem_req_addr=cpu_imem_req_addr ^ 32\'d4;','CPU5 pair I architectural data/error'),
        # These modify private copies of unchanged legacy modules. The product
        # Cache sources are retained exactly; the mutations prove that the
        # integrated model exercises replacement/error/write semantics too.
        mutant('legacy_d_failed_write_keeps_stale_line','if(state==OUT_REQ && write_hit_q) begin',"if(1'b0) begin",data,path='rtl/data_cache.v'),
        mutant('legacy_d_write_miss_allocates','write_hit_q<=request_ok && in_range && req_write && (hit0||hit1);','write_hit_q<=request_ok && in_range && req_write;',data,path='rtl/data_cache.v'),
        mutant('legacy_d_installs_partial_line','if(fill_word==LINE_WORDS-1) begin','if(fill_word==LINE_WORDS-2) begin',data,path='rtl/data_cache.v'),
        mutant('legacy_i_lru_always_way_zero','assign recent_victim=lru_pending && lru_set==lookup_set ? lru_value : victim_lru[lookup_set];',"assign recent_victim=1'b0;",'Cache refill/LRU',path='rtl/instr_cache.v'),
    ]


def guards():
    return [dict(name='adapter_non_boolean',kind='parameter_guard',top='cpu5_cache_guard_adapter_tb',
                 expected_assertion='CPU5 cache adapter requires boolean cache enables'),
            dict(name='cached_top_dcache_without_ram',kind='parameter_guard',top='cpu5_cache_guard_top_tb',
                 expected_assertion='CPU5 cached top requires active CPU and RAM for D cache')]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
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
