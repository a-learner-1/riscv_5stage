"""Generate and audit the real-IF FENCE ordering, machine device and interrupt matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
from cpu5_cache_reference import analyze, selftest_decoder, selftest_evidence

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s13_cache_program'
SOURCES = ['rtl/instr_mem.v', 'rtl/instr_bus_adapter.v', 'rtl/branch_predictor.v', 'rtl/if_stage.v',
           'rtl/alu.v', 'rtl/regfile.v', 'rtl/rv32m_unit.v', 'rtl/cpu5_if_adapter.v', 'rtl/cpu5_hazard.v',
           'rtl/cpu5_pipeline_skeleton.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
           'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v', 'rtl/cpu5_csr_unit.v', 'rtl/cpu5_m_owner.v',
           'rtl/cpu5_irq_ctrl.v', 'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_top.v','rtl/cpu5_cached_top.v','rtl/cpu5_cache_adapter.v','rtl/instr_cache.v','rtl/data_cache.v', 'rtl/cpu5_pipeline_types.vh',
           'rtl/cpu5_mmio_endpoint.v', 'rtl/cpu5_mmio_router.v', 'rtl/cpu5_machine_endpoint.v', 'rtl/cpu5_machine_router.v', 'rtl/machine_timer.v', 'rtl/gpio_mmio.v', 'rtl/uart_tx.v',
           'rtl/uart_rx.v', 'rtl/uart_rx_fifo.v', 'rtl/uart_rx_mmio.v', 'tb/cpu5_cache_program_tb.v',
           'run_cpu5_cache_program.do', 'tools/run_cpu5_cache_program.py', 'tools/cpu5_cache_reference.py',
           'tools/cpu5_csr_reference.py', 'tools/cpu5_m_reference.py','programs/data_handshake_blank.hex']


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
    main=[];handler=[];labels={};fixups=[];fence_words=[];ordered_pairs=[]
    def emit(word):
        pc=len(main)*4;main.append(word)
        if word&127==15 and (word>>12)&7==0:fence_words.append((pc,word))
        return pc
    def fence(word=0x0ff0000f):return emit(word)
    def pair(word):
        pc=emit(word);ordered_pairs.append([pc-4,pc]);return pc
    for word in (0x000100b7,0x20000137,addi(3,0,1),addi(4,0,-1),addi(5,0,0x200),csr(0,0x305,1,5),
                 0x000012b7,addi(5,5,-0x778),csr(0,0x304,1,5),store(3,2,0x50)):emit(word)
    fence();pair(load(6,2,0x50))
    # Every reserved source/destination/fm bit is architecturally ignored.
    # x31 is still uninitialized here, so reading/writing it is observable.
    fence(0xffff8f8f)
    for word in (csr(7,0x344,2,0),csr(0,0x344,1,0),csr(8,0x344,2,0),csr(0,0x300,5,8)):emit(word)
    first_mepc=len(main)*4
    emit(csr(0,0x300,5,0));emit(store(0,2,0x44));fence(0x0000000f)
    pair(store(0,2,0x40));fence(0x8330000f);pair(load(9,2,0x40));emit(load(10,2,0x44))
    emit(store(9,1,0));fence(0x0010000f);pair(load(28,1,0));emit(store(8,1,4))
    emit(store(0,2,0x4c));emit(store(0,2,0x48));fence();pair(load(11,2,0x48));emit(load(12,2,0x4c))
    priority_set_pc=emit(store(3,2,0x50));fence(0x0000000f)
    for word in (csr(7,0x344,2,0),csr(0,0x344,1,0),csr(13,0x344,2,0),csr(0,0x300,5,8)):emit(word)
    priority_mepc=len(main)*4
    emit(csr(0,0x300,5,0));fence(0xf1200f8f)
    pair(load(14,2,0x48))
    for word in (load(15,2,0x4c),load(16,2,0x50),csr(17,0x344,2,0),store(14,1,8),store(15,1,12),
                 store(16,1,16),store(17,1,20),addi(3,0,7),0x02318933):emit(word)
    branch_pc=emit(branch(0,0,12));emit(store(3,2,0x50));emit(store(0,2,0x4c))
    fence(0x0100000f);sync_pc=emit(0x0000100f)
    emit(addi(31,0,0x77));emit(store(31,2,0x20));fence();pair(load(27,2,0x20));fence(0x8000000f)
    pair(store(27,1,24));fence(0x000f808f)
    for word in (load(6,1,0),load(6,1,4),load(6,1,0),store(3,1,28,0),load(6,1,28,4),store(3,1,30,1),load(6,1,28),load(6,1,32),load(6,1,64),load(6,1,0),load(6,1,32),load(6,1,64),load(6,1,0)):emit(word)
    emit(addi(6,0,0x3e0));terminal_pc=emit(0x00030067)
    def h(word):
        pc=0x200+len(handler)*4;handler.append(word)
        if word&127==15 and (word>>12)&7==0:fence_words.append((pc,word))
        return pc
    def label(name):labels[name]=0x200+len(handler)*4
    def hb(a,b,target,function=0):fixups.append((len(handler),a,b,target,function));h(0)
    for word in (csr(20,0x342,2,0),csr(21,0x341,2,0),csr(22,0x300,2,0),csr(23,0x343,2,0),
                 csr(24,0x340,2,0),addi(24,24,1),csr(0,0x340,1,24),addi(25,0,16),0x039c0cb3,0x01908cb3,
                 store(21,25,64),store(20,25,68),store(22,25,72),store(23,25,76),0x0ff0000f):h(word)
    hb(20,0,'irq',4)
    for word in (addi(21,21,4),csr(0,0x341,1,21),0x0000000f,0x30200073):h(word)
    label('irq');h(0x80000d37);h(addi(26,26,3));hb(20,26,'software');h(addi(26,26,4));hb(20,26,'timer')
    h(0x8330000f);h(0x30200073)
    label('software');h(store(0,2,0x50));h(0x0ff0000f);h(load(29,2,0x50));h(0x30200073)
    label('timer');h(store(4,2,0x4c));h(0x0ff0000f);h(store(4,2,0x48));h(0x0000000f);h(load(30,2,0x4c));h(0x30200073)
    for index,a,b,target,function in fixups:handler[index]=branch(a,b,labels[target]-(0x200+index*4),function)
    words[:len(main)]=main;words[128:128+len(handler)]=handler
    fixture=dict(first_mepc=first_mepc,priority_mepc=priority_mepc,priority_set_pc=priority_set_pc,
                 branch_pc=branch_pc,wrongpath_pcs=[branch_pc+4,branch_pc+8],sync_pcs=[sync_pc],
                 terminal_pc=terminal_pc,ram_words=64,irq_causes=[0x80000003,0x8000000b,0x80000003,0x80000007],
                 fence_words=[dict(pc=pc,instr=word) for pc,word in fence_words],ordered_pairs=ordered_pairs,
                 coverage=['SW/FENCE/LW RAM and GPIO device write/FENCE/readback',
                           'canonical 0ff0000f, FENCE.TSO 8330000f, zero masks, ignored fm/rd/rs1',
                           'FENCE.I precise illegal instruction and trap handler skip/MRET',
                           'timer/MSIP write-FENCE, four prioritized IRQs and MRET restoration',
                           'per-edge Fence MEM/owner/exmove/D/M issue/WB/IF observation',
                           'ID/EX x BP x I/D wait x forwarding'],
                 reachability_limit='Top has no external flush: issued LOAD becomes live MEM atomically and masks IRQ, so killed-D drain waiting is tested by the direct-core control suite, not claimed here.')
    write_hex(directory/'program.hex',words);write_hex(directory/'ram_initial.hex',[0x10000000+i for i in range(64)])
    write_hex(directory/'fixture.hex',[fixture[k] for k in ('first_mepc','priority_mepc','priority_set_pc','terminal_pc','branch_pc')]+[sync_pc])
    (directory/'fixture.json').write_text(json.dumps(fixture,indent=2)+'\n',encoding='utf-8')
    for case in range(64):(directory/f'cases/case{case}').mkdir(parents=True,exist_ok=True)
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
    # Stage an exact source snapshot. Every ModelSim subprocess, ini and work
    # library stays inside this suite's private directory, even inside Tcl.
    private=OUT/'simulator'/'stage';private.mkdir(parents=True,exist_ok=True)
    staged_names=SOURCES
    for name in staged_names:
        target=private/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
    assert all(hashlib.sha256((private/name).read_bytes()).hexdigest()==before[name] for name in SOURCES),'staged source mismatch'
    mapping=subprocess.run([str(args.vsim.with_name('vmap.exe')),'-c'],cwd=private,capture_output=True,text=True,encoding='utf-8',errors='replace')
    assert mapping.returncode==0 and (private/'modelsim.ini').is_file(),mapping.stdout+mapping.stderr
    process=subprocess.run([str(args.vsim),'-c','-modelsimini',str(private/'modelsim.ini'),'-do','do run_cpu5_cache_program.do'],cwd=private,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    staged_out=private/'build/cpu5_s13_cache_program'
    if staged_out.is_dir():shutil.copytree(staged_out,OUT,dirs_exist_ok=True)
    output=process.stdout+process.stderr;(OUT/'console.log').write_text(output,encoding='utf-8',newline='')
    assert process.returncode==0 and 'CPU5 CACHE PROGRAM PASS' in output,(process.returncode,output[-10000:])
    assert not any(line.lstrip().startswith(('# ** Fatal:','# ** Error:','# ** Warning:','Traceback (')) for line in output.splitlines()),'unexpected simulator diagnostic'
    result=analyze(OUT);result['negative_evidence_tests']=selftest_evidence(OUT)
    assert before=={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in SOURCES},'source changed during FENCE program run'
    result.update(private_simulator_cwd=str(private),staged_sources_match=True,source_sha256=before,sources_unchanged=True,compile_zero_warning_error=True,processes=[dict(name='program',status='PASS',exit_code=0)])
    (OUT/'analysis.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','case_count','total_retired','total_irqs','total_sync_traps','total_d_requests','total_device_effects')}))


if __name__=='__main__':
    main()
