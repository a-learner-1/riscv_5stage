"""Hand-encoded synchronous-fault fixtures with an explicit normal handler.

Expected normal retirement is a bounded prefix; JAL x0,0 remains an ordinary
retiring instruction. No stop sentinel, CSR, MRET or IRQ is used.
"""
import argparse,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
FIELDS=('pc','instr','rd','value','writes','nextpc')
NAMES=('if_access','illegal','ecall','ebreak','branch_alignment','jalr_alignment',
       'load_alignment','load_range','store_alignment','store_range',
       'load_bus_error','store_bus_error','old_load_error_young_id_branch')
def addi(d,a,n):return ((n&4095)<<20)|(a<<15)|(d<<7)|0x13
def lui(d,n):return (n<<12)|(d<<7)|0x37
def load(d,a,n):return ((n&4095)<<20)|(a<<15)|(2<<12)|(d<<7)|3
def store(b,a,n):return (((n&4095)>>5)<<25)|(b<<20)|(a<<15)|(2<<12)|((n&31)<<7)|0x23
def jal(d,n):return (((n>>20)&1)<<31)|(((n>>1)&1023)<<21)|(((n>>11)&1)<<20)|(((n>>12)&255)<<12)|(d<<7)|0x6f
def branch(n):return (((n>>12)&1)<<31)|(((n>>5)&63)<<25)|(((n>>1)&15)<<8)|(((n>>11)&1)<<7)|0x63
def write_hex(path,values):path.write_text(''.join(f'{x&0xffffffff:08x}\n' for x in values),encoding='ascii')
def build(out,kind):
    out.mkdir(parents=True,exist_ok=True)
    fault_words=[load(5,1,0),0xffffffff,0x73,0x100073,branch(2),addi(5,0,14)&~0x7f|0x67,
                 load(5,1,1),load(5,1,32),store(2,1,1),store(2,1,32),load(5,1,0),store(2,1,4),load(5,1,0)]
    causes=[1,2,11,3,0,0,4,5,6,7,5,7,5]
    tvals=[12,0xffffffff,0,12,14,14,0x10001,0x10020,0x10001,0x10020,0x10000,0x10004,0x10000]
    signature=0x400+kind
    words=[jal(0,0)]*256
    words[:6]=[lui(1,0x10),addi(2,0,0x55),store(2,1,0),fault_words[kind],addi(3,0,0x33),store(3,1,8)]
    if kind==12:
        words[4]=jal(6,16);words[8]=addi(7,0,0x77);words[9]=store(7,1,8)
    handler=[lui(10,0x10),addi(11,0,signature),store(11,10,16),load(12,10,16),addi(13,12,1),jal(0,0)]
    words[64:70]=handler
    normal=[(0,words[0],1,0x10000,1,4),(4,words[1],2,0x55,1,8),(8,words[2],0,0,0,12),
            (0x100,handler[0],10,0x10000,1,0x104),(0x104,handler[1],11,signature,1,0x108),
            (0x108,handler[2],0,0,0,0x10c),(0x10c,handler[3],12,signature,1,0x110),
            (0x110,handler[4],13,signature+1,1,0x114)]
    normal += [(0x114,handler[5],0,0x118,0,0x114)]*(64-len(normal))
    initial=[0x10000000+i for i in range(8)];final=initial.copy();final[0]=0x55;final[4]=signature
    accesses=[dict(pc=8,addr=0x10000,wdata=0x55,wstrb=15,size=2,is_write=1,rdata=initial[0],error=0,retire_index=2)]
    if kind in (10,11,12):
        st=kind==11;addr=0x10004 if st else 0x10000
        accesses.append(dict(pc=12,addr=addr,wdata=0x55 if st else 0,wstrb=15 if st else 0,
            size=2,is_write=int(st),rdata=initial[1] if st else 0x55,error=1,retire_index=None))
    accesses += [dict(pc=0x108,addr=0x10010,wdata=signature,wstrb=15,size=2,is_write=1,rdata=initial[4],error=0,retire_index=5),
                 dict(pc=0x10c,addr=0x10010,wdata=0,wstrb=0,size=2,is_write=0,rdata=signature,error=0,retire_index=6)]
    meta=dict(kind=kind,name=NAMES[kind],rom_words=256,ram_words=8,ram_base=0x10000,ram_bytes=32,
        trap_vector=0x100,fault_pc=12,fault_instr=fault_words[kind],accepted_fault_instr=0x13 if kind==0 else fault_words[kind],
        fault_cause=causes[kind],fault_tval=tvals[kind],if_fetch_error=kind==0,
        if_error_pcs=[12,16] if kind==0 else [16] if kind==1 else [],architectural_if_error_pc=12 if kind==0 else None,
        d_error_pcs=[12] if kind in (10,11,12) else [],error_store_writes=False,
        signature=signature,signature_addr=0x10010,gold_retire_count=64,minimum_retire_count=9,
        expected_mem_accesses=accesses,final_initialized_gpr={'1':0x10000,'2':0x55,'10':0x10000,'11':signature,'12':signature,'13':signature+1},
        notes=['No CSR/MRET/IRQ; handler does not return','IF fault instruction is normalized to NOP by unchanged adapter',
               'failed STORE endpoint chosen not to modify RAM; no general rollback claim',
               'kind1 PC0x10 request held through trap then returned as stale error'])
    write_hex(out/'program.hex',words)
    for column,name in enumerate(FIELDS):write_hex(out/f'expected_{name}.hex',[r[column] for r in normal])
    for name,value in [('pc',12),('instr',meta['accepted_fault_instr']),('cause',causes[kind]),('tval',tvals[kind]),('target',0x100)]:
        write_hex(out/f'expected_trap_{name}.hex',[value])
    for name in ('pc','addr','wdata','wstrb','size','is_write','rdata','error'):
        write_hex(out/f'expected_mem_{name}.hex',[r[name] for r in accesses])
    write_hex(out/'ram_initial.hex',initial);write_hex(out/'ram_final.hex',final)
    defined={0:0,**{int(r):v for r,v in meta['final_initialized_gpr'].items()}}
    (out/'final_gpr.hex').write_text(''.join(f'{defined[r]:08x}\n' if r in defined else 'xxxxxxxx\n' for r in range(32)),encoding='ascii')
    write_hex(out/'final_gpr_mask.hex',[int(r in defined) for r in range(32)])
    (out/'fixture.json').write_text(json.dumps(meta,indent=2)+'\n')
    return meta
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,default=ROOT/'build/cpu5_s6_trap');a=p.parse_args()
    # Fixed published machine encodings and hand values check the producer.
    assert lui(1,0x10)==0x000100b7 and addi(2,0,0x55)==0x05500113
    assert store(2,1,0)==0x0020a023 and load(5,1,0)==0x0000a283
    assert branch(2)==0x00000163 and jal(0,0)==0x0000006f and jal(6,16)==0x0100036f
    summary=[build(a.output/f'kind{k}',k) for k in range(13)]
    (a.output/'oracle_summary.json').write_text(json.dumps(dict(selftests=7,kinds=13,cases=104,fixtures=summary),indent=2)+'\n')
    manifest={str(f.relative_to(a.output)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest()
              for f in sorted(a.output.glob('kind*/*')) if f.is_file()}
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('CPU5 TRAP vectors: 13 kinds, 104 matrix cases, 64 normal-retire gold prefixes')
if __name__=='__main__':main()
