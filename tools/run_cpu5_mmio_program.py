"""Generate and audit the real-IF UART/GPIO/ordered-device program matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from cpu5_mmio_reference import analyze, selftest_decoder, selftest_evidence

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s10_mmio_program'
SOURCES = ['rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v', 'rtl/if_stage.v',
           'rtl/alu.v', 'rtl/regfile.v', 'rtl/rv32m_unit.v', 'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v',
           'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
           'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/cpu5_m_owner.v',
           'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_top.v', 'rtl/cpu5_pipeline_types.vh',
           'rtl/cpu5_mmio_endpoint.v', 'rtl/cpu5_mmio_router.v', 'rtl/gpio_mmio.v', 'rtl/uart_tx.v',
           'rtl/uart_rx.v', 'rtl/uart_rx_fifo.v', 'rtl/uart_rx_mmio.v', 'tb/cpu5_mmio_program_tb.v',
           'run_cpu5_mmio_program.do', 'tools/run_cpu5_mmio_program.py', 'tools/cpu5_mmio_reference.py',
           'tools/cpu5_csr_reference.py', 'tools/cpu5_m_reference.py']


def addi(rd, rs, value):
    return ((value & 4095) << 20) | (rs << 15) | (rd << 7) | 0x13


def csr(rd, address, function, source):
    return (address << 20) | (source << 15) | (function << 12) | (rd << 7) | 0x73


def load(rd, base, offset, function=2):
    return ((offset & 4095) << 20) | (base << 15) | (function << 12) | (rd << 7) | 3


def store(source, base, offset, function=2):
    return (((offset & 4095) >> 5) << 25) | (source << 20) | (base << 15) | (function << 12) | ((offset & 31) << 7) | 0x23


def branch(a, b, offset, function=0):
    return (((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) | (b << 20) | (a << 15) | (function << 12) | (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63


def write_hex(path, values):
    path.write_text(''.join(f'{value & 0xffffffff:08x}\n' for value in values), encoding='ascii')


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    words = [0x0000006f] * 256
    main = [0x000100b7, 0x20000137, 0x300001b7, 0x90000237,
            addi(5, 0, 0x200), csr(0, 0x305, 1, 5), 0x000012b7,
            addi(5, 5, -2048), csr(0, 0x304, 1, 5), csr(0, 0x300, 5, 8),
            addi(5, 0, 0x55), store(5, 2, 0x20), addi(5, 0, 0xff), store(5, 2, 0x28),
            addi(5, 0, 0x0a), store(5, 2, 0x2c), addi(5, 0, 4), store(5, 2, 0x30),
            addi(5, 0, 3), store(5, 2, 0x34), load(6, 2, 0x20), store(6, 1, 8),
            load(7, 2, 0x24), load(8, 2, 0x18), store(8, 1, 0), load(9, 2, 0x18), store(9, 1, 4),
            addi(5, 0, 0x51), store(5, 2, 0x10, 0), load(10, 2, 0), store(10, 1, 12),
            load(11, 2, 4), store(11, 1, 16)]
    stats_pc = len(main) * 4
    main += [load(12, 3, 0), store(12, 1, 20), load(13, 4, 0), store(13, 1, 24)]
    branch_pc = len(main) * 4
    main += [branch(0, 0, 12), load(29, 2, 0x18), load(30, 4, 4),
             load(14, 2, 0x20, 0), store(5, 2, 0x14), addi(31, 0, 0x77), 0x0000006f]
    # BLT mcause,x0 skips synchronous-fault mepc adjustment for IRQ.
    handler = [csr(20, 0x342, 2, 0), csr(21, 0x341, 2, 0), csr(22, 0x300, 2, 0),
               csr(23, 0x343, 2, 0), csr(24, 0x340, 2, 0), addi(24, 24, 1),
               csr(0, 0x340, 1, 24), addi(25, 0, 16), 0x039c0cb3, 0x01908cb3,
               store(21, 25, 64), store(20, 25, 68), store(22, 25, 72), store(23, 25, 76),
               branch(20, 0, 12, 4), addi(21, 21, 4), csr(0, 0x341, 1, 21), 0x30200073]
    words[:len(main)] = main; words[128:128+len(handler)] = handler
    fixture = dict(stats_pc=stats_pc, irq_mepc=stats_pc+4, branch_pc=branch_pc,
                   wrongpath_pcs=[branch_pc+4, branch_pc+8], terminal_pc=(len(main)-1)*4,
                   sync_pcs=[branch_pc+12, branch_pc+16], ram_words=64, uart_bytes=[0xa6, 0x3c],
                   stats_value=0x13579bdf, unknown_value=0x2468ace0,
                   coverage=['physical UART RX A6/3C preloading; two real FIFO pops',
                             'GPIO OUT/OE/SET/CLR/XOR and synchronized input', 'physical UART TX 0x51 exactly once',
                             'cycle/instret sampled from independent pre-edge cycle and retirement prefix',
                             'Stats/unknown reads external and authorized only in MEM',
                             'held Stats read blocks IRQ, read retires and next edge IRQ takes',
                             'two precise local access faults and handler mepc skip',
                             'taken branch suppresses young pop and unknown request',
                             'ID/EX x BP x I/D wait x forwarding'])
    write_hex(directory/'program.hex', words)
    write_hex(directory/'ram_initial.hex', [0x10000000+i for i in range(64)])
    write_hex(directory/'fixture.hex', [fixture[k] for k in ('stats_pc','irq_mepc','branch_pc','terminal_pc')])
    (directory/'fixture.json').write_text(json.dumps(fixture, indent=2)+'\n', encoding='utf-8')
    for case in range(16):
        (directory/f'cases/case{case}').mkdir(parents=True, exist_ok=True)
    (directory/'vector_manifest.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.glob('*.hex'))},indent=2)+'\n',encoding='utf-8')
    return fixture


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    parser.add_argument('--generate-only',action='store_true')
    args=parser.parse_args()
    if args.generate_only:
        print(json.dumps(dict(status='PASS',vectors=generate(OUT),decoder=selftest_decoder()))); return
    before={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES}
    generate(OUT)
    # Private cwd and ini: no root ModelSim mapping is mutated by this suite.
    private=OUT/'simulator';private.mkdir(exist_ok=True)
    mapping=subprocess.run([str(args.vsim.with_name('vmap.exe')),'-c'],cwd=private,capture_output=True,text=True,encoding='utf-8',errors='replace')
    assert mapping.returncode==0 and (private/'modelsim.ini').is_file(),mapping.stdout+mapping.stderr
    command=f'cd {{{ROOT.as_posix()}}}; do run_cpu5_mmio_program.do'
    process=subprocess.run([str(args.vsim),'-c','-modelsimini',str(private/'modelsim.ini'),'-do',command],cwd=private,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    output=process.stdout+process.stderr;(OUT/'console.log').write_text(output,encoding='utf-8',newline='')
    assert process.returncode==0 and 'CPU5 MMIO PROGRAM PASS' in output,(process.returncode,output[-10000:])
    assert not any(line.lstrip().startswith(('# ** Fatal:','# ** Error:','# ** Warning:','Traceback (')) for line in output.splitlines()),'unexpected simulator diagnostic'
    result=analyze(OUT);result['negative_evidence_tests']=selftest_evidence(OUT)
    assert before=={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES},'source changed during MMIO program run'
    result.update(source_sha256=before,sources_unchanged=True,compile_zero_warning_error=True,processes=[dict(name='program',status='PASS',exit_code=0)])
    (OUT/'analysis.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','case_count','total_retired','total_irqs','total_sync_traps','total_d_requests','total_local_effects')}))


if __name__=='__main__':
    main()
