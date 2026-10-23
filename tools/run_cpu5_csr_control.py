"""Run force-free CPU5 CSR/MRET directed tests and close their ledgers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s7_csr_control'
SOURCES = ['rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
           'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
           'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v',
           'rtl/cpu5_pipeline_types.vh', 'rtl/cpu5_alu_pipeline.v',
           'tb/cpu5_csr_control_tb.v', 'run_cpu5_csr_control.do',
           'tools/run_cpu5_csr_control.py']


def hashes():
    return {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path,
                        default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    before = hashes()
    # Eliminate stale PASS summaries before a new simulation.
    for mode in (0, 1):
        (OUT / f'mode{mode}_summary.json').unlink(missing_ok=True)
    command = [str(args.vsim), '-c', '-do', 'run_cpu5_csr_control.do']
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=240)
    output = result.stdout + result.stderr
    (OUT / 'console.log').write_text(output, encoding='utf-8', newline='')
    assert result.returncode == 0 and 'CPU5 CSR CONTROL DIRECTED TEST PASS' in output, output[-6000:]
    assert not any(line.lstrip().startswith(('# ** Fatal:', '# ** Error:',
                                            '# ** Warning:', 'Traceback ('))
                   for line in output.splitlines()), 'simulation diagnostics'
    modes = [json.loads((OUT / f'mode{m}_summary.json').read_text()) for m in (0, 1)]
    for mode, summary in enumerate(modes):
        assert summary['pass'] and summary['mode'] == mode and summary['cases'] == 43
        assert summary['retired'] == summary['wb'] and summary['requests'] == summary['responses']
        assert summary['csr_retired'] >= 120 and summary['mret_retired'] >= 7
        assert summary['traps'] >= 25 and summary['killed_error_responses'] == 2
        assert summary['committed_state_checks'] >= 500
        assert summary['mem_wait_edges'] and summary['held_wb_edges'] and summary['held_d_edges']
        assert summary['trap_with_old_wb_write'] and summary['retire_during_killed_drain'] >= 8
        assert summary['mret_with_old_wb_write']
        assert mode == 0 or summary['id_branch_from_pending_csr']
    assert hashes() == before, 'sources changed during directed verification'
    evidence = dict(status='PASS', sources_unchanged=True, source_sha256=before,
                    command=command, exit_code=result.returncode, modes=modes,
                    cases=sum(m['cases'] for m in modes),
                    retired=sum(m['retired'] for m in modes),
                    traps=sum(m['traps'] for m in modes),
                    scope='CPU5 minimal machine CSR/MRET directed control; no IRQ/M/MMIO/SoC claim')
    (OUT / 'verification.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: evidence[key] for key in ('status', 'cases', 'retired', 'traps')}))


if __name__ == '__main__':
    main()
