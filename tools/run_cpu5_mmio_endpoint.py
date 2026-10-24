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
OUT = ROOT / 'build/cpu5_s10_mmio_endpoint'
ENDPOINT = 'rtl/cpu5_mmio_endpoint.v'
TB = 'tb/cpu5_mmio_endpoint_tb.v'
RTL = ['rtl/uart_tx.v', 'rtl/uart_rx.v', 'rtl/uart_rx_fifo.v',
       'rtl/uart_rx_mmio.v', 'rtl/gpio_mmio.v', ENDPOINT]
SOURCES = RTL + [TB, 'run_cpu5_mmio_endpoint.do', 'tools/run_cpu5_mmio_endpoint.py']
LIB = 'cpu5_s10_endpoint_specimen'
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILED = 'CPU5 MMIO ENDPOINT CLEAN COMPILE PASS'
PASSED = 'CPU5 MMIO ENDPOINT REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutation(name, old, new, assertion):
    return dict(name=name, kind='rtl_semantic', changed_file=ENDPOINT,
                old=old, new=new, expected_assertion='MMIO endpoint oracle ' + assertion,
                top='cpu5_mmio_endpoint_tb')


def mutations():
    return [
        mutation('captured_address_corrupted', 'addr_q<=req_addr;', "addr_q<=req_addr^32'd4;",
                 'pre-effect read snapshot and errors'),
        mutation('live_write_data_instead_of_capture', 'wdata_q<=req_wdata;', 'wdata_q<=32\'d0;',
                 'GPIO post-execution model'),
        mutation('live_write_direction_instead_of_capture', 'write_q<=req_write;', 'write_q<=!req_write;',
                 'pre-effect read snapshot and errors'),
        mutation('lost_captured_size', 'size_q<=req_size;', "size_q<=2'd0;",
                 'pre-effect read snapshot and errors'),
        mutation('lost_captured_strobes', 'wstrb_q<=req_wstrb;', "wstrb_q<=4'd0;",
                 'GPIO side effect qualification'),
        mutation('ready_bypasses_response_phase', 'assign req_ready = rst_n && (state_q==IDLE);',
                 'assign req_ready = rst_n && ((state_q==IDLE) || (state_q==RESPONSE));',
                 'ready has no response bypass'),
        mutation('response_valid_before_execution', 'assign rsp_valid = rst_n && (state_q==RESPONSE);',
                 'assign rsp_valid = rst_n && (state_q!=IDLE);',
                 'registered response timing'),
        mutation('repeat_effect_on_response_backpressure', 'assign endpoint_fire = rst_n && (state_q==STAGED);',
                 'assign endpoint_fire = rst_n && (state_q!=IDLE);',
                 'unique delayed endpoint fire'),
        mutation('effect_at_request_capture', 'assign endpoint_fire = rst_n && (state_q==STAGED);',
                 'assign endpoint_fire = rst_n && (state_q==IDLE) && req_valid;',
                 'unique delayed endpoint fire'),
        mutation('response_not_frozen_under_backpressure', 'RESPONSE: if (rsp_ready) state_q<=IDLE;',
                 'RESPONSE: begin rsp_rdata<=read_value; if (rsp_ready) state_q<=IDLE; end',
                 'pre-effect read snapshot and errors'),
        mutation('counter_swapped', 'read_value=cycle_count[31:0];', 'read_value=instret_count[31:0];',
                 'pre-effect read snapshot and errors'),
        mutation('tx_busy_write_silently_succeeds', 'access_legal=!tx_busy;', "access_legal=1'b1;",
                 'TX side effect qualification'),
        mutation('tx_wrong_byte_lane', '.data(wdata_q[7:0]),', '.data(wdata_q[15:8]),',
                 'TX physical captured byte'),
        mutation('rx_data_read_does_not_pop', '.read_enable(rx_read_fire),', ".read_enable(1'b0),",
                 'pre-effect read snapshot and errors'),
        mutation('gpio_write_lacks_legality_gate', 'wire gpio_write_fire = endpoint_fire && access_legal && write_q && gpio_write_hit;',
                 'wire gpio_write_fire = endpoint_fire && write_q && gpio_write_hit;',
                 'GPIO side effect qualification'),
        mutation('invalid_read_nonzero_payload', "rsp_rdata<=access_legal ? read_value : 32'd0;",
                 "rsp_rdata<=access_legal ? read_value : 32'hfeedface;",
                 'pre-effect read snapshot and errors'),
        mutation('rx_w1c_write_removed', '.write_enable(rx_write_fire),', ".write_enable(1'b0),",
                 'pre-effect read snapshot and errors'),
        mutation('write_strobes_not_validated', "wire write_shape = write_q && word_access && (wstrb_q==4'b1111);",
                 'wire write_shape = write_q && word_access;', 'pre-effect read snapshot and errors'),
    ]


def guards():
    return [dict(name='console_echo_boolean_guard', kind='parameter_guard',
                 expected_assertion='CPU5 MMIO SIM_CONSOLE_ECHO must be boolean',
                 top='cpu5_mmio_endpoint_echo_guard_tb'),
            dict(name='uart_minimum_clock_guard', kind='parameter_guard',
                 expected_assertion='UART RX requires CLOCK_HZ>0, BAUD>0 and clocks/bit>=4',
                 top='cpu5_mmio_endpoint_clock_guard_tb'),
            dict(name='uart_fifo_occupancy_guard', kind='parameter_guard',
                 expected_assertion='UART RX MMIO FIFO_DEPTH must be 1..255 for 8-bit occupancy',
                 top='cpu5_mmio_endpoint_fifo_guard_tb')]


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
    (path / 'build/cpu5_s10_mmio_endpoint').mkdir(parents=True)
    (path / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', f'vmap {LIB} work',
        f'vlog -sv -work {LIB} ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    top = spec['top'] if spec else 'cpu5_mmio_endpoint_tb'
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
        summary = json.loads((path / 'build/cpu5_s10_mmio_endpoint/summary.json').read_text())
        assert summary['pass'] and summary['checks'] > 40000 and summary['errors'] > 800
        assert summary['accepted'] == 860 and summary['gpio_writes'] == 10
        assert summary['held_cycles'] > 1000 and summary['resets'] == 3
        assert summary['accepted'] == summary['fires'] + 1
        assert summary['fires'] == summary['responses'] + 1
        assert summary['rx_pops'] == 2 and summary['tx_sends'] == summary['physical_tx'] >= 3
        record['summary'] = summary
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
                  rtl_mutations_rejected=sum(r['kind'] == 'rtl_semantic' for r in records),
                  parameter_guards_rejected=sum(r['kind'] == 'parameter_guard' for r in records),
                  compile_zero_warning_error=True,
                  scope='captured local endpoint, physical UART and independent GPIO/RX protocol oracle; no CPU or board claim')
    rendered = json.dumps(result, indent=2) + '\n'
    (directory / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps({key: result[key] for key in ('status', 'rtl_mutations_rejected',
                     'parameter_guards_rejected', 'sources_unchanged')}))


if __name__ == '__main__':
    main()
