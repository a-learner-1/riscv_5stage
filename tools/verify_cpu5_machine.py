"""Verify CPU5 machine devices, natural timer IRQs and all prior CPU5 stages."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_mmio import SOURCES as MMIO_SOURCES, PERIPHERALS, same_sources, read, sha, negatives

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s11_verification'
BASE = 'd74836b60f5d313cff408956e373b0a7aa79cc1a'
MACHINE_SOURCES = [
    'rtl/machine_timer.v', 'rtl/cpu5_machine_endpoint.v', 'rtl/cpu5_machine_router.v',
    'tb/cpu5_machine_endpoint_tb.v', 'tb/cpu5_machine_router_tb.v',
    'tb/cpu5_machine_control_tb.v', 'tb/cpu5_machine_program_tb.v',
    'run_cpu5_machine_endpoint.do', 'run_cpu5_machine_router.do',
    'run_cpu5_machine_control.do', 'run_cpu5_machine_program.do',
    'tools/run_cpu5_machine_endpoint.py', 'tools/run_cpu5_machine_router.py',
    'tools/run_cpu5_machine_control.py', 'tools/run_cpu5_machine_program.py',
    'tools/cpu5_machine_reference.py', 'tools/verify_cpu5_machine_mutations.py',
    'tools/verify_cpu5_machine.py', 'tools/freeze_cpu5_machine.py',
    'docs/cpu5_machine_contract_20261024.md',
]
SOURCES = sorted(set(MMIO_SOURCES + MACHINE_SOURCES))
LEGACY = ['rtl/cpu_top.v', 'rtl/if_stage.v', 'rtl/rv32m_unit.v'] + PERIPHERALS + [
    'rtl/machine_timer.v', 'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_ram_owner.v',
    'rtl/cpu5_csr_unit.v', 'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_mmio_endpoint.v', 'rtl/cpu5_mmio_router.v']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference', action='store_true', help='reuse completed MMIO compatibility only on every tested-source SHA match')
    ap.add_argument('--reuse-suites', action='store_true', help='reuse completed machine suites only on every tested-source SHA match')
    ap.add_argument('--allow-core-extension', action='store_true', help='authorize only cpu5_alu_pipeline.v to evolve for a later opt-in core stage; keep all functional and source SHA gates')
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = {p: sha(ROOT / p) for p in SOURCES}
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', source_sha256=before), indent=2) + '\n', encoding='utf-8')
    processes = []

    def execute(name, script, reuse, path):
        if reuse:
            record = read(path)
            same_sources(record)
            assert record['status'] == ('PARTIAL VERIFIED: CPU5 minimum MMIO and ordered non-RAM' if name == 'reference' else 'PASS')
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=True, source_sha_checks=len(record['source_sha256'])))
        else:
            command = [sys.executable, '-B', script, '--vsim', str(a.vsim)]
            p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                               encoding='utf-8', errors='replace', timeout=3000)
            output = p.stdout + p.stderr
            (OUT / (name + '_console.log')).write_text(output, encoding='utf-8', newline='')
            assert p.returncode == 0 and 'Traceback (most recent call last)' not in output, (name, p.returncode, output[-8000:])
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=False, command=command))
        print(name, 'PASS', flush=True)

    reference_path = ROOT / 'build/cpu5_s10_verification/verification.json'
    execute('reference', 'tools/verify_cpu5_mmio.py', a.reuse_reference, reference_path)
    reference = read(reference_path)
    same_sources(reference)
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in reference['processes'])
    scripts = dict(endpoint='tools/run_cpu5_machine_endpoint.py', router='tools/run_cpu5_machine_router.py',
                   control='tools/run_cpu5_machine_control.py', program='tools/run_cpu5_machine_program.py',
                   mutations='tools/verify_cpu5_machine_mutations.py')
    suites = {}
    for name, script in scripts.items():
        path = ROOT / f'build/cpu5_s11_machine_{name}/verification.json'
        execute(name, script, a.reuse_suites, path)
        suites[name] = read(path)
        assert suites[name]['status'] == 'PASS'
        same_sources(suites[name])
    endpoint, router, control, program, mutations = (suites[k] for k in scripts)
    negatives(endpoint, 21, 2)
    negatives(router, 4, 0)
    negatives(mutations, 15, 3)
    e = endpoint['positive']['summary']
    assert e['configurations'] == 4 and e['checks'] == 1152952 and e['accepted'] == 14496
    assert e['accepted'] == e['fires'] + e['canceled_before_fire']
    assert e['fires'] == e['responses'] + e['canceled_after_fire']
    assert e['canceled_before_fire'] == e['canceled_after_fire'] == 4
    assert e['errors'] == 14394 and e['legal_ops'] == 98
    assert e['timer_writes'] == 34 and e['software_writes'] == 12 and e['held_cycles'] == 25128
    assert e['carries'] == 4 and e['wraps'] == 2
    assert len(endpoint['positive']['summaries']) == 4
    r = router['positive']['summary']
    assert r['accepts'] == r['responses'] + r['reset_drops'] == 19
    assert r['reset_drops'] == 4 and r['external_accepts'] == 5 and r['machine_effects'] == 7
    c = control['positive']['summary']
    assert c['cases'] == control['cases'] == 18 and c['retired'] == c['wb'] == 778
    assert c['irqs'] == 10 and c['traps'] == 24 and c['requests'] == c['responses'] == 86
    assert c['checks'] == 17448 and c['natural_wait_edges'] == 452
    assert len(control['positive']['cases']) == 18
    for case in control['positive']['cases']:
        assert case['retired'] == case['wb'] and case['requests'] == case['responses']
        if case['scenario'] == 8:
            assert case['natural_wait_edges'] == 226 and case['natural_irq_time'] == 253
    assert program['case_count'] == 16 and program['total_retired'] == program['total_wb_packets'] == 2416
    assert program['total_irqs'] == 64 and program['total_sync_traps'] == 16
    assert program['total_d_requests'] == program['total_d_responses'] == 768
    assert program['total_requests'] == program['total_responses'] == 2899
    assert program['total_device_effects'] == 304 and program['total_timer_writes'] == 96
    assert program['total_software_writes'] == 64 and program['total_normal_effects'] == 32
    assert program['total_gpio_writes'] == 16 and program['total_cycle_checks'] == 8808
    assert sum(c['immediate_post_mret_irqs'] for c in program['cases']) == 32
    assert program['decoder_selftest']['fixed_word_checks'] == 15
    assert program['decoder_selftest']['device_state_checks'] == 5 and program['decoder_selftest']['total_checks'] == 20
    assert program['negative_evidence_tests']['rejected_count'] == 14 and program['negative_evidence_tests']['good_inputs_unchanged']
    authorized_core_extension = ['rtl/cpu5_alu_pipeline.v'] if a.allow_core_extension else []
    legacy_checked = [path for path in LEGACY if path not in authorized_core_extension]
    for path in legacy_checked:
        original = subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT)
        assert original == (ROOT / path).read_bytes().replace(b'\r\n', b'\n'), path
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'verification changed source'
    result = dict(status='PARTIAL VERIFIED: CPU5 machine timer and software interrupt devices', source_sha256=before,
                  sources_unchanged=True, processes=processes, suites=suites,
                  compatibility_reference='build/cpu5_s10_verification/verification.json',
                  legacy_components_unchanged=legacy_checked, authorized_core_extension=authorized_core_extension,
                  rtl_mutations_rejected=40, parameter_guards_rejected=5,
                  BP_Stats_devices='NOT IMPLEMENTED', FENCE='NOT ENABLED IN THIS COMPATIBILITY CONFIGURATION' if a.allow_core_extension else 'NOT IMPLEMENTED',
                  cache_AXI_SoC='NOT INTEGRATED', full_A01_A16='NOT RUN', STA='NOT RUN', board='NOT RUN', performance_claim='NONE')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(dict(status=result['status'], sources=len(before), rtl_mutations_rejected=40, parameter_guards_rejected=5)))


if __name__ == '__main__':
    main()
