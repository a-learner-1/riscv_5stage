"""Verify CPU5 base FENCE and the complete same-source compatibility chain."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from verify_cpu5_machine import SOURCES as MACHINE_SOURCES, same_sources, read, sha

ROOT = Path(__file__).resolve().parents[1]
BASE = 'ea03aba50e22ee9ca59c07abe3a7dd4f6f6905c3'
OUT = ROOT / 'build/cpu5_s12_verification'
FENCE_SOURCES = [
    'tb/cpu5_fence_control_tb.v', 'tb/cpu5_fence_decode_tb.v', 'tb/cpu5_fence_program_tb.v',
    'run_cpu5_fence_control.do', 'run_cpu5_fence_decode.do', 'run_cpu5_fence_program.do',
    'tools/run_cpu5_fence_control.py', 'tools/run_cpu5_fence_decode.py', 'tools/run_cpu5_fence_program.py',
    'tools/cpu5_fence_reference.py', 'tools/verify_cpu5_fence_mutations.py',
    'tools/verify_cpu5_fence.py', 'tools/freeze_cpu5_fence.py', 'docs/cpu5_fence_contract_20261024.md',
]
SOURCES = sorted(set(MACHINE_SOURCES + FENCE_SOURCES))
STATUS = 'PARTIAL VERIFIED: CPU5 base FENCE'


def negative_gate(record, semantics, guards):
    assert record['status'] == 'PASS'
    positive = record.get('positive', record.get('good_reference'))
    assert positive['status'] == 'PASS' and positive['simulation_exit_code'] == 0
    assert positive['compile']['status'] == 'PASS' and positive['compile']['exit_code'] == 0
    assert positive['compile']['warnings'] == positive['compile']['errors'] == 0
    good_directory = ROOT / positive['directory']
    assert good_directory.resolve().is_relative_to(ROOT.resolve() / 'build')
    for path, expected in positive['source_sha256'].items():
        assert sha(good_directory/path) == expected == sha(ROOT/path)
    for path, expected in positive['retained_artifact_sha256'].items(): assert sha(good_directory/path) == expected
    items = record['specimens']
    assert len(items) == semantics + guards
    assert sum(s['kind'] == 'rtl_semantic' for s in items) == semantics
    assert sum(s['kind'] == 'parameter_guard' for s in items) == guards
    for item in items:
        assert item['status'] == 'REJECTED' and item['simulation_exit_code'] != 0
        assert item['compile']['status'] == 'PASS' and item['compile']['exit_code'] == 0
        assert item['compile']['warnings'] == item['compile']['errors'] == 0
        tokens = item['expected_assertion']
        if isinstance(tokens, str): tokens = [tokens]
        assert any(token in item['actual_assertion'] for token in tokens)
        directory = ROOT / item['directory']
        assert directory.resolve().is_relative_to(ROOT.resolve() / 'build')
        assert sha(directory/'simulation_console.log') == item['simulation_console_sha256']
        assert item['actual_assertion'] in (directory/'simulation_console.log').read_text(encoding='utf-8')
        assert sha(directory/'compile_console.log') == item['compile']['console_sha256']
        change = item['changed_source']
        if item['kind'] == 'rtl_semantic':
            assert change['good_sha256'] == sha(ROOT/change['path'])
            assert change['good_sha256'] != change['bad_sha256'] == sha(directory/change['path'])
            assert change['path'].startswith('rtl/')
        else:
            assert change is None
        for path, expected in item['source_sha256'].items():
            assert sha(directory/path) == expected
            if not change or path != change['path']: assert sha(ROOT/path) == expected
        for path, expected in item['retained_artifact_sha256'].items(): assert sha(directory/path) == expected


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reuse-reference', action='store_true', help='reuse only complete machine compatibility with every tested source SHA matching')
    ap.add_argument('--reuse-suites', action='store_true', help='reuse only complete FENCE suites with every tested source SHA matching')
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = {p: sha(ROOT / p) for p in SOURCES}
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', source_sha256=before), indent=2)+'\n', encoding='utf-8')
    processes = []

    def execute(name, script, path, reuse, flags=()):
        if reuse:
            record = read(ROOT / path)
            same_sources(record)
            assert record['status'] == ('PARTIAL VERIFIED: CPU5 machine timer and software interrupt devices' if name == 'reference' else 'PASS')
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=True, source_sha_checks=len(record['source_sha256'])))
        else:
            command = [sys.executable, '-B', script, '--vsim', str(a.vsim), *flags]
            p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=3600)
            output = p.stdout + p.stderr
            (OUT / (name+'_console.log')).write_text(output, encoding='utf-8', newline='')
            assert p.returncode == 0 and 'Traceback (most recent call last)' not in output, (name, output[-9000:])
            processes.append(dict(name=name, status='PASS', exit_code=0, reused=False, command=command))
        record = read(ROOT / path)
        same_sources(record)
        print(name, 'PASS', flush=True)
        return record

    reference = execute('reference', 'tools/verify_cpu5_machine.py', 'build/cpu5_s11_verification/verification.json', a.reuse_reference, ('--allow-core-extension',))
    assert reference['authorized_core_extension'] == ['rtl/cpu5_alu_pipeline.v']
    assert all(p['status'] == 'PASS' and p['exit_code'] == 0 for p in reference['processes'])
    suites = {}
    for name, script in dict(control='tools/run_cpu5_fence_control.py', decode='tools/run_cpu5_fence_decode.py',
                             program='tools/run_cpu5_fence_program.py', mutations='tools/verify_cpu5_fence_mutations.py').items():
        suites[name] = execute(name, script, f'build/cpu5_s12_fence_{name}/verification.json', a.reuse_suites)
    c, d, p, m = (suites[k] for k in ('control','decode','program','mutations'))
    assert c['cases'] == 56 and c['retired'] == c['wb'] == 206 and c['fences'] == c['retire_barriers'] == 38
    assert c['irqs'] == 2 and c['sync_traps'] == 18 and c['requests'] == c['responses'] + c['reset_abandoned_requests'] == 28
    assert c['reset_abandoned_requests'] == 2 and c['fence_wait_edges'] >= 50
    assert c['fence_redirects'] == c['fence_m_background'] == 2
    assert len(d['positive']['summaries']) == 5
    assert sum(s['fences'] for s in d['positive']['summaries']) == 16572
    assert sum(s['retired'] for s in d['positive']['summaries']) == 16696
    negative_gate(d, 6, 0)
    negative_gate(m, 15, 2)
    assert p['case_count'] == 16 and p['total_retired'] == p['total_wb_packets'] == 2848
    assert p['total_irqs'] == 64 and p['total_sync_traps'] == 16
    assert p['total_d_requests'] == p['total_d_responses'] == 816
    assert p['total_requests'] == p['total_responses']
    assert p['total_ordered_successor_pairs'] == 128 and p['total_fence_retired'] > 0
    assert p['decoder_selftest']['fixed_word_checks'] >= 12
    assert p['negative_evidence_tests']['rejected_count'] == 18 and p['negative_evidence_tests']['good_inputs_unchanged']
    staged = Path(p['private_simulator_cwd'])
    assert staged.resolve().is_relative_to(ROOT.resolve() / 'build')
    for path, expected in p['source_sha256'].items(): assert sha(staged/path) == expected
    old_rtl = subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'rtl'], cwd=ROOT).decode().splitlines()
    immutable = [path for path in old_rtl if path not in ('rtl/cpu5_alu_pipeline.v','rtl/cpu5_top.v')]
    for path in immutable:
        assert subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT) == (ROOT/path).read_bytes().replace(b'\r\n',b'\n'), path
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'verification changed source'
    result = dict(status=STATUS, base_commit=BASE, source_sha256=before, sources_unchanged=True,
                  processes=processes, suites=suites, compatibility_reference='build/cpu5_s11_verification/verification.json',
                  legacy_rtl_unchanged=immutable, rtl_mutations_rejected=21, parameter_guards_rejected=2,
                  FENCE='BASE FULL DATA BARRIER', FENCE_I='UNSUPPORTED: PRECISE ILLEGAL',
                  BP_Stats_devices='NOT IMPLEMENTED', cache_AXI_SoC='NOT INTEGRATED',
                  full_A01_A16='NOT RUN', STA='NOT RUN', board='NOT RUN', performance_claim='NONE')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status=STATUS,sources=len(before),rtl_mutations_rejected=21,parameter_guards_rejected=2)))


if __name__ == '__main__': main()
