"""Private machine-device response-route tests and independently compiled RTL mutants."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s11_machine_router'
ROUTER = 'rtl/cpu5_machine_router.v'
TB = 'tb/cpu5_machine_router_tb.v'
RTL = ['rtl/uart_tx.v', 'rtl/uart_rx.v', 'rtl/uart_rx_fifo.v', 'rtl/uart_rx_mmio.v',
       'rtl/gpio_mmio.v', 'rtl/cpu5_mmio_endpoint.v', 'rtl/cpu5_mmio_router.v',
       'rtl/machine_timer.v', 'rtl/cpu5_machine_endpoint.v', ROUTER]
SOURCES = RTL + [TB, 'run_cpu5_machine_router.do', 'tools/run_cpu5_machine_router.py']
BAD_DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILED = 'CPU5 MACHINE ROUTER CLEAN COMPILE PASS'
PASSED = 'CPU5 MACHINE ROUTER REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def specimens():
    return [
        dict(name='response_uses_live_machine_address', old='assign rsp_rdata=machine_q?machine_rsp_rdata:normal_rsp_rdata;',
             new='assign rsp_rdata=req_machine?machine_rsp_rdata:normal_rsp_rdata;',
             expected_assertion='MACHINE router oracle held response route and snapshot'),
        dict(name='accepted_machine_route_not_saved', old='machine_q<=req_machine;', new="machine_q<=1'b0;",
             expected_assertion=['MACHINE router oracle held response route and snapshot',
                                 'CPU5 machine response has no accepted route']),
        dict(name='machine_response_overwritten_by_turnover', old='(response_fire && !machine_q && !req_machine)',
             new='(response_fire && !req_machine)',
             expected_assertion='MACHINE router oracle machine response prohibits turnover'),
        dict(name='msip_sent_to_unmapped_normal_endpoint', old="ENABLE_SOFTWARE_DEVICE && req_addr>=32'h20000050",
             new="1'b0 && req_addr>=32'h20000050",
             expected_assertion='MACHINE router oracle local execution owns accepted transaction'),
    ]


def process(vsim, path, script, name):
    p = subprocess.run([str(vsim), '-c', '-do', script], cwd=path, capture_output=True,
                       text=True, encoding='utf-8', errors='replace', timeout=180)
    output = p.stdout + p.stderr
    log = path / (name + '_console.log')
    log.write_text(output, encoding='utf-8', newline='')
    return p.returncode, output, log


def verify(vsim, path, spec, originals):
    path.mkdir(parents=True)
    for rel in RTL + [TB]:
        target = path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(originals[rel])
    (path / 'build/cpu5_s11_machine_router').mkdir(parents=True)
    change = None
    if spec:
        target = path / ROUTER
        source = target.read_text(encoding='utf-8')
        assert source.count(spec['old']) == 1
        target.write_text(source.replace(spec['old'], spec['new']), encoding='utf-8', newline='\n')
        change = dict(path=ROUTER, good_sha256=hashlib.sha256(originals[ROUTER]).hexdigest(),
                      bad_sha256=sha(target), old=spec['old'], new=spec['new'])
        assert change['good_sha256'] != change['bad_sha256']
    (path / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', 'vmap router_work work',
        'vlog -sv -work router_work ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    (path / 'simulate.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file simulation_transcript.log',
        'vmap router_work work', 'vsim -voptargs="+acc" -onfinish stop -wlf router.wlf router_work.cpu5_machine_router_tb',
        'log -r sim:/*', 'run -all',
        'if {[examine -radix unsigned sim:/cpu5_machine_router_tb/test_pass] != 1} {quit -code 1 -f}',
        f'echo "{PASSED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    code, output, compile_log = process(vsim, path, 'compile.do', 'compile')
    assert code == 0 and COMPILED in output and not BAD_DIAGNOSTIC.search(output), (path.name, output[-5000:])
    compile_record = dict(status='PASS', exit_code=code, warnings=0, errors=0, console_sha256=sha(compile_log))
    code, output, simulation_log = process(vsim, path, 'simulate.do', 'simulation')
    assert not BAD_DIAGNOSTIC.search(output), (path.name, output[-5000:])
    actual = next((line.strip() for line in output.splitlines() if '** Fatal:' in line), None)
    if spec:
        tokens = spec['expected_assertion'] if isinstance(spec['expected_assertion'], list) else [spec['expected_assertion']]
        assert code != 0 and actual and any(token in actual for token in tokens), (path.name, code, spec, output[-7000:])
        status = 'REJECTED'
    else:
        assert code == 0 and PASSED in output and not actual, (path.name, code, output[-7000:])
        status = 'PASS'
    record = dict(name=path.name, kind='rtl_semantic' if spec else 'good_reference', status=status,
                  directory=path.relative_to(ROOT).as_posix(), compile=compile_record,
                  simulation_exit_code=code, simulation_console_sha256=sha(simulation_log),
                  expected_assertion=spec['expected_assertion'] if spec else None,
                  actual_assertion=actual, changed_source=change,
                  source_sha256={p: sha(path / p) for p in RTL + [TB]},
                  retained_artifact_sha256={p.name: sha(p) for p in path.iterdir()
                                           if p.is_file() and p.suffix in ('.do', '.log', '.wlf')})
    if not spec:
        summary = json.loads((path / 'build/cpu5_s11_machine_router/summary.json').read_text())
        assert summary['status'] == 'PASS' and summary['accepts'] == summary['responses'] + summary['reset_drops'] == 19
        assert summary['reset_drops'] == 4 and summary['external_accepts'] == 5
        assert summary['local_effects'] == 5 and summary['gpio_effects'] == 2 and summary['machine_effects'] == 7
        record['summary'] = summary
    (path / 'result.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(path.name, status, flush=True)
    return record


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    a = ap.parse_args()
    originals = {p: (ROOT / p).read_bytes() for p in SOURCES}
    before = {p: hashlib.sha256(data).hexdigest() for p, data in originals.items()}
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_') + uuid.uuid4().hex[:8]
    run = OUT / 'runs' / run_id
    run.mkdir(parents=True)
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', run_id=run_id), indent=2) + '\n', encoding='utf-8')
    positive = verify(a.vsim, run / 'good_reference', None, originals)
    records = [verify(a.vsim, run / s['name'], s, originals) for s in specimens()]
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'router verification changed source'
    result = dict(status='PASS', run_id=run_id, source_sha256=before, sources_unchanged=True,
                  positive=positive, specimens=records, rtl_mutations_rejected=4,
                  parameter_guards_rejected=0, compile_zero_warning_error=True)
    rendered = json.dumps(result, indent=2) + '\n'
    (run / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps(dict(status='PASS', summary=positive['summary'], rtl_mutations_rejected=4)))


if __name__ == '__main__':
    main()
