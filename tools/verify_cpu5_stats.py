"""Verify CPU5 ten-class cycle producer, ABI, real snapshots and fresh compatibility."""
import argparse
import itertools
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_d0 import SOURCES as BASE_SOURCES,same_sources,sha,read
from cpu5_stats_baseline import audit_baseline,MODIFIED,BASE
from run_cpu5_cycle_profile import SOURCES as CYCLE_SOURCES
from run_cpu5_stats_endpoint import SOURCES as ENDPOINT_SOURCES
from run_cpu5_profile_program import SOURCES as PROGRAM_SOURCES
from run_cpu5_stats_system import SOURCES as SYSTEM_SOURCES,analyze as analyze_system
from run_cpu5_m_stats_window import SOURCES as M_WINDOW_SOURCES,analyze as analyze_m_window
from run_cpu5_stats_compat import SOURCES as COMPAT_SOURCES,TOPS
from check_cpu5_stats_abi import SOURCES as ABI_SOURCES
from cpu5_profile_reference import analyze as analyze_program,selftest_evidence

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_verification'
STATUS='PARTIAL VERIFIED: CPU5 ten-class cycle Stats schema4/profile2'
NEW_FILES=[
    'rtl/axi_lite_cpu5_stats.v','rtl/cpu5_stats_axi_lite_top.v',
    'tb/cpu5_m_stats_window_tb.v','tools/run_cpu5_m_stats_window.py',
    *['software/cpu5_stats/'+n for n in ('cpu5_stats.h','smoke.c','start.S','link.ld')],
    *['tb/'+n+'.v' for n in ('axi_lite_cpu5_stats_tb','cpu5_cycle_profile_tb','cpu5_profile_program_tb','cpu5_stats_system_tb')],
    *['run_cpu5_'+n+'.do' for n in ('stats_endpoint','cycle_profile','profile_program','stats_system')],
    *['tools/'+n+'.py' for n in ('run_cpu5_stats_endpoint','run_cpu5_cycle_profile','run_cpu5_profile_program','cpu5_profile_reference',
        'run_cpu5_stats_system','cpu5_stats_abi','check_cpu5_stats_abi','run_cpu5_stats_compat','cpu5_stats_baseline','verify_cpu5_stats','freeze_cpu5_stats')],
    'docs/cpu5_stats_contract_20261025.md',
]
LEGACY_ARTIFACTS=('rtl/axi_lite_coremark_stats.v','rtl/cpu_top.v','rtl/soc_coremark_axi_top.v',
                  'software/coremark_port/coremark_axi_stats.h','tb/axi_lite_coremark_stats_tb.v')
SOURCES=sorted(set(BASE_SOURCES+CYCLE_SOURCES+ENDPOINT_SOURCES+PROGRAM_SOURCES+SYSTEM_SOURCES+M_WINDOW_SOURCES+COMPAT_SOURCES+ABI_SOURCES+NEW_FILES+list(LEGACY_ARTIFACTS)))


def retained(r):
    assert r['compile']['status']=='PASS' and r['compile']['exit_code']==r['compile']['warnings']==r['compile']['errors']==0
    folder=ROOT/r['directory'];assert folder.resolve().is_relative_to(ROOT.resolve()/'build')
    for path,expected in r['source_sha256'].items():assert sha(folder/path)==expected
    for path,expected in r['retained_artifact_sha256'].items():assert sha(folder/path)==expected
    assert sha(folder/'compile_console.log')==r['compile']['console_sha256']
    assert any(path.endswith('_console.log') and expected==r['simulation_console_sha256']
               for path,expected in r['retained_artifact_sha256'].items()),'simulation console receipt missing'


def positive(r):
    same_sources(r);assert r['status']=='PASS' and r['sources_unchanged']
    p=r['positive'];retained(p);assert p['status']=='PASS' and p['simulation_exit_code']==0
    for path,expected in p['source_sha256'].items():assert sha(ROOT/path)==expected


def mutations(r,semantic,guards):
    assert r['rtl_semantic_rejected']==semantic and r.get('parameter_guards_rejected',0)==guards
    assert len(r['specimens'])==semantic+guards
    for s in r['specimens']:
        retained(s);assert s['status']=='REJECTED' and s['simulation_exit_code']!=0
        tokens=s['expected_assertion'];tokens=[tokens] if isinstance(tokens,str) else tokens
        assert any(t in s['actual_assertion'] for t in tokens)
        change=s['changed_source']
        if change:assert change['bad_sha256']!=change['good_sha256']==sha(ROOT/change['path'])


