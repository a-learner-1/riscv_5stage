"""Verify isolated CPU5 native I/D Cache integration and all earlier CPU5 stages."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_fence import SOURCES as FENCE_SOURCES, same_sources, read, sha, negative_gate
from run_cpu5_cache_adapter import SOURCES as ADAPTER_SOURCES
from run_cpu5_cache_control import SOURCES as CONTROL_SOURCES
from run_cpu5_cache_program import SOURCES as PROGRAM_SOURCES
from verify_cpu5_cache_mutations import SOURCES as MUTATION_SOURCES

ROOT=Path(__file__).resolve().parents[1]
BASE='40f92eb6b5da71898f824425a880e7b172c3b85a'
OUT=ROOT/'build/cpu5_s13_verification'
STATUS='PARTIAL VERIFIED: CPU5 native I/D Cache integration'
CACHE_NEW_FILES=[
    'rtl/cpu5_cache_adapter.v','rtl/cpu5_cached_top.v',
    'tb/cpu5_cache_adapter_tb.v','tb/cpu5_cache_control_tb.v','tb/cpu5_cache_program_tb.v',
    'run_cpu5_cache_adapter.do','run_cpu5_cache_control.do','run_cpu5_cache_program.do',
    'tools/run_cpu5_cache_adapter.py','tools/run_cpu5_cache_control.py','tools/run_cpu5_cache_program.py',
    'tools/cpu5_cache_reference.py','tools/verify_cpu5_cache_mutations.py',
    'tools/verify_cpu5_cache.py','tools/freeze_cpu5_cache.py','docs/cpu5_cache_contract_20261024.md',
]
SOURCES=sorted(set(FENCE_SOURCES+ADAPTER_SOURCES+CONTROL_SOURCES+PROGRAM_SOURCES+MUTATION_SOURCES+CACHE_NEW_FILES))


def positive_gate(record):
    positive=record['positive']
    assert positive['status']=='PASS' and positive['simulation_exit_code']==0
    assert positive['compile']['exit_code']==positive['compile']['warnings']==positive['compile']['errors']==0
    directory=ROOT/positive['directory']
    assert directory.resolve().is_relative_to(ROOT.resolve()/'build')
    for path,expected in positive['source_sha256'].items(): assert sha(directory/path)==expected==sha(ROOT/path)
    for path,expected in positive['retained_artifact_sha256'].items(): assert sha(directory/path)==expected


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference',action='store_true',help='reuse only complete FENCE compatibility on every tested-source SHA match')
    ap.add_argument('--reuse-suites',action='store_true',help='reuse only complete Cache suites on every tested-source SHA match')
    a=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    before={path:sha(ROOT/path) for path in SOURCES}
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',source_sha256=before),indent=2)+'\n',encoding='utf-8')
    processes=[]
    def execute(name,script,path,reuse):
        if reuse:
            rec=read(ROOT/path);same_sources(rec)
            assert rec['status']==('PARTIAL VERIFIED: CPU5 base FENCE' if name=='reference' else 'PASS')
            processes.append(dict(name=name,status='PASS',exit_code=0,reused=True,source_sha_checks=len(rec['source_sha256'])))
        else:
            command=[sys.executable,'-B',script,'--vsim',str(a.vsim)]
            p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=3600)
            output=p.stdout+p.stderr;(OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
            assert p.returncode==0 and 'Traceback (most recent call last)' not in output,(name,output[-9000:])
            processes.append(dict(name=name,status='PASS',exit_code=0,reused=False,command=command))
        rec=read(ROOT/path);same_sources(rec);print(name,'PASS',flush=True);return rec
    reference=execute('reference','tools/verify_cpu5_fence.py','build/cpu5_s12_verification/verification.json',a.reuse_reference)
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in reference['processes'])
    scripts=dict(adapter='tools/run_cpu5_cache_adapter.py',control='tools/run_cpu5_cache_control.py',
                 program='tools/run_cpu5_cache_program.py',mutations='tools/verify_cpu5_cache_mutations.py')
    suites={name:execute(name,script,f'build/cpu5_s13_cache_{name}/verification.json',a.reuse_suites) for name,script in scripts.items()}
    adapter,control,program,mutations=(suites[k] for k in scripts)
    positive_gate(adapter);positive_gate(control)
    assert adapter['configurations']==12 and adapter['checks']==2160
    assert adapter['backend_requests']==adapter['backend_responses']+adapter['backend_reset_drops']==5514
    assert adapter['front_requests']==adapter['front_responses']+adapter['front_reset_drops']==2328
    assert adapter['backend_reset_drops']==8 and adapter['front_reset_drops']==24
    assert control['cases']==84 and control['retired']==control['wb']==312 and control['fences']==control['retire_barriers']==56
    assert control['requests']==control['responses']+control['reset_abandoned_requests']==56
    assert control['reset_abandoned_requests']==10 and control['sync_traps']==28 and control['irqs']==2
    backend=control['backend_summary']
    assert backend['requests']==backend['responses']+backend['reset_abandoned']==110
    assert backend['live_refill_errors']==backend['killed_refill_errors']==8
    front=control['frontend_summary']
    assert front['cases']==8 and front['packets']==26 and front['fault_packets']==2 and front['stale_errors']==4
    assert front['requests']==front['responses']+front['reset_drops']==48 and front['reset_drops']==8
    assert front['backend_requests']==front['backend_responses']==60 and front['backend_reset_drops']==0
    assert front['checks']==200 and front['held_edges']==12
    assert program['case_count']==64 and program['total_retired']==program['total_wb_packets']==12258
    assert program['total_workload_retired']==191*64 and program['total_terminal_retired']==64 and program['total_drain_tail_retired']==34
    assert program['total_irqs']==256 and program['total_sync_traps']==64
    assert program['total_d_requests']==program['total_d_responses']==4096
    assert program['total_requests']==program['total_responses']==15362
    assert program['total_cache_front_i_requests']==program['total_cache_front_i_responses']+program['total_cache_front_i_reset_canceled']==14131
    assert program['total_cache_front_i_reset_canceled']==32 and program['total_cache_backend_held_reset']==64
    assert program['total_cache_front_d_requests']==program['total_cache_front_d_responses']==2624
    assert program['total_cache_backend_d_requests']==program['total_cache_backend_d_responses']==3264
    assert program['total_cache_i_hits']==4944 and program['total_cache_i_misses']==2096 and program['total_cache_i_refills']==8271
    assert program['total_cache_d_hits']==128 and program['total_cache_d_misses']==256 and program['total_cache_d_refills']==1024
    assert program['total_cache_ram_writes']==1856 and program['total_cache_counter_checks']==768
    assert program['total_ordered_successor_pairs']==512 and program['total_fence_retired']==1472
    assert program['decoder_selftest']['fixed_word_checks']==37 and program['decoder_selftest']['device_state_checks']==5
    assert program['negative_evidence_tests']['rejected_count']==23 and program['negative_evidence_tests']['good_inputs_unchanged']
    assert {(c['id_mode'],c['predict'],c['wait'],c['forwarding'],c['icache'],c['dcache']) for c in program['cases']}=={(i,j,k,l,m,n) for i in (0,1) for j in (0,1) for k in (0,1) for l in (0,1) for m in (0,1) for n in (0,1)}
    for case in program['cases']:
        assert case['workload_retired']==191 and case['terminal_retired']==1 and case['drain_tail_retired']<=2
        assert case['defined_gpr']==31 and case['unchanged_unknown_gpr']==1
        if case['icache']: assert case['cache_i_hits']>0 and case['cache_i_misses']>0
        else: assert case['cache_i_hits']==case['cache_i_misses']==case['cache_i_refills']==0
        if case['dcache']: assert case['cache_d_hits']>0 and case['cache_d_misses']>0
        else: assert case['cache_d_hits']==case['cache_d_misses']==case['cache_d_refills']==0
    staged=Path(program['private_simulator_cwd'])
    assert staged.resolve().is_relative_to(ROOT.resolve()/'build')
    for path,expected in program['source_sha256'].items(): assert sha(staged/path)==expected
    semantics=mutations['rtl_semantic_rejected'];guards=mutations['parameter_guards_rejected']
    assert semantics==18 and guards==2
    negative_gate(mutations,semantics,guards)
    old_rtl=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'rtl'],cwd=ROOT).decode().splitlines()
    for path in old_rtl:
        assert subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT)==(ROOT/path).read_bytes().replace(b'\r\n',b'\n'),path
    assert before=={path:sha(ROOT/path) for path in SOURCES},'verification changed source'
    result=dict(status=STATUS,base_commit=BASE,source_sha256=before,sources_unchanged=True,processes=processes,suites=suites,
                compatibility_reference='build/cpu5_s12_verification/verification.json',legacy_rtl_unchanged=old_rtl,
                rtl_mutations_rejected=semantics,parameter_guards_rejected=guards,
                cache='OPTIONAL NATIVE I/D; ORIGINAL CACHE RTL UNCHANGED',FENCE_I='UNSUPPORTED',
                AXI_D0_SoC='NOT INTEGRATED',BP_Stats_devices='NOT IMPLEMENTED',full_A01_A16='NOT RUN',
                STA='NOT RUN',board='NOT RUN',performance_claim='NONE')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status=STATUS,sources=len(before),rtl_mutations_rejected=semantics,parameter_guards_rejected=guards)))


if __name__=='__main__':main()
