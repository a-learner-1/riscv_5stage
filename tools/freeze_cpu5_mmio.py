"""Freeze verified CPU5 MMIO sources and raw evidence, without simulator caches."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
from verify_cpu5_mmio import ROOT, SOURCES, BASE, same_sources, read, negatives


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8', newline='\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dest', type=Path, default=ROOT / 'docs/evidence/cpu5_mmio_20261024')
    a = ap.parse_args()
    result = read(ROOT / 'build/cpu5_s10_verification/verification.json')
    assert result['status'] == 'PARTIAL VERIFIED: CPU5 minimum MMIO and ordered non-RAM'
    same_sources(result)
    assert all(s['status'] == 'PASS' for s in result['suites'].values())
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in result['processes'])
    negatives(result['suites']['endpoint'], 18, 3)
    negatives(result['suites']['router'], 4, 0)
    negatives(result['suites']['mutations'], 17, 3)
    selected_runs = {}
    for name in ('cpu5_s7_csr_mutations', 'cpu5_s8_m_owner', 'cpu5_s8_m_mutations',
                 'cpu5_s9_irq_ctrl', 'cpu5_s9_irq_mutations',
                 'cpu5_s10_mmio_endpoint', 'cpu5_s10_mmio_router', 'cpu5_s10_mmio_mutations'):
        record = read(ROOT / 'build' / name / 'verification.json')
        assert record['status'] == 'PASS'
        selected_runs[name] = record['run_id']
    a.dest.mkdir(parents=True, exist_ok=True)
    identity = {}
    for path in SOURCES:
        data = (ROOT / path).read_bytes()
        identity[path] = dict(raw_sha256=sha(data), lf_sha256=sha(data.replace(b'\r\n', b'\n')))
    write_json(a.dest / 'source_identity.json', dict(base_commit=BASE, sources=identity))
    write_json(a.dest / 'verification.json', result)
    entries = {}
    approved_s10 = {'cpu5_s10_mmio_' + name for name in ('endpoint', 'router', 'control', 'program', 'mutations', 'program_negative_evidence')}
    approved_s10.add('cpu5_s10_verification')
    with zipfile.ZipFile(a.dest / 'raw_evidence.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for directory in sorted((ROOT / 'build').iterdir()):
            if not directory.is_dir() or not re.match(r'^cpu5_s(?:[1-9]|10)_', directory.name):
                continue
            if directory.name.startswith('cpu5_s10_') and directory.name not in approved_s10:
                continue
            for path in sorted(directory.rglob('*')):
                if not path.is_file():
                    continue
                parts = path.relative_to(directory).parts
                if directory.name in selected_runs and len(parts) > 2 and parts[0] == 'runs' and parts[1] != selected_runs[directory.name]:
                    continue
                if any(p in ('work', 'worklib', '__pycache__') or p.endswith('_work') for p in parts[:-1]):
                    continue
                if path.name.endswith(('.mpf', '.bak')):
                    continue
                rel = path.relative_to(ROOT).as_posix()
                data = path.read_bytes()
                assert rel not in entries
                entries[rel] = sha(data)
                archive.writestr(rel, data)
        for path in SOURCES:
            data = (ROOT / path).read_bytes()
            entries['tested_sources/' + path] = sha(data)
            archive.writestr('tested_sources/' + path, data)
    with zipfile.ZipFile(a.dest / 'raw_evidence.zip') as archive:
        assert archive.testzip() is None and set(archive.namelist()) == set(entries)
        for name, expected in entries.items():
            assert sha(archive.read(name)) == expected, name
    write_json(a.dest / 'archive_entries.json', entries)
    write_json(a.dest / 'selected_runs.json', selected_runs)
    manifest = {p.name: sha(p.read_bytes()) for p in sorted(a.dest.iterdir()) if p.is_file() and p.name != 'manifest.json'}
    write_json(a.dest / 'manifest.json', dict(status='FROZEN', files=manifest, archive_entries=len(entries)))
    print(json.dumps(dict(status='FROZEN', source_count=len(identity), archive_entries=len(entries), archive_bytes=(a.dest / 'raw_evidence.zip').stat().st_size)))


if __name__ == '__main__':
    main()
