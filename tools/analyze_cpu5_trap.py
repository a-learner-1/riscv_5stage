"""Independently audit CPU5 synchronous-Trap machine words and real event logs.

This module imports neither fixture generation code nor RTL.  The decoder and
byte-memory interpreter below compute faults before any architectural write.
No CSR, MRET, IRQ, M extension, or architectural privilege state is modeled.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
MASK = 0xffffffff
FIELDS = ("pc", "instr", "rd", "value", "writes", "nextpc")
TRACE_HEADER = ("kind", "cycle", "index", "seq", "pc", "instr", "rd", "value", "writes", "instret", "nextpc")
ACCEPT_HEADER = ("cycle", "seq", "pc", "instr")
EVENT_HEADER = ("cycle", "event", "seq", "pc", "nextpc", "target", "taken", "pred_next", "pred_taken", "is_branch", "is_jal", "is_jalr")
D_HEADER = ("event", "cycle", "seq", "pc", "addr", "wdata", "wstrb", "size", "is_write", "rdata", "error")
TRAP_HEADER = ("cycle", "seq", "pc", "instr", "cause", "tval", "target")
IF_HEADER = ("event", "cycle", "addr", "error")
HEX_FIELDS = {"seq", "pc", "instr", "value", "nextpc", "target", "pred_next", "addr", "wdata", "wstrb", "rdata", "cause", "tval"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def signed(value: int, bits: int = 32) -> int:
    value %= 1 << bits
    return value if value < 1 << (bits - 1) else value - (1 << bits)


def read_hex(path: Path) -> list[int]:
    lines = path.read_text(encoding="ascii").splitlines()
    require(bool(lines) and all(len(x) == 8 and all(c in "0123456789abcdefABCDEF" for c in x) for x in lines), f"{path}: exact 32-bit hex required")
    return [int(x, 16) for x in lines]


def read_csv(path: Path, header: tuple[str, ...]) -> list[dict]:
    result = []
    with path.open(newline="", encoding="ascii") as stream:
        reader = csv.DictReader(stream)
        require(tuple(reader.fieldnames or ()) == header, f"{path}: incorrect CSV header")
        for number, source in enumerate(reader):
            require(None not in source and all(value is not None and value != "" for value in source.values()), f"{path.name} row{number}: incomplete row")
            row = {}
            for name, value in source.items():
                if name in ("kind", "event"):
                    row[name] = value
                    continue
                require(value == value.strip(), f"{path.name} row{number}: whitespace in {name}")
                try:
                    row[name] = int(value, 16 if name in HEX_FIELDS else 10)
                except ValueError as error:
                    raise ValueError(f"{path.name} row{number}: invalid {name}") from error
                require(row[name] >= 0, f"{path.name} row{number}: negative {name}")
                if name in HEX_FIELDS:
                    require(row[name] <= (0xffffffffffffffff if name == "seq" else MASK), f"{path.name} row{number}: oversized {name}")
            result.append(row)
    return result


class SynchronousFault(Exception):
    def __init__(self, cause: int, tval: int, access: dict | None = None):
        self.cause, self.tval, self.access = cause, tval & MASK, access


def execute_instruction(word: int, pc: int, registers: list[int], memory: bytearray,
                        fixture: dict) -> dict:
    """Decode one machine word; all faults precede GPR/normal-store mutation."""
    if pc in fixture.get("if_error_pcs", []):
        raise SynchronousFault(1, pc)
    if word == 0x00000073:
        raise SynchronousFault(11, 0)
    if word == 0x00100073:
        raise SynchronousFault(3, pc)
    op = word & 0x7f
    function = (word // 4096) & 7
    upper = word // (1 << 25)
    rd, rs1, rs2 = (word // 128) & 31, (word // 32768) & 31, (word // 1048576) & 31
    left, right = registers[rs1], registers[rs2]
    imm_i = signed(word // 1048576, 12)
    value, following, taken, target = 0, (pc + 4) & MASK, False, (pc + 4) & MASK
    name, access = "", None

    def legal(ok: bool) -> None:
        if not ok:
            raise SynchronousFault(2, word)

    if op == 0x37 or op == 0x17:
        name = "LUI" if op == 0x37 else "AUIPC"
        value = (word & 0xfffff000) + (pc if op == 0x17 else 0)
    elif op in (0x13, 0x33):
        immediate_mode = op == 0x13
        second = imm_i if immediate_mode else right
        shift = rs2 if immediate_mode else right & 31
        suffix = "I" if immediate_mode else ""
        if function == 0:
            legal(immediate_mode or upper in (0, 32))
            name = "ADDI" if immediate_mode else "SUB" if upper == 32 else "ADD"
            value = left - second if name == "SUB" else left + second
        elif function == 1:
            legal(upper == 0)
            name, value = "SLL" + suffix, left << shift
        elif function == 2:
            legal(immediate_mode or upper == 0)
            name, value = "SLT" + suffix, int(signed(left) < signed(second))
        elif function == 3:
            legal(immediate_mode or upper == 0)
            name, value = "SLTIU" if immediate_mode else "SLTU", int(left < (second & MASK))
        elif function == 4:
            legal(immediate_mode or upper == 0)
            name, value = "XOR" + suffix, left ^ second
        elif function == 5:
            legal(upper in (0, 32))
            name = ("SRA" if upper == 32 else "SRL") + suffix
            value = signed(left) >> shift if upper == 32 else left >> shift
        elif function == 6:
            legal(immediate_mode or upper == 0)
            name, value = "OR" + suffix, left | second
        else:
            legal(immediate_mode or upper == 0)
            name, value = "AND" + suffix, left & second
    elif op == 0x63:
        immediate = ((word & 0x80000000) >> 19) | ((word & 0x00000080) << 4) | ((word & 0x7e000000) >> 20) | ((word & 0x00000f00) >> 7)
        target = (pc + signed(immediate, 13)) & MASK
        if function == 0:
            name, taken = "BEQ", left == right
        elif function == 1:
            name, taken = "BNE", left != right
        elif function == 4:
            name, taken = "BLT", signed(left) < signed(right)
        elif function == 5:
            name, taken = "BGE", signed(left) >= signed(right)
        elif function == 6:
            name, taken = "BLTU", left < right
        elif function == 7:
            name, taken = "BGEU", left >= right
        else:
            raise SynchronousFault(2, word)
        rd = 0
        following = target if taken else following
    elif op == 0x6f:
        immediate = ((word & 0x80000000) >> 11) | (word & 0x000ff000) | ((word & 0x00100000) >> 9) | ((word & 0x7fe00000) >> 20)
        name, value, taken = "JAL", following, True
        following = target = (pc + signed(immediate, 21)) & MASK
    elif op == 0x67:
        legal(function == 0)
        name, value, taken = "JALR", following, True
        following = target = (left + imm_i) & 0xfffffffe
    elif op in (0x03, 0x23):
        writing = op == 0x23
        if writing:
            legal(function <= 2)
            name = ("SB", "SH", "SW")[function]
            immediate = ((word & 0xfe000000) >> 20) | ((word & 0x00000f80) >> 7)
            displacement = signed(immediate, 12)
            rd = 0
        else:
            legal(function in (0, 1, 2, 4, 5))
            name = {0: "LB", 1: "LH", 2: "LW", 4: "LBU", 5: "LHU"}[function]
            displacement = imm_i
        count = 1 << (function & 3)
        address = (left + displacement) & MASK
        if address % count:
            raise SynchronousFault(6 if writing else 4, address)
        ram_base = fixture.get("ram_base", 0x10000)
        if address < ram_base or address + count > ram_base + len(memory):
            raise SynchronousFault(7 if writing else 5, address)
        offset, lane = address - ram_base, address & 3
        aligned = offset & ~3
        raw = sum(memory[aligned + n] << (8 * n) for n in range(4))
        strobe = ((1 << count) - 1) << lane if writing else 0
        store_value = (right << (8 * lane)) & MASK if writing else 0
        mask = sum(255 << (8 * n) for n in range(4) if strobe & (1 << n))
        error = pc in fixture.get("d_error_pcs", [])
        access = dict(pc=pc, instr=word, addr=address, wdata=store_value & mask,
                      wstrb=strobe, size=function & 3, is_write=int(writing),
                      rdata=raw, error=int(error))
        if error:
            if writing and fixture.get("error_store_writes", False):
                for n in range(count):
                    memory[offset + n] = (right >> (8 * n)) & 255
            raise SynchronousFault(7 if writing else 5, address, access)
        if writing:
            for n in range(count):
                memory[offset + n] = (right >> (8 * n)) & 255
        else:
            value = sum(memory[offset + n] << (8 * n) for n in range(count))
            if function in (0, 1):
                value = signed(value, 8 * count)
    else:
        raise SynchronousFault(2, word)
    if taken and following % 4:
        raise SynchronousFault(0, following)
    value &= MASK
    writes = int(rd != 0)
    if writes:
        registers[rd] = value
    registers[0] = 0
    return dict(pc=pc, instr=word, rd=rd, value=value, writes=writes,
                nextpc=following, target=target, taken=int(taken), opcode=name,
                access=access)


def simulate(program: list[int], initial: list[int], fixture: dict, limit: int = 64) -> dict:
    registers, memory = [0] * 32, bytearray(b"".join(x.to_bytes(4, "little") for x in initial))
    pc, arch_pc, events, traps, accesses = 0, 0, [], [], []
    for _ in range(limit + 16):
        require(pc % 4 == 0 and 0 <= pc < len(program) * 4, f"reference PC outside ROM {pc:x}")
        word = program[pc // 4]
        try:
            event = execute_instruction(word, pc, registers, memory, fixture)
        except SynchronousFault as fault:
            require(not traps, "fixture unexpectedly raised a second architectural Trap")
            instruction = fixture.get("accepted_fault_instr", 0x13) if fault.cause == 1 else word
            descriptor = dict(pc=pc, instr=instruction, cause=fault.cause,
                              tval=fault.tval, target=fixture.get("trap_vector", 0x100),
                              arch_before=arch_pc, arch_after=fixture.get("trap_vector", 0x100),
                              before_index=len(events))
            if fault.access is not None:
                fault.access.update(retire_index=None, trap_index=len(traps))
                accesses.append(fault.access)
            traps.append(descriptor)
            arch_pc = pc = descriptor["target"]
            continue
        event["index"] = len(events)
        if event["access"] is not None:
            event["access"].update(retire_index=len(events), trap_index=None)
            accesses.append(event["access"])
        events.append(event)
        arch_pc = pc = event["nextpc"]
        if len(events) == limit:
            final = [int.from_bytes(memory[n:n + 4], "little") for n in range(0, len(memory), 4)]
            return dict(trace=events, traps=traps, accesses=accesses, memory=final,
                        registers=registers, opcode_counts=dict(Counter(x["opcode"] for x in events)))
    raise ValueError("reference failed to reach its retirement bound")


def decoder_selftest() -> int:
    """Fixed published encodings and hand results, independent of the producer."""
    registers=[0]*32; registers[1]=0x10000; registers[2]=0x55
    ram=bytearray(bytes.fromhex('efcdab8900000000000000000000000000000000000000000000000000000000'))
    fixture=dict(ram_base=0x10000)
    ordinary=[(0x000100b7,0,1,0x10000,4),(0x05500113,4,2,0x55,8),
              (0xfff00193,8,3,MASK,12),(0x0000a283,12,5,0x89abcdef,16),
              (0x00008283,12,5,0xffffffef,16),(0x0000c283,12,5,0xef,16),
              (0x00009283,12,5,0xffffcdef,16),(0x0000d283,12,5,0xcdef,16),
              (0x0000006f,0x114,0,0x118,0x114)]
    for word,pc,rd,value,nextpc in ordinary:
        result=execute_instruction(word,pc,registers.copy(),ram.copy(),fixture)
        require((result['rd'],result['value'],result['nextpc'])==(rd,value,nextpc),'independent decoder fixed normal word')
    faults=[(0x00000073,12,11,0,fixture),(0x00100073,12,3,12,fixture),
            (0xffffffff,12,2,0xffffffff,fixture),(0x00000163,12,0,14,fixture),
            (0x00e002e7,12,0,14,fixture),(0x0010a283,12,4,0x10001,fixture),
            (0x0200a283,12,5,0x10020,fixture),(0x0020a0a3,12,6,0x10001,fixture),
            (0x0220a023,12,7,0x10020,fixture),
            (0x0000a283,12,1,12,dict(fixture,if_error_pcs=[12])),
            (0x0000a283,12,5,0x10000,dict(fixture,d_error_pcs=[12])),
            (0x0020a223,12,7,0x10004,dict(fixture,d_error_pcs=[12]))]
    for word,pc,cause,tval,configuration in faults:
        regs,mem=registers.copy(),ram.copy()
        try:execute_instruction(word,pc,regs,mem,configuration)
        except SynchronousFault as fault:
            require((fault.cause,fault.tval)==(cause,tval),'independent decoder fixed fault descriptor')
            require(regs==registers and mem==ram,'independent decoder fault changed architecture')
        else:raise ValueError('independent decoder fixed fault not raised')
    return len(ordinary)+len(faults)


def check_vectors(directory: Path) -> tuple[dict, dict]:
    decoder_checks = decoder_selftest()
    summary = json.loads((directory / 'oracle_summary.json').read_text(encoding='utf-8'))
    require(summary.get('kinds') == 13 and summary.get('cases') == 104 and summary.get('selftests', 0) >= 7, 'vector fixture matrix/selftests')
    golden, results = {}, []
    for kind in range(13):
        name, folder = f'kind{kind}', directory / f'kind{kind}'
        meta = json.loads((folder / 'fixture.json').read_text(encoding='utf-8'))
        require(meta['kind'] == kind and meta['trap_vector'] == 0x100, f'{name}: fixture identity')
        program, initial = read_hex(folder / 'program.hex'), read_hex(folder / 'ram_initial.hex')
        require(len(program) == 256 and len(initial) == 8, f'{name}: ROM/RAM dimensions')
        computed = simulate(program, initial, meta)
        for field in FIELDS:
            require(read_hex(folder / f'expected_{field}.hex') == [row[field] for row in computed['trace']], f'{name}: independent retirement {field}')
        require(len(computed['traps']) == 1, f'{name}: exactly one architectural Trap')
        trap = computed['traps'][0]
        for field in ('pc', 'instr', 'cause', 'tval', 'target'):
            require(read_hex(folder / f'expected_trap_{field}.hex') == [trap[field]], f'{name}: independent Trap {field}')
        require(trap['before_index'] == 3 and trap['pc'] == meta['fault_pc'] and trap['cause'] == meta['fault_cause'] and trap['tval'] == meta['fault_tval'], f'{name}: precise oldest fault contract')
        for field in ('pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write', 'rdata', 'error'):
            require(read_hex(folder / f'expected_mem_{field}.hex') == [row[field] for row in computed['accesses']], f'{name}: independent memory {field}')
        require(computed['memory'] == read_hex(folder / 'ram_final.hex'), f'{name}: independent complete final RAM')
        for reg, value in meta['final_initialized_gpr'].items():
            require(computed['registers'][int(reg)] == value, f'{name}: independent initialized GPR x{reg}')
        require(computed['registers'][3] == 0 and computed['registers'][5] == 0 and computed['registers'][6] == 0 and computed['registers'][7] == 0, f'{name}: fault/young effects in machine-word reference')
        # The RTL intentionally does not reset its GPR array.  Only declared,
        # initialized architectural registers can be compared to numeric gold.
        mask_path = folder / 'final_gpr_mask.hex'
        if mask_path.exists():
            mask, words = read_hex(mask_path), (folder / 'final_gpr.hex').read_text(encoding='ascii').splitlines()
            require(len(mask) == len(words) == 32 and set(mask) <= {0, 1}, f'{name}: GPR initialization mask')
            require({i for i, x in enumerate(mask) if x} == {0, 1, 2, 10, 11, 12, 13}, f'{name}: exact initialized register set')
            require(all(int(words[i], 16) == computed['registers'][i] for i, valid in enumerate(mask) if valid), f'{name}: masked gold GPR mismatch')
        golden[name] = dict(computed, fixture=meta)
        results.append(dict(kind=kind, name=meta['name'], status='PASS', retired=len(computed['trace']), d_accesses=len(computed['accesses']), trap={key:trap[key] for key in ('pc','instr','cause','tval','target')}))
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    require(set(manifest) == {path.relative_to(directory).as_posix() for path in directory.glob('kind*/*') if path.is_file()}, 'vector manifest complete file membership')
    for name, digest in manifest.items():
        require(hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest, f'{name}: vector SHA256')
    return dict(status='PASS', kinds=results, producer_selftests=summary['selftests'], independent_decoder=True, independent_decoder_selftests=decoder_checks), golden


def control_fields(oracle: dict) -> dict:
    name = oracle['opcode']
    return dict(pc=oracle['pc'], nextpc=oracle['nextpc'], target=oracle['target'], taken=oracle['taken'],
                is_branch=int(name.startswith('B')), is_jal=int(name == 'JAL'), is_jalr=int(name == 'JALR'))


def audit_case(directory: Path, reference: dict) -> dict:
    descriptor = json.loads((directory / 'descriptor.json').read_text(encoding='utf-8'))
    case = descriptor.get('case')
    require(type(case) is int and case >= 0 and directory.name == f'case{case}', f'{directory.name}: incorrect case identity')
    require(tuple(descriptor.get(key) for key in ('id_mode','predict','wait','kind','fixture_name')) == (case%2,(case//2)%2,(case//4)%2,case//8,f'kind{case//8}'), f'case{case}: complete fault x ID/EX x BP x wait matrix')
    metrics = json.loads((directory / 'metrics.json').read_text(encoding='utf-8'))
    accepts = read_csv(directory / 'accept.csv', ACCEPT_HEADER)
    rows = read_csv(directory / 'trace.csv', TRACE_HEADER)
    events = read_csv(directory / 'events.csv', EVENT_HEADER)
    traps = read_csv(directory / 'traps.csv', TRAP_HEADER)
    require(len(traps) == 1, f'case{case}: exactly one Trap event required')
    trap, wanted_trap = traps[0], reference['traps'][0]
    for field in ('pc','instr','cause','tval','target'):
        require(trap[field] == wanted_trap[field], f'case{case}: Trap {field} mismatch')
    accepted, last_cycle, last_seq = {}, 0, -1
    for ordinal, row in enumerate(accepts):
        require(row['cycle'] > last_cycle and row['seq'] > last_seq, f'case{case} accept{ordinal}: non-monotonic cycle/age')
        accepted[row['seq']] = row
        last_cycle, last_seq = row['cycle'], row['seq']
    require(trap['seq'] in accepted, f'case{case}: Trap lacks accepted fault owner')
    fault = accepted[trap['seq']]
    require(fault['pc'] == trap['pc'] and fault['instr'] == trap['instr'] and fault['cycle'] < trap['cycle'], f'case{case}: Trap IFID ownership mismatch')
    retired, wb, retired_by_seq = [], [], {}
    last_cycle, kinds = 0, set()
    for ordinal, row in enumerate(rows):
        message = f'case{case} row{ordinal} {row["kind"]}'
        require(row['kind'] in ('retire','wb'), f'{message}: unknown trace event')
        require(row['cycle'] > 0 and row['cycle'] >= last_cycle, f'{message}: unordered cycle')
        if row['cycle'] != last_cycle:
            kinds.clear()
        require(row['kind'] not in kinds, f'{message}: repeated same-edge event')
        kinds.add(row['kind']);last_cycle=row['cycle']
        ledger = retired if row['kind'] == 'retire' else wb
        index = len(ledger)
        require(row['index'] == index and index < len(reference['trace']), f'{message}: extra/missing/reordered index')
        expected = reference['trace'][index]
        for field in FIELDS:
            if row['kind'] == 'wb' and field == 'nextpc':
                continue
            require(row[field] == expected[field], f'{message}: {field} mismatch')
        require(row['writes'] in (0,1) and row['seq'] != trap['seq'], f'{message}: fault instruction had architectural effect')
        if row['kind'] == 'retire':
            require(row['seq'] in accepted and row['seq'] > (retired[-1]['seq'] if retired else -1), f'{message}: missing/duplicate/reordered retirement age')
            owner = accepted[row['seq']]
            require(owner['pc'] == row['pc'] and owner['instr'] == row['instr'] and owner['cycle'] < row['cycle'], f'{message}: IFID ownership mismatch')
            require(row['cycle'] != trap['cycle'], f'{message}: Trap and ordinary retirement shared edge')
            require(row['instret'] == index+1, f'{message}: instret did not count ordinary retirement only')
            if index < wanted_trap['before_index']:
                require(row['seq'] < trap['seq'] and row['cycle'] < trap['cycle'], f'{message}: older instruction did not retire before Trap')
            else:
                require(row['seq'] > trap['seq'] and row['cycle'] > trap['cycle'] and owner['cycle'] > trap['cycle'], f'{message}: handler was not freshly fetched after Trap')
            retired_by_seq[row['seq']] = row
            retired.append(row)
        else:
            require(index < len(retired), f'{message}: WB precedes MEM retirement')
            parent = retired[index]
            require(row['seq'] == parent['seq'] and row['cycle'] == parent['cycle']+1, f'{message}: physical WB owner/edge mismatch')
            require(row['instret'] == len(retired), f'{message}: pre-edge WB instret mismatch')
            # A Trap can move architectural_next_pc between retirement and WB.
            preceding = [x for x in retired if x['cycle'] < row['cycle']]
            last_transfer = max([(x['cycle'], x['nextpc']) for x in preceding] + ([(trap['cycle'],trap['target'])] if trap['cycle'] < row['cycle'] else []))
            require(row['nextpc'] == last_transfer[1], f'{message}: pre-edge architectural PC mismatch')
            require('retire' not in kinds, f'{message}: WB must precede same-edge retirement row')
            wb.append(row)
    require(len(retired) >= reference['fixture']['minimum_retire_count'], f'case{case}: handler normal retirement prefix too short')
    require(len(retired) == len(wb), f'case{case}: final physical WB ledger not drained')
    # The only architectural PC transfer between normal gold rows 2 and 3 is
    # the single fault.  Fault and younger wrong-path IFID owners never retire.
    require(retired[2]['nextpc'] == trap['pc'] and retired[3]['pc'] == trap['target'], f'case{case}: Trap architecture transfer mismatch')
    bp, redirects, killed_redirects, last_cycle, per_edge = {}, {}, {}, 0, set()
    for ordinal, event in enumerate(events):
        message = f'case{case} event{ordinal} {event["event"]}'
        kind = event['event']
        require(kind in ('bp','redirect') and event['cycle'] > 0 and event['cycle'] >= last_cycle, f'{message}: invalid/unordered control event')
        if event['cycle'] != last_cycle:
            per_edge.clear()
        require(kind not in per_edge, f'{message}: repeated event edge')
        per_edge.add(kind);last_cycle=event['cycle']
        if event['seq'] not in retired_by_seq:
            # An ID JAL may resolve speculatively while an older LOAD awaits
            # its unknown response.  Its later error must revoke retirement,
            # GPR, BP and D effects; an earlier fetch redirect is reversible.
            require(kind == 'redirect' and descriptor['kind'] == 12 and descriptor['id_mode'] == 1,
                    f'{message}: fault/killed/unretired owner had committed control effect')
            require(event['seq'] in accepted and event['seq'] > trap['seq'] and event['seq'] not in killed_redirects,
                    f'{message}: killed speculative redirect lacks unique younger owner')
            speculative = accepted[event['seq']]
            require(speculative['pc'] == 16 and speculative['instr'] == 0x0100036f and speculative['cycle'] <= event['cycle'] < trap['cycle'],
                    f'{message}: killed redirect occurred after older fault became known')
            expected = execute_instruction(speculative['instr'], speculative['pc'], reference['registers'].copy(), bytearray(32), reference['fixture'])
            for field,value in control_fields(expected).items():
                require(event[field] == value, f'{message}: speculative redirect {field} mismatch')
            require(event['pred_next'] != event['nextpc'] and event['pred_taken'] in (0,1), f'{message}: invalid speculative redirect prediction')
            if not descriptor['predict']:
                require(event['pred_next'] == 20 and event['pred_taken'] == 0, f'{message}: disabled speculative prediction metadata')
            killed_redirects[event['seq']] = event
            continue
        owner = retired_by_seq[event['seq']]
        expected = reference['trace'][owner['index']]
        for field, value in control_fields(expected).items():
            require(event[field] == value, f'{message}: {field} mismatch')
        for field in ('taken','pred_taken','is_branch','is_jal','is_jalr'):
            require(event[field] in (0,1), f'{message}: invalid {field}')
        ledger = bp if kind == 'bp' else redirects
        require(event['seq'] not in ledger, f'{message}: duplicate owner effect')
        if kind == 'bp':
            require(event['cycle'] == owner['cycle'], f'{message}: BP not authorized by same-edge MEM retirement')
        else:
            require(event['pred_next'] != event['nextpc'] and accepted[event['seq']]['cycle'] <= event['cycle'] < owner['cycle'], f'{message}: redirect outside live mismatch lifetime')
            if not descriptor['predict']:
                require(event['pred_next'] == (event['pc']+4)&MASK and event['pred_taken'] == 0, f'{message}: disabled predictor metadata')
        ledger[event['seq']] = event
    if descriptor['predict']:
        require(set(bp) == set(retired_by_seq), f'case{case}: BP commits do not match normal retirement ledger')
        mismatches = {seq for seq, row in bp.items() if row['pred_next'] != row['nextpc']}
    else:
        require(not bp, f'case{case}: disabled BP had commits')
        mismatches = {row['seq'] for row in retired if row['nextpc'] != (row['pc']+4)&MASK}
    require(set(redirects) == mismatches, f'case{case}: redirect ledger not closed')
    if descriptor['kind'] == 12 and descriptor['id_mode']:
        require(len(killed_redirects) == 1, f'case{case}: missing speculative ID redirect before older LOAD error')
    if descriptor['predict']:
        require(all(all(bp[seq][field] == redirects[seq][field] for field in EVENT_HEADER if field not in ('cycle','event')) for seq in redirects), f'case{case}: redirect/BP metadata mismatch')
    drows = read_csv(directory / 'd.csv', D_HEADER)
    request, response, pending, ordinal = {}, {}, {}, 0
    expected_d = reference['accesses']
    last_cycle = -1
    for number, row in enumerate(drows):
        message = f'case{case} D{number} {row["event"]}'
        require(row['event'] in ('req','rsp') and row['cycle'] >= last_cycle and row['cycle'] > 0, f'{message}: invalid/unordered D event')
        last_cycle = row['cycle']
        require(row['seq'] in accepted and accepted[row['seq']]['pc'] == row['pc'], f'{message}: D accepted owner PC mismatch')
        require(accepted[row['seq']]['cycle'] < row['cycle'], f'{message}: D before owner acceptance')
        if row['event'] == 'req':
            require(row['error'] == 0, f'{message}: request error metadata')
            require(row['seq'] not in request and ordinal < len(expected_d), f'{message}: duplicate/extra D request')
            # A single owner permits a new request only after old response.
            require(not pending, f'{message}: second outstanding D owner')
            gold = expected_d[ordinal];ordinal += 1
            require(row['pc'] == gold['pc'], f'{message}: wrong-path or faulting address instruction issued D')
            if gold['retire_index'] is None:
                require(row['seq'] == trap['seq'] and row['cycle'] < trap['cycle'], f'{message}: faulting bus access lost its precise owner')
            else:
                owner = retired[gold['retire_index']]
                require(row['seq'] == owner['seq'] and row['cycle'] < owner['cycle'], f'{message}: D request retirement ownership mismatch')
            request[row['seq']] = (row,gold);pending[row['seq']] = (row,gold)
        else:
            require(row['seq'] in pending and row['seq'] not in response, f'{message}: D response lacks outstanding owner')
            original,gold = pending.pop(row['seq'])
            require(row['cycle'] >= original['cycle'], f'{message}: D response precedes request')
            require(all(row[field] == original[field] for field in ('pc','addr','wdata','wstrb','size','is_write')), f'{message}: D response descriptor ownership mismatch')
            require(row['error'] == gold['error'], f'{message}: D response error mismatch')
            if not row['is_write']:
                require(row['rdata'] == gold['rdata'], f'{message}: raw load response word mismatch')
            if gold['retire_index'] is None:
                require(row['cycle'] <= trap['cycle'], f'{message}: Trap preceded faulting bus response')
            else:
                require(row['cycle'] <= retired[gold['retire_index']]['cycle'], f'{message}: memory retired before completion')
            response[row['seq']] = row
        for field in ('addr','wstrb','size','is_write'):
            require(row[field] == gold[field], f'{message}: {field} mismatch')
        mask = sum(255 << (8*n) for n in range(4) if gold['wstrb'] & (1<<n))
        require(row['wdata']&mask == gold['wdata'], f'{message}: enabled store data mismatch')
    require(not pending and set(request) == set(response) and ordinal == len(expected_d), f'case{case}: D transaction ledger not closed')
    require(read_hex(directory / 'actual_ram_final.hex') == reference['memory'], f'case{case}: complete final RAM mismatch')
    final_gpr = (directory / 'actual_gpr_final.hex').read_text(encoding='ascii').splitlines()
    require(len(final_gpr) == 32, f'case{case}: complete GPR observation missing')
    for reg in (0,1,2,10,11,12,13):
        require(int(final_gpr[reg],16) == reference['registers'][reg], f'case{case}: initialized GPR x{reg} mismatch')
    for reg in set(range(32)) - {0,1,2,10,11,12,13}:
        require(final_gpr[reg].lower() == 'xxxxxxxx', f'case{case}: uninitialized/killed GPR x{reg} changed')
    ifrows = read_csv(directory / 'if.csv', IF_HEADER)
    ifrequests, ifresponses, outstanding, stale_errors, last_cycle = 0,0,[],0,0
    for number,row in enumerate(ifrows):
        message=f'case{case} IF{number}'
        require(row['event'] in ('req','rsp') and row['cycle'] >= last_cycle and row['cycle'] > 0, f'{message}: invalid/unordered IF event')
        require(row['error'] in (0,1), f'{message}: invalid IF error')
        last_cycle=row['cycle']
        if row['event']=='req':
            require(row['error']==0, f'{message}: request error metadata')
            outstanding.append(row);ifrequests+=1
        else:
            require(outstanding and outstanding.pop(0)['addr']==row['addr'], f'{message}: response lost request identity')
            require(row['error'] == int(row['addr'] in reference['fixture']['if_error_pcs']), f'{message}: injected IF error mismatch')
            ifresponses+=1
            stale_errors += int(row['error'] and row['cycle'] >= trap['cycle'] and row['addr'] != trap['pc'])
    require(not outstanding and ifrequests==ifresponses, f'case{case}: IF request/response ledger not drained')
    if descriptor['kind']==1:
        require(stale_errors >= 1, f'case{case}: held stale IF error not observed after Trap')
    counts=dict(retired=len(retired),wb_packets=len(wb),accepted=len(accepts),redirects=len(redirects)+len(killed_redirects),bp_commits=len(bp),traps=1,d_requests=len(request),d_responses=len(response),requests=ifrequests,responses=ifresponses)
    counts.update(resolved=sum(row['is_branch'] or row['is_jal'] for row in bp.values()), mispredict=len(mismatches) if descriptor['predict'] else 0,
                  direction_error=sum((row['is_branch'] or row['is_jal']) and row['taken']!=row['pred_taken'] for row in bp.values()),
                  target_error=sum((row['is_branch'] or row['is_jal']) and row['taken'] and row['pred_taken'] and row['nextpc']!=row['pred_next'] for row in bp.values()))
    for field,value in counts.items():
        require(type(metrics.get(field)) is int and metrics[field]==value, f'case{case}: metric {field} mismatch')
    require(int(str(metrics.get('fault_seq')),16)==trap['seq'], f'case{case}: fault_seq metric mismatch')
    require(metrics.get('stale_if_errors')==stale_errors, f'case{case}: stale IF error metric mismatch')
    require(type(metrics.get('cycles')) is int and metrics['cycles'] > max(row['cycle'] for row in rows+accepts+events+traps+drows+ifrows), f'case{case}: final cycle does not cover drain')
    return dict(status='PASS',**descriptor,**counts,cycles=metrics['cycles'],fault_seq=f'{trap["seq"]:016x}',fault_cause=trap['cause'],fault_pc=trap['pc'],stale_if_errors=stale_errors,complete_ram_words=len(reference['memory']),defined_gpr_checked=7,uninitialized_gpr_unchanged=25,killed_speculative_redirects=len(killed_redirects))


def analyze(directory: Path, vectors_only: bool=False) -> dict:
    vectors,golden=check_vectors(directory)
    if vectors_only:
        return dict(schema=1,status='PASS',scope='CPU5 minimum synchronous Trap vectors',vectors=vectors)
    paths=sorted((directory/'cases').glob('case*'),key=lambda p:int(p.name[4:]))
    require([p.name for p in paths]==[f'case{i}' for i in range(104)],'all 104 Trap case IDs required')
    cases=[audit_case(path,golden[f'kind{int(path.name[4:])//8}']) for path in paths]
    return dict(schema=1,status='PASS',scope='CPU5 minimum synchronous Trap end-to-end simulation',
                limitation='Fixed vector and debug snapshots only; no CSR/MRET/IRQ, MMIO, M extension, SoC/cache integration, STA, or board performance claim.',
                vectors=vectors,case_count=len(cases),cases=cases,total_retired=sum(x['retired'] for x in cases),
                total_wb_packets=sum(x['wb_packets'] for x in cases),total_traps=sum(x['traps'] for x in cases),
                total_d_requests=sum(x['d_requests'] for x in cases),total_d_responses=sum(x['d_responses'] for x in cases),
                checks=['independent machine-word decoder and byte RAM interpreter','precise PC/cause/tval and fixed vector','fault and killed instructions have no retirement/GPR/BP/D effects','earlier speculative ID redirect revoked by older LOAD error','ordinary retirement count excludes Trap','unique accepted 64-bit sequence owner','physical WB follows retired packet','D owner request/error/response identity','held stale IF error drain','fresh handler normal ALU/LOAD/STORE and self-loop','all RAM words, seven defined GPRs and 25 untouched unknown GPRs','104 fault x ID/EX x predictor x backpressure combinations'])


def selftest(directory: Path) -> dict:
    _,golden=check_vectors(directory)
    scratch=directory.parent/(directory.name+'_analyzer_selftest');scratch.mkdir(parents=True,exist_ok=True)
    require(directory.resolve() not in scratch.resolve().parents,'negative fixture outside good evidence')
    good=[p for p in sorted(directory.rglob('*')) if p.is_file() and p.name not in ('analysis.json','independent_vectors.json')]
    def hashes():return {p.relative_to(directory).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in good}
    before=hashes();results=[]
    mutations=[('trap_pc_wrong',0,'traps.csv','Trap pc mismatch'),('trap_cause_wrong',0,'traps.csv','Trap cause mismatch'),
        ('trap_tval_wrong',0,'traps.csv','Trap tval mismatch'),('trap_owner_wrong',0,'traps.csv','Trap IFID ownership mismatch'),
        ('handler_retire_value_wrong',0,'trace.csv','value mismatch'),('physical_wb_missing',0,'trace.csv','extra/missing/reordered index'),
        ('accepted_owner_wrong',0,'accept.csv','IFID ownership mismatch'),('duplicate_d_request',0,'d.csv','duplicate/extra D request'),
        ('response_owner_pc_wrong',0,'d.csv','D accepted owner PC mismatch'),('load_raw_word_wrong',0,'d.csv','raw load response word mismatch'),
        ('fault_bus_error_cleared',80,'d.csv','D response error mismatch'),('final_ram_wrong',0,'actual_ram_final.hex','complete final RAM mismatch'),
        ('initialized_gpr_wrong',0,'actual_gpr_final.hex','initialized GPR x12 mismatch')]
    for name,case,filename,reason in mutations:
        source=directory/f'cases/case{case}';target=scratch/name/f'case{case}'
        shutil.copytree(source,target,dirs_exist_ok=True);path=target/filename
        if filename.endswith('.csv'):
            with path.open(newline='',encoding='ascii') as f:
                reader=csv.DictReader(f);fields=list(reader.fieldnames);rows=list(reader)
            if name.startswith('trap_'):
                field={'trap_pc_wrong':'pc','trap_cause_wrong':'cause','trap_tval_wrong':'tval','trap_owner_wrong':'seq'}[name]
                rows[0][field]=f'{int(rows[0][field],16)^1:x}'
            elif name=='handler_retire_value_wrong':
                row=next(x for x in rows if x['kind']=='retire' and int(x['pc'],16)==0x110);row['value']=f'{int(row["value"],16)^1:08x}'
            elif name=='physical_wb_missing':rows.pop(next(i for i,x in enumerate(rows) if x['kind']=='wb'))
            elif name=='accepted_owner_wrong':rows[0]['pc']=f'{int(rows[0]["pc"],16)^4:08x}'
            elif name=='duplicate_d_request':
                i=next(i for i,x in enumerate(rows) if x['event']=='req');rows.insert(i+1,dict(rows[i]))
            elif name=='response_owner_pc_wrong':
                row=next(x for x in rows if x['event']=='rsp');row['pc']=f'{int(row["pc"],16)^4:08x}'
            elif name=='load_raw_word_wrong':
                row=next(x for x in rows if x['event']=='rsp' and x['is_write']=='0');row['rdata']=f'{int(row["rdata"],16)^1:08x}'
            elif name=='fault_bus_error_cleared':next(x for x in rows if x['event']=='rsp' and x['error']=='1')['error']='0'
            with path.open('w',newline='',encoding='ascii') as f:
                writer=csv.DictWriter(f,fieldnames=fields,lineterminator='\n');writer.writeheader();writer.writerows(rows)
        else:
            lines=path.read_text(encoding='ascii').splitlines();i=12 if filename=='actual_gpr_final.hex' else 2
            lines[i]=f'{int(lines[i],16)^1:08x}';path.write_text('\n'.join(lines)+'\n',encoding='ascii')
        try:audit_case(target,golden[f'kind{case//8}'])
        except ValueError as error:
            message=str(error);require(reason in message,f'negative {name} rejected for unintended reason: {message}')
        else:raise ValueError(f'negative {name} falsely accepted')
        require(path.read_bytes()!=(source/filename).read_bytes(),f'negative {name} made no change')
        (target.parent/'rejection.txt').write_text(message+'\n',encoding='utf-8')
        results.append(dict(name=name,case=case,status='REJECTED',error=message,changed_file=filename,good_sha256=hashlib.sha256((source/filename).read_bytes()).hexdigest(),bad_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    require(before==hashes(),'negative copies changed original good evidence')
    for suffix,value in (('before',before),('after',hashes())):(scratch/f'good_{suffix}_sha256.json').write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
    result=dict(schema=1,status='PASS',rejected_count=len(results),rejected=results,good_inputs_unchanged=True,good_input_files=len(good))
    (scratch/'summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result


def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--directory',type=Path,default=ROOT/'build/cpu5_s6_trap')
    parser.add_argument('--vectors-only',action='store_true');parser.add_argument('--selftest',action='store_true');args=parser.parse_args()
    result=analyze(args.directory,args.vectors_only)
    if args.selftest:
        require(not args.vectors_only,'--selftest needs actual simulation evidence');result['negative_evidence_tests']=selftest(args.directory)
    destination='independent_vectors.json' if args.vectors_only else 'analysis.json'
    (args.directory/destination).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status='PASS',cases=result.get('case_count',0),retired=result.get('total_retired',0),traps=result.get('total_traps',0),d_requests=result.get('total_d_requests',0),rejected=result.get('negative_evidence_tests',{}).get('rejected_count',0))))


if __name__=='__main__':main()
