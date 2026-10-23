"""Generate hand-encoded CPU5 RV32M programs; run and independently audit RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from cpu5_m_reference import FIELDS, analyze, decoder_selftest, selftest_evidence, simulate

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s8_m_program'
SOURCES = ['rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v', 'rtl/if_stage.v',
           'rtl/alu.v', 'rtl/regfile.v', 'rtl/rv32m_unit.v', 'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v',
           'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
           'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/cpu5_m_owner.v',
           'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_top.v', 'rtl/cpu5_pipeline_types.vh',
           'tb/cpu5_m_program_tb.v', 'run_cpu5_m_program.do', 'tools/run_cpu5_m_program.py', 'tools/cpu5_m_reference.py']


def addi(rd, source, value):
    return ((value & 4095) << 20) | (source << 15) | (rd << 7) | 0x13


def m(rd, left, right, function):
    return (1 << 25) | (right << 20) | (left << 15) | (function << 12) | (rd << 7) | 0x33


def store(source, base, offset):
    return (((offset & 4095) >> 5) << 25) | (source << 20) | (base << 15) | (2 << 12) | ((offset & 31) << 7) | 0x23


def load(rd, base, offset):
    return ((offset & 4095) << 20) | (base << 15) | (2 << 12) | (rd << 7) | 3


def beq(left, right, offset):
    return (((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) | (right << 20) | (left << 15) | (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63


def write_hex(path, values):
    path.write_text(''.join(f'{value & 0xffffffff:08x}\n' for value in values), encoding='ascii')


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    assert m(4, 2, 3, 0) == 0x02310233 and m(4, 2, 3, 7) == 0x02317233
    assert store(25, 1, 0) == 0x0190a023 and load(26, 1, 0) == 0x0000ad03
    words = [0x0000006f] * 256
    body = [0x000100b7, addi(2, 0, -7), addi(3, 0, 3)]
    body += [m(4 + function, 2, 3, function) for function in range(8)]
    body += [0x80000637, addi(13, 0, -1), m(14, 12, 13, 4), m(15, 12, 13, 6),
             m(16, 2, 0, 4), m(17, 2, 0, 6), m(18, 2, 0, 5), m(19, 2, 0, 7),
             m(20, 12, 13, 1), m(20, 12, 13, 2), m(20, 13, 13, 3), m(20, 13, 13, 0),
             m(0, 13, 3, 0), m(20, 2, 3, 4), addi(21, 20, 10), addi(23, 0, 24), addi(24, 0, 55),
             m(22, 21, 3, 0), beq(22, 23, 8), addi(24, 0, 99),
             m(25, 22, 3, 0), store(25, 1, 0), load(26, 1, 0), m(27, 26, 3, 4),
             store(27, 1, 4), m(20, 27, 3, 0), m(20, 20, 3, 4),
             addi(29, 0, 4), 0x00004f37, m(29, 29, 30, 0), load(30, 29, 4),
             0x30102f73, addi(2, 0, 7), addi(3, 0, -3), m(20, 2, 3, 4), m(21, 2, 3, 6),
             m(22, 2, 3, 2), m(23, 0, 3, 4), m(24, 0, 3, 6),
             m(25, 12, 0, 4), m(26, 12, 0, 6), m(27, 13, 13, 0),
             store(20, 1, 8), store(21, 1, 12), 0x0000006f]
    terminal = (len(body) - 1) * 4
    words[:len(body)] = body
    initial = [0x10000000 + index for index in range(8)]
    reference = simulate(words, initial)
    write_hex(directory / 'program.hex', words);write_hex(directory / 'ram_initial.hex', initial)
    write_hex(directory / 'ram_final.hex', reference['memory']);write_hex(directory / 'terminal_pc.hex', [terminal])
    for field in FIELDS:
        write_hex(directory / f'expected_{field}.hex', [row[field] for row in reference['events']])
    for field in ('pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write', 'rdata'):
        write_hex(directory / f'expected_mem_{field}.hex', [row[field] for row in reference['accesses']])
    (directory / 'final_gpr.hex').write_text(''.join('xxxxxxxx\n' if value is None else f'{value:08x}\n' for value in reference['gpr']), encoding='ascii')
    write_hex(directory / 'final_gpr_mask.hex', [int(value is not None) for value in reference['gpr']])
    fixture = dict(rom_words=256, ram_words=8, terminal_pc=terminal, body_instructions=len(body), m_count=sum(row['is_m'] for row in reference['events']), d_count=len(reference['accesses']),
                   coverage=['MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU', 'signed and mixed high products',
                             'signed quotient truncates toward zero; remainder follows dividend', 'divide by zero and INT_MIN/-1 fast paths',
                             'back-to-back distinct sticky-done generations and rd=x0', 'GPR→M and M→M/ALU/branch/store/load address',
                             'RAM signatures and all physical GPRs including untouched unknowns', 'truthful misa RV32IM'])
    (directory / 'fixture.json').write_text(json.dumps(fixture, indent=2) + '\n', encoding='utf-8')
    write_hex(directory / 'memory_count.hex', [fixture['d_count']])
    for case in range(16):
        (directory / f'cases/case{case}').mkdir(parents=True, exist_ok=True)
    (directory / 'vector_manifest.json').write_text(json.dumps({path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(directory.glob('*.hex'))}, indent=2) + '\n', encoding='utf-8')
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    parser.add_argument('--generate-only', action='store_true');args = parser.parse_args()
    if args.generate_only:
        print(json.dumps(dict(status='PASS', vectors=generate(OUT), decoder=decoder_selftest())));return
    before = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}
    generate(OUT)
    process = subprocess.run([str(args.vsim), '-c', '-do', 'run_cpu5_m_program.do'], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=240)
    output = process.stdout + process.stderr;(OUT / 'console.log').write_text(output, encoding='utf-8', newline='')
    assert process.returncode == 0 and 'CPU5 M PROGRAM PASS' in output, (process.returncode, output[-7000:])
    assert not any(line.lstrip().startswith(('# ** Fatal:', '# ** Error:', '# ** Warning:', 'Traceback (')) for line in output.splitlines()), 'unexpected simulator diagnostic'
    result = analyze(OUT);result['negative_evidence_tests'] = selftest_evidence(OUT)
    assert before == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}, 'source changed during real M program run'
    (OUT / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    result.update(source_sha256=before, sources_unchanged=True, processes=[dict(name='program', status='PASS', exit_code=0)])
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='PASS', cases=result['case_count'], total_retired=result['total_retired'], total_wb_packets=result['total_wb_packets'], total_m_issues=result['total_m_issues'], total_m_completions=result['total_m_completions'], total_d_requests=result['total_d_requests'], bad_evidence_rejected=result['negative_evidence_tests']['rejected_count'])))


if __name__ == '__main__':
    main()
