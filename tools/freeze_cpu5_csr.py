"""Freeze verified CPU5 CSR/MRET raw evidence without simulator work libraries."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

from verify_cpu5_csr import ROOT, SOURCES


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--dest', type=Path, default=ROOT / 'docs/evidence/cpu5_csr_20261023')
    a = ap.parse_args()
    verified = ROOT / 'build/cpu5_s7_verification/verification.json'
    result = json.loads(verified.read_text(encoding='utf-8'))
    assert result['sources_unchanged']
    assert result['status'] == 'PARTIAL VERIFIED: CPU5 minimal machine CSR/MRET'
    assert all(s['status'] == 'PASS' for s in result['suites'].values())
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in result['processes'])
    final_mutation_run = result['suites']['mutations']['run_id']
    for rel, expected in result['source_sha256'].items():
        assert digest((ROOT / rel).read_bytes()) == expected, ('source changed', rel)
    a.dest.mkdir(parents=True, exist_ok=True)
    identities = {}
    for rel in sorted(set(SOURCES + ['tools/freeze_cpu5_csr.py'])):
        data = (ROOT / rel).read_bytes()
        identities[rel] = dict(raw_sha256=digest(data), lf_sha256=digest(data.replace(b'\r\n', b'\n')))
    (a.dest / 'source_identity.json').write_text(json.dumps(dict(
        base_commit='5be17af25087ab82eb85d913b4e37193b83db164', sources=identities), indent=2) + '\n', encoding='utf-8')
    shutil.copyfile(verified, a.dest / 'verification.json')
    entry_hashes = {}
    with zipfile.ZipFile(a.dest / 'raw_evidence.zip', 'w', compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for directory in sorted((ROOT / 'build').glob('cpu5_s[1-7]_*')):
            if not directory.is_dir():
                continue
            for path in sorted(directory.rglob('*')):
                if not path.is_file():
                    continue
                parts = path.relative_to(directory).parts
                if directory.name == 'cpu5_s7_csr_mutations' and len(parts) > 2 and parts[0] == 'runs' and parts[1] != final_mutation_run:
                    continue
                # ModelSim database files are reproducible tool caches; raw
                # transcripts, bad RTL, traces, vectors and waves are retained.
                if any(part in ('work', 'worklib', '__pycache__') or part.endswith('_work') for part in parts[:-1]):
                    continue
                if path.name.endswith(('.mpf', '.bak')):
                    continue
                rel = path.relative_to(ROOT).as_posix()
                data = path.read_bytes()
                entry_hashes[rel] = digest(data)
                archive.writestr(rel, data)
        for rel in sorted(identities):
            data = (ROOT / rel).read_bytes()
            entry_hashes['tested_sources/' + rel] = digest(data)
            archive.writestr('tested_sources/' + rel, data)
    with zipfile.ZipFile(a.dest / 'raw_evidence.zip') as archive:
        assert archive.testzip() is None
    (a.dest / 'archive_entries.json').write_text(json.dumps(entry_hashes, indent=2) + '\n', encoding='utf-8')
    frozen = {path.name: digest(path.read_bytes()) for path in sorted(a.dest.iterdir())
              if path.is_file() and path.name != 'manifest.json'}
    (a.dest / 'manifest.json').write_text(json.dumps(dict(status='FROZEN', files=frozen,
        archive_entries=len(entry_hashes)), indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='FROZEN', files=len(frozen), archive_entries=len(entry_hashes),
                         archive_bytes=(a.dest / 'raw_evidence.zip').stat().st_size)))


if __name__ == '__main__':
    main()
