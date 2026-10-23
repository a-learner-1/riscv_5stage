"""Build hand-encoded real-fetch CPU5 CSR/MRET programs and audit simulation.

The producer below only emits instructions. Architectural expectations are
computed by a separate machine-word decoder that does not import these helpers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from cpu5_csr_reference import FIELDS, analyze, selftest_decoder, selftest_evidence, simulate

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s7_csr_program'
SOURCES = ['programs/data_handshake_blank.hex', 'rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v', 'rtl/if_stage.v',
           'rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v',
           'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
           'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v',
           'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_top.v', 'rtl/cpu5_pipeline_types.vh',
           'tb/cpu5_csr_program_tb.v', 'run_cpu5_csr_program.do',
           'tools/run_cpu5_csr_program.py', 'tools/cpu5_csr_reference.py']


def addi(rd, rs, immediate):
    return ((immediate & 4095) << 20) | (rs << 15) | (rd << 7) | 0x13


def csr(rd, address, function, source):
    return (address << 20) | (source << 15) | (function << 12) | (rd << 7) | 0x73


def write_hex(path, values):
    path.write_text(''.join(f'{value & 0xffffffff:08x}\n' for value in values), encoding='ascii')


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    # Encodings fixed independently in cpu5_csr_reference's hand-value tests.
    assert addi(1, 0, 0x155) == 0x15500093
    assert csr(3, 0x340, 1, 1) == 0x340091f3
    assert [csr(rd, 0x340, function, operand) for rd, function, operand in
            ((6, 2, 2), (7, 3, 2), (8, 5, 3), (9, 6, 20), (10, 7, 5))] == [0x34012373, 0x340133f3, 0x3401d473, 0x340a64f3, 0x3402f573]
    program = [0x0000006f] * 512
    body = [addi(1, 0, 0x155), csr(3, 0x340, 1, 1), addi(4, 3, 1),
            csr(5, 0x340, 2, 0), addi(2, 0, 10), csr(6, 0x340, 2, 2),
            csr(7, 0x340, 3, 2), csr(8, 0x340, 5, 3), csr(9, 0x340, 6, 20),
            csr(10, 0x340, 7, 5), csr(11, 0x340, 6, 0), csr(12, 0x340, 7, 0),
            csr(0, 0x340, 1, 0), csr(13, 0x340, 2, 0), addi(2, 0, 0),
            csr(14, 0x340, 2, 2), csr(15, 0x340, 3, 2), csr(0, 0x340, 5, 0),
            csr(16, 0x340, 2, 0), addi(1, 0, -1), csr(0, 0x300, 1, 1),
            csr(17, 0x300, 2, 0), csr(0, 0x300, 5, 8),
            addi(1, 0, 0x63), csr(0, 0x341, 1, 1), csr(18, 0x341, 2, 0),
            addi(1, 0, 0x355), csr(0, 0x342, 1, 1), csr(19, 0x342, 2, 0),
            addi(1, 0, -1), csr(0, 0x343, 1, 1), csr(19, 0x343, 2, 0),
            addi(1, 0, 0x403), csr(0, 0x305, 1, 1), csr(18, 0x305, 2, 0),
            0x00000073, csr(17, 0x300, 2, 0), addi(1, 0, 0x503),
            csr(0, 0x305, 1, 1), csr(18, 0x305, 2, 0), 0x00100073]
    # Fixed misa truthfully advertises RV32I, with ignored WARL writes.
    body += [csr(24, 0x301, function, source) for function, source in
             ((1, 0), (2, 0), (3, 2), (5, 0), (6, 31), (7, 31))]
    # Every implemented ID is read-only zero. Read suppression and actual
    # zero operand values are distinct from architectural write intent.
    body += [csr(24, address, 2, 0) for address in range(0xf11, 0xf16)]
    body += [csr(24, address, function, source) for address, function, source in
             ((0xf11, 1, 0), (0xf12, 2, 2), (0xf13, 3, 2), (0xf14, 5, 0), (0xf15, 7, 1))]
    body += [csr(24, 0xf11, 6, 0), csr(24, 0xf15, 7, 0)]
    body += [csr(25, address, 2, 0) for address in (0x304, 0x344, 0xb00, 0xb02, 0xc00, 0xc02, 0x7c0)]
    # An unknown SYSTEM instruction and illegal CSR funct3 remain precise.
    body += [0x10500073, 0x34004073, csr(26, 0x342, 2, 0),
             csr(27, 0x343, 2, 0), csr(28, 0x340, 2, 0), addi(29, 28, 7),
             addi(31, 0, 0x5a), 0x0000006f]
    assert len(body) * 4 < 0x400, 'main body overlaps first handler'
    terminal = (len(body) - 1) * 4
    program[:len(body)] = body
    handler = [csr(20, 0x342, 2, 0), csr(21, 0x341, 2, 0), csr(22, 0x343, 2, 0),
               csr(23, 0x300, 2, 0), addi(21, 21, 4), csr(0, 0x341, 1, 21),
               csr(0, 0x342, 5, 0), csr(0, 0x343, 5, 0), 0x30200073]
    for address in (0x400, 0x500):
        program[address // 4:address // 4 + len(handler)] = handler
    write_hex(directory / 'program.hex', program)
    reference = simulate(program)
    for field in FIELDS:
        write_hex(directory / f'expected_{field}.hex', [int(x[field] == 'trap') if field == 'kind' else x[field] for x in reference['events']])
    (directory / 'final_gpr.hex').write_text(''.join('xxxxxxxx\n' if value is None else f'{value:08x}\n' for value in reference['gpr']), encoding='ascii')
    write_hex(directory / 'final_gpr_mask.hex', [int(value is not None) for value in reference['gpr']])
    write_hex(directory / 'terminal_pc.hex', [terminal])
    fixture = dict(rom_words=512, terminal_pc=terminal, instructions=len(body), handler_vectors=[0x400, 0x500],
                   expected_traps=len([x for x in reference['events'] if x['kind'] == 'trap']),
                   notes=['six CSR opcodes, CSR result consumer, back-to-back CSR RAW',
                          'zero source value with nonzero source register retains write intent',
                          'mstatus MIE/MPIE and fixed MPP; direct mtvec/mepc low bits WARL',
                          'handler reads trap state, edits mepc, clears software mcause/mtval, MRET',
                          'fixed RV32I misa writes ignored; IDs zero read-only',
                          'unsupported mie/mip/counters/unknown CSR and unknown SYSTEM illegal',
                          'defined and untouched unknown physical GPRs checked separately'])
    (directory / 'fixture.json').write_text(json.dumps(fixture, indent=2) + '\n', encoding='utf-8')
    for case in range(16):
        (directory / f'cases/case{case}').mkdir(parents=True, exist_ok=True)
    (directory / 'vector_manifest.json').write_text(json.dumps({x.name: hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted(directory.glob('*.hex'))}, indent=2) + '\n', encoding='utf-8')
    return fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    parser.add_argument('--generate-only', action='store_true')
    args = parser.parse_args()
    if args.generate_only:
        print(json.dumps(dict(status='PASS', vectors=generate(OUT), decoder=selftest_decoder())));return
    before = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}
    generate(OUT)
    process = subprocess.run([str(args.vsim), '-c', '-do', 'run_cpu5_csr_program.do'], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=240)
    output = process.stdout + process.stderr
    (OUT / 'console.log').write_text(output, encoding='utf-8', newline='')
    assert process.returncode == 0 and 'CPU5 CSR PROGRAM PASS' in output, (process.returncode, output[-6000:])
    assert not any(line.lstrip().startswith(('# ** Fatal:', '# ** Error:', '# ** Warning:', 'Traceback (')) for line in output.splitlines()), 'unexpected simulator diagnostic'
    result = analyze(OUT)
    result['negative_evidence_tests'] = selftest_evidence(OUT)
    (OUT / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    assert before == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}, 'source changed during CSR program run'
    result.update(source_sha256=before, sources_unchanged=True, processes=[dict(name='program', status='PASS', exit_code=0)])
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='PASS', cases=result['case_count'], total_retired=result['total_retired'], total_wb_packets=result['total_wb_packets'], total_traps=result['total_traps'], negative_evidence_rejected=result['negative_evidence_tests']['rejected_count'])))


if __name__ == '__main__':
    main()
