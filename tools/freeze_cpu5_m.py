"""Freeze verified CPU5 RV32M/owner sources and raw evidence, without tool caches."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from verify_cpu5_m import ROOT, SOURCES


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8', newline='\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dest', type=Path, default=ROOT / 'docs/evidence/cpu5_m_20261023')
    a = parser.parse_args()
    verified = ROOT / 'build/cpu5_s8_verification/verification.json'
    result = json.loads(verified.read_text(encoding='utf-8'))
    assert result['status'] == 'PARTIAL VERIFIED: CPU5 RV32M with generation owner'
    assert result['sources_unchanged'] and all(s['status'] == 'PASS' for s in result['suites'].values())
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in result['processes'])
    for path, expected in result['source_sha256'].items():
        assert sha((ROOT / path).read_bytes()) == expected, ('tested source changed', path)
    selected_runs = {
        'cpu5_s7_csr_mutations': json.loads((ROOT / 'build/cpu5_s7_csr_mutations/verification.json').read_text())['run_id'],
        'cpu5_s8_m_owner': result['suites']['owner']['run_id'],
        'cpu5_s8_m_mutations': result['suites']['mutations']['run_id'],
    }
    a.dest.mkdir(parents=True, exist_ok=True)
    identity = {}
    for path in SOURCES:
        data = (ROOT / path).read_bytes()
        identity[path] = dict(raw_sha256=sha(data), lf_sha256=sha(data.replace(b'\r\n', b'\n')))
    write_json(a.dest / 'source_identity.json', dict(base_commit='3d2644e248347429610ca46a555c2ed361c6e9ae', sources=identity))
    # The raw original verification JSON is retained inside the archive too.
    write_json(a.dest / 'verification.json', result)
    entries = {}
    with zipfile.ZipFile(a.dest / 'raw_evidence.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for directory in sorted((ROOT / 'build').glob('cpu5_s[1-8]_*')):
            if not directory.is_dir():
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
                entries[rel] = sha(data)
                archive.writestr(rel, data)
        for path in SOURCES:
            data = (ROOT / path).read_bytes()
            entries['tested_sources/' + path] = sha(data)
            archive.writestr('tested_sources/' + path, data)
    with zipfile.ZipFile(a.dest / 'raw_evidence.zip') as archive:
        assert archive.testzip() is None
    write_json(a.dest / 'archive_entries.json', entries)
    manifest = {p.name: sha(p.read_bytes()) for p in sorted(a.dest.iterdir()) if p.is_file() and p.name != 'manifest.json'}
    write_json(a.dest / 'manifest.json', dict(status='FROZEN', files=manifest, archive_entries=len(entries)))
    print(json.dumps(dict(status='FROZEN', source_count=len(identity), archive_entries=len(entries), archive_bytes=(a.dest / 'raw_evidence.zip').stat().st_size)))


if __name__ == '__main__':
    main()