def cycle_gate(r):
    positive(r);assert r['configurations']==4 and not r['reference_only']
    assert r['cycles']==sum(r['class_counts'])==1073 and all(r['class_counts'])
    assert r['retired']==r['wb']==92 and r['checks']==108
    mutations(r,15,0)
    assert {(c['forwarding'],c['id_mode']) for c in r['positive']['cases']}==set(itertools.product((0,1),(0,1)))
    for i,c in enumerate(r['positive']['cases']):
        assert read(ROOT/r['positive']['directory']/f'build/cpu5_s16_cycle_profile/case{i}_summary.json')==c


def endpoint_gate(r):
    positive(r);assert r['configurations']==3 and len(r['cases'])==3
    mutations(r,6,2)
    for i,c in enumerate(r['cases']):
        assert c['status']=='PASS' and c['carry_checks']==c['wrap_checks']==10 and c['edge_checks']>0
        assert read(ROOT/r['positive']['directory']/f'build/cpu5_s16_stats_endpoint/case{i}_summary.json')==c
    assert 'schema3/profile1' in r['legacy'] and 'sixteen new offsets remain reserved SLVERR' in r['legacy']


def program_gate(r):
    same_sources(r);assert r['status']=='PASS' and r['sources_unchanged'] and r['compile_zero_warning_error']
    assert r['case_count']==r['simulation_case_passes']==384 and len(r['simulation_batches'])==24
    assert r['total_retired']==r['total_wb_packets'] and r['total_workload_retired']==232*384
    assert r['total_irqs']==1536 and r['total_sync_traps']==1152
    assert r['total_profile_start_count']==768 and r['total_profile_stop_count']==384
    assert r['total_profile_owner_crossings']==384 and r['total_profile_printed_words']==40*384
    assert r['total_profile_stats_reads']==r['total_profile_stats_responses']
    assert sum(r['profile_class_totals'].values())==r['total_profile_edge_checks']
    assert sum(r['profile_window_totals'].values())==r['total_profile_window_cycles']
    assert r['profile_class_totals']['div_wait']==0
    neg=r['negative_evidence_tests'];assert neg['rejected_count']==52 and neg['architectural_rejected_count']==38 and neg['profile_rejected_count']==14 and neg['good_inputs_unchanged']
    folder=ROOT/'build/cpu5_s16_profile_program'
    for name,expected in r['raw_output_sha256'].items():assert sha(folder/name)==expected
    assert sha(folder/'console.log')==r['simulation_console_sha256']
    for name,expected in r['input_vector_sha256'].items():assert sha(folder/name)==expected
    for b in r['simulation_batches']:
        assert b['status']=='PASS' and b['simulation_exit_code']==b['warnings']==b['errors']==0 and sha(ROOT/b['waveform'])==b['waveform_sha256']
    private=Path(r['private_simulator_cwd']);assert private.resolve().is_relative_to(ROOT.resolve()/'build')
    for name,expected in r['source_sha256'].items():assert sha(private/name)==expected
    current=analyze_program(folder);assert all(r[k]==v for k,v in current.items()),'program raw no longer matches accepted gold'
    assert selftest_evidence(folder)==neg


def system_gate(r):
    positive(r);assert r['configurations']==8 and r['total_stats_reads']==808 and r['total_profile_words_checked']==640
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in r['processes'])
    folder=ROOT/'build/cpu5_s16_stats_system'
    for path,expected in r['raw_artifact_sha256'].items():
        assert (ROOT/path).resolve().is_relative_to(folder.resolve())
        assert sha(ROOT/path)==expected
    assert len(r['firmware'])==8
    for i,fw in enumerate(r['firmware']):
        assert fw['case']==i and 0<fw['text_bytes']<=32768 and '15.2.0' in fw['compiler_version']
        for step in fw['steps']:assert step['exit_code']==0
        for path,expected in fw['source_sha256'].items():assert sha(ROOT/path)==expected
        for path,expected in fw['artifact_sha256'].items():assert sha(folder/f'firmware/case{i}'/path)==expected
        assert read(folder/f'firmware/case{i}/build.json')==fw
    current=analyze_system(folder);assert all(r[k]==v for k,v in current.items()),'system raw no longer matches accepted gold'
    for c in r['cases']:
        assert c['stats_reads']==c['stats_responses']==101 and c['ram_words_checked']==4096
        assert c['window']['cycle_classes']['mul_wait']>0 and c['window']['cycle_classes']['div_wait']>0


