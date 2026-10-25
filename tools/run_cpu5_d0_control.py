"""Private core/cache/D0 control verification; every run retains raw evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s15_d0_control'
RTL = ['rtl/alu.v', 'rtl/regfile.v', 'rtl/rv32m_unit.v', 'rtl/cpu5_hazard.v',
       'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
       'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v',
       'rtl/cpu5_m_owner.v', 'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_alu_pipeline.v',
       'rtl/instr_cache.v', 'rtl/data_cache.v', 'rtl/cpu5_cache_adapter.v',
       'rtl/data_mem.v', 'rtl/data_bus_adapter.v', 'rtl/soc_data_mem.v',
       'rtl/dmem_region_router.v', 'rtl/dmem_axi_lite_bridge.v', 'rtl/cpu5_d0_backend.v']
TB = 'tb/cpu5_d0_control_tb.v'
COPIES = RTL + ['rtl/cpu5_pipeline_types.vh', TB]
SOURCES = COPIES + ['run_cpu5_d0_control.do', 'tools/run_cpu5_d0_control.py']
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(vsim, cwd, script, phase):
    p = subprocess.run([str(vsim), '-c', '-do', script], cwd=cwd,
                       capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=240)
    output = p.stdout + p.stderr
    log = cwd / (phase + '_console.log')
    log.write_text(output, encoding='utf-8', newline='')
    assert p.returncode == 0 and not DIAGNOSTIC.search(output) and '** Fatal:' not in output, (phase, p.returncode, output[-12000:])
    return log, output


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args = ap.parse_args()
    source_sha = {p: sha(ROOT / p) for p in SOURCES}
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_') + uuid.uuid4().hex[:8]
    run_dir = OUT / 'runs' / run_id
    specimen = run_dir / 'good_reference'
    specimen.mkdir(parents=True)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'verification.json').write_text(json.dumps({'status': 'RUNNING', 'run_id': run_id}, indent=2) + '\n')
    for rel in COPIES:
        dest = specimen / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes((ROOT / rel).read_bytes())
    (specimen / 'build/cpu5_s15_d0_control').mkdir(parents=True)
    (specimen / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', 'vmap d0_control_work work',
        'vlog -sv +incdir+. -work d0_control_work ' + ' '.join(RTL + [TB]),
        'echo "CPU5 D0 CONTROL CLEAN COMPILE PASS"', 'quit -code 0 -f', '']))
    (specimen / 'simulate.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file simulation_transcript.log',
        'vmap d0_control_work work',
        'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf d0_control_work.cpu5_d0_control_tb',
        'log -r sim:/*', 'run -all',
        'if {[examine -radix unsigned sim:/cpu5_d0_control_tb/test_pass] != 1} {quit -code 1 -f}',
        'echo "CPU5 D0 CONTROL REFERENCE PASS"', 'quit -code 0 -f', '']))
    compile_log, compile_output = run(args.vsim, specimen, 'compile.do', 'compile')
    assert 'CPU5 D0 CONTROL CLEAN COMPILE PASS' in compile_output
    simulation_log, output = run(args.vsim, specimen, 'simulate.do', 'simulation')
    assert 'CPU5 D0 CONTROL REFERENCE PASS' in output
    configs = [json.loads((specimen / f'build/cpu5_s15_d0_control/config{n}_summary.json').read_text()) for n in range(8)]
    for n, c in enumerate(configs):
        assert c['pass'] and c['config'] == n
        assert c['requests'] == c['responses'] + c['reset_abandoned_requests']
        assert c['backend_requests'] == c['backend_responses'] + c['backend_reset_abandoned']
        assert c['retired'] == c['wb'] + c['reset_abandoned_wb'] and c['sync_traps'] == c['precise_errors'] == 3 and c['irqs'] == 1
        assert c['kill_complete'] == 1 and c['ram_writes'] >= 4 and c['store_wb_hold'] == 1 and c['flush_rejected'] == 2
        assert c['axi_ar'] >= 4 and c['axi_aw'] >= 1 and c['axi_w'] == c['axi_aw']
        if c['d0']:
            assert c['local_requests'] > 0
        else:
            assert c['local_requests'] == 0
        if c['wait']:
            assert c['kill_held'] == c['kill_accepted'] == 1 and c['fence_wait_edges'] > 0
        if c['cache']:
            assert c['cache_hits'] >= 1
        else:
            assert c['cache_hits'] == 0
        if c['d0'] and c['wait']:
            assert c['reset_checks'] == 2 and c['held_local_edges'] > 0
    assert source_sha == {p: sha(ROOT / p) for p in SOURCES}, 'source changed during verification'
    sums = {k: sum(c[k] for c in configs) for k in configs[0] if k not in ('pass', 'config', 'd0', 'cache', 'wait')}
    retained = {p.relative_to(specimen).as_posix(): sha(p) for p in specimen.rglob('*')
                if p.is_file() and p.suffix in ('.do', '.log', '.wlf', '.ini', '.csv', '.json')}
    positive = dict(name='good_reference', kind='good_reference', status='PASS',
                    directory=specimen.relative_to(ROOT).as_posix(),
                    compile=dict(status='PASS', exit_code=0, warnings=0, errors=0,
                                 console_sha256=sha(compile_log)),
                    simulation_exit_code=0, simulation_console_sha256=sha(simulation_log),
                    source_sha256={p: sha(specimen / p) for p in COPIES},
                    retained_artifact_sha256=retained, configs=configs)
    result = dict(status='PASS', run_id=run_id, configurations=8, positive=positive,
                  source_sha256=source_sha, sources_unchanged=True,
                  compile_zero_warning_error=True, compile_console_sha256=sha(compile_log),
                  simulation_console_sha256=sha(simulation_log), configs=configs, **sums,
                  directory=specimen.relative_to(ROOT).as_posix(),
                  scope='EX core with independent retire/WB/GPR/CSR/IRQ model; D0 on/off x Dcache on/off x endpoint waits; physical RAM writes and persistence, legal killed reads/FENCE, STORE WB/flush/IRQ, ordered external AXI and real errors. Native IF inherited and not newly claimed.',
                  retained_artifact_sha256=retained)
    rendered = json.dumps(result, indent=2) + '\n'
    (run_dir / 'verification.json').write_text(rendered)
    (OUT / 'verification.json').write_text(rendered)
    print(json.dumps({k: result[k] for k in ('status', 'cases', 'retired', 'sync_traps', 'irqs', 'requests', 'responses')}))


if __name__ == '__main__':
    main()
