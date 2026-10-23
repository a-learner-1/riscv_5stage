"""Verify independent CPU5 M ownership, actual bad RTL and finite 64-bit guards."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s8_m_owner'
OWNER = 'rtl/cpu5_m_owner.v'
RTL = ['rtl/rv32m_unit.v', OWNER]
TB = 'tb/cpu5_m_owner_tb.v'
SOURCES = RTL + [TB, 'run_cpu5_m_owner.do', 'tools/run_cpu5_m_owner.py']
LIB = 'cpu5_s8_owner_specimen'
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILED = 'CPU5 M OWNER CLEAN COMPILE PASS'
PASSED = 'CPU5 M OWNER REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutation(name, old, new, assertion):
    return dict(name=name, kind='rtl_semantic', old=old, new=new,
                expected_assertion=assertion, top='cpu5_m_owner_tb', overrides=[])


def mutations():
    return [
        mutation('generation_not_advanced',
                 "next_generation_q<=next_generation_q+64'd1;", 'next_generation_q<=next_generation_q;',
                 'M OWNER post-edge generation allocation'),
        mutation('division_requires_busy_at_done',
                 'wire fresh_result=state_q==WAIT_RESULT && unit_done;',
                 'wire fresh_result=state_q==WAIT_RESULT && unit_done && (!op_q[2] || unit_busy);',
                 'M OWNER fast result required a busy/done-low transition'),
        mutation('stale_saved_result_returned',
                 'assign completion_result=state_q==HOLD_RESULT?result_q:unit_result;',
                 'assign completion_result=result_q;',
                 'M OWNER arithmetic result'),
        mutation('epoch_kills_architectural_owner',
                 'wire kill_owner=kill_valid && seq_q>=kill_cut_seq;',
                 'wire kill_owner=(kill_valid && seq_q>=kill_cut_seq) || epoch_q!=issue_epoch;',
                 'M OWNER age kill mismatch'),
        mutation('killed_completion_waits_for_ready',
                 'assign drain_fire=completion_valid && completion_killed;',
                 'assign drain_fire=completion_valid && completion_killed && completion_ready;',
                 'M OWNER killed completion not auto-drained'),
        mutation('same_edge_kill_not_visible',
                 'assign completion_killed=effective_killed;',
                 'assign completion_killed=killed_q;',
                 'M OWNER age kill mismatch'),
        mutation('live_result_dropped_on_backpressure',
                 'state_q<=HOLD_RESULT;', 'state_q<=NONE;',
                 'M OWNER post-edge ownership ledger'),
        mutation('slot_can_issue_before_owner_release',
                 'assign issue_ready=rst_n && state_q==NONE && !unit_busy &&',
                 'assign issue_ready=rst_n && !unit_busy &&',
                 'CPU5 M start overlaps old ownership or result consumption'),
        mutation('owner_op_lost',
                 'instr_q<=issue_instr;epoch_q<=issue_epoch;op_q<=issue_op;',
                 "instr_q<=issue_instr;epoch_q<=issue_epoch;op_q<=3'd0;",
                 'M OWNER metadata/generation changed'),
        mutation('age_cut_truncated_to_32_bits',
                 'wire kill_owner=kill_valid && seq_q>=kill_cut_seq;',
                 'wire kill_owner=kill_valid && seq_q[31:0]>=kill_cut_seq[31:0];',
                 'M OWNER age kill mismatch'),
        mutation('unit_start_repeats_held_issue',
                 'assign unit_start_fire=issue_fire;', 'assign unit_start_fire=issue_valid;',
                 'CPU5 M start differs from owner issue'),
    ]


def guards():
    return [
        dict(name='generation64_exhaustion', kind='generation_guard',
             expected_assertion='CPU5 M generation exhausted; reset required',
             top='cpu5_m_owner_guard_tb', overrides=[]),
        dict(name='invalid_age_width', kind='parameter_guard',
             expected_assertion='CPU5 M owner requires 64-bit age and positive epoch',
             top='cpu5_m_owner_guard_tb', overrides=['-gSEQ_BITS=32']),
    ]


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
        target = path / OWNER
        text = target.read_text(encoding='utf-8')
        assert text.count(spec['old']) == 1, ('mutation anchor not unique', spec['name'])
        target.write_text(text.replace(spec['old'], spec['new']), encoding='utf-8', newline='')
        change = dict(path=OWNER, good_sha256=hashlib.sha256(originals[OWNER]).hexdigest(),
                      bad_sha256=sha(target), old=spec['old'], new=spec['new'])
        assert change['good_sha256'] != change['bad_sha256']
    (path / 'build/cpu5_s8_m_owner').mkdir(parents=True)
    (path / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', f'vmap {LIB} work',
        f'vlog -sv -work {LIB} ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    top = spec['top'] if spec else 'cpu5_m_owner_tb'
    overrides = ' '.join(spec['overrides']) if spec else ''
    lines = ['onerror {quit -code 1 -f}', 'transcript file simulation_transcript.log',
             f'vmap {LIB} work',
             f'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf {overrides} {LIB}.{top}',
             'log -r sim:/*', 'run -all']
    if spec:
        # A guard or semantic assertion must actually emit Fatal; a plain exit
        # is never evidence. The Python caller classifies the exact assertion.
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
        ('must compile without warnings/errors before semantic test', path.name, code, text[-6000:])
    compile_record = dict(status='PASS', exit_code=code, warnings=0, errors=0,
                          console_sha256=sha(compile_log))
    code, text, simulation_log = process([str(vsim), '-c', '-do', 'simulate.do'], path, 'simulation', timeout)
    assert not DIAGNOSTIC.search(text), ('simulation infra/compile warning or error', path.name, text[-6000:])
    assertion = next((line.strip() for line in text.splitlines() if '** Fatal:' in line), None)
    if spec:
        assert code != 0 and assertion and spec['expected_assertion'] in assertion, \
            ('designated semantic assertion not reached', path.name, code,
             spec['expected_assertion'], text[-6000:])
        if spec['kind'] == 'generation_guard':
            assert 'M OWNER EXHAUSTION START' in text and \
                'M OWNER EXHAUSTION RESULT generation=fffffffffffffffe' in text, \
                'exhaustion must follow a real last-generation start and result'
        status = 'REJECTED'
    else:
        assert code == 0 and PASSED in text and not assertion, ('good owner failed', code, text[-6000:])
        status = 'PASS'
    record = dict(name=path.name, kind=spec['kind'] if spec else 'good_reference',
                  status=status, directory=path.relative_to(ROOT).as_posix(),
                  compile=compile_record, simulation_exit_code=code,
                  expected_assertion=spec['expected_assertion'] if spec else None,
                  actual_assertion=assertion, changed_source=change,
                  source_sha256={rel: sha(path / rel) for rel in RTL + [TB]},
                  simulation_console_sha256=sha(simulation_log),
                  retained_artifact_sha256={p.name: sha(p) for p in path.iterdir()
                                           if p.is_file() and p.suffix in ('.do', '.log', '.wlf')})
    if not spec:
        summary = path / 'build/cpu5_s8_m_owner/owner_summary.json'
        record['summary'] = json.loads(summary.read_text(encoding='utf-8'))
        value = record['summary']
        assert value['pass'] and value['cases'] == 149 and value['starts'] == 152
        assert value['starts'] == value['live_consumed'] + value['killed_drained'] + value['reset_canceled']
        assert value['live_consumed'] == 140 and value['killed_drained'] == 10
        assert value['fast_results'] >= 12 and value['cross_bit32_generations'] >= 100
        assert value['held_edges'] >= 150 and value['blocked_issue_edges'] >= 15
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
    records = [verify(args.vsim, directory / s['name'], s, originals, args.timeout) for s in specs]
    assert before == {rel: sha(ROOT / rel) for rel in SOURCES}, 'test changed good input'
    result = dict(status='PARTIAL' if args.only else 'PASS', source_sha256=before,
                  sources_unchanged=True, run_id=run_id, positive=positive,
                  specimens=records, rtl_mutations_rejected=sum(r['kind'] == 'rtl_semantic' for r in records),
                  parameter_guards_rejected=sum(r['kind'] == 'parameter_guard' for r in records),
                  generation_guards_rejected=sum(r['kind'] == 'generation_guard' for r in records),
                  compile_zero_warning_error=True, unchanged_legacy_rv32m=before['rtl/rv32m_unit.v'],
                  retirement_architecture='owner unit only; no CPU/IRQ/performance claim')
    rendered = json.dumps(result, indent=2) + '\n'
    (directory / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps({key: result[key] for key in ('status', 'rtl_mutations_rejected',
                     'parameter_guards_rejected', 'generation_guards_rejected', 'sources_unchanged')}))


if __name__ == '__main__':
    main()
