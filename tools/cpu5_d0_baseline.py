"""Audit the immutable S14 baseline archive against the current S15 dependencies.

This reuses previously completed simulations; it does not label an archive
identity audit as a fresh simulation. New D0 paths are exercised separately.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import zipfile
from verify_cpu5_axi import SOURCES as AXI_SOURCES

ROOT=Path(__file__).resolve().parents[1]
BASE='aad84b44eae382cf243a4929a3114c5db6980198'
EVIDENCE='docs/evidence/cpu5_axi_20261025'


def digest(data): return hashlib.sha256(data).hexdigest()


def file_digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        while chunk:=stream.read(1024*1024):h.update(chunk)
    return h.hexdigest()


def read(path): return json.loads(path.read_text(encoding='utf-8'))


def audit_baseline(root=ROOT):
    evidence=root/EVIDENCE
    manifest=read(evidence/'manifest.json')
    assert manifest['status']=='FROZEN'
    committed=subprocess.check_output(['git','show',BASE+':'+EVIDENCE+'/manifest.json'],cwd=root)
    assert committed==(evidence/'manifest.json').read_bytes(),'baseline manifest differs from S14 commit'
    for name,expected in manifest['files'].items():assert file_digest(evidence/name)==expected,name
    identity=read(evidence/'source_identity.json')['sources']
    verification=read(evidence/'verification.json')
    assert verification['status']=='PARTIAL VERIFIED: CPU5 AXI4-Lite data master'
    assert verification['sources_unchanged']
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in verification['processes'])
    assert all(s['status']=='PASS' for s in verification['suites'].values())
    assert set(identity)==set(AXI_SOURCES)==set(verification['source_sha256'])
    before={p:file_digest(root/p) for p in AXI_SOURCES}
    for path,source in identity.items():
        assert digest((root/path).read_bytes().replace(b'\r\n',b'\n'))==source['lf_sha256'],path
        assert verification['source_sha256'][path]==source['raw_sha256'],path
    entries=read(evidence/'archive_entries.json')
    assert len(entries)==manifest['archive_entries']==17365
    with zipfile.ZipFile(evidence/'raw_evidence.zip') as archive:
        assert len(archive.namelist())==len(set(archive.namelist())) and set(archive.namelist())==set(entries)
        for path,expected in entries.items():
            h=hashlib.sha256()
            with archive.open(path) as stream:
                while chunk:=stream.read(1024*1024):h.update(chunk)
            assert h.hexdigest()==expected,path
        for path,source in identity.items():assert entries['tested_sources/'+path]==source['raw_sha256']
    checked=0
    def stored(record):
        nonlocal checked
        assert record['compile']['status']=='PASS'
        assert record['compile']['exit_code']==record['compile']['warnings']==record['compile']['errors']==0
        prefix=record['directory']+'/'
        for path,expected in record['source_sha256'].items():assert entries[prefix+path]==expected;checked+=1
        for path,expected in record['retained_artifact_sha256'].items():assert entries[prefix+path]==expected;checked+=1
        assert entries[prefix+'compile_console.log']==record['compile']['console_sha256']
        assert entries[prefix+'simulation_console.log']==record['simulation_console_sha256']
    suites=verification['suites']
    for name in ('bridge','control'):
        assert suites[name]['positive']['status']=='PASS' and suites[name]['positive']['simulation_exit_code']==0
        stored(suites[name]['positive'])
    mutations=suites['mutations']
    stored(mutations['good_reference'])
    assert mutations['rtl_semantic_rejected']==18 and mutations['parameter_guards_rejected']==1
    for specimen in mutations['specimens']:
        assert specimen['status']=='REJECTED' and specimen['simulation_exit_code']!=0
        tokens=specimen['expected_assertion'];tokens=[tokens] if isinstance(tokens,str) else tokens
        assert any(token in specimen['actual_assertion'] for token in tokens)
        stored(specimen)
        change=specimen['changed_source']
        if change:
            assert change['good_sha256']==identity[change['path']]['raw_sha256']
            assert change['bad_sha256']!=change['good_sha256']
    program=suites['program']
    assert program['case_count']==program['simulation_case_passes']==192 and len(program['simulation_batches'])==12
    for batch in program['simulation_batches']:
        assert batch['status']=='PASS' and batch['simulation_exit_code']==batch['warnings']==batch['errors']==0
        assert entries[batch['waveform']]==batch['waveform_sha256'];checked+=1
    for path,expected in program['source_sha256'].items():
        assert entries['build/cpu5_s14_axi_program/simulator/stage/'+path]==expected;checked+=1
    assert program['negative_evidence_tests']['rejected_count']==29 and program['negative_evidence_tests']['good_inputs_unchanged']
    assert before=={p:file_digest(root/p) for p in AXI_SOURCES},'baseline source changed during audit'
    out=root/'build/cpu5_s15_reference';out.mkdir(parents=True,exist_ok=True)
    for name in ('manifest.json','source_identity.json','verification.json','archive_entries.json'):
        (out/('baseline_'+name)).write_bytes((evidence/name).read_bytes())
    result=dict(status='PASS',mode='FROZEN S14 SIMULATION REUSE WITH COMPLETE ARCHIVE AND LF SOURCE IDENTITY AUDIT',
                baseline_commit=BASE,baseline_evidence=EVIDENCE,baseline_manifest_sha256=file_digest(evidence/'manifest.json'),
                baseline_raw_archive_sha256=manifest['files']['raw_evidence.zip'],baseline_archive_entries=len(entries),
                baseline_sources=len(identity),stored_source_log_wave_references_checked=checked,
                source_sha256=before,sources_unchanged=True,simulations_rerun=False,
                scope='All S14 source dependencies equivalent by canonical LF; all original frozen archive bytes/CRC verified; new S15 routes require fresh tests')
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    return result


if __name__=='__main__':
    result=audit_baseline()
    print(json.dumps({key:result[key] for key in ('status','baseline_sources','baseline_archive_entries','stored_source_log_wave_references_checked','simulations_rerun')}))
