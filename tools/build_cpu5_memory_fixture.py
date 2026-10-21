"""Build deterministic hand-encoded RV32I memory fixtures; no product inputs change."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/cpu5_s05_memory"
OUT.mkdir(parents=True, exist_ok=True)


def initial_word(i):
    return (0xA5000000 ^ (i * 0x10203)) & 0xFFFFFFFF


def build(kind):
    regs = [0] * 32
    mem = [initial_word(i) for i in range(4096)]
    code, golden, tx = [], [], []

    def emit(insn, rd=0, value=None):
        pc = len(code) * 4
        code.append(insn)
        golden.append(dict(pc=pc, rd=rd, write=int(rd != 0), value=0 if value is None else value & 0xFFFFFFFF))
        if rd:
            regs[rd] = value & 0xFFFFFFFF

    def lui(rd, value):
        emit((value & 0xFFFFF000) | (rd << 7) | 0x37, rd, value & 0xFFFFF000)

    def addi(rd, rs, imm):
        emit(((imm & 4095) << 20) | (rs << 15) | (rd << 7) | 0x13, rd, regs[rs] + imm)

    lui(1, 0x10000)
    lui(2, 0x11000)
    # Prepare four different STORE operands before the consecutive memory
    # instruction stream; no ADDI is inserted between LW/SW pairs.
    for r, upper, low in ((5, 0x1357A000, -1057), (6, 0x12345000, 1656),
                          (7, 0x0BADD000, -1282), (8, 0xFEEDA000, 1370)):
        lui(r, upper)
        addi(r, r, low)
    operations = [
        (0, 0, "cold"), (0, 4, "same_line"), (0, 8, "hit_stream"),
        (0, 12, "hit_stream"), (0, 0, "hit_stream"), (0, 4, "hit_stream"),
        (1, 4, "lw_sw_same"), (0, 4, "sw_lw_same"), (0, 8, "lw_lw_diff"),
        (1, 12, "lw_sw_diff"), (0, 0, "sw_lw_diff"),
        (0, 16, "cross_line"), (0, 20, "new_line_hit"),
        (0, 1024, "way1_fill"), (0, 0, "way0_hit"),
        (0, 1028, "way1_hit"), (0, 2048, "way_evict"),
        (0, 1024, "way1_retained"), (0, 0, "evicted_miss"),
        (1, 3072, "write_no_allocate"), (0, 3072, "read_after_write_miss"),
        (0, 3076, "hit_after_fill"), (1, 3076, "write_hit"),
        (0, 3076, "same_address_fresh"), (0, 16, "other_set_hit"),
    ]
    store_index = 0
    for n, (wr, off, scenario) in enumerate(operations):
        base_reg = 1 if off < 2048 else 2
        if wr:
            store_reg = 5 + store_index
            store_index += 1
            imm = off & 4095
            emit(((imm >> 5) << 25) | (store_reg << 20) | (base_reg << 15) | (2 << 12) | ((imm & 31) << 7) | 0x23)
            mem[off // 4] = regs[store_reg]
            data = regs[store_reg]
        else:
            rd = 10 + n % 20
            emit(((off & 4095) << 20) | (base_reg << 15) | (2 << 12) | (rd << 7) | 0x03, rd, mem[off // 4])
            data = mem[off // 4]
        tx.append(dict(owner=n, pc=(len(code)-1)*4, write=wr, addr=0x10000+off, data=data, error=0, scenario=scenario))
    # Final instruction must fault and must not retire. An aligned out-of-range
    # request reaches the native non-RAM error endpoint; an unaligned LW is
    # rejected by the cache before any backend request.
    if kind == "illegal":
        lui(3, 0x50000)
        code.append((3 << 15) | (2 << 12) | (31 << 7) | 3)
        fault_addr = 0x50000
    else:
        code.append((2 << 20) | (1 << 15) | (2 << 12) | (31 << 7) | 3)
        fault_addr = 0x10002
    tx.append(dict(owner=len(tx), pc=(len(code)-1)*4, write=0, addr=fault_addr, data=0, error=1, scenario=kind))
    path = OUT / f"cpu_{kind}.hex"
    path.write_text("".join(f"{x:08x}\n" for x in code), encoding="ascii")
    (OUT/f"cpu_{kind}_golden.json").write_text(json.dumps(dict(instructions=code, retirements=golden, transactions=tx), indent=2)+"\n")
    # $readmemh integer arrays avoid any dependency on JSON inside simulator.
    (OUT/f"cpu_{kind}_pc.hex").write_text("".join(f"{g['pc']:08x}\n" for g in golden))
    (OUT/f"cpu_{kind}_rd.hex").write_text("".join(f"{g['rd']:08x}\n" for g in golden))
    (OUT/f"cpu_{kind}_value.hex").write_text("".join(f"{g['value']:08x}\n" for g in golden))
    return dict(kind=kind, retired=len(golden), requests=len(tx), fault_pc=(len(code)-1)*4)


if __name__ == "__main__":
    print(json.dumps([build("illegal"), build("unaligned")]))
