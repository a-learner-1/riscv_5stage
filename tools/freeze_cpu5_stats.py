"""Freeze selected fresh Stats runs and immutable S15/S14 reference identities."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from verify_cpu5_stats import ROOT,SOURCES,BASE,STATUS,RECORDS,GATES,same_sources,read,sha


def digest(data):return hashlib.sha256(data).hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--dest',type=Path,default=ROOT/'docs/evidence/cpu5_stats_20261025');a=ap.parse_args()
    result=read(ROOT/'build/cpu5_s16_verification/verification.json');assert result['status']==STATUS;same_sources(result)
    assert all(p['status']=='PASS' and p['exit_code']==0 for p in result['processes'])
    selected={}
    for name,gate in GATES.items():
        current=read(ROOT/RECORDS[name]);assert current==result['suites'][name],'selected suite differs from aggregate'
        gate(current)
        process=next(p for p in result['processes'] if p['name']==name)
        assert sha(ROOT/RECORDS[name])==process['record_sha256']
        if 'run_id' in current:selected[Path(RECORDS[name]).parent.name]=current['run_id']
    reference=result['reference'];same_sources(reference)
    assert reference==read(ROOT/'build/cpu5_s16_reference/verification.json') and not reference['simulations_rerun']
    dependency=ROOT/reference['baseline_evidence']
    assert sha(dependency/'manifest.json')==reference['baseline_manifest_sha256'] and sha(dependency/'raw_evidence.zip')==reference['baseline_raw_archive_sha256']
    transitive=reference['transitive_dependency'];old=ROOT/transitive['path']
    assert sha(old/'manifest.json')==transitive['manifest_sha256'] and sha(old/'raw_evidence.zip')==transitive['raw_archive_sha256']
    a.dest.mkdir(parents=True,exist_ok=True)
    identity={}
    for name in SOURCES:
        data=(ROOT/name).read_bytes();identity[name]=dict(raw_sha256=digest(data),lf_sha256=digest(data.replace(b'\r\n',b'\n')))
    write(a.dest/'source_identity.json',dict(base_commit=BASE,sources=identity));write(a.dest/'verification.json',result)
    approved=('cpu5_s16_reference','cpu5_s16_cycle_profile','cpu5_s16_stats_endpoint','cpu5_s16_profile_program',
              'cpu5_s16_profile_program_negative_evidence','cpu5_s16_stats_system','cpu5_s16_m_stats_window','cpu5_s16_stats_compat','cpu5_s16_stats_abi','cpu5_s16_verification')
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
                if name=='cpu5_s16_profile_program' and parts[:2]==('simulator','stage') and 'build' in parts[2:-1]:continue
                rel=path.relative_to(ROOT).as_posix();data=path.read_bytes();assert rel not in entries
                entries[rel]=digest(data);archive.writestr(rel,data)
        for name in SOURCES:
            data=(ROOT/name).read_bytes();entries['tested_sources/'+name]=digest(data);archive.writestr('tested_sources/'+name,data)
    with zipfile.ZipFile(a.dest/'raw_evidence.zip') as archive:
        assert archive.testzip() is None and len(archive.namelist())==len(set(archive.namelist())) and set(archive.namelist())==set(entries)
        for name,expected in entries.items():assert digest(archive.read(name))==expected,name
    write(a.dest/'archive_entries.json',entries);write(a.dest/'selected_runs.json',selected)
    manifest={p.name:sha(p) for p in sorted(a.dest.iterdir()) if p.is_file() and p.name!='manifest.json'}
    write(a.dest/'manifest.json',dict(status='FROZEN',files=manifest,archive_entries=len(entries),
        baseline_dependency=dict(commit=BASE,path=reference['baseline_evidence'],manifest_sha256=reference['baseline_manifest_sha256'],
            raw_archive_sha256=reference['baseline_raw_archive_sha256'],archive_entries=reference['baseline_archive_entries'],
            simulations_rerun=False,transitive_dependency=transitive)))
    print(json.dumps(dict(status='FROZEN',tested_sources=len(identity),archive_entries=len(entries),archive_bytes=(a.dest/'raw_evidence.zip').stat().st_size)))


if __name__=='__main__':main()
