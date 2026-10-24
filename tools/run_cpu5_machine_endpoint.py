"""Private ModelSim endpoint oracle and real RTL semantic negative controls."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s11_machine_endpoint'
ENDPOINT = 'rtl/cpu5_machine_endpoint.v'
TB = 'tb/cpu5_machine_endpoint_tb.v'
RTL = ['rtl/machine_timer.v', ENDPOINT]
SOURCES = RTL + [TB, 'run_cpu5_machine_endpoint.do', 'tools/run_cpu5_machine_endpoint.py']
LIB = 'cpu5_s11_machine_specimen'
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILED = 'CPU5 MACHINE ENDPOINT CLEAN COMPILE PASS'
PASSED = 'CPU5 MACHINE ENDPOINT REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutation(name, old, new, assertion, rel=ENDPOINT):
    return dict(name=name, kind='rtl_semantic', changed_file=rel,
                old=old, new=new, expected_assertion='MACHINE endpoint oracle ' + assertion,
                top='cpu5_machine_endpoint_tb')


def mutations():
    return [
        mutation('captured_address_corrupted', 'addr_q<=req_addr;', "addr_q<=req_addr^32'd4;", 'pre-edge read snapshot and errors'),
        mutation('captured_data_zeroed', 'wdata_q<=req_wdata;', "wdata_q<=32'd0;", 'MSIP retained level'),
        mutation('captured_direction_inverted', 'write_q<=req_write;', 'write_q<=!req_write;', 'pre-edge read snapshot and errors'),
        mutation('captured_size_lost', 'size_q<=req_size;', "size_q<=2'd0;", 'pre-edge read snapshot and errors'),
        mutation('captured_strobes_lost', 'wstrb_q<=req_wstrb;', "wstrb_q<=4'd15;", 'pre-edge read snapshot and errors'),
        mutation('ready_bypasses_held_response', 'assign req_ready=rst_n && state_q==IDLE;', 'assign req_ready=rst_n && state_q!=STAGED;', 'ready has no response bypass'),
        mutation('response_valid_before_execution', 'assign rsp_valid=rst_n && state_q==RESPONSE;', 'assign rsp_valid=rst_n && state_q!=IDLE;', 'registered response timing'),
        mutation('repeat_endpoint_execution', 'wire endpoint_fire=rst_n && state_q==STAGED;', 'wire endpoint_fire=rst_n && state_q!=IDLE;', 'unique delayed endpoint fire'),
        mutation('execute_at_capture_edge', 'wire endpoint_fire=rst_n && state_q==STAGED;', 'wire endpoint_fire=rst_n && state_q==IDLE && req_valid;', 'unique delayed endpoint fire'),
        mutation('response_changes_under_backpressure', 'RESPONSE:if(rsp_ready)state_q<=IDLE;', 'RESPONSE:begin rsp_rdata<=read_value;if(rsp_ready)state_q<=IDLE;end', 'pre-edge read snapshot and errors'),
        mutation('msip_uses_all_bits', 'software_msip<=wdata_q[0];', 'software_msip<=|wdata_q;', 'MSIP retained level'),
        mutation('msip_clears_on_response', 'if(software_write_fire)software_msip<=wdata_q[0];', "if(software_write_fire)software_msip<=wdata_q[0];else if(rsp_valid && rsp_ready)software_msip<=0;", 'MSIP retained level'),
        mutation('timer_write_ignores_legality', 'wire timer_write_fire=endpoint_fire && access_legal && write_q && timer_write_hit;', 'wire timer_write_fire=endpoint_fire && write_q && timer_write_hit;', 'timer write qualification'),
        mutation('write_strobe_unchecked', 'wire write_shape=write_q && word_shape && wstrb_q==15;', 'wire write_shape=write_q && word_shape;', 'timer write qualification'),
        mutation('read_strobe_unchecked', 'wire read_shape=!write_q && word_shape && wstrb_q==0;', 'wire read_shape=!write_q && word_shape;', 'pre-edge read snapshot and errors'),
        mutation('illegal_read_nonzero', "rsp_rdata<=access_legal?read_value:32'd0;", "rsp_rdata<=access_legal?read_value:32'hfeedface;", 'pre-edge read snapshot and errors'),
        mutation('timer_ticks_twice', "mtime <= mtime + 64'd1;", "mtime <= mtime + 64'd2;", 'mtime mathematical state', 'rtl/machine_timer.v'),
        mutation('timer_write_increments_other_half', 'mtime <= {mtime[63:32], write_data};', "mtime <= {mtime[63:32]+32'd1, write_data};", 'mtime mathematical state', 'rtl/machine_timer.v'),
        mutation('compare_write_stops_time', "else\n                mtime <= mtime + 64'd1;", "else if (!write_enable)\n                mtime <= mtime + 64'd1;", 'mtime mathematical state', 'rtl/machine_timer.v'),
        mutation('signed_timer_compare', 'assign mtip = (mtime >= mtimecmp);', 'assign mtip = ($signed(mtime) >= $signed(mtimecmp));', 'reset cancels response and source', 'rtl/machine_timer.v'),
        mutation('compare_low_destroys_high', 'mtimecmp <= {mtimecmp[63:32], write_data};', "mtimecmp <= {32'd0, write_data};", 'mtimecmp mathematical state', 'rtl/machine_timer.v'),
    ]


def guards():
    return [dict(name=source+'_enable_boolean', kind='parameter_guard',
                 expected_assertion='CPU5 machine device enables must be boolean',
                 top='cpu5_machine_endpoint_'+source+'_guard_tb') for source in ('timer','software')]


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
    (path / 'build/cpu5_s11_machine_endpoint').mkdir(parents=True)
    (path / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', f'vmap {LIB} work',
        f'vlog -sv -work {LIB} ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    top = spec['top'] if spec else 'cpu5_machine_endpoint_tb'
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
        assert code == 0 and PASSED in text and not assertion, ('good endpoint failed', code, text[-6000:])
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
        summaries = [json.loads((path / f'build/cpu5_s11_machine_endpoint/mask{mask}_summary.json').read_text()) for mask in range(4)]
        for mask, summary in enumerate(summaries):
            assert summary['pass'] and summary['mask'] == mask and summary['checks'] > 100000
            assert summary['accepted'] == summary['fires'] + summary['canceled_before_fire']
            assert summary['fires'] == summary['responses'] + summary['canceled_after_fire']
            assert summary['canceled_before_fire'] == summary['canceled_after_fire'] == 1
            assert summary['resets'] == 3 and summary['errors'] > 3500
            if mask & 1: assert summary['carries'] >= 2 and summary['wraps'] >= 1
            if mask & 2: assert summary['software_writes'] >= 6
        record['summaries'] = summaries
        record['summary'] = dict(configurations=4, **{key: sum(s[key] for s in summaries) for key in summaries[0] if key not in ('pass','mask')})
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
    records, failures = [], []
    for spec in specs:
        try:
            records.append(verify(args.vsim, directory / spec['name'], spec, originals, args.timeout))
        except AssertionError as error:
            failures.append(dict(name=spec['name'],error=str(error)))
            print(spec['name'], 'FAILED CHECK', flush=True)
    if failures:
        (directory / 'failures.json').write_text(json.dumps(failures,indent=2)+'\n',encoding='utf-8')
    assert not failures, failures
    assert before == {rel: sha(ROOT / rel) for rel in SOURCES}, 'test changed good source'
    result = dict(status='PARTIAL' if args.only else 'PASS', source_sha256=before, sources_unchanged=True,
                  run_id=run_id, positive=positive, specimens=records,
                  rtl_mutations_rejected=sum(r['kind'] == 'rtl_semantic' for r in records),
                  parameter_guards_rejected=sum(r['kind'] == 'parameter_guard' for r in records),
                  compile_zero_warning_error=True,
                  scope='captured machine timer/MSIP endpoint with independent per-edge 64-bit oracle; no CPU/board claim')
    rendered = json.dumps(result, indent=2) + '\n'
    (directory / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps({key: result[key] for key in ('status', 'rtl_mutations_rejected',
                     'parameter_guards_rejected', 'sources_unchanged')}))


if __name__ == '__main__':
    main()
