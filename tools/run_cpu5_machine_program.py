"""Generate and audit the real-IF machine timer/software interrupt program matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from cpu5_machine_reference import analyze, selftest_decoder, selftest_evidence

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s11_machine_program'
SOURCES = ['rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v', 'rtl/if_stage.v',
           'rtl/alu.v', 'rtl/regfile.v', 'rtl/rv32m_unit.v', 'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v',
           'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
           'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/cpu5_m_owner.v',
           'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_top.v', 'rtl/cpu5_pipeline_types.vh',
           'rtl/cpu5_mmio_endpoint.v', 'rtl/cpu5_mmio_router.v', 'rtl/cpu5_machine_endpoint.v', 'rtl/cpu5_machine_router.v', 'rtl/machine_timer.v', 'rtl/gpio_mmio.v', 'rtl/uart_tx.v',
           'rtl/uart_rx.v', 'rtl/uart_rx_fifo.v', 'rtl/uart_rx_mmio.v', 'tb/cpu5_machine_program_tb.v',
           'run_cpu5_machine_program.do', 'tools/run_cpu5_machine_program.py', 'tools/cpu5_machine_reference.py',
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
    words=[0x0000006f]*256
    main=[0x000100b7,0x20000137,addi(3,0,1),addi(4,0,-1),addi(5,0,0x200),csr(0,0x305,1,5),
          0x000012b7,addi(5,5,-0x778),csr(0,0x304,1,5),store(3,2,0x50),load(6,2,0x50),
          csr(7,0x344,2,0),csr(0,0x344,1,0),csr(8,0x344,2,0),csr(0,0x300,5,8)]
    first_mepc=len(main)*4
    main += [csr(0,0x300,5,0),store(0,2,0x44),store(0,2,0x40),load(9,2,0x40),load(10,2,0x44),
             store(9,1,0),store(8,1,4),store(0,2,0x4c),store(0,2,0x48),load(11,2,0x48),load(12,2,0x4c)]
    priority_set_pc=len(main)*4
    main += [store(3,2,0x50),csr(7,0x344,2,0),csr(0,0x344,1,0),csr(13,0x344,2,0),csr(0,0x300,5,8)]
    priority_mepc=len(main)*4
    main += [csr(0,0x300,5,0),load(14,2,0x48),load(15,2,0x4c),load(16,2,0x50),csr(17,0x344,2,0),
             store(14,1,8),store(15,1,12),store(16,1,16),store(17,1,20),addi(3,0,7),0x02318933]
    branch_pc=len(main)*4
    main += [branch(0,0,12),store(3,2,0x50),store(0,2,0x4c)]
    sync_pc=len(main)*4
    main += [load(19,2,0x40,0),addi(31,0,0x77),store(31,2,0x20),load(27,2,0x20),store(27,1,24),0x0000006f]
    handler=[csr(20,0x342,2,0),csr(21,0x341,2,0),csr(22,0x300,2,0),csr(23,0x343,2,0),
             csr(24,0x340,2,0),addi(24,24,1),csr(0,0x340,1,24),addi(25,0,16),0x039c0cb3,0x01908cb3,
             store(21,25,64),store(20,25,68),store(22,25,72),store(23,25,76),
             branch(20,0,16,4),addi(21,21,4),csr(0,0x341,1,21),0x30200073,
             0x80000d37,addi(26,26,3),branch(20,26,16),addi(26,26,4),branch(20,26,16),0x30200073,
             store(0,2,0x50),0x30200073,store(4,2,0x4c),store(4,2,0x48),0x30200073]
    words[:len(main)]=main;words[128:128+len(handler)]=handler
    fixture=dict(first_mepc=first_mepc,priority_mepc=priority_mepc,priority_set_pc=priority_set_pc,
                 branch_pc=branch_pc,wrongpath_pcs=[branch_pc+4,branch_pc+8],sync_pcs=[sync_pc],
                 terminal_pc=(len(main)-1)*4,ram_words=64,irq_causes=[0x80000003,0x8000000b,0x80000003,0x80000007],
                 coverage=['MMIO software IRQ set/read/clear; mip writes ignored',
                           'timer pre-edge read, mtime half writes, compare high/low safe clear',
                           'external/software/timer simultaneous priority and MRET restoration',
                           'independent full-cycle timer/compare/software register and two-flop/old-arm checks',
                           'wrong-path software and comparator writes have no first presentation',
                           'illegal device LB precise trap; ordinary GPIO and RAM route still operate',
                           'ID/EX x BP x I/D wait x forwarding'])
    write_hex(directory/'program.hex',words);write_hex(directory/'ram_initial.hex',[0x10000000+i for i in range(64)])
    write_hex(directory/'fixture.hex',[fixture[k] for k in ('first_mepc','priority_mepc','priority_set_pc','terminal_pc','branch_pc')]+[sync_pc])
    (directory/'fixture.json').write_text(json.dumps(fixture,indent=2)+'\n',encoding='utf-8')
    for case in range(16):(directory/f'cases/case{case}').mkdir(parents=True,exist_ok=True)
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
    command=f'cd {{{ROOT.as_posix()}}}; do run_cpu5_machine_program.do'
    process=subprocess.run([str(args.vsim),'-c','-modelsimini',str(private/'modelsim.ini'),'-do',command],cwd=private,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    output=process.stdout+process.stderr;(OUT/'console.log').write_text(output,encoding='utf-8',newline='')
    assert process.returncode==0 and 'CPU5 MACHINE PROGRAM PASS' in output,(process.returncode,output[-10000:])
    assert not any(line.lstrip().startswith(('# ** Fatal:','# ** Error:','# ** Warning:','Traceback (')) for line in output.splitlines()),'unexpected simulator diagnostic'
    result=analyze(OUT);result['negative_evidence_tests']=selftest_evidence(OUT)
    assert before=={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES},'source changed during machine program run'
    result.update(source_sha256=before,sources_unchanged=True,compile_zero_warning_error=True,processes=[dict(name='program',status='PASS',exit_code=0)])
    (OUT/'analysis.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','case_count','total_retired','total_irqs','total_sync_traps','total_d_requests','total_device_effects')}))


if __name__=='__main__':
    main()
