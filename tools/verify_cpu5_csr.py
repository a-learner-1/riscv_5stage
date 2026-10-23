"""Reproduce the opt-in CPU5 minimal machine CSR/MRET stage and compatibility gates."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from verify_cpu5_trap import SOURCES as TRAP_SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s7_verification'
CSR_SOURCES = [
    'programs/data_handshake_blank.hex',
    'rtl/cpu5_csr_unit.v', 'tb/cpu5_csr_control_tb.v', 'tb/cpu5_csr_program_tb.v',
    'run_cpu5_csr_control.do', 'run_cpu5_csr_program.do',
    'tools/run_cpu5_csr_control.py', 'tools/run_cpu5_csr_program.py',
    'tools/cpu5_csr_reference.py', 'tools/verify_cpu5_csr_mutations.py',
    'tools/verify_cpu5_csr.py', 'tools/freeze_cpu5_csr.py', 'docs/cpu5_csr_contract_20261023.md',
]
SOURCES = sorted(set(TRAP_SOURCES + CSR_SOURCES))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference', action='store_true',
                    help='reuse baseline only when every recorded source SHA matches')
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = {rel: sha(ROOT / rel) for rel in SOURCES}
    processes = []
    commands = []
    if a.reuse_reference:
        ref = read(ROOT / 'build/cpu5_s6_verification/verification.json')
        assert ref['sources_unchanged'] and all(p['exit_code'] == 0 for p in ref['processes'])
        assert all(sha(ROOT / rel) == h for rel, h in ref['source_sha256'].items()), \
            'baseline source changed; rerun without --reuse-reference'
        processes.append(dict(name='reference', status='PASS', exit_code=0, reused=True,
                              source_sha_checks=len(ref['source_sha256'])))
    else:
        commands.append(('reference', [sys.executable, '-B', 'tools/verify_cpu5_trap.py',
                                       '--vsim', str(a.vsim)]))
    commands += [
        ('control', [sys.executable, '-B', 'tools/run_cpu5_csr_control.py', '--vsim', str(a.vsim)]),
        ('program', [sys.executable, '-B', 'tools/run_cpu5_csr_program.py', '--vsim', str(a.vsim)]),
        ('mutations', [sys.executable, '-B', 'tools/verify_cpu5_csr_mutations.py', '--vsim', str(a.vsim)]),
    ]
    for name, command in commands:
        p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=900)
        output = p.stdout + p.stderr
        (OUT / (name + '_console.log')).write_text(output, encoding='utf-8', newline='')
        assert p.returncode == 0, (name, p.returncode, output[-6000:])
        # Expected bad-RTL and invalid-parameter failures must be classified and
        # recorded by their dedicated runner, not silently accepted by this gate.
        assert 'Traceback (most recent call last)' not in output, (name, output[-6000:])
        processes.append(dict(name=name, status='PASS', exit_code=p.returncode))
        print(name, 'PASS', flush=True)
    assert before == {rel: sha(ROOT / rel) for rel in SOURCES}, 'verification changed source'
    suites = {name: read(ROOT / f'build/cpu5_s7_csr_{name}/verification.json')
              for name in ('control', 'program', 'mutations')}
    assert all(v['status'] == 'PASS' for v in suites.values())
    for name, suite in suites.items():
        assert suite.get('sources_unchanged', suite.get('good_sources_unchanged', False)), name
        assert all(sha(ROOT / rel) == h for rel, h in suite['source_sha256'].items()), name
    assert suites['control']['cases'] == 86
    assert all(m['retired'] == m['wb'] and m['requests'] == m['responses']
               for m in suites['control']['modes'])
    program = suites['program']
    assert program['case_count'] == 16 and program['total_retired'] == program['total_wb_packets']
    assert program['total_i_requests'] == program['total_i_responses']
    assert program['decoder_selftest']['fixed_word_checks'] >= 30
    assert program['negative_evidence_tests']['rejected_count'] == 9
    assert program['negative_evidence_tests']['good_inputs_unchanged']
    mutations = suites['mutations']
    assert mutations['rtl_semantic_rejected'] == 14 and mutations['parameter_guards_rejected'] == 4
    assert mutations['compile_zero_warning_error'] and mutations['good_reference']['status'] == 'PASS'
    result = dict(status='PARTIAL VERIFIED: CPU5 minimal machine CSR/MRET',
                  source_sha256=before, sources_unchanged=True, processes=processes,
                  suites=suites, compatibility_reference='build/cpu5_s6_verification/verification.json',
                  IRQ_M_MMIO='NOT IMPLEMENTED', cache_AXI_SoC='NOT INTEGRATED',
                  software_counters='NOT IMPLEMENTED', full_A01_A16='NOT RUN',
                  STA='NOT RUN', board='NOT RUN', performance_claim='NONE')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status=result['status'], sources=len(before),
                          suites={k: v['status'] for k, v in suites.items()})))


if __name__ == '__main__':
    main()
