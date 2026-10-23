"""Verify opt-in CPU5 machine IRQs, source identity and all prior CPU5 stages."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_m import SOURCES as M_SOURCES

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s9_verification'
BASE = 'baa2275d5a2ccb204f23b37414bc7a59f746ecaa'
LEGACY_PORTS = 'docs/cpu5_irq_legacy_ports_20261024.json'
IRQ_SOURCES = [
    'rtl/cpu5_irq_ctrl.v', 'tb/cpu5_irq_ctrl_tb.v',
    'tb/cpu5_irq_control_tb.v', 'tb/cpu5_irq_program_tb.v',
    'run_cpu5_irq_ctrl.do', 'run_cpu5_irq_control.do', 'run_cpu5_irq_program.do',
    'tools/run_cpu5_irq_ctrl.py', 'tools/run_cpu5_irq_control.py',
    'tools/run_cpu5_irq_program.py', 'tools/cpu5_irq_reference.py',
    'tools/verify_cpu5_irq_mutations.py', 'tools/verify_cpu5_irq.py',
    'tools/freeze_cpu5_irq.py', 'docs/cpu5_irq_contract_20261024.md', LEGACY_PORTS,
]
SOURCES = sorted(set(M_SOURCES + IRQ_SOURCES))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def same_sources(record):
    assert record.get('sources_unchanged', record.get('good_sources_unchanged', False))
    assert all(sha(ROOT / p) == h for p, h in record['source_sha256'].items()), 'tested source changed; rerun suite'


def legacy_ports():
    proof = read(ROOT / LEGACY_PORTS)
    assert proof['base_commit'] == BASE and len(proof['adaptations']) == 14
    paths = set()
    for item in proof['adaptations']:
        path = item['path']
        assert path.startswith('tb/cpu5_') and path not in paths
        paths.add(path)
        data = (ROOT / path).read_bytes().replace(b'\r\n', b'\n')
        old = item['old'].encode(); new = item['new'].encode()
        assert old == b' dut(' and data.count(new) == 1
        base = subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT)
        assert data.replace(new, old, 1) == base, ('legacy test stimulus/assertions changed', path)
        assert hashlib.sha256(base).hexdigest() == item['before_lf_sha256']
        assert hashlib.sha256(data).hexdigest() == item['after_lf_sha256']
    return dict(status='PASS', reversible_explicit_zero_connections=14, stimuli_and_assertions_unchanged=True)


def negatives(suite, rtl, guards):
    assert suite['compile_zero_warning_error']
    records = suite['specimens']
    assert len(records) == rtl + guards and len({r['name'] for r in records}) == len(records)
    assert sum(r['kind'] == 'rtl_semantic' for r in records) == rtl
    assert sum(r['kind'] == 'parameter_guard' for r in records) == guards
    for record in records:
        c = record['compile']
        assert record['status'] == 'REJECTED' and c['status'] == 'PASS'
        assert c['exit_code'] == c['warnings'] == c['errors'] == 0
        assert record['simulation_exit_code'] != 0 and '** Fatal:' in record['actual_assertion']
        tokens = record['expected_assertion']
        if isinstance(tokens, str):
            tokens = [tokens]
        assert any(token in record['actual_assertion'] for token in tokens)
        change = record['changed_source']
        directory = ROOT / record['directory']
        if change:
            assert change['good_sha256'] != change['bad_sha256']
            assert sha(directory / change['path']) == change['bad_sha256']
            if record['kind'] == 'rtl_semantic':
                assert change['path'].startswith('rtl/')
        else:
            # Unit guards are separately selected tops already containing an
            # illegal parameter. Their RTL remains good, unlike mutants.
            assert record['kind'] == 'parameter_guard'
            assert record['name'] in ('controller_invalid_source_boolean', 'bank_invalid_source_boolean')
            top = 'cpu5_irq_ctrl_guard_tb' if record['name'].startswith('controller_') else 'cpu5_irq_bank_guard_tb'
            assert top in (directory / 'simulate.do').read_text(encoding='utf-8')
            for path, expected in record['source_sha256'].items():
                assert sha(directory / path) == expected == sha(ROOT / path)
        for path, expected in record['retained_artifact_sha256'].items():
            assert sha(directory / path) == expected


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference', action='store_true', help='reuse completed M compatibility only on every tested-source SHA match')
    ap.add_argument('--reuse-suites', action='store_true', help='reuse completed IRQ suites only on every tested-source SHA match')
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = {p: sha(ROOT / p) for p in SOURCES}
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', source_sha256=before), indent=2) + '\n', encoding='utf-8')
    processes = []

    def execute(name, script, reuse, record_path):
        if reuse:
            record = read(record_path)
            same_sources(record)
            assert record['status'] == 'PASS' or (name == 'reference' and record['status'] == 'PARTIAL VERIFIED: CPU5 RV32M with generation owner')
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=True,
                                  source_sha_checks=len(record['source_sha256'])))
        else:
            command = [sys.executable, '-B', script, '--vsim', str(a.vsim)]
            p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                               encoding='utf-8', errors='replace', timeout=1800)
            output = p.stdout + p.stderr
            (OUT / (name + '_console.log')).write_text(output, encoding='utf-8', newline='')
            assert p.returncode == 0 and 'Traceback (most recent call last)' not in output, (name, p.returncode, output[-8000:])
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=False, command=command))
        print(name, 'PASS', flush=True)

    reference_path = ROOT / 'build/cpu5_s8_verification/verification.json'
    execute('reference', 'tools/verify_cpu5_m.py', a.reuse_reference, reference_path)
    reference = read(reference_path)
    same_sources(reference)
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in reference['processes'])
    scripts = dict(ctrl='tools/run_cpu5_irq_ctrl.py', control='tools/run_cpu5_irq_control.py',
                   program='tools/run_cpu5_irq_program.py', mutations='tools/verify_cpu5_irq_mutations.py')
    suites = {}
    for name, script in scripts.items():
        path = ROOT / f'build/cpu5_s9_irq_{name}/verification.json'
        execute(name, script, a.reuse_suites, path)
        suites[name] = read(path)
        assert suites[name]['status'] == 'PASS'
        same_sources(suites[name])
    unit, control, program, mutations = (suites[k] for k in scripts)
    assert unit['source_configurations'] == 8 and unit['controller_checks'] >= 4888 and unit['bank_checks'] >= 1112
    assert len(unit['positive']['summaries']['ctrl']) == len(unit['positive']['summaries']['bank']) == 8
    negatives(unit, 15, 2)
    assert control['cases'] == 54 and control['retired'] == 284 and control['irqs'] == 44 and control['sync_traps'] == 6
    assert all(m['retired'] == m['wb'] and m['requests'] == m['responses'] for m in control['modes'])
    assert control['m_issued'] == control['m_completed'] + control['m_drained'] == 6
    assert program['case_count'] == 16 and program['total_retired'] == program['total_wb_packets'] == 1088
    assert program['total_irqs'] == 48 and program['total_m_drains'] == 16
    assert program['total_d_requests'] == program['total_d_responses'] == 224
    assert program['total_i_requests'] == program['total_i_responses']
    assert program['total_stale_if_errors'] == 16
    assert all(c['m_issues'] == c['m_starts'] == c['m_completions'] + c['m_drains'] == 5 for c in program['cases'])
    assert sum(c['cycle_audit']['immediate_post_mret_irqs'] for c in program['cases']) == 32
    assert program['decoder_selftest']['fixed_word_checks'] == 12
    assert program['negative_evidence_tests']['rejected_count'] == 11 and program['negative_evidence_tests']['good_inputs_unchanged']
    assert mutations['good_reference']['status'] == 'PASS'
    negatives(mutations, 22, 3)
    port_proof = legacy_ports()
    for path in ('rtl/cpu_top.v', 'rtl/if_stage.v', 'rtl/rv32m_unit.v'):
        original = subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT)
        assert original == (ROOT / path).read_bytes().replace(b'\r\n', b'\n'), path
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'verification changed source'
    result = dict(status='PARTIAL VERIFIED: CPU5 synchronized machine IRQ', source_sha256=before,
                  sources_unchanged=True, processes=processes, suites=suites,
                  compatibility_reference='build/cpu5_s8_verification/verification.json',
                  legacy_port_proof=port_proof, legacy_cpu_top_if_rv32m_unchanged=True,
                  MMIO='NOT IMPLEMENTED; raw level pins and device fixtures only', FENCE='NOT IMPLEMENTED',
                  cache_AXI_SoC='NOT INTEGRATED', full_A01_A16='NOT RUN', STA='NOT RUN', board='NOT RUN', performance_claim='NONE')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(dict(status=result['status'], sources=len(before), rtl_mutants_rejected=37, parameter_guards_rejected=5)))


if __name__ == '__main__':
    main()
