"""Verify CPU5 opt-in RV32M/owner, fresh functional evidence and compatibility."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_csr import SOURCES as CSR_SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s8_verification'
M_SOURCES = [
    'rtl/rv32m_unit.v', 'rtl/cpu5_m_owner.v',
    'tb/cpu5_m_owner_tb.v', 'tb/cpu5_m_control_tb.v', 'tb/cpu5_m_program_tb.v',
    'run_cpu5_m_owner.do', 'run_cpu5_m_control.do', 'run_cpu5_m_program.do',
    'tools/run_cpu5_m_owner.py', 'tools/run_cpu5_m_control.py', 'tools/run_cpu5_m_program.py',
    'tools/cpu5_m_reference.py', 'tools/verify_cpu5_m_mutations.py',
    'tools/verify_cpu5_m.py', 'tools/freeze_cpu5_m.py', 'docs/cpu5_m_contract_20261023.md',
]
SOURCES = sorted(set(CSR_SOURCES + M_SOURCES))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    parser.add_argument('--reuse-reference', action='store_true', help='only reuse complete CSR compatibility on exact tested-source SHA match')
    a = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = {p: sha(ROOT / p) for p in SOURCES}
    commands, processes = [], []
    if a.reuse_reference:
        reference = read(ROOT / 'build/cpu5_s7_verification/verification.json')
        assert reference['sources_unchanged'] and all(p['exit_code'] == 0 for p in reference['processes'])
        assert all(sha(ROOT / p) == h for p, h in reference['source_sha256'].items()), 'reference source changed; run fresh compatibility'
        processes.append(dict(name='reference', status='PASS', exit_code=0, reused=True,
                              source_sha_checks=len(reference['source_sha256'])))
    else:
        commands.append(('reference', [sys.executable, '-B', 'tools/verify_cpu5_csr.py', '--vsim', str(a.vsim)]))
    for suite in ('owner', 'control', 'program'):
        commands.append((suite, [sys.executable, '-B', f'tools/run_cpu5_m_{suite}.py', '--vsim', str(a.vsim)]))
    commands.append(('mutations', [sys.executable, '-B', 'tools/verify_cpu5_m_mutations.py', '--vsim', str(a.vsim)]))
    for name, command in commands:
        p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=1200)
        output = p.stdout + p.stderr
        (OUT / (name + '_console.log')).write_text(output, encoding='utf-8', newline='')
        assert p.returncode == 0 and 'Traceback (most recent call last)' not in output, (name, p.returncode, output[-7000:])
        processes.append(dict(name=name, status='PASS', exit_code=p.returncode))
        print(name, 'PASS', flush=True)
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'verification changed source'
    suites = {name: read(ROOT / f'build/cpu5_s8_m_{name}/verification.json')
              for name in ('owner', 'control', 'program', 'mutations')}
    for name, suite in suites.items():
        assert suite['status'] == 'PASS', name
        assert suite.get('sources_unchanged', suite.get('good_sources_unchanged', False)), name
        assert all(sha(ROOT / p) == h for p, h in suite['source_sha256'].items()), name
    c = suites['control']
    assert c['cases'] >= 42 and c['m_issued'] == c['m_completed'] + c['m_drained']
    assert all(m['retired'] == m['wb'] and m['requests'] == m['responses'] for m in c['modes'])
    p = suites['program']
    assert p['case_count'] == 16 and p['total_retired'] == p['total_wb_packets']
    assert p['total_i_requests'] == p['total_i_responses']
    assert p['total_m_issues'] == p['total_m_starts'] == p['total_m_completions']
    assert p['total_d_requests'] == p['total_d_responses'] and p['decoder_selftest']['fixed_word_checks'] >= 42
    assert p['negative_evidence_tests']['rejected_count'] == 9 and p['negative_evidence_tests']['good_inputs_unchanged']
    owner = suites['owner']
    assert owner['rtl_mutations_rejected'] == 11 and owner['parameter_guards_rejected'] == 1
    assert owner['generation_guards_rejected'] == 1 and owner['compile_zero_warning_error']
    assert owner['positive']['summary']['starts'] == 152
    mutations = suites['mutations']
    assert mutations['rtl_semantic_rejected'] == 9 and mutations['parameter_guards_rejected'] == 1
    assert mutations['compile_zero_warning_error'] and mutations['good_reference']['status'] == 'PASS'
    legacy = subprocess.check_output(['git', 'show', '3d2644e248347429610ca46a555c2ed361c6e9ae:rtl/rv32m_unit.v'], cwd=ROOT)
    assert legacy == (ROOT / 'rtl/rv32m_unit.v').read_bytes().replace(b'\r\n', b'\n'), 'legacy M unit changed'
    result = dict(status='PARTIAL VERIFIED: CPU5 RV32M with generation owner',
                  source_sha256=before, sources_unchanged=True, processes=processes, suites=suites,
                  compatibility_reference='build/cpu5_s7_verification/verification.json',
                  legacy_rv32m_unchanged=True,
                  IRQ_MMIO='NOT IMPLEMENTED', FENCE='NOT IMPLEMENTED', cache_AXI_SoC='NOT INTEGRATED',
                  full_A01_A16='NOT RUN', STA='NOT RUN', board='NOT RUN', performance_claim='NONE')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status=result['status'], sources=len(before), suites={k: v['status'] for k, v in suites.items()})))


if __name__ == '__main__':
    main()
