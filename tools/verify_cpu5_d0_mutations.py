"""Reject private CPU5 D0 wiring, router and real RAM mutations after clean compilation."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import uuid
from run_cpu5_d0_backend import ROOT, SOURCES as BACKEND_SOURCES, sha, verify_one

OUT=ROOT/'build/cpu5_s15_d0_mutations'
SOURCES=BACKEND_SOURCES
BACKEND='rtl/cpu5_d0_backend.v'
ROUTER='rtl/dmem_region_router.v'
RAM='rtl/soc_data_mem.v'
ARCH='D0 backend architectural data/error'


def mutant(name,old,new,token,path=BACKEND,top='cpu5_d0_backend_tb'):
    return dict(name=name,kind='rtl_semantic',changed_file=path,old=old,new=new,expected_assertion=token,top=top)


def specimens():
    return [
        mutant('d0_normal_range_bypassed','generate if(ENABLE_D0_BRAM)begin:g_d0',
               "generate if(ENABLE_D0_BRAM && DMEM_BASE_ADDR==32'hfffffff0)begin:g_d0",'D0 backend request wait parameter not propagated'),
        mutant('ram_request_address_corrupted','.req_addr(ram_req_addr),',
               ".req_addr(ram_req_addr ^ 32'd1),",ARCH),
        mutant('ram_request_data_corrupted','.req_wdata(ram_req_wdata),',
               ".req_wdata(ram_req_wdata ^ 32'd1),",ARCH),
        mutant('ram_request_strobes_shifted','.req_wstrb(ram_req_wstrb),',
               ".req_wstrb({ram_req_wstrb[2:0],1'b0}),",ARCH),
        mutant('ram_request_size_corrupted','.req_size(ram_req_size),',
               ".req_size(2'd3),",ARCH),
        mutant('ram_response_data_corrupted','.m0_rsp_rdata(ram_rsp_rdata),',
               ".m0_rsp_rdata(ram_rsp_rdata ^ 32'd1),",ARCH),
        mutant('ram_response_errors_swallowed','.m0_rsp_error(ram_rsp_error),',
               ".m0_rsp_error(1'b0),",ARCH),
        mutant('axi_request_address_corrupted','.req_addr(axi_req_addr),',
               ".req_addr(axi_req_addr ^ 32'd4),",'D0 backend AXI AW route/descriptor mismatch'),
        mutant('axi_request_data_corrupted','.req_wdata(axi_req_wdata),',
               ".req_wdata(axi_req_wdata ^ 32'd1),",'D0 backend AXI W route/descriptor mismatch'),
        mutant('disabled_bypass_strobes_corrupted','assign axi_req_wstrb=req_wstrb;',
               "assign axi_req_wstrb={req_wstrb[2:0],1'b0};",ARCH),
        mutant('disabled_bypass_response_corrupted','assign rsp_rdata=axi_rsp_rdata;',
               "assign rsp_rdata=axi_rsp_rdata ^ 32'd1;",ARCH),
        mutant('d0_request_wait_ignored','.REQ_WAIT_CYCLES(D0_REQ_WAIT_CYCLES),',
               '.REQ_WAIT_CYCLES(0),','D0 backend request wait parameter not propagated'),
        mutant('d0_response_wait_ignored','.RSP_WAIT_CYCLES(D0_RSP_WAIT_CYCLES)) u_ram(',
               '.RSP_WAIT_CYCLES(0)) u_ram(','D0 backend response wait parameter not propagated'),
        mutant('router_response_uses_live_address',
               "assign rsp_rdata = active ? (target_q ? m1_rsp_rdata : m0_rsp_rdata) : 32'd0;",
               "assign rsp_rdata = active ? (!select_m0 ? m1_rsp_rdata : m0_rsp_rdata) : 32'd0;",ARCH,path=ROUTER),
        mutant('router_range_includes_end','({32\'d0, req_addr} < M0_END_ADDR);',
               '({32\'d0, req_addr} <= M0_END_ADDR);','D0 backend expected AXI route was lost',path=ROUTER),
        mutant('router_upper_endpoint_truncated','localparam [63:0] M0_END_ADDR =',
               'localparam [31:0] M0_END_ADDR =','D0 backend request wait parameter not propagated',path=ROUTER),
        mutant('router_consumes_unselected_response','assign m1_rsp_ready = rst_n && active && target_q && rsp_ready;',
               'assign m1_rsp_ready = rst_n && active && rsp_ready;','D0 router consumed an unselected response',path=ROUTER,top='d0_native_backend_tb'),
        mutant('router_response_edge_ready',
               'assign req_ready = rst_n && !active &&',
               'assign req_ready = rst_n && (!active || (rsp_valid && rsp_ready)) &&',
               'D0 backend response-edge turnover forbidden',path=ROUTER),
        mutant('ram_write_uses_valid_without_accept',
               'wire mem_we = rst_n && req_fire && req_write && request_ok;',
               'wire mem_we = rst_n && req_valid && req_write && request_ok;',
               'D0 RAM physical write authorization mismatch',path=RAM),
        mutant('ram_invalid_strobe_allowed',
               '(!req_write || req_wstrb == expected_wstrb);',"1'b1;",
               'D0 RAM physical write authorization mismatch',path=RAM),
        mutant('ram_invalid_read_leaks_old_data',
               "assign rsp_rdata = rsp_error ? 32'd0 : adapter_rdata;",
               'assign rsp_rdata = adapter_rdata;',ARCH,path=RAM),
    ]


def guards():
    return [
        dict(name='d0_backend_rejects_nonboolean_enable',kind='parameter_guard',top='cpu5_d0_backend_guard_tb',
             expected_assertion='CPU5 D0 backend requires boolean D0 enable'),
        dict(name='d0_top_requires_active_ram',kind='parameter_guard',top='cpu5_d0_top_guard_tb',
             expected_assertion='CPU5 D0 top requires external data and active RAM CPU when D0 is enabled'),
    ]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--only',action='append');ap.add_argument('--list',action='store_true');a=ap.parse_args()
    all_specs=specimens()+guards()
    if a.list:print('\n'.join(s['name'] for s in all_specs));return
    assert not a.only or set(a.only)<={s['name'] for s in all_specs}
    specs=[s for s in all_specs if not a.only or s['name'] in a.only]
    originals={p:(ROOT/p).read_bytes() for p in SOURCES};before={p:sha(ROOT/p) for p in SOURCES}
    run_id=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8]
    run=OUT/'runs'/run_id;run.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=run_id,source_sha256=before),indent=2)+'\n',encoding='utf-8')
    # The positive snapshot is reusable only when the complete tested source set
    # and every retained result artifact still have their recorded identities.
    reference=json.loads((ROOT/'build/cpu5_s15_d0_backend/good_reference.json').read_text())
    assert reference['status']=='PASS' and set(reference['source_sha256'])==set(BACKEND_SOURCES)
    assert all(sha(ROOT/p)==expected for p,expected in reference['source_sha256'].items())
    positive=reference['positive'];assert positive['status']=='PASS'
    positive_path=ROOT/positive['directory']
    assert all(sha(positive_path/p)==expected for p,expected in positive['source_sha256'].items())
    assert all(sha(positive_path/p)==expected for p,expected in positive['retained_artifact_sha256'].items())
    records=[];failures=[]
    for spec in specs:
        try:records.append(verify_one(a.vsim,run/spec['name'],spec,originals))
        except AssertionError as error:
            failures.append(dict(name=spec['name'],error=str(error)));print(spec['name'],'FAILED CHECK',flush=True)
    if failures:(run/'failures.json').write_text(json.dumps(failures,indent=2)+'\n',encoding='utf-8')
    assert not failures,failures
    assert before=={p:sha(ROOT/p) for p in SOURCES},'mutation suite changed good inputs'
    result=dict(status='PARTIAL' if a.only else 'PASS',run_id=run_id,source_sha256=before,good_sources_unchanged=True,
        good_reference=positive,good_reference_reused=True,specimens=records,
        rtl_semantic_rejected=sum(s['kind']=='rtl_semantic' for s in records),
        parameter_guards_rejected=sum(s['kind']=='parameter_guard' for s in records),compile_zero_warning_error=True)
    rendered=json.dumps(result,indent=2)+'\n'
    (run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','rtl_semantic_rejected','parameter_guards_rejected','good_sources_unchanged')}))


if __name__=='__main__':main()
