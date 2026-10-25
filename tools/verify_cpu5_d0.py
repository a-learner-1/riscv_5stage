"""Verify fresh CPU5 D0 suites and audit immutable S14 compatibility evidence."""
import argparse
import itertools
import json
from pathlib import Path
import subprocess
import sys
from cpu5_d0_baseline import audit_baseline
from verify_cpu5_axi import SOURCES as AXI_SOURCES, same_sources, read, sha
from run_cpu5_d0_backend import SOURCES as BACKEND_SOURCES
from run_cpu5_d0_control import SOURCES as CONTROL_SOURCES
from run_cpu5_d0_program import SOURCES as PROGRAM_SOURCES
from cpu5_d0_reference import analyze, selftest_evidence

ROOT=Path(__file__).resolve().parents[1]
BASE='aad84b44eae382cf243a4929a3114c5db6980198'
OUT=ROOT/'build/cpu5_s15_verification'
STATUS='PARTIAL VERIFIED: CPU5 optional D0 local data RAM routing'
D0_NEW_FILES=[
    'rtl/cpu5_d0_backend.v','rtl/cpu5_d0_axi_lite_top.v',
    'tb/cpu5_d0_backend_tb.v','tb/cpu5_d0_control_tb.v','tb/cpu5_d0_program_tb.v',
    'run_cpu5_d0_backend.do','run_cpu5_d0_control.do','run_cpu5_d0_program.do',
    'tools/run_cpu5_d0_backend.py','tools/run_cpu5_d0_control.py','tools/run_cpu5_d0_program.py',
    'tools/cpu5_d0_reference.py','tools/cpu5_d0_baseline.py','tools/verify_cpu5_d0.py',
    'tools/verify_cpu5_d0_mutations.py',
    'tools/freeze_cpu5_d0.py','docs/cpu5_d0_contract_20261025.md',
]
SOURCES=sorted(set(AXI_SOURCES+BACKEND_SOURCES+CONTROL_SOURCES+PROGRAM_SOURCES+D0_NEW_FILES))


def retained(record):
    """Recheck source snapshots and raw results, not just their PASS labels."""
    assert record['compile']['status']=='PASS'
    assert record['compile']['exit_code']==record['compile']['warnings']==record['compile']['errors']==0
    directory=ROOT/record['directory']
    assert directory.resolve().is_relative_to(ROOT.resolve()/'build')
    for path,expected in record['source_sha256'].items():assert sha(directory/path)==expected
    for path,expected in record['retained_artifact_sha256'].items():assert sha(directory/path)==expected
    assert sha(directory/'compile_console.log')==record['compile']['console_sha256']
    assert sha(directory/'simulation_console.log')==record['simulation_console_sha256']


def unit_gate(unit):
    same_sources(unit)
    assert unit['status']=='PASS' and unit['sources_unchanged']
    good=unit['positive'];retained(good)
    assert good['status']=='PASS' and good['simulation_exit_code']==0
    for path,expected in good['source_sha256'].items():assert sha(ROOT/path)==expected
    assert len(good['cases'])==6 and all(c['status']=='PASS' for c in good['cases'])
    for i,c in enumerate(good['cases']):
        assert c['accepted']==c['responses']+c['reset_drops']
        assert read(ROOT/good['directory']/f'build/cpu5_s15_d0_backend/case{i}_summary.json')==c
    assert read(ROOT/good['directory']/'d0_native_backend_tb_summary.json')==good['legacy_native']
    specimens=unit['specimens']
    assert len({s['name'] for s in specimens})==len(specimens)
    semantics=[s for s in specimens if s['kind']=='rtl_semantic']
    guards=[s for s in specimens if s['kind']=='parameter_guard']
    assert len(semantics)>=12 and len(guards)==2
    for s in specimens:
        retained(s)
        assert s['status']=='REJECTED' and s['simulation_exit_code']!=0
        tokens=s['expected_assertion'];tokens=[tokens] if isinstance(tokens,str) else tokens
        assert any(token in s['actual_assertion'] for token in tokens)
        if s['changed_source']:
            change=s['changed_source'];assert change['bad_sha256']!=change['good_sha256']==sha(ROOT/change['path'])
    return len(semantics),len(guards)


def control_gate(control):
    same_sources(control)
    assert control['status']=='PASS' and control['sources_unchanged']
    good=control['positive'];retained(good)
    assert good['status']=='PASS' and good['simulation_exit_code']==0
    for path,expected in good['source_sha256'].items():assert sha(ROOT/path)==expected
    assert control['configurations']==8 and control['retired']==control['wb']+control['reset_abandoned_wb']
    assert control['requests']==control['responses']+control['reset_abandoned_requests']
    assert control['sync_traps']>0 and control['irqs']==8
    assert {(c['d0'],c['cache'],c['wait']) for c in control['configs']}==set(itertools.product((0,1),(0,1),(0,1)))
    for c in control['configs']:
        assert c['retired']==c['wb']+c['reset_abandoned_wb']
        assert c['requests']==c['responses']+c['reset_abandoned_requests']
        assert c['backend_requests']==c['backend_responses']+c['backend_reset_abandoned']
        assert c['sync_traps']==c['precise_errors']==3 and c['irqs']==1
        assert c['kill_complete']==1 and c['store_wb_hold']==1 and c['flush_rejected']==2


