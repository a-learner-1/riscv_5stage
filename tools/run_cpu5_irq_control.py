"""Run real-RTL CPU5 machine IRQ directed tests and close all owner ledgers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s9_irq_control'
SOURCES = ['rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
           'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
           'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/rv32m_unit.v',
           'rtl/cpu5_m_owner.v', 'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_pipeline_types.vh',
           'rtl/cpu5_alu_pipeline.v', 'tb/cpu5_irq_control_tb.v',
           'run_cpu5_irq_control.do', 'tools/run_cpu5_irq_control.py']


def hashes():
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path,
                        default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = hashes()
    for mode in (0, 1):
        (OUT / f'mode{mode}_summary.json').unlink(missing_ok=True)
    command = [str(args.vsim), '-c', '-do', 'run_cpu5_irq_control.do']
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=240)
    output = result.stdout + result.stderr
    (OUT / 'console.log').write_text(output, encoding='utf-8', newline='')
    assert result.returncode == 0 and 'CPU5 IRQ CONTROL DIRECTED TEST PASS' in output, output[-7000:]
    assert not any(line.lstrip().startswith(('# ** Fatal:', '# ** Error:',
                                            '# ** Warning:', 'Traceback ('))
                   for line in output.splitlines()), 'simulation diagnostics'
    modes = [json.loads((OUT / f'mode{m}_summary.json').read_text()) for m in (0, 1)]
    for mode, summary in enumerate(modes):
        assert summary['pass'] and summary['mode'] == mode and summary['cases'] == 27
        assert summary['retired'] == summary['wb'] and summary['requests'] == summary['responses']
        assert summary['irqs'] == 22 and summary['sync_traps'] == 3
        assert summary['m_issued'] == summary['m_completed'] + summary['m_drained']
        assert summary['m_completed'] == 2 and summary['m_drained'] == 1
        assert summary['irq_with_old_wb_write'] and summary['irq_with_held_wb']
        assert summary['revoked_arm_edges'] and summary['killed_d_responses'] == 1
        assert summary['handler_retire_during_m_drain'] >= 2
        assert summary['held_d_edges'] and summary['committed_state_checks'] >= 1000
    assert hashes() == before, 'sources changed during directed verification'
    evidence = dict(status='PASS', sources_unchanged=True, source_sha256=before,
                    command=command, exit_code=result.returncode, modes=modes,
                    cases=sum(m['cases'] for m in modes),
                    retired=sum(m['retired'] for m in modes),
                    sync_traps=sum(m['sync_traps'] for m in modes),
                    irqs=sum(m['irqs'] for m in modes),
                    m_issued=sum(m['m_issued'] for m in modes),
                    m_completed=sum(m['m_completed'] for m in modes),
                    m_drained=sum(m['m_drained'] for m in modes),
                    scope='CPU5 opt-in machine IRQ directed control; raw IRQ pins only; no MMIO/SoC claim')
    (OUT / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: evidence[key] for key in
                     ('status', 'cases', 'retired', 'sync_traps', 'irqs', 'm_issued', 'm_completed', 'm_drained')}))


if __name__ == '__main__':
    main()
