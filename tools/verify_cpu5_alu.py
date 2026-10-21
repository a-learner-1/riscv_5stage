"""Reproduce stage 3A-1 ALU subset tests; this is not full CPU5 ISA acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s2_verification'
SOURCES = [
    'rtl/cpu5_top.v', 'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_alu_decode.v',
    'rtl/cpu5_pipeline_types.vh', 'rtl/cpu5_pipeline_skeleton.v',
    'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v', 'rtl/if_stage.v',
    'rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v',
    'rtl/alu.v', 'rtl/regfile.v',
    'tb/cpu5_alu_decode_tb.v', 'tb/cpu5_alu_top_tb.v', 'tb/cpu5_alu_control_tb.v',
    'run_cpu5_alu_decode.do', 'run_cpu5_alu_top.do', 'run_cpu5_alu_control.do',
    'tools/generate_cpu5_alu_vectors.py', 'tools/analyze_cpu5_alu_trace.py',
    'tools/verify_cpu5_alu.py',
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    # Ensure vmap only updates this workspace's local simulator configuration.
    if not (ROOT / 'modelsim.ini').exists():
        subprocess.run([str(args.vsim.with_name('vmap.exe')), '-c'], cwd=ROOT, check=True)
    before = {name: digest(ROOT / name) for name in SOURCES}
    processes = []
    commands = [
        ('decode', [str(args.vsim), '-c', '-do', 'run_cpu5_alu_decode.do'], 'CPU5_ALU_DECODE PASS'),
        ('top', [str(args.vsim), '-c', '-do', 'run_cpu5_alu_top.do'], 'CPU5 ALU TOP PASS'),
        ('control', [str(args.vsim), '-c', '-do', 'run_cpu5_alu_control.do'], 'CPU5_ALU_CONTROL_PASS'),
        ('trace', [sys.executable, '-B', 'tools/analyze_cpu5_alu_trace.py', '--selftest'], '"status": "PASS"'),
    ]
    for name, command, marker in commands:
        p = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=90)
        output = p.stdout + p.stderr
        (OUT / (name + '_console.log')).write_text(output, encoding='utf-8', newline='')
        assert p.returncode == 0 and marker in output, (name, p.returncode, output[-2500:])
        assert not any(s in output for s in ('** Fatal:', '** Error:', '** Warning:')), name
        processes.append(dict(name=name, exit_code=p.returncode, status='PASS'))
    after = {name: digest(ROOT / name) for name in SOURCES}
    assert before == after, 'tests changed source files'
    trace = json.loads((ROOT / 'build/cpu5_s2_alu/independent_trace_audit.json').read_text())
    result = dict(status='PARTIAL VERIFIED: stage 3A-1 integer ALU only',
                  processes=processes, source_sha256=before, sources_unchanged=True,
                  case_count=trace['case_count'], total_retired=trace['total_retired'],
                  total_wb_packets=trace['total_wb_packets'], total_gpr_writes=trace['total_gpr_writes'],
                  full_A01_A16='NOT RUN', forwarding='NOT IMPLEMENTED',
                  branch_D_M_CSR_Trap_IRQ='NOT IMPLEMENTED',
                  STA='NOT RUN', board='NOT RUN')
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: result[k] for k in ('status', 'case_count', 'total_retired', 'total_wb_packets', 'total_gpr_writes')}))


if __name__ == '__main__':
    main()
