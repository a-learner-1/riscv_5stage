"""Reject real private AXI manager mutations only after clean independent compilation."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import uuid
from run_cpu5_axi_bridge import ROOT, SOURCES as BRIDGE_SOURCES, sha, verify_one

OUT=ROOT/'build/cpu5_s14_axi_mutations'
SOURCES=BRIDGE_SOURCES+['tools/verify_cpu5_axi_mutations.py']
BRIDGE='rtl/dmem_axi_lite_bridge.v'


def mutant(name,old,new,token,path=BRIDGE,top='axi_lite_bridge_tb'):
    return dict(name=name,kind='rtl_semantic',changed_file=path,old=old,new=new,expected_assertion=token,top=top)


def specimens():
    return [
        mutant('aw_valid_waits_for_ready','assign m_axi_awvalid = rst_n && (state == SEND_WRITE) && !aw_done;',
               'assign m_axi_awvalid = rst_n && (state == SEND_WRITE) && !aw_done && m_axi_awready;','Write VALID depends on READY'),
        mutant('w_valid_waits_for_ready','assign m_axi_wvalid = rst_n && (state == SEND_WRITE) && !w_done;',
               'assign m_axi_wvalid = rst_n && (state == SEND_WRITE) && !w_done && m_axi_wready;','Write VALID depends on READY'),
        mutant('ar_valid_waits_for_ready','assign m_axi_arvalid = rst_n && (state == SEND_READ);',
               'assign m_axi_arvalid = rst_n && (state == SEND_READ) && m_axi_arready;','Read VALID depends on READY'),
        mutant('aw_sent_flag_ignored','&& !aw_done;',"&& 1'b1;",['AW-first sequencing','Duplicate/overlapping AW acceptance']),
        mutant('w_sent_flag_ignored','&& !w_done;',"&& 1'b1;",['W-first sequencing','Duplicate/overlapping W acceptance']),
        mutant('write_completes_after_one_half','(aw_done || aw_fire) && (w_done || w_fire)',
               '(aw_done || aw_fire) || (w_done || w_fire)','W VALID/payload changed under backpressure'),
        mutant('byte_address_not_aligned',"addr_q <= {req_addr[31:2], 2'b00};",'addr_q <= req_addr;','Invalid AXI AW payload'),
        mutant('write_data_corrupted','wdata_q <= req_wdata;',"wdata_q <= req_wdata ^ 32'd1;",'Bridge altered aligned address or pre-shifted write data/strobes'),
        mutant('write_strobes_shifted','wstrb_q <= req_wstrb;',"wstrb_q <= {req_wstrb[2:0],1'b0};",'Bridge altered aligned address or pre-shifted write data/strobes'),
        mutant('invalid_shape_sent_to_axi','if (!request_ok) begin',"if (1'b0) begin",'AXI bridge timeout CPU='),
        mutant('halfword_strobe_validated_as_byte',"(req_size == 2'd1) ? (4'b0011 << req_addr[1:0]) :", "(req_size == 2'd1) ? (4'b0001 << req_addr[1:0]) :",'Write VALID depends on READY'),
        mutant('exokay_write_treated_as_success',"case (m_axi_bresp)\n                            2'b00: rsp_error_q <= 1'b0;", "case (m_axi_bresp)\n                            2'b00,2'b01: rsp_error_q <= 1'b0;",'AXI Cache architectural data/error',top='cpu5_axi_bridge_tb'),
        mutant('exokay_read_treated_as_success',"case (m_axi_rresp)\n                            2'b00: begin", "case (m_axi_rresp)\n                            2'b00,2'b01: begin",'AXI Cache architectural data/error',top='cpu5_axi_bridge_tb'),
        mutant('write_errors_swallowed',"default: rsp_error_q <= 1'b1;", "default: rsp_error_q <= 1'b0;",'CPU response mismatch'),
        mutant('error_read_data_not_zeroed',"default: begin\n                                rsp_rdata_q <= 32'd0;\n                                rsp_error_q <= 1'b1;", "default: begin\n                                rsp_rdata_q <= m_axi_rdata;\n                                rsp_error_q <= 1'b1;",'CPU response mismatch'),
        mutant('cpu_response_not_held','if (rsp_ready)\n                        state <= IDLE;',"if (1'b1)\n                        state <= IDLE;",'CPU response not retained during backpressure'),
        mutant('accepts_native_while_busy','assign req_ready = rst_n && (state == IDLE);','assign req_ready = rst_n;','CPU response not retained during backpressure'),
        mutant('reset_replays_cpu_response','if (!rst_n) begin\n            state <= IDLE;', 'if (!rst_n) begin\n            state <= CPU_RSP;','Bridge did not return to idle after reset'),
    ]


def guards():
    return [dict(name='axi_top_requires_external_dmem',kind='parameter_guard',top='cpu5_axi_bridge_guard_tb',
                 expected_assertion='CPU5 AXI-Lite top requires external data interface')]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--only',action='append');ap.add_argument('--list',action='store_true');a=ap.parse_args()
    all_specs=specimens()+guards()
    if a.list: print('\n'.join(s['name'] for s in all_specs));return
    assert not a.only or set(a.only)<={s['name'] for s in all_specs}
    specs=[s for s in all_specs if not a.only or s['name'] in a.only]
    originals={p:(ROOT/p).read_bytes() for p in SOURCES};before={p:sha(ROOT/p) for p in SOURCES}
    run_id=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8];run=OUT/'runs'/run_id;run.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=run_id,source_sha256=before),indent=2)+'\n',encoding='utf-8')
    # Reuse the just-completed good reference only when its complete tested
    # source set still matches. Private good snapshot/artifacts are retained.
    reference=json.loads((ROOT/'build/cpu5_s14_axi_bridge/verification.json').read_text())
    assert reference['status']=='PASS' and set(reference['source_sha256'])==set(BRIDGE_SOURCES)
    assert all(sha(ROOT/p)==expected for p,expected in reference['source_sha256'].items())
    positive=reference['positive'];assert positive['status']=='PASS'
    records=[];failures=[]
    for spec in specs:
        try: records.append(verify_one(a.vsim,run/spec['name'],spec,originals))
        except AssertionError as error: failures.append(dict(name=spec['name'],error=str(error)));print(spec['name'],'FAILED CHECK',flush=True)
    if failures:(run/'failures.json').write_text(json.dumps(failures,indent=2)+'\n',encoding='utf-8')
    assert not failures,failures
    assert before=={p:sha(ROOT/p) for p in SOURCES},'mutation suite changed good inputs'
    result=dict(status='PARTIAL' if a.only else 'PASS',run_id=run_id,source_sha256=before,good_sources_unchanged=True,
                good_reference=positive,good_reference_reused=True,specimens=records,
                rtl_semantic_rejected=sum(s['kind']=='rtl_semantic' for s in records),
                parameter_guards_rejected=sum(s['kind']=='parameter_guard' for s in records),compile_zero_warning_error=True)
    rendered=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','rtl_semantic_rejected','parameter_guards_rejected','good_sources_unchanged')}))


if __name__=='__main__':main()
