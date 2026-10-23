"""Generate the deterministic DIV/three-IRQ fixture and audit fresh RTL runs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from cpu5_irq_reference import FIELDS, analyze, decoder_selftest, selftest_evidence, simulate

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s9_irq_program'
SOURCES = ['rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v', 'rtl/if_stage.v',
           'rtl/alu.v', 'rtl/regfile.v', 'rtl/rv32m_unit.v', 'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v',
           'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
           'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/cpu5_m_owner.v', 'rtl/cpu5_irq_ctrl.v',
           'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_top.v', 'rtl/cpu5_pipeline_types.vh',
           'tb/cpu5_irq_program_tb.v', 'run_cpu5_irq_program.do', 'tools/run_cpu5_irq_program.py', 'tools/cpu5_irq_reference.py',
           'tools/cpu5_m_reference.py', 'tools/cpu5_csr_reference.py']


def addi(rd, rs, value):
    return ((value & 4095) << 20) | (rs << 15) | (rd << 7) | 0x13


def csr(rd, address, function, source):
    return (address << 20) | (source << 15) | (function << 12) | (rd << 7) | 0x73


def store(source, base, offset):
    return (((offset & 4095) >> 5) << 25) | (source << 20) | (base << 15) | (2 << 12) | ((offset & 31) << 7) | 0x23


def write_hex(path, values):
    path.write_text(''.join(f'{value & 0xffffffff:08x}\n' for value in values), encoding='ascii')


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    program = [0x0000006f] * 256
    main = [0x000100b7, addi(2, 0, 0x200), csr(0, 0x305, 1, 2), 0x00001137,
            addi(2, 2, -0x778), csr(0, 0x304, 1, 2), csr(3, 0x304, 2, 0),
            csr(0, 0x344, 1, 2), csr(4, 0x344, 2, 0), addi(5, 0, -123),
            addi(6, 0, 7), csr(0, 0x300, 5, 8), 0x0262c3b3,
            addi(8, 7, 20), store(8, 1, 0), 0x0000a483, csr(10, 0x344, 2, 0),
            csr(11, 0x300, 2, 0), csr(12, 0x304, 2, 0), csr(13, 0x340, 2, 0),
            0x30102f73, 0x0000006f]
    assert main[12] == 0x0262c3b3 and store(8, 1, 0) == 0x0080a023
    handler = [csr(20, 0x342, 2, 0), csr(21, 0x341, 2, 0), csr(22, 0x300, 2, 0),
               csr(23, 0x343, 2, 0), csr(24, 0x340, 2, 0), addi(24, 24, 1),
               csr(0, 0x340, 1, 24), addi(25, 0, 16), 0x039c0cb3,
               0x01908cb3, store(21, 25, 0), store(20, 25, 4),
               store(22, 25, 8), store(23, 25, 12), 0x30200073]
    program[:len(main)] = main;program[128:128 + len(handler)] = handler
    initial = [0x10000000 + index for index in range(16)]
    fixture = dict(div_pc=0x30, held_if_pc=0x34, terminal_pc=(len(main) - 1) * 4, handler_pc=0x200,
                   ram_words=16, d_count=14, irq_causes=[0x8000000b, 0x80000003, 0x80000007],
                   coverage=['all sources pending, external > software > timer', 'two synchronizer stages and per-cycle old arm/current state audit',
                             'IRQ cancels running DIV without waiting; old generation drains once', 'ISR MUL waits for old M resource, then uses fresh result',
                             'continuous remaining pending IRQ exactly one edge after MRET', 'mepc derived solely from known program DIV boundary',
                             'held stale IF error drained after IRQ', 'handler CSR snapshots saved into separate ordinary RAM slots',
                             'mie WARL, mip hardware-only writes ignored, final pending zero', 'ID/EX, BP, I/D waits and forwarding off/on'])
    reference = simulate(program, initial, fixture['div_pc'])
    assert len(reference['accesses']) == fixture['d_count']
    write_hex(directory / 'program.hex', program);write_hex(directory / 'ram_initial.hex', initial)
    write_hex(directory / 'ram_final.hex', reference['memory']);write_hex(directory / 'terminal_pc.hex', [fixture['terminal_pc']])
    for field in FIELDS:
        write_hex(directory / f'expected_{field}.hex', [int(row[field] == 'irq') if field == 'kind' else row[field] for row in reference['events']])
    for field in ('pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write', 'rdata'):
        write_hex(directory / f'expected_mem_{field}.hex', [row[field] for row in reference['accesses']])
    (directory / 'final_gpr.hex').write_text(''.join('xxxxxxxx\n' if value is None else f'{value:08x}\n' for value in reference['gpr']), encoding='ascii')
    write_hex(directory / 'final_gpr_mask.hex', [int(value is not None) for value in reference['gpr']])
    (directory / 'fixture.json').write_text(json.dumps(fixture, indent=2) + '\n', encoding='utf-8')
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
    before = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES};generate(OUT)
    process = subprocess.run([str(args.vsim), '-c', '-do', 'run_cpu5_irq_program.do'], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=240)
    output = process.stdout + process.stderr;(OUT / 'console.log').write_text(output, encoding='utf-8', newline='')
    assert process.returncode == 0 and 'CPU5 IRQ PROGRAM PASS' in output, (process.returncode, output[-8000:])
    assert not any(line.lstrip().startswith(('# ** Fatal:', '# ** Error:', '# ** Warning:', 'Traceback (')) for line in output.splitlines()), 'unexpected simulator diagnostic'
    result = analyze(OUT);result['negative_evidence_tests'] = selftest_evidence(OUT)
    assert before == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in SOURCES}, 'source changed during IRQ program run'
    (OUT / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    result.update(source_sha256=before, sources_unchanged=True, processes=[dict(name='program', status='PASS', exit_code=0)])
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='PASS', cases=result['case_count'], total_retired=result['total_retired'], total_wb_packets=result['total_wb_packets'], total_irqs=result['total_irqs'], total_m_drains=result['total_m_drains'], total_d_requests=result['total_d_requests'], bad_evidence_rejected=result['negative_evidence_tests']['rejected_count'])))


if __name__ == '__main__':
    main()
