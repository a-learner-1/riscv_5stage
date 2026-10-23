"""Verify IRQ synchronization/arbitration and conditional machine IRQ CSRs."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s9_irq_ctrl'
BANK = 'rtl/cpu5_csr_unit.v'
CTRL = 'rtl/cpu5_irq_ctrl.v'
TB = 'tb/cpu5_irq_ctrl_tb.v'
RTL = [BANK, CTRL]
SOURCES = RTL + [TB, 'run_cpu5_irq_ctrl.do', 'tools/run_cpu5_irq_ctrl.py']
LIB = 'cpu5_s9_irq_specimen'
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILED = 'CPU5 IRQ CTRL CLEAN COMPILE PASS'
PASSED = 'CPU5 IRQ CTRL REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutation(name, rel, old, new, assertion):
    return dict(name=name, kind='rtl_semantic', changed_file=rel, old=old, new=new,
                expected_assertion=assertion, top='cpu5_irq_ctrl_tb')


def mutations():
    return [
        mutation('external_synchronizer_bypassed', CTRL,
                 'external_sync_q<=external_meta_q;', 'external_sync_q<=irq_external;',
                 'IRQ CTRL post-edge synchronizer'),
        mutation('irq_bypasses_old_arm', CTRL,
                 'assign irq_take=rst_n && irq_arm_q && irq_eligible_now && safe_boundary &&',
                 'assign irq_take=rst_n && irq_eligible_now && safe_boundary &&',
                 'CPU5 IRQ lacks pre-edge safe armed eligibility'),
        mutation('speculative_post_status_arbitrates_now', CTRL,
                 'assign irq_eligible_now=global_enable && |enabled_pending;',
                 'assign irq_eligible_now=post_commit_global_enable && |enabled_pending;',
                 'IRQ CTRL current CSR eligibility'),
        mutation('arm_ignores_retired_global_enable', CTRL,
                 'wire next_global=retire_fire?post_commit_global_enable:global_enable;',
                 'wire next_global=global_enable;',
                 'IRQ CTRL post-commit arm timing'),
        mutation('arm_ignores_retired_mie', CTRL,
                 'wire [31:0] next_mie=retire_fire?post_commit_mie:mie_value;',
                 'wire [31:0] next_mie=mie_value;',
                 'IRQ CTRL post-commit arm timing'),
        mutation('software_preempts_external_priority', CTRL,
                 "assign irq_cause=enabled_pending[11]?32'h8000000b:\n        enabled_pending[3]?32'h80000003:",
                 "assign irq_cause=enabled_pending[3]?32'h80000003:\n        enabled_pending[11]?32'h8000000b:",
                 'IRQ CTRL source priority'),
        mutation('arm_not_canceled_when_ineligible', CTRL,
                 'else irq_arm_q<=next_eligible;', 'else irq_arm_q<=irq_arm_q || next_eligible;',
                 'IRQ CTRL post-commit arm timing'),
        mutation('irq_ignores_sync_fault_priority', CTRL,
                 'mem_enable && !flush_active && !sync_fault;', 'mem_enable && !flush_active;',
                 'CPU5 IRQ lacks pre-edge safe armed eligibility'),
        mutation('irq_ignores_safe_boundary', CTRL,
                 'irq_arm_q && irq_eligible_now && safe_boundary &&',
                 'irq_arm_q && irq_eligible_now &&',
                 'CPU5 IRQ lacks pre-edge safe armed eligibility'),
        mutation('mie_unsupported_bits_writable', BANK,
                 "12'h304:csr_mie<=write_value & IRQ_MASK;", "12'h304:csr_mie<=write_value;",
                 'IRQ BANK committed state'),
        mutation('mip_write_has_software_side_effect', BANK,
                 "12'h304:csr_mie<=write_value & IRQ_MASK;",
                 "12'h304:csr_mie<=write_value & IRQ_MASK;\n                12'h344:csr_mie<=write_value & IRQ_MASK;",
                 'IRQ BANK committed state'),
        mutation('mip_reports_unimplemented_sources', BANK,
                 "12'h344:begin known=IRQ_ENABLED;read_value=irq_pending & IRQ_MASK;end",
                 "12'h344:begin known=IRQ_ENABLED;read_value=irq_pending;end",
                 'IRQ BANK CSR decode/read'),
        mutation('mie_present_without_any_irq_source', BANK,
                 "12'h304:begin known=IRQ_ENABLED;read_value=csr_mie;end",
                 "12'h304:begin known=1'b1;read_value=csr_mie;end",
                 'IRQ BANK CSR decode/read'),
        mutation('mret_preview_uses_old_mie', BANK,
                 'assign post_commit_global_enable=mret_fire?csr_mstatus[7]:',
                 'assign post_commit_global_enable=mret_fire?csr_mstatus[3]:',
                 'IRQ BANK post-commit preview'),
        mutation('post_mie_preview_not_warl', BANK,
                 '(write_value & IRQ_MASK):csr_mie;', '(write_value):csr_mie;',
                 'IRQ BANK post-commit preview'),
    ]


def guards():
    return [dict(name='controller_invalid_source_boolean', kind='parameter_guard',
                 expected_assertion='CPU5 IRQ source parameters must be boolean', top='cpu5_irq_ctrl_guard_tb'),
            dict(name='bank_invalid_source_boolean', kind='parameter_guard',
                 expected_assertion='CPU5 CSR IRQ source parameters must be boolean', top='cpu5_irq_bank_guard_tb')]


def process(command, cwd, name, timeout):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=timeout)
    text = result.stdout + result.stderr
    path = cwd / (name + '_console.log')
    path.write_text(text, encoding='utf-8', newline='')
    return result.returncode, text, path


def prepare(path, spec, originals):
    path.mkdir(parents=True, exist_ok=False)
    for rel in RTL + [TB]:
        target = path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(originals[rel])
    change = None
    if spec and spec['kind'] == 'rtl_semantic':
        target = path / spec['changed_file']
        text = target.read_text(encoding='utf-8')
        assert text.count(spec['old']) == 1, ('mutation anchor not unique', spec['name'])
        target.write_text(text.replace(spec['old'], spec['new']), encoding='utf-8', newline='')
        change = dict(path=spec['changed_file'], good_sha256=hashlib.sha256(originals[spec['changed_file']]).hexdigest(),
                      bad_sha256=sha(target), old=spec['old'], new=spec['new'])
        assert change['good_sha256'] != change['bad_sha256']
    (path / 'build/cpu5_s9_irq_ctrl').mkdir(parents=True)
    (path / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', f'vmap {LIB} work',
        f'vlog -sv -work {LIB} ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    top = spec['top'] if spec else 'cpu5_irq_ctrl_tb'
    lines = ['onerror {quit -code 1 -f}', 'transcript file simulation_transcript.log',
             f'vmap {LIB} work', f'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf {LIB}.{top}',
             'log -r sim:/*', 'run -all']
    if spec:
        lines.append('quit -code 1 -f')
    else:
        lines += [f'if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 1 -f}}',
                  f'echo "{PASSED}"', 'quit -code 0 -f']
    (path / 'simulate.do').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return change


def verify(vsim, path, spec, originals, timeout):
    change = prepare(path, spec, originals)
    code, text, compile_log = process([str(vsim), '-c', '-do', 'compile.do'], path, 'compile', timeout)
    assert code == 0 and COMPILED in text and not DIAGNOSTIC.search(text), \
        ('clean compile required before semantic test', path.name, code, text[-6000:])
    compile_record = dict(status='PASS', exit_code=code, warnings=0, errors=0, console_sha256=sha(compile_log))
    code, text, simulation_log = process([str(vsim), '-c', '-do', 'simulate.do'], path, 'simulation', timeout)
    assert not DIAGNOSTIC.search(text), ('simulation infrastructure warning/error', path.name, text[-6000:])
    assertion = next((line.strip() for line in text.splitlines() if '** Fatal:' in line), None)
    if spec:
        assert code != 0 and assertion and spec['expected_assertion'] in assertion, \
            ('designated semantic assertion not reached', path.name, code, spec['expected_assertion'], text[-6000:])
        status = 'REJECTED'
    else:
        assert code == 0 and PASSED in text and not assertion, ('good unit failed', code, text[-6000:])
        status = 'PASS'
    record = dict(name=path.name, kind=spec['kind'] if spec else 'good_reference', status=status,
                  directory=path.relative_to(ROOT).as_posix(), compile=compile_record,
                  simulation_exit_code=code, expected_assertion=spec['expected_assertion'] if spec else None,
                  actual_assertion=assertion, changed_source=change,
                  source_sha256={rel: sha(path / rel) for rel in RTL + [TB]},
                  simulation_console_sha256=sha(simulation_log),
                  retained_artifact_sha256={p.name: sha(p) for p in path.iterdir()
                                           if p.is_file() and p.suffix in ('.do', '.log', '.wlf')})
    if not spec:
        summaries = {kind: [json.loads((path / f'build/cpu5_s9_irq_ctrl/{kind}_mask{mask}.json').read_text())
                           for mask in range(8)] for kind in ('ctrl', 'bank')}
        for kind, values in summaries.items():
            assert all(value['pass'] and value['mask'] == mask for mask, value in enumerate(values)), kind
        assert all(value['checks'] >= 580 for value in summaries['ctrl'])
        assert summaries['ctrl'][0]['takes'] == 0
        assert all(value['post_commit_open'] and value['post_commit_mie_open'] and value['takes'] >= 3
                   for value in summaries['ctrl'][1:])
        assert all(value['checks'] >= 60 and value['trap_checks'] == 1 and value['mret_checks'] == 2
                   for value in summaries['bank'])
        assert all(value['mip_writes'] == 24 for value in summaries['bank'][1:])
        record['summaries'] = summaries
    (path / 'result.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(path.name, status, flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    parser.add_argument('--timeout', type=int, default=240)
    parser.add_argument('--only', action='append', help='debug selected negatives; result is PARTIAL')
    args = parser.parse_args()
    all_specs = mutations() + guards()
    assert not args.only or set(args.only) <= {s['name'] for s in all_specs}
    specs = [s for s in all_specs if not args.only or s['name'] in args.only]
    before = {rel: sha(ROOT / rel) for rel in SOURCES}
    originals = {rel: (ROOT / rel).read_bytes() for rel in SOURCES}
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_') + uuid.uuid4().hex[:8]
    directory = OUT / 'runs' / run_id
    directory.mkdir(parents=True, exist_ok=False)
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', run_id=run_id,
        source_sha256=before), indent=2) + '\n', encoding='utf-8')
    positive = verify(args.vsim, directory / 'good_reference', None, originals, args.timeout)
    records = [verify(args.vsim, directory / spec['name'], spec, originals, args.timeout) for spec in specs]
    assert before == {rel: sha(ROOT / rel) for rel in SOURCES}, 'test changed good source'
    result = dict(status='PARTIAL' if args.only else 'PASS', source_sha256=before, sources_unchanged=True,
                  run_id=run_id, positive=positive, specimens=records,
                  source_configurations=8, controller_checks=sum(v['checks'] for v in positive['summaries']['ctrl']),
                  bank_checks=sum(v['checks'] for v in positive['summaries']['bank']),
                  rtl_mutations_rejected=sum(r['kind'] == 'rtl_semantic' for r in records),
                  parameter_guards_rejected=sum(r['kind'] == 'parameter_guard' for r in records),
                  compile_zero_warning_error=True, scope='independent IRQ controller and machine CSR bank; no CPU/board/performance claim')
    rendered = json.dumps(result, indent=2) + '\n'
    (directory / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps({key: result[key] for key in ('status', 'source_configurations', 'controller_checks',
                     'bank_checks', 'rtl_mutations_rejected', 'parameter_guards_rejected', 'sources_unchanged')}))


if __name__ == '__main__':
    main()
