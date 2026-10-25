"""Freeze tested CPU5 AXI sources, selected runs and raw semantic evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
from verify_cpu5_axi import ROOT, SOURCES, BASE, STATUS, same_sources, read, negative_gate, bridge_gate, control_gate, program_gate


def digest(data): return hashlib.sha256(data).hexdigest()


def write(path, data):
    path.write_text(json.dumps(data, indent=2)+'\n', encoding='utf-8', newline='\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dest', type=Path, default=ROOT/'docs/evidence/cpu5_axi_20261025')
    a = ap.parse_args()
    result = read(ROOT/'build/cpu5_s14_verification/verification.json')
    assert result['status'] == STATUS
    same_sources(result)
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in result['processes'])
    assert all(s['status'] == 'PASS' for s in result['suites'].values())
    bridge_gate(result['suites']['bridge']);control_gate(result['suites']['control']);program_gate(result['suites']['program'])
    negative_gate(result['suites']['mutations'], result['rtl_mutations_rejected'], result['parameter_guards_rejected'])
    if result['compatibility_recovery']:
        recovery=result['compatibility_recovery']
        assert digest((ROOT/recovery['record']).read_bytes())==recovery['record_sha256']
        parent=(ROOT/recovery['record']).parent
        assert digest((parent/'resume_procedure.py').read_bytes())==recovery['procedure_sha256']
        assert digest((parent/'prior_disk_full_console.log').read_bytes())==recovery['prior_disk_full_console_sha256']
    selected = {}
    for name in ('cpu5_s7_csr_mutations', 'cpu5_s8_m_owner', 'cpu5_s8_m_mutations',
                 'cpu5_s9_irq_ctrl', 'cpu5_s9_irq_mutations',
                 'cpu5_s10_mmio_endpoint', 'cpu5_s10_mmio_router', 'cpu5_s10_mmio_mutations',
                 'cpu5_s11_machine_endpoint', 'cpu5_s11_machine_router', 'cpu5_s11_machine_control', 'cpu5_s11_machine_mutations',
                 'cpu5_s12_fence_control', 'cpu5_s12_fence_decode', 'cpu5_s12_fence_mutations',
                 'cpu5_s13_cache_adapter', 'cpu5_s13_cache_control', 'cpu5_s13_cache_mutations',
                 'cpu5_s14_axi_bridge', 'cpu5_s14_axi_control', 'cpu5_s14_axi_mutations'):
        record = read(ROOT/'build'/name/'verification.json')
        assert record['status'] == 'PASS'
        same_sources(record)
        selected[name] = record['run_id']
    a.dest.mkdir(parents=True, exist_ok=True)
    identity = {}
    for name in SOURCES:
        data = (ROOT/name).read_bytes()
        identity[name] = dict(raw_sha256=digest(data), lf_sha256=digest(data.replace(b'\r\n',b'\n')))
    write(a.dest/'source_identity.json', dict(base_commit=BASE, sources=identity))
    write(a.dest/'verification.json', result)
    approved = {f'cpu5_s{stage}_{prefix}_'+name for stage,prefix in ((10,'mmio'),(11,'machine'),(12,'fence'),(13,'cache'),(14,'axi'))
                for name in ('endpoint','router','control','decode','adapter','bridge','program','mutations','program_negative_evidence')}
    approved.update(f'cpu5_s{stage}_verification' for stage in (10,11,12,13,14))
    approved.add('cpu5_s14_compatibility_resume')
    entries = {}
    with zipfile.ZipFile(a.dest/'raw_evidence.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for directory in sorted((ROOT/'build').iterdir()):
            if not directory.is_dir() or not re.match(r'^cpu5_s(?:[1-9]|10|11|12|13|14)_', directory.name): continue
            if directory.name.startswith(('cpu5_s10_','cpu5_s11_','cpu5_s12_','cpu5_s13_','cpu5_s14_')) and directory.name not in approved: continue
            for path in sorted(directory.rglob('*')):
                if not path.is_file(): continue
                parts = path.relative_to(directory).parts
                if directory.name in selected and len(parts)>2 and parts[0]=='runs' and parts[1]!=selected[directory.name]: continue
                if any(p in ('work','worklib','__pycache__') or p.endswith('_work') for p in parts[:-1]): continue
                if path.name.endswith(('.mpf','.bak')): continue
                # Program output was copied from the private simulator stage;
                # keep one canonical output set plus its staged sources/ini.
                if directory.name in ('cpu5_s12_fence_program','cpu5_s13_cache_program','cpu5_s14_axi_program') and parts[:2]==('simulator','stage') and 'build' in parts[2:-1]: continue
                rel = path.relative_to(ROOT).as_posix()
                data = path.read_bytes()
                assert rel not in entries
                entries[rel] = digest(data)
                archive.writestr(rel,data)
        for name in SOURCES:
            data = (ROOT/name).read_bytes()
            entries['tested_sources/'+name] = digest(data)
            archive.writestr('tested_sources/'+name,data)
    with zipfile.ZipFile(a.dest/'raw_evidence.zip') as archive:
        assert archive.testzip() is None and set(archive.namelist())==set(entries)
        for name,expected in entries.items(): assert digest(archive.read(name))==expected, name
    write(a.dest/'archive_entries.json', entries)
    write(a.dest/'selected_runs.json', selected)
    manifest = {p.name:digest(p.read_bytes()) for p in sorted(a.dest.iterdir()) if p.is_file() and p.name!='manifest.json'}
    write(a.dest/'manifest.json', dict(status='FROZEN',files=manifest,archive_entries=len(entries)))
    print(json.dumps(dict(status='FROZEN',source_count=len(identity),archive_entries=len(entries),archive_bytes=(a.dest/'raw_evidence.zip').stat().st_size)))


if __name__ == '__main__': main()
