"""Audit the immutable S15/S14 evidence chain and exact CPU5 observer-only delta."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

ROOT=Path(__file__).resolve().parents[1]
BASE='102806a554a9ebee497289d4830e59d22bccbdef'
EVIDENCE='docs/evidence/cpu5_d0_20261025'
OLD_COMMENT=b'// New width is explicit. Classification hardware is NOT IMPLEMENTED.'
MODIFIED_TB=['tb/cpu5_'+name+'_tb.v' for name in ('axi_control','cache_control','csr_control','d0_control','fence_control','fence_decode','irq_control','m_control','mmio_control','ram_control','trap_control')]
MODIFIED_NAMED_TB=['tb/cpu5_'+name+'_tb.v' for name in ('alu_control','forward_control','branch_control')]
MODIFIED=['rtl/cpu5_alu_pipeline.v','rtl/cpu5_top.v','rtl/cpu5_cached_top.v','rtl/cpu5_axi_lite_top.v','rtl/cpu5_d0_axi_lite_top.v']+MODIFIED_TB+MODIFIED_NAMED_TB


def digest(data):return hashlib.sha256(data).hexdigest()
def sha(path):return digest(path.read_bytes())
def read(path):return json.loads(path.read_text(encoding='utf-8'))


def strip_observer(path,data):
    """A strict inverse, never a general formatting or semantic equivalence claim."""
    def remove(token):
        nonlocal data
        assert data.count(token)==1,(path,'observer anchor',token)
        data=data.replace(token,b'')
    if path=='rtl/cpu5_alu_pipeline.v':
        remove(b'    output reg [9:0] perf_cycle_events,\n')
        data,count=re.subn(rb'    // CPU5_PROFILE_BEGIN\n.*?    // CPU5_PROFILE_END\n',b'',data,flags=re.S)
        assert count==1
    elif path=='rtl/cpu5_top.v':
        remove(b'    wire [9:0] alu_perf_cycle_events;\n')
        remove(b'            .perf_cycle_events(alu_perf_cycle_events),\n')
        remove(b'        assign alu_perf_cycle_events=0;\n')
        assert data.count(b'    assign perf_cycle_events=alu_perf_cycle_events;')==1
        data=data.replace(b'    assign perf_cycle_events=alu_perf_cycle_events;',b'    assign perf_cycle_events=0;')
        data=data.replace(b'// Registered schema4/profile2 events; zero in metadata-only scaffold.',OLD_COMMENT)
        data=data.replace(b'// Registered classifier and cycle_count describe the same counted edge.',b'// Full ten-class profiling is not connected in this ALU-only subset.')
    elif path in MODIFIED_TB:
        assert data.count(b'.perf_cycle_events(),.*')==1,path
        data=data.replace(b'.perf_cycle_events(),.*',b'.*')
    elif path in MODIFIED_NAMED_TB:
        assert data.count(b'dut(.perf_cycle_events(),.irq_external')==1,path
        data=data.replace(b'dut(.perf_cycle_events(),.irq_external',b'dut(.irq_external')
    elif path in MODIFIED:
        assert data.count(b'// Registered schema4/profile2 events; zero in the metadata-only scaffold.')==1,path
        data=data.replace(b'// Registered schema4/profile2 events; zero in the metadata-only scaffold.',OLD_COMMENT)
    else:raise AssertionError('unexpected changed baseline file: '+path)
    return data


def audit_archive(folder):
    manifest=read(folder/'manifest.json')
    assert manifest['status']=='FROZEN'
    rel=folder.relative_to(ROOT).as_posix()
    assert subprocess.check_output(['git','show',BASE+':'+rel+'/manifest.json'],cwd=ROOT)==(folder/'manifest.json').read_bytes()
    for name,expected in manifest['files'].items():assert sha(folder/name)==expected,(rel,name)
    entries=read(folder/'archive_entries.json');assert len(entries)==manifest['archive_entries']
    with zipfile.ZipFile(folder/'raw_evidence.zip') as archive:
        assert len(archive.namelist())==len(set(archive.namelist())) and set(archive.namelist())==set(entries)
        for name,expected in entries.items():
            h=hashlib.sha256()
            with archive.open(name) as stream:
                while part:=stream.read(1024*1024):h.update(part)
            assert h.hexdigest()==expected,name
    return manifest,entries


def audit_baseline():
    folder=ROOT/EVIDENCE;manifest,entries=audit_archive(folder)
    identity=read(folder/'source_identity.json')['sources'];verification=read(folder/'verification.json')
    assert verification['status']=='PARTIAL VERIFIED: CPU5 optional D0 local data RAM routing'
    assert verification['sources_unchanged'] and len(identity)==235
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in verification['processes'])
    assert all(s['status']=='PASS' for s in verification['suites'].values())
    before={p:sha(ROOT/p) for p in identity};changed=[];checks=0
    for path,expected in identity.items():
        assert verification['source_sha256'][path]==expected['raw_sha256']==entries['tested_sources/'+path]
        data=(ROOT/path).read_bytes().replace(b'\r\n',b'\n')
        assert digest(subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT))==expected['lf_sha256']
        if digest(data)!=expected['lf_sha256']:
            changed.append(path);assert digest(strip_observer(path,data))==expected['lf_sha256'],path
    assert set(changed)==set(MODIFIED),(changed,MODIFIED)
    def stored(rec):
        nonlocal checks
        assert rec['compile']['status']=='PASS' and rec['compile']['exit_code']==rec['compile']['warnings']==rec['compile']['errors']==0
        prefix=rec['directory']+'/'
        for path,expected in rec['source_sha256'].items():assert entries[prefix+path]==expected;checks+=1
        for path,expected in rec['retained_artifact_sha256'].items():assert entries[prefix+path]==expected;checks+=1
        assert entries[prefix+'compile_console.log']==rec['compile']['console_sha256']
        assert entries[prefix+'simulation_console.log']==rec['simulation_console_sha256']
    for name in ('backend','control'):
        suite=verification['suites'][name];stored(suite['positive'])
        assert suite['positive']['status']=='PASS' and suite['positive']['simulation_exit_code']==0
    backend=verification['suites']['backend'];assert backend['rtl_semantic_rejected']==21 and backend['parameter_guards_rejected']==2
    for spec in backend['specimens']:
        stored(spec);assert spec['status']=='REJECTED' and spec['simulation_exit_code']!=0
        tokens=spec['expected_assertion'];tokens=[tokens] if isinstance(tokens,str) else tokens
        assert any(t in spec['actual_assertion'] for t in tokens)
    program=verification['suites']['program']
    assert program['case_count']==program['simulation_case_passes']==384 and len(program['simulation_batches'])==24
    for batch in program['simulation_batches']:
        assert batch['status']=='PASS' and batch['simulation_exit_code']==batch['warnings']==batch['errors']==0
        assert entries[batch['waveform']]==batch['waveform_sha256'];checks+=1
    for path,expected in program['source_sha256'].items():
        assert entries['build/cpu5_s15_d0_program/simulator/stage/'+path]==expected;checks+=1
    assert program['negative_evidence_tests']['rejected_count']==38 and program['negative_evidence_tests']['good_inputs_unchanged']
    dep=manifest['baseline_dependency'];old_folder=ROOT/dep['path'];old_manifest,old_entries=audit_archive(old_folder)
    assert sha(old_folder/'manifest.json')==dep['manifest_sha256'] and sha(old_folder/'raw_evidence.zip')==dep['raw_archive_sha256']
    assert len(old_entries)==dep['archive_entries']==17365
    assert before=={p:sha(ROOT/p) for p in identity},'baseline inputs changed during audit'
    out=ROOT/'build/cpu5_s16_reference';out.mkdir(parents=True,exist_ok=True)
    for name in ('manifest.json','source_identity.json','verification.json','archive_entries.json'):(out/('baseline_'+name)).write_bytes((folder/name).read_bytes())
    result=dict(status='PASS',baseline_commit=BASE,baseline_evidence=EVIDENCE,baseline_sources=len(identity),
        baseline_manifest_sha256=sha(folder/'manifest.json'),baseline_raw_archive_sha256=sha(folder/'raw_evidence.zip'),
        baseline_archive_entries=len(entries),transitive_dependency=dep,transitive_archive_entries=len(old_entries),
        stored_source_log_wave_references_checked=checks,source_sha256=before,sources_unchanged=True,simulations_rerun=False,
        canonical_lf_unchanged=len(identity)-len(changed),exact_reversible_observer_or_port_comment_delta=sorted(changed),
        scope='Immutable S15/S14 evidence reuse with complete ZIP SHA/CRC; original CPU5 control statements exact after removing named observer-only additions and unused test ports/comments; fresh S16 control/program/system tests required')
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    return result


if __name__=='__main__':
    result=audit_baseline();print(json.dumps({k:result[k] for k in ('status','baseline_sources','canonical_lf_unchanged','baseline_archive_entries','transitive_archive_entries','stored_source_log_wave_references_checked')}))