def program_gate(p):
    same_sources(p)
    assert p['status']=='PASS' and p['sources_unchanged'] and p['compile_zero_warning_error']
    assert p['case_count']==p['simulation_case_passes']==384 and len(p['simulation_batches'])==24
    assert p['total_retired']==p['total_wb_packets'] and p['total_workload_retired']==232*384
    assert p['total_irqs']==4*384 and p['total_sync_traps']==3*384
    assert p['total_d_requests']==p['total_d_responses']
    assert p['total_bridge_requests']==p['total_bridge_responses']
    assert p['total_d0_requests']==p['total_d0_responses']>0 and p['total_d0_physical_writes']>0
    assert p['total_axi_aw']==p['total_axi_w']==p['total_axi_b']==p['total_axi_write_pairs']
    assert p['total_axi_ar']==p['total_axi_r']
    assert p['total_axi_b_errors']==p['total_axi_r_errors']==384
    assert p['decoder_selftest']['fixed_word_checks']==39 and p['decoder_selftest']['device_state_checks']==5
    assert p['negative_evidence_tests']['rejected_count']==38 and p['negative_evidence_tests']['good_inputs_unchanged']
    assert sha(ROOT/'build/cpu5_s15_d0_program/console.log')==p['simulation_console_sha256']
    for path,expected in p['input_vector_sha256'].items():assert sha(ROOT/'build/cpu5_s15_d0_program'/path)==expected
    for b in p['simulation_batches']:
        assert b['status']=='PASS' and b['simulation_exit_code']==b['warnings']==b['errors']==0
        assert sha(ROOT/b['waveform'])==b['waveform_sha256']
    staged=Path(p['private_simulator_cwd'])
    assert staged.resolve().is_relative_to(ROOT.resolve()/'build')
    for path,expected in p['source_sha256'].items():assert sha(staged/path)==expected
    keys=('id_mode','predict','wait','forwarding','icache','dcache','axi_mode','d0')
    assert {tuple(c[k] for k in keys) for c in p['cases']}==set(itertools.product((0,1),(0,1),(0,1),(0,1),(0,1),(0,1),(0,1,2),(0,1)))
    for c in p['cases']:
        assert c['workload_retired']==232 and c['terminal_retired']==1 and c['drain_tail_retired']<=2
        assert c['axi_b_errors']==c['axi_r_errors']==1
        if c['d0']:
            assert c['d0_requests']==c['d0_responses']>0 and c['bridge_requests']==c['bridge_responses']==2
            assert c['axi_commits']==0 and c['d0_physical_writes']==37
        else:assert c['d0_requests']==c['d0_responses']==c['d0_physical_writes']==c['d0_physical_reads']==0
    # Bind analysis to the raw CSV/HEX currently being frozen. A stale PASS
    # record cannot authenticate subsequently modified case artifacts.
    raw=ROOT/'build/cpu5_s15_d0_program'
    current=analyze(raw)
    assert all(p[key]==value for key,value in current.items()),'raw program evidence differs from accepted analysis'
    assert selftest_evidence(raw)==p['negative_evidence_tests'],'bad-evidence rejection receipt differs'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-suites',action='store_true',help='reuse only complete fresh S15 suites with exact dependency SHA identity')
    a=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    before={path:sha(ROOT/path) for path in SOURCES}
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',source_sha256=before),indent=2)+'\n',encoding='utf-8')
    baseline=audit_baseline();assert baseline['status']=='PASS' and not baseline['simulations_rerun']
    processes=[dict(name='reference',status='PASS',exit_code=0,reused=True,mode=baseline['mode'])]
    suites={}
    for name in ('backend','control','program'):
        path=ROOT/f'build/cpu5_s15_d0_{name}/verification.json'
        command=[sys.executable,'-B',f'tools/run_cpu5_d0_{name}.py','--vsim',str(a.vsim)]
        if not a.reuse_suites:
            proc=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=1200)
            output=proc.stdout+proc.stderr;(OUT/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
            assert proc.returncode==0 and 'Traceback (most recent call last)' not in output,(name,output[-12000:])
        record=read(path);same_sources(record);assert record['status']=='PASS'
        suites[name]=record;processes.append(dict(name=name,status='PASS',exit_code=0,reused=a.reuse_suites,command=command,record_sha256=sha(path)))
        print(name,'PASS',flush=True)
    semantics,guards=unit_gate(suites['backend']);control_gate(suites['control']);program_gate(suites['program'])
    old_rtl=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'rtl'],cwd=ROOT).decode().splitlines()
    for path in old_rtl:assert subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT)==(ROOT/path).read_bytes().replace(b'\r\n',b'\n'),path
    assert before=={path:sha(ROOT/path) for path in SOURCES},'verification changed source'
    result=dict(status=STATUS,base_commit=BASE,source_sha256=before,sources_unchanged=True,processes=processes,
                reference=baseline,suites=suites,legacy_rtl_unchanged=old_rtl,rtl_semantic_rejected=semantics,parameter_guards_rejected=guards,
                D0='OPTIONAL LOCAL SYNCHRONOUS DATA RAM; DEFAULT OFF',AXI='SINGLE OUTSTANDING AXI4-LITE DATA MASTER; NATIVE IF',
                FENCE_I='UNSUPPORTED',Stats_fabric_SoC='NOT INTEGRATED',full_A01_A16='NOT RUN',STA='NOT RUN',board='NOT RUN',performance_claim='NONE')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status=STATUS,sources=len(before),rtl_semantic_rejected=semantics,parameter_guards_rejected=guards)))


if __name__=='__main__':main()
