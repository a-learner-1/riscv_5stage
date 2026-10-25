"""Freeze fresh D0 evidence and an explicit immutable S14 evidence dependency."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from verify_cpu5_d0 import ROOT, SOURCES, BASE, STATUS, same_sources, read, unit_gate, control_gate, program_gate


def digest(data):return hashlib.sha256(data).hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dest',type=Path,default=ROOT/'docs/evidence/cpu5_d0_20261025')
    a=ap.parse_args();result=read(ROOT/'build/cpu5_s15_verification/verification.json')
    assert result['status']==STATUS;same_sources(result)
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in result['processes'])
    unit_gate(result['suites']['backend']);control_gate(result['suites']['control']);program_gate(result['suites']['program'])
    reference=result['reference'];same_sources(reference)
    assert reference['status']=='PASS' and not reference['simulations_rerun']
    dependency=ROOT/reference['baseline_evidence']
    assert digest((dependency/'raw_evidence.zip').read_bytes())==reference['baseline_raw_archive_sha256']
    assert digest((dependency/'manifest.json').read_bytes())==reference['baseline_manifest_sha256']
    selected={}
    for name in ('backend','control','mutations'):
        record=read(ROOT/f'build/cpu5_s15_d0_{name}/verification.json');same_sources(record)
        assert record['status']=='PASS'
        if name in ('backend','control'):
            assert record==result['suites'][name],'current suite is not the selected verified suite'
        else:
            backend=result['suites']['backend']
            assert record['run_id']==backend['mutation_run_id']
            assert digest((ROOT/f'build/cpu5_s15_d0_{name}/verification.json').read_bytes())==backend['mutation_verification_sha256']
            assert record['specimens']==backend['specimens']
        selected['cpu5_s15_d0_'+name]=record['run_id']
    assert read(ROOT/'build/cpu5_s15_d0_program/verification.json')==result['suites']['program']
    assert read(ROOT/'build/cpu5_s15_reference/verification.json')==reference
    a.dest.mkdir(parents=True,exist_ok=True)
    identity={}
    for name in SOURCES:
        data=(ROOT/name).read_bytes();identity[name]=dict(raw_sha256=digest(data),lf_sha256=digest(data.replace(b'\r\n',b'\n')))
    write(a.dest/'source_identity.json',dict(base_commit=BASE,sources=identity))
    write(a.dest/'verification.json',result)
    approved=('cpu5_s15_reference','cpu5_s15_d0_backend','cpu5_s15_d0_control','cpu5_s15_d0_mutations','cpu5_s15_d0_program','cpu5_s15_d0_program_negative_evidence','cpu5_s15_verification')
    entries={}
    with zipfile.ZipFile(a.dest/'raw_evidence.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name in approved:
            directory=ROOT/'build'/name;assert directory.is_dir(),name
            for path in sorted(directory.rglob('*')):
                if not path.is_file():continue
                parts=path.relative_to(directory).parts
                if name in selected and len(parts)>2 and parts[0]=='runs' and parts[1]!=selected[name]:continue
                if any(p in ('work','worklib','__pycache__') or p.endswith('_work') for p in parts[:-1]):continue
                if path.name.endswith(('.mpf','.bak')):continue
                if name=='cpu5_s15_d0_program' and parts[:2]==('simulator','stage') and 'build' in parts[2:-1]:continue
                rel=path.relative_to(ROOT).as_posix();data=path.read_bytes()
                assert rel not in entries;entries[rel]=digest(data);archive.writestr(rel,data)
        for name in SOURCES:
            data=(ROOT/name).read_bytes();entries['tested_sources/'+name]=digest(data);archive.writestr('tested_sources/'+name,data)
    with zipfile.ZipFile(a.dest/'raw_evidence.zip') as archive:
        assert archive.testzip() is None and len(archive.namelist())==len(set(archive.namelist())) and set(archive.namelist())==set(entries)
        for name,expected in entries.items():assert digest(archive.read(name))==expected,name
    write(a.dest/'archive_entries.json',entries)
    write(a.dest/'selected_runs.json',selected)
    manifest={p.name:digest(p.read_bytes()) for p in sorted(a.dest.iterdir()) if p.is_file() and p.name!='manifest.json'}
    write(a.dest/'manifest.json',dict(status='FROZEN',files=manifest,archive_entries=len(entries),
          baseline_dependency=dict(commit=BASE,path=reference['baseline_evidence'],raw_archive_sha256=reference['baseline_raw_archive_sha256'],
                                   manifest_sha256=reference['baseline_manifest_sha256'],archive_entries=reference['baseline_archive_entries'],simulations_rerun=False)))
    print(json.dumps(dict(status='FROZEN',source_count=len(identity),archive_entries=len(entries),archive_bytes=(a.dest/'raw_evidence.zip').stat().st_size,
                         referenced_old_archive_entries=reference['baseline_archive_entries'])))


if __name__=='__main__':main()
