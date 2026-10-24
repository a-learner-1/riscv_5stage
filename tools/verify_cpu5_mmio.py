"""Verify CPU5 ordered MMIO, real device effects and all prior CPU5 stages."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_irq import SOURCES as IRQ_SOURCES, same_sources, read, sha

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s10_verification'
BASE = 'fb5d1a48776b87976b1bdcbe0c98a301d757b753'
PERIPHERALS = ['rtl/uart_tx.v', 'rtl/uart_rx.v', 'rtl/uart_rx_fifo.v', 'rtl/uart_rx_mmio.v', 'rtl/gpio_mmio.v']
MMIO_SOURCES = PERIPHERALS + [
    'rtl/cpu5_mmio_endpoint.v', 'rtl/cpu5_mmio_router.v',
    'tb/cpu5_mmio_endpoint_tb.v', 'tb/cpu5_mmio_router_tb.v',
    'tb/cpu5_mmio_control_tb.v', 'tb/cpu5_mmio_program_tb.v',
    'run_cpu5_mmio_endpoint.do', 'run_cpu5_mmio_router.do',
    'run_cpu5_mmio_control.do', 'run_cpu5_mmio_program.do',
    'tools/run_cpu5_mmio_endpoint.py', 'tools/run_cpu5_mmio_router.py',
    'tools/run_cpu5_mmio_control.py', 'tools/run_cpu5_mmio_program.py',
    'tools/cpu5_mmio_reference.py', 'tools/verify_cpu5_mmio_mutations.py',
    'tools/verify_cpu5_mmio.py', 'tools/freeze_cpu5_mmio.py',
    'docs/cpu5_mmio_contract_20261024.md',
]
SOURCES = sorted(set(IRQ_SOURCES + MMIO_SOURCES))


def negatives(suite, rtl, guards):
    assert suite['compile_zero_warning_error']
    records = suite['specimens']
    assert len(records) == rtl + guards and len({r['name'] for r in records}) == len(records)
    assert sum(r['kind'] == 'rtl_semantic' for r in records) == rtl
    assert sum(r['kind'] == 'parameter_guard' for r in records) == guards
    for record in records:
        c = record['compile']
        assert c['status'] == 'PASS' and c['exit_code'] == c['warnings'] == c['errors'] == 0
        assert record['status'] == 'REJECTED' and record['simulation_exit_code'] != 0
        assert '** Fatal:' in record['actual_assertion']
        tokens = record['expected_assertion']
        if isinstance(tokens, str):
            tokens = [tokens]
        assert any(token in record['actual_assertion'] for token in tokens)
        directory = ROOT / record['directory']
        change = record['changed_source']
        if change:
            assert change['good_sha256'] == sha(ROOT / change['path'])
            assert change['good_sha256'] != change['bad_sha256'] == sha(directory / change['path'])
            if record['kind'] == 'rtl_semantic':
                assert change['path'].startswith('rtl/')
        else:
            assert record['kind'] == 'parameter_guard'
        sources = record.get('specimen_source_sha256', record.get('source_sha256'))
        assert sources
        for path, expected in sources.items():
            assert sha(directory / path) == expected
            if not change or path != change['path']:
                assert sha(ROOT / path) == expected
        for path, expected in record['retained_artifact_sha256'].items():
            assert sha(directory / path) == expected
    positive = suite.get('positive', suite.get('good_reference'))
    assert positive['status'] == 'PASS' and positive['compile']['exit_code'] == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference', action='store_true', help='reuse complete IRQ compatibility only on every tested-source SHA match')
    ap.add_argument('--reuse-suites', action='store_true', help='reuse complete MMIO suites only on every tested-source SHA match')
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = {p: sha(ROOT / p) for p in SOURCES}
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', source_sha256=before), indent=2) + '\n', encoding='utf-8')
    processes = []

    def execute(name, script, reuse, path):
        if reuse:
            record = read(path)
            same_sources(record)
            assert record['status'] == ('PARTIAL VERIFIED: CPU5 synchronized machine IRQ' if name == 'reference' else 'PASS')
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=True, source_sha_checks=len(record['source_sha256'])))
        else:
            command = [sys.executable, '-B', script, '--vsim', str(a.vsim)]
            p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                               encoding='utf-8', errors='replace', timeout=2400)
            output = p.stdout + p.stderr
            (OUT / (name + '_console.log')).write_text(output, encoding='utf-8', newline='')
            assert p.returncode == 0 and 'Traceback (most recent call last)' not in output, (name, p.returncode, output[-8000:])
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=False, command=command))
        print(name, 'PASS', flush=True)

    reference_path = ROOT / 'build/cpu5_s9_verification/verification.json'
    execute('reference', 'tools/verify_cpu5_irq.py', a.reuse_reference, reference_path)
    reference = read(reference_path)
    same_sources(reference)
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in reference['processes'])
    scripts = dict(endpoint='tools/run_cpu5_mmio_endpoint.py', router='tools/run_cpu5_mmio_router.py',
                   control='tools/run_cpu5_mmio_control.py', program='tools/run_cpu5_mmio_program.py',
                   mutations='tools/verify_cpu5_mmio_mutations.py')
    suites = {}
    for name, script in scripts.items():
        path = ROOT / f'build/cpu5_s10_mmio_{name}/verification.json'
        execute(name, script, a.reuse_suites, path)
        suites[name] = read(path)
        assert suites[name]['status'] == 'PASS'
        same_sources(suites[name])
    endpoint, router, control, program, mutations = (suites[k] for k in scripts)
    negatives(endpoint, 18, 3)
    negatives(router, 4, 0)
    negatives(mutations, 17, 3)
    e = endpoint['positive']['summary']
    assert e['checks'] >= 40455 and e['accepted'] == 860 and e['errors'] == 808
    assert e['accepted'] == e['fires'] + e['canceled_before_fire']
    assert e['fires'] == e['responses'] + 1 and e['resets'] == 3
    assert e['tx_sends'] == e['physical_tx'] == 7 and e['rx_pops'] == 2 and e['gpio_writes'] == 10
    r = router['positive']['summary']
    assert r['accepts'] == r['responses'] + r['reset_drops'] == 9
    assert r['reset_drops'] == 2 and r['external_accepts'] == 4 and r['local_effects'] == 4 and r['gpio_effects'] == 2
    assert control['cases'] == 46 and control['retired'] == 210 and control['irqs'] == 10 and control['sync_traps'] == 14
    assert control['io_reads'] == 22 and control['io_writes'] == 6
    for mode in control['modes']:
        assert mode['retired'] == mode['wb']
        assert mode['requests'] == mode['responses'] + mode['reset_abandoned_requests'] == 19
        assert mode['reset_abandoned_requests'] == 1 and mode['reset_phases'] == 3
    assert program['case_count'] == 16 and program['total_retired'] == program['total_wb_packets'] == 1489
    assert program['total_irqs'] == 16 and program['total_sync_traps'] == 32
    assert program['total_d_requests'] == program['total_d_responses'] == 560
    assert program['total_requests'] == program['total_responses'] == 1828
    assert program['total_local_effects'] == 224 and program['total_gpio_writes'] == 80
    assert program['total_rx_pops'] == 32 and program['total_tx_events'] == 16 and program['total_cycle_checks'] == 7377
    assert program['decoder_selftest']['fixed_word_checks'] == 15
    assert program['negative_evidence_tests']['rejected_count'] == 12 and program['negative_evidence_tests']['good_inputs_unchanged']
    legacy = ['rtl/cpu_top.v', 'rtl/if_stage.v', 'rtl/rv32m_unit.v'] + PERIPHERALS
    for path in legacy:
        original = subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT)
        assert original == (ROOT / path).read_bytes().replace(b'\r\n', b'\n'), path
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'verification changed source'
    result = dict(status='PARTIAL VERIFIED: CPU5 minimum MMIO and ordered non-RAM', source_sha256=before,
                  sources_unchanged=True, processes=processes, suites=suites,
                  compatibility_reference='build/cpu5_s9_verification/verification.json',
                  legacy_components_unchanged=legacy, rtl_mutations_rejected=39, parameter_guards_rejected=6,
                  timer_MSIP_BP_Stats_devices='NOT IMPLEMENTED', FENCE='NOT IMPLEMENTED',
                  cache_AXI_SoC='NOT INTEGRATED', full_A01_A16='NOT RUN', STA='NOT RUN', board='NOT RUN', performance_claim='NONE')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(dict(status=result['status'], sources=len(before), rtl_mutations_rejected=39, parameter_guards_rejected=6)))


if __name__ == '__main__':
    main()
