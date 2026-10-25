"""Verify CPU5 Cache-to-AXI4-Lite integration and same-source compatibility."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_cache import SOURCES as CACHE_SOURCES, same_sources, read, sha, positive_gate, negative_gate
from run_cpu5_axi_bridge import SOURCES as BRIDGE_SOURCES
from run_cpu5_axi_control import SOURCES as CONTROL_SOURCES
from run_cpu5_axi_program import SOURCES as PROGRAM_SOURCES
from verify_cpu5_axi_mutations import SOURCES as MUTATION_SOURCES

ROOT=Path(__file__).resolve().parents[1]
BASE='88466d9764bd5c36265439720e28bebfd7c684c2'
OUT=ROOT/'build/cpu5_s14_verification'
STATUS='PARTIAL VERIFIED: CPU5 AXI4-Lite data master'
AXI_NEW_FILES=[
    'rtl/cpu5_axi_lite_top.v',
    'tb/cpu5_axi_bridge_tb.v','tb/cpu5_axi_control_tb.v','tb/cpu5_axi_program_tb.v',
    'run_cpu5_axi_bridge.do','run_cpu5_axi_control.do','run_cpu5_axi_program.do',
    'tools/run_cpu5_axi_bridge.py','tools/run_cpu5_axi_control.py','tools/run_cpu5_axi_program.py',
    'tools/cpu5_axi_reference.py','tools/verify_cpu5_axi_mutations.py',
    'tools/verify_cpu5_axi.py','tools/freeze_cpu5_axi.py','docs/cpu5_axi_contract_20261024.md',
]
SOURCES=sorted(set(CACHE_SOURCES+BRIDGE_SOURCES+CONTROL_SOURCES+PROGRAM_SOURCES+MUTATION_SOURCES+AXI_NEW_FILES))


def bridge_gate(bridge):
    positive_gate(bridge)
    assert bridge['configurations']==6 and bridge['checks']==216
    assert bridge['front_requests']==bridge['front_responses']+bridge['front_reset_drops']==222
    assert bridge['front_reset_drops']==6
    assert bridge['backend_requests']==bridge['backend_responses']+bridge['backend_reset_drops']==372
    assert bridge['backend_reset_drops']==6 and bridge['ar']==bridge['r']+bridge['axi_read_reset_drops']==327
    assert bridge['aw']==bridge['w']==bridge['b']==bridge['physical_writes']==36
    assert bridge['errors']==60 and bridge['invalid']==18 and bridge['side_reads']==12
    assert bridge['early_b_hold']==bridge['early_r_hold']==0
    assert bridge['aw_stalls']==bridge['w_stalls']==120 and bridge['ar_stalls']==981 and bridge['cpu_rsp_stalls']==1080
    legacy=bridge['legacy_bridge']
    assert legacy['cpu_requests']==legacy['cpu_responses']+legacy['abandoned_requests']==36
    assert legacy['cpu_responses']==30 and legacy['cpu_errors']==13 and legacy['invalid_cases']==9
    assert legacy['aw_count']==legacy['w_count']==12 and legacy['b_count']==10
    assert legacy['ar_count']==13 and legacy['r_count']==12 and legacy['paired_writes']==11
    assert legacy['order_aw_first']>0 and legacy['order_w_first']>0 and legacy['order_same']>0
    ram=bridge['legacy_ram']
    assert ram==dict(aw_count=28,w_count=28,b_count=26,ar_count=11,r_count=10,
                     ram_write_edges=24,ram_read_edges=8,contention_blocks=1)


def control_gate(control):
    positive_gate(control)
    assert control['cases']==136 and control['retired']==control['wb']==528
    assert control['fences']==control['retire_barriers']==84 and control['sync_traps']==50 and control['irqs']==4
    assert control['requests']==control['responses']+control['reset_abandoned_requests']==120
    assert control['responses']==98 and control['reset_abandoned_requests']==22
    assert control['fence_wait_edges']==412 and control['fence_barrier_edges']==556 and control['committed_state_checks']==9542
    b=control['backend_summary'];a=control['axi_summary'];f=control['frontend_summary']
    assert b['requests']==b['responses']+b['reset_abandoned']==258 and b['responses']==236 and b['reset_abandoned']==22
    assert b['writes']==30 and b['live_refill_errors']==b['killed_refill_errors']==24
    assert a['native_requests']==a['native_responses']+a['native_reset_drops']==258
    assert a['physical_writes']==a['b']+a['reset_paired']==26
    assert a['aw']==a['physical_writes']+a['reset_aw_only']==28
    assert a['w']==a['physical_writes']+a['reset_w_only']==28
    assert a['ar']==a['r']+a['reset_read']==218
    assert a['b']+a['r']==a['native_responses']+a['reset_captured']==240
    assert a['reset_aw_only']==a['reset_w_only']==a['reset_paired']==a['reset_read']==2 and a['reset_captured']==4
    assert a['cpu_rsp_held']==0 and a['irq_store_wait']==12
    assert (a['rresp1'],a['rresp2'],a['rresp3'])==(16,22,16)
    assert (a['bresp1'],a['bresp2'],a['bresp3'])==(2,4,2)
    assert (a['aw_first'],a['w_first'],a['together'])==(6,8,10)
    assert (a['aw_held'],a['w_held'],a['ar_held'])==(98,106,706)
    assert f['cases']==8 and f['packets']==26 and f['fault_packets']==2 and f['stale_errors']==4
    assert f['requests']==f['responses']+f['reset_drops']==48 and f['backend_requests']==f['backend_responses']==60
    assert f['checks']==200


def program_gate(program):
    assert program['case_count']==192 and len(program['cases'])==192
    assert program['total_retired']==program['total_wb_packets']==36771 and program['total_drain_tail_retired']==99
    assert program['total_workload_retired']==191*192 and program['total_terminal_retired']==192
    assert program['total_irqs']==768 and program['total_sync_traps']==192 and program['total_fence_retired']==4416
    assert program['total_d_requests']==program['total_d_responses']==12288
    assert program['total_cache_front_d_requests']==program['total_cache_front_d_responses']==7872
    assert program['total_cache_backend_d_requests']==program['total_cache_backend_d_responses']==9792
    assert program['total_cache_d_hits']==384 and program['total_cache_d_misses']==768 and program['total_cache_d_refills']==3072
    assert program['total_cache_ram_writes']==5568 and program['total_cache_counter_checks']==2304
    assert program['total_requests']==program['total_responses']==46125
    assert program['total_cache_front_i_requests']==program['total_cache_front_i_responses']+program['total_cache_front_i_reset_canceled']==42456
    assert program['total_cache_front_i_reset_canceled']==96 and program['total_cache_backend_held_reset']==192
    assert program['total_cache_i_hits']==14856 and program['total_cache_i_misses']==6288 and program['total_cache_i_refills']==24813
    assert program['total_axi_native_requests']==program['total_axi_native_responses']==9792
    assert program['total_axi_aw']==program['total_axi_w']==program['total_axi_b']==program['total_axi_commits']==5568
    assert program['total_axi_ar']==program['total_axi_r']==4224
    assert program['total_axi_same']==program['total_axi_aw_first']==program['total_axi_w_first']==1856
    assert program['total_axi_aw_stalls']==program['total_axi_w_stalls']==5568 and program['total_axi_ar_stalls']==6336
    assert program['total_axi_b_held']==program['total_axi_r_held']==0
    assert program['total_axi_edge_checks']==program['total_cycle_checks']==240357
    assert program['total_ordered_successor_pairs']==1536
    assert program['decoder_selftest']['fixed_word_checks']==37 and program['decoder_selftest']['device_state_checks']==5
    assert program['negative_evidence_tests']['rejected_count']==29 and program['negative_evidence_tests']['good_inputs_unchanged']
    assert len(program['simulation_batches'])==12 and program['simulation_case_passes']==192
    assert sha(ROOT/'build/cpu5_s14_axi_program/console.log')==program['simulation_console_sha256']
    for path,expected in program['input_vector_sha256'].items():
        assert sha(ROOT/'build/cpu5_s14_axi_program'/path)==expected
    for batch in program['simulation_batches']:
        assert batch['status']=='PASS' and batch['simulation_exit_code']==batch['warnings']==batch['errors']==0
        assert sha(ROOT/batch['waveform'])==batch['waveform_sha256']
    staged=Path(program['private_simulator_cwd'])
    assert staged.resolve().is_relative_to(ROOT.resolve()/'build')
    for path,expected in program['source_sha256'].items(): assert sha(staged/path)==expected
    for case in program['cases']:
        assert case['workload_retired']==191 and case['terminal_retired']==1 and case['drain_tail_retired']<=2
        assert case['defined_gpr']==31 and case['unchanged_unknown_gpr']==1
        assert case['axi_native_requests']==case['axi_native_responses']==case['axi_commits']+case['axi_ar']
        assert case['axi_aw']==case['axi_w']==case['axi_b']==case['axi_commits']==29
        assert case['axi_ar']==case['axi_r'] and case['axi_b_held']==case['axi_r_held']==0
        assert case['axi_same']+case['axi_aw_first']+case['axi_w_first']==29
        if case['icache']: assert case['cache_i_hits']>0 and case['cache_i_misses']>0
        else: assert case['cache_i_hits']==case['cache_i_misses']==case['cache_i_refills']==0
        if case['dcache']: assert case['cache_d_hits']>0 and case['cache_d_misses']>0
        else: assert case['cache_d_hits']==case['cache_d_misses']==case['cache_d_refills']==0
    assert {(c['id_mode'],c['predict'],c['wait'],c['forwarding'],c['icache'],c['dcache'],c['axi_mode']) for c in program['cases']}=={(i,j,k,l,m,n,o) for i in (0,1) for j in (0,1) for k in (0,1) for l in (0,1) for m in (0,1) for n in (0,1) for o in (0,1,2)}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference',action='store_true',help='reuse only complete Cache compatibility on every tested-source SHA match')
    ap.add_argument('--reuse-suites',action='store_true',help='reuse only complete AXI suites on every tested-source SHA match')
    a=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    before={path:sha(ROOT/path) for path in SOURCES}
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',source_sha256=before),indent=2)+'\n',encoding='utf-8')
    processes=[]
    def execute(name,script,path,reuse):
        if reuse:
            rec=read(ROOT/path);same_sources(rec)
            assert rec['status']==('PARTIAL VERIFIED: CPU5 native I/D Cache integration' if name=='reference' else 'PASS')
            processes.append(dict(name=name,status='PASS',exit_code=0,reused=True,source_sha_checks=len(rec['source_sha256'])))
        else:
            command=[sys.executable,'-B',script,'--vsim',str(a.vsim)]
            p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=5400)
            output=p.stdout+p.stderr;(OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
            assert p.returncode==0 and 'Traceback (most recent call last)' not in output,(name,output[-9000:])
            processes.append(dict(name=name,status='PASS',exit_code=0,reused=False,command=command))
        rec=read(ROOT/path);same_sources(rec);print(name,'PASS',flush=True);return rec
    reference=execute('reference','tools/verify_cpu5_cache.py','build/cpu5_s13_verification/verification.json',a.reuse_reference)
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in reference['processes'])
    scripts=dict(bridge='tools/run_cpu5_axi_bridge.py',control='tools/run_cpu5_axi_control.py',
                 program='tools/run_cpu5_axi_program.py',mutations='tools/verify_cpu5_axi_mutations.py')
    suites={name:execute(name,script,f'build/cpu5_s14_axi_{name}/verification.json',a.reuse_suites) for name,script in scripts.items()}
    bridge,control,program,mutations=(suites[k] for k in scripts)
    bridge_gate(bridge);control_gate(control);program_gate(program)
    semantics=mutations['rtl_semantic_rejected'];guards=mutations['parameter_guards_rejected']
    assert semantics==18 and guards==1
    negative_gate(mutations,semantics,guards)
    old_rtl=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'rtl'],cwd=ROOT).decode().splitlines()
    for path in old_rtl:
        assert subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT)==(ROOT/path).read_bytes().replace(b'\r\n',b'\n'),path
    recovery=None
    resume_path=ROOT/'build/cpu5_s14_compatibility_resume/verification.json'
    if resume_path.exists():
        resume=read(resume_path);same_sources(resume)
        assert resume['status']=='PASS' and resume['sources_unchanged']
        assert set(resume['source_sha256'])==set(CACHE_SOURCES)
        assert [p['name'] for p in resume['processes']]==['m','irq','mmio','machine','fence','cache']
        for process in resume['processes']:
            assert process['status']=='PASS' and process['exit_code']==0
            assert sha(resume_path.parent/(process['name']+'_console.log'))==process['console_sha256']
        recovery=dict(record=resume_path.relative_to(ROOT).as_posix(),record_sha256=sha(resume_path),
                      procedure_sha256=sha(resume_path.parent/'resume_procedure.py'),
                      prior_disk_full_console_sha256=sha(resume_path.parent/'prior_disk_full_console.log'),
                      reused_complete_stage='S1-S7 completed in this S14 workspace before disk-full failure; exact dependency SHA gate',
                      fresh_resumed_stages=[p['name'] for p in resume['processes']])
    assert before=={path:sha(ROOT/path) for path in SOURCES},'verification changed source'
    result=dict(status=STATUS,base_commit=BASE,source_sha256=before,sources_unchanged=True,processes=processes,suites=suites,
                compatibility_reference='build/cpu5_s13_verification/verification.json',legacy_rtl_unchanged=old_rtl,
                compatibility_recovery=recovery,
                rtl_mutations_rejected=semantics,parameter_guards_rejected=guards,
                AXI='SINGLE OUTSTANDING AXI4-LITE DATA MASTER; NATIVE INSTRUCTION BACKEND',FENCE_I='UNSUPPORTED',
                D0_Stats_fabric_SoC='NOT INTEGRATED',full_A01_A16='NOT RUN',STA='NOT RUN',board='NOT RUN',performance_claim='NONE')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status=STATUS,sources=len(before),rtl_mutations_rejected=semantics,parameter_guards_rejected=guards)))


if __name__=='__main__':main()
