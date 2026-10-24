"""Run real-RTL CPU5 ordered MMIO directed tests and close all owner ledgers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s10_mmio_control'
SOURCES = ['rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
           'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
           'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/rv32m_unit.v',
           'rtl/cpu5_m_owner.v', 'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_pipeline_types.vh',
           'rtl/cpu5_alu_pipeline.v', 'tb/cpu5_mmio_control_tb.v',
           'run_cpu5_mmio_control.do', 'tools/run_cpu5_mmio_control.py']


def hashes():
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path,
                        default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = hashes()
    (OUT / "verification.json").write_text(json.dumps(dict(status="RUNNING", source_sha256=before), indent=2) + "\n", encoding="utf-8")
    for mode in (0, 1):
        (OUT / f'mode{mode}_summary.json').unlink(missing_ok=True)
    command = [str(args.vsim), '-c', '-do', 'run_cpu5_mmio_control.do']
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=240)
    output = result.stdout + result.stderr
    (OUT / 'console.log').write_text(output, encoding='utf-8', newline='')
    assert result.returncode == 0 and 'CPU5 MMIO CONTROL DIRECTED TEST PASS' in output, output[-7000:]
    assert not any(line.lstrip().startswith(('# ** Fatal:', '# ** Error:',
                                            '# ** Warning:', 'Traceback ('))
                   for line in output.splitlines()), 'simulation diagnostics'
    modes = [json.loads((OUT / f'mode{m}_summary.json').read_text()) for m in (0, 1)]
    for mode, summary in enumerate(modes):
        assert summary['pass'] and summary['mode'] == mode and summary['cases'] == 23
        assert summary['retired'] == summary['wb']
        assert summary['requests'] == summary['responses'] + summary['reset_abandoned_requests']
        assert summary['reset_abandoned_requests'] == 1
        assert summary['irqs'] == 5 and summary['sync_traps'] == 7
        assert summary['ram_turnover'] == 1 and summary['cached'] == 2
        assert summary['io_blocked'] == 1 and summary['reset_phases'] == 3
        assert summary['io_writes'] == 3 and summary['io_reads'] >= 11
        assert summary['flush_rejected'] == 6 and summary['held_d_edges']
    assert hashes() == before, 'sources changed during directed verification'
    evidence = dict(status='PASS', sources_unchanged=True, source_sha256=before,
                    command=command, exit_code=result.returncode, modes=modes,
                    compile_zero_warning_error=True,
                    cases=sum(m['cases'] for m in modes),
                    retired=sum(m['retired'] for m in modes),
                    sync_traps=sum(m['sync_traps'] for m in modes),
                    irqs=sum(m['irqs'] for m in modes),
                    io_reads=sum(m['io_reads'] for m in modes),
                    io_writes=sum(m['io_writes'] for m in modes),
                    scope='CPU5 opt-in ordered MMIO control with independent endpoint handshake effects; no SoC/board claim')
    (OUT / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: evidence[key] for key in
                     ('status', 'cases', 'retired', 'sync_traps', 'irqs', 'io_reads', 'io_writes')}))


if __name__ == '__main__':
    main()