def mwindow_gate(r):
    positive(r)
    assert r['configurations']==4 and r['total_reads']==392 and r['total_retired']==12
    assert r['total_owner_crossings']==4 and r['total_window_cycles']==8
    assert r['fast_allocation_boundary']==r['killed_background_crossings']==1 and r['normal_live_crossings']==2
    raw=ROOT/r['positive']['directory']/'build/cpu5_s16_m_stats_window'
    current=analyze_m_window(raw);assert all(r[k]==v for k,v in current.items())
    for c in r['cases']:
        assert c['retired']==c['wb']==3 and c['owner_starts']==c['owner_completions']==1
        w=c['window'];assert sum(w['profile_delta'])==w['cycles'] and int(w['owner_seq'],16)==0x200000002
        if c['fast']:assert w['start_owner_valid']==0 and w['start_issue']==1 and w['profile_delta'][7]==1
        if c['killed']:assert w['profile_delta'][6]==w['profile_delta'][7]==0


def compat_gate(r):
    positive(r);assert r['top_count']==len(TOPS)==17
    assert [c['top'] for c in r['cases']]==TOPS
    for c in r['cases']:
        assert c['status']=='PASS' and c['simulation_exit_code']==c['warnings']==c['errors']==0
        assert sha(ROOT/r['positive']['directory']/(c['top']+'_console.log'))==c['console_sha256']
    for path,value in r['summaries'].items():assert read(ROOT/r['positive']['directory']/path)==value


def abi_gate(r):
    same_sources(r);assert r['status']=='PASS' and r['sources_unchanged']
    assert r['reader']['rejected_count']==17 and r['reader']['offset_words']==40 and len(r['c_guards'])==11
    for c in r['c_guards']:assert c['exit_code']==c['expected_exit_code']
    for path,expected in r['retained_artifact_sha256'].items():assert sha(ROOT/path)==expected


GATES=dict(cycle=cycle_gate,endpoint=endpoint_gate,program=program_gate,system=system_gate,mwindow=mwindow_gate,compat=compat_gate,abi=abi_gate)
RECORDS={n:'build/cpu5_s16_'+p+'/verification.json' for n,p in dict(cycle='cycle_profile',endpoint='stats_endpoint',program='profile_program',system='stats_system',mwindow='m_stats_window',compat='stats_compat',abi='stats_abi').items()}
SCRIPTS=dict(cycle='run_cpu5_cycle_profile',endpoint='run_cpu5_stats_endpoint',program='run_cpu5_profile_program',system='run_cpu5_stats_system',mwindow='run_cpu5_m_stats_window',compat='run_cpu5_stats_compat',abi='check_cpu5_stats_abi')


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'));ap.add_argument('--reuse-suites',action='store_true');a=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True);before={p:sha(ROOT/p) for p in SOURCES}
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',source_sha256=before),indent=2)+'\n',encoding='utf-8')
    reference=audit_baseline();processes=[dict(name='reference',status='PASS',exit_code=0,reused=True,simulations_rerun=False)]
    suites={}
    for name in GATES:
        command=[sys.executable,'-B','tools/'+SCRIPTS[name]+'.py']
        if name!='abi':command+=['--vsim',str(a.vsim)]
        if not a.reuse_suites:
            proc=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=1200)
            output=proc.stdout+proc.stderr;(OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
            assert proc.returncode==0 and 'Traceback (most recent call last)' not in output,(name,output[-14000:])
        record=read(ROOT/RECORDS[name]);GATES[name](record);suites[name]=record
        processes.append(dict(name=name,status='PASS',exit_code=0,reused=a.reuse_suites,command=command,record=RECORDS[name],record_sha256=sha(ROOT/RECORDS[name])))
        print(name,'PASS',flush=True)
    assert before=={p:sha(ROOT/p) for p in SOURCES}
    changed=subprocess.check_output(['git','diff',BASE,'--name-only','--','rtl','tb'],cwd=ROOT).decode().splitlines()
    base_tracked=set(subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'rtl','tb'],cwd=ROOT).decode().splitlines())
    checked_old={p for p in base_tracked if p.startswith('rtl/') or p in BASE_SOURCES}
    assert set(changed)&checked_old==set(MODIFIED),'unexpected architectural/test change'
    for path in LEGACY_ARTIFACTS:
        assert subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT)==(ROOT/path).read_bytes().replace(b'\r\n',b'\n'),path
    result=dict(status=STATUS,base_commit=BASE,source_sha256=before,sources_unchanged=True,processes=processes,reference=reference,suites=suites,
        reversible_observer_changes=sorted(MODIFIED),legacy_stats_preserved=list(LEGACY_ARTIFACTS),rtl_semantic_rejected=21,parameter_guards_rejected=2,
        hardware_schema=4,profile_schema=2,event_width=10,COREMARK='NOT RUN',full_A01_A16='NOT RUN',STA='NOT RUN',board='NOT RUN',performance_claim='NONE')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status=STATUS,sources=len(SOURCES),rtl_semantic_rejected=21,parameter_guards_rejected=2)))


if __name__=='__main__':main()
