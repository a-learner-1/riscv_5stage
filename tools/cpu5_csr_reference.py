"""Independent RV32I machine-word model for CPU5's minimum machine CSR stage.

This decoder imports neither the fixture producer nor RTL. Uninitialized GPR
reads are rejected, so a convenient zero-filled software register array cannot
hide a missing hardware initialization. CSR reads/RMW, synchronous exceptions,
MRET and the architectural next PC are interpreted before comparing real logs.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
MASK = 0xffffffff
CSRS = ('mstatus', 'mtvec', 'mscratch', 'mepc', 'mcause', 'mtval')
ADDRESSES = dict(zip((0x300, 0x305, 0x340, 0x341, 0x342, 0x343), CSRS))
FIELDS = ('kind', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc', 'cause', 'tval') + CSRS
EVENT_HEADER = ('kind', 'cycle', 'index', 'seq', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc', 'cause', 'tval') + CSRS + ('instret',)
WB_HEADER = ('cycle', 'index', 'seq', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc')
ACCEPT_HEADER = ('cycle', 'seq', 'pc', 'instr')
IF_HEADER = ('event', 'cycle', 'addr')
HEX_FIELDS = {'seq', 'pc', 'instr', 'value', 'nextpc', 'cause', 'tval', 'addr', *CSRS}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_hex(path):
    lines = path.read_text(encoding='ascii').splitlines()
    require(lines and all(len(x) == 8 and all(c in '0123456789abcdefABCDEF' for c in x) for x in lines), f'{path}: exact 32-bit hex required')
    return [int(x, 16) for x in lines]


def read_csv(path, header):
    result = []
    with path.open(newline='', encoding='ascii') as stream:
        source = csv.DictReader(stream)
        require(tuple(source.fieldnames or ()) == header, f'{path.name}: incorrect CSV header')
        for number, record in enumerate(source):
            require(None not in record and all(x is not None and x and x == x.strip() for x in record.values()), f'{path.name} row{number}: malformed row')
            row = {}
            for field, value in record.items():
                if field in ('kind', 'event'):
                    row[field] = value
                else:
                    try:
                        row[field] = int(value, 16 if field in HEX_FIELDS else 10)
                    except ValueError as error:
                        raise ValueError(f'{path.name} row{number}: invalid {field}') from error
                    require(row[field] >= 0, f'{path.name} row{number}: negative {field}')
                    if field in HEX_FIELDS:
                        require(row[field] <= (0xffffffffffffffff if field == 'seq' else MASK), f'{path.name} row{number}: oversized {field}')
            result.append(row)
    return result


class Machine:
    def __init__(self):
        self.gpr = [None] * 32
        self.gpr[0] = 0
        self.csr = dict(mstatus=0x1800, mtvec=0x100, mscratch=0, mepc=0, mcause=0, mtval=0)
        self.pc = 0
        self.instret = 0

    def operand(self, reg):
        require(self.gpr[reg] is not None, f'reference read uninitialized x{reg} at {self.pc:x}')
        return self.gpr[reg]

    def step(self, word):
        pc = self.pc
        opcode, f3 = word & 127, (word >> 12) & 7
        rd, rs1, rs2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        following, value, writes = (pc + 4) & MASK, 0, False
        cause = tval = 0
        fault = False
        if word in (0x00000073, 0x00100073):
            cause, tval = (11, 0) if word == 0x73 else (3, pc)
            fault = True
        elif word == 0x30200073:
            rd = 0
            following = self.csr['mepc']
            old = self.csr['mstatus']
            self.csr['mstatus'] = 0x1880 | ((old >> 4) & 8)
        elif opcode == 0x73 and f3 in (1, 2, 3, 5, 6, 7):
            address = word >> 20
            operand = rs1 if f3 & 4 else self.operand(rs1)
            intent = f3 in (1, 5) or rs1 != 0
            if address in ADDRESSES:
                name = ADDRESSES[address]
                value = self.csr[name]
                if intent:
                    replacement = operand if (f3 & 3) == 1 else value | operand if (f3 & 3) == 2 else value & ~operand
                    if name == 'mstatus':
                        replacement = 0x1800 | (replacement & 0x88)
                    elif name in ('mepc', 'mtvec'):
                        replacement &= 0xfffffffc
                    self.csr[name] = replacement & MASK
            elif address == 0x301:
                value = 0x40000100  # RV32I only; WARL writes ignored.
            elif 0xf11 <= address <= 0xf15 and not intent:
                value = 0
            else:
                cause, tval, fault = 2, word, True
            writes = rd != 0
        elif opcode == 0x37:
            value, writes = word & 0xfffff000, rd != 0
        elif opcode == 0x13 and f3 == 0:
            displacement = word >> 20
            if displacement & 0x800:
                displacement -= 4096
            value, writes = self.operand(rs1) + displacement, rd != 0
        elif opcode == 0x33 and f3 == 0 and word >> 25 == 0:
            value, writes = self.operand(rs1) + self.operand(rs2), rd != 0
        elif opcode == 0x6f:
            displacement = ((word >> 31) << 20) | (((word >> 12) & 255) << 12) | (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1)
            if displacement & (1 << 20):
                displacement -= 1 << 21
            value, writes, following = following, rd != 0, (pc + displacement) & MASK
        else:
            cause, tval, fault = 2, word, True
        if fault:
            old = self.csr['mstatus']
            self.csr.update(mstatus=0x1800 | ((old & 8) << 4), mepc=pc & 0xfffffffc, mcause=cause, mtval=tval & MASK)
            following = self.csr['mtvec']
            event = dict(kind='trap', pc=pc, instr=word, rd=0, value=0, writes=0, nextpc=following, cause=cause, tval=tval & MASK)
        else:
            value &= MASK
            if writes:
                self.gpr[rd] = value
            self.instret += 1
            event = dict(kind='retire', pc=pc, instr=word, rd=rd, value=value, writes=int(writes), nextpc=following, cause=0, tval=0)
        self.pc = following
        return dict(**event, **self.csr)


def simulate(program, limit=512):
    machine, events = Machine(), []
    for _ in range(limit):
        require(machine.pc % 4 == 0 and 0 <= machine.pc < len(program) * 4, f'reference PC outside ROM {machine.pc:x}')
        events.append(machine.step(program[machine.pc // 4]))
    return dict(events=events, gpr=machine.gpr, csr=machine.csr, instret=machine.instret)


def selftest_decoder():
    """Published fixed words and hand-computed values; no fixture encoder import."""
    count = 0
    def check(machine, word, expected):
        nonlocal count
        event = machine.step(word)
        require(all(event[k] == v for k, v in expected.items()), f'decoder selftest word {word:08x}: {event} != {expected}')
        count += 1
        return event
    m = Machine()
    check(m, 0x15500093, dict(value=0x155, rd=1, writes=1, nextpc=4))
    check(m, 0x340091f3, dict(value=0, mscratch=0x155, rd=3))
    check(m, 0x00a00113, dict(value=10, rd=2))
    check(m, 0x34012373, dict(value=0x155, mscratch=0x15f, rd=6))
    check(m, 0x340133f3, dict(value=0x15f, mscratch=0x155, rd=7))
    check(m, 0x3401d473, dict(value=0x155, mscratch=3, rd=8))
    check(m, 0x340a64f3, dict(value=3, mscratch=0x17, rd=9))
    check(m, 0x3402f573, dict(value=0x17, mscratch=0x12, rd=10))
    check(m, 0x340065f3, dict(value=0x12, mscratch=0x12, rd=11))
    check(m, 0x34007673, dict(value=0x12, mscratch=0x12, rd=12))
    check(m, 0x30045073, dict(value=0x1800, mstatus=0x1808, writes=0))
    m.gpr[1] = 0x403
    check(m, 0x30509073, dict(mtvec=0x400))
    check(m, 0x00000073, dict(kind='trap', cause=11, tval=0, mstatus=0x1880, mepc=48, nextpc=0x400))
    m.gpr[1] = 0x123
    check(m, 0x34109073, dict(mepc=0x120))
    check(m, 0x30200073, dict(kind='retire', nextpc=0x120, mstatus=0x1888, rd=0, value=0, writes=0))
    check(m, 0x301010f3, dict(value=0x40000100, rd=1))
    check(m, 0xf11020f3, dict(value=0, rd=1))
    check(m, 0xf11010f3, dict(kind='trap', cause=2, tval=0xf11010f3))
    m.gpr[2] = 0
    check(m, 0xf11120f3, dict(kind='trap', cause=2, tval=0xf11120f3))
    check(m, 0xf11060f3, dict(kind='retire', value=0))
    for word in (0x304020f3, 0x344020f3, 0xb00020f3, 0xc00020f3, 0xc02020f3, 0x7c0020f3):
        check(m, word, dict(kind='trap', cause=2, tval=word))
    m = Machine()
    check(m, 0xfff00093, dict(value=MASK))
    check(m, 0x30009073, dict(mstatus=0x1888))
    check(m, 0x00100073, dict(kind='trap', cause=3, tval=8, mepc=8))
    try:
        Machine().step(0x00010093)
    except ValueError as error:
        require('uninitialized x2' in str(error), 'wrong uninitialized-read rejection')
        count += 1
    else:
        raise ValueError('uninitialized GPR falsely accepted')
    return dict(status='PASS', fixed_word_checks=count)


def audit_case(directory, reference, terminal_pc):
    events = read_csv(directory / 'events.csv', EVENT_HEADER)
    accepts = read_csv(directory / 'accept.csv', ACCEPT_HEADER)
    wb = read_csv(directory / 'wb.csv', WB_HEADER)
    ifrows = read_csv(directory / 'if.csv', IF_HEADER)
    metrics = json.loads((directory / 'metrics.json').read_text())
    owners = {}
    for number, row in enumerate(accepts):
        require(row['cycle'] > 0 and row['seq'] not in owners and (not number or row['seq'] > accepts[number - 1]['seq']), f'accepted owner identity/order row{number}')
        owners[row['seq']] = row
    require(events and len(events) <= len(reference['events']), 'event prefix missing/overflow')
    retired, traps, seen, count, previous_cycle, previous_seq = [], [], set(), 0, 0, -1
    for number, row in enumerate(events):
        expected = reference['events'][number]
        require(row['index'] == number, f'event index mismatch row{number}')
        require(row['cycle'] > previous_cycle and row['seq'] > previous_seq and row['seq'] not in seen, f'event age/cycle row{number}')
        seen.add(row['seq']); previous_cycle, previous_seq = row['cycle'], row['seq']
        require(row['seq'] in owners and all(owners[row['seq']][k] == row[k] for k in ('pc', 'instr')) and owners[row['seq']]['cycle'] < row['cycle'], f'event accepted owner mismatch row{number}')
        for field in FIELDS:
            require(row[field] == expected[field], f'event {field} mismatch row{number}: {row[field]} != {expected[field]}')
        if row['kind'] == 'retire':
            count += 1;retired.append(row)
        else:
            require(row['kind'] == 'trap', f'unknown event kind row{number}')
            traps.append(row)
        require(row['instret'] == count, f'instret excludes trap mismatch row{number}')
    require(len(wb) == len(retired), 'WB ledger not drained')
    for number, (row, old) in enumerate(zip(wb, retired)):
        require(row['index'] == number and row['cycle'] > old['cycle'], f'WB retirement ordering row{number}')
        for field in ('seq', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc'):
            require(row[field] == old[field], f'WB {field} mismatch row{number}')
    require(any(x['kind'] == 'retire' and x['pc'] == terminal_pc for x in events), 'terminal normal JAL not retired')
    require(len(traps) == len([x for x in reference['events'] if x['kind'] == 'trap']), 'precise trap count mismatch')
    final = (directory / 'actual_gpr_final.hex').read_text(encoding='ascii').splitlines()
    require(len(final) == 32, 'complete physical GPR observation required')
    for register, value in enumerate(reference['gpr']):
        if value is None:
            require(final[register].lower() == 'xxxxxxxx', f'uninitialized GPR x{register} changed')
        else:
            require(final[register].lower() == f'{value:08x}', f'final GPR x{register} mismatch')
    pending, requests, responses, last_cycle = [], 0, 0, 0
    for row in ifrows:
        require(row['event'] in ('req', 'rsp') and row['cycle'] >= last_cycle, 'IF event kind/order mismatch')
        last_cycle = row['cycle']
        if row['event'] == 'req':
            require(not pending, 'IF owner overwrite')
            pending.append(row['addr']);requests += 1
        else:
            require(pending and pending.pop(0) == row['addr'], 'IF response owner mismatch')
            responses += 1
    require(not pending and requests == responses, 'IF request response ledger not drained')
    counts = dict(retired=len(retired), wb_packets=len(wb), traps=len(traps), events=len(events), accepted=len(accepts), requests=requests, responses=responses)
    for key, value in counts.items():
        require(type(metrics.get(key)) is int and metrics[key] == value, f'metric {key} mismatch')
    require(metrics['cycles'] > max([x['cycle'] for x in events + wb + ifrows]), 'final cycle does not cover drain')
    return dict(status='PASS', **counts, cycles=metrics['cycles'], defined_gpr=sum(x is not None for x in reference['gpr']), unchanged_unknown_gpr=sum(x is None for x in reference['gpr']))


def analyze(directory):
    program = read_hex(directory / 'program.hex')
    fixture = json.loads((directory / 'fixture.json').read_text())
    reference = simulate(program)
    # Recompute all producer-supplied expectations directly from machine words.
    for field in FIELDS:
        values = [int(x[field] == 'trap') if field == 'kind' else x[field] for x in reference['events']]
        require(read_hex(directory / f'expected_{field}.hex') == values, f'generated expected {field} differs from independent execution')
    paths = sorted((directory / 'cases').glob('case*'), key=lambda x: int(x.name[4:]))
    require([x.name for x in paths] == [f'case{i}' for i in range(16)], 'all sixteen matrix cases required')
    cases = [dict(case=i, id_mode=i % 2, predict=(i // 2) % 2, wait=(i // 4) % 2, forwarding=i // 8, **audit_case(path, reference, fixture['terminal_pc'])) for i, path in enumerate(paths)]
    return dict(status='PASS', scope='CPU5 minimal machine CSR/MRET real IF end-to-end', cases=cases, case_count=len(cases), total_retired=sum(x['retired'] for x in cases), total_wb_packets=sum(x['wb_packets'] for x in cases), total_traps=sum(x['traps'] for x in cases), total_i_requests=sum(x['requests'] for x in cases), total_i_responses=sum(x['responses'] for x in cases), decoder_selftest=selftest_decoder(), modeled_csrs=list(ADDRESSES.values()) + ['misa-fixed', 'zero-read-only-IDs'], limitation='No IRQ, M, MMIO, system integration, STA, board or performance claim')


def selftest_evidence(directory):
    scratch = directory.parent / (directory.name + '_negative_evidence')
    scratch.mkdir(parents=True, exist_ok=True)
    reference = simulate(read_hex(directory / 'program.hex'))
    terminal = json.loads((directory / 'fixture.json').read_text())['terminal_pc']
    source = directory / 'cases/case0'
    protected = [x for x in directory.rglob('*') if x.is_file() and x.name not in ('analysis.json', 'verification.json')]
    def digest():
        return {x.relative_to(directory).as_posix(): hashlib.sha256(x.read_bytes()).hexdigest() for x in protected}
    before, results = digest(), []
    mutations = [('csr_old_value', 'events.csv', 'event value mismatch'), ('mret_target', 'events.csv', 'event nextpc mismatch'), ('trap_mstatus', 'events.csv', 'event mstatus mismatch'), ('trap_cause', 'events.csv', 'event cause mismatch'), ('csr_state', 'events.csv', 'event mscratch mismatch'), ('owner', 'events.csv', 'event accepted owner mismatch'), ('missing_wb', 'wb.csv', 'WB ledger not drained'), ('physical_wb_value', 'wb.csv', 'WB value mismatch'), ('final_gpr', 'actual_gpr_final.hex', 'final GPR x3 mismatch')]
    for name, filename, reason in mutations:
        destination = scratch / name
        shutil.copytree(source, destination, dirs_exist_ok=True)
        changed = destination / filename
        if filename.endswith('.csv'):
            with changed.open(newline='', encoding='ascii') as stream:
                reader = csv.DictReader(stream);header = reader.fieldnames;rows = list(reader)
            if name == 'missing_wb':
                rows.pop(0)
            else:
                row = rows[0]
                if name == 'csr_old_value':
                    row = next(x for x in rows if x['kind'] == 'retire' and int(x['instr'], 16) & 127 == 0x73);field = 'value'
                elif name == 'mret_target':
                    row = next(x for x in rows if x['instr'] == '30200073');field = 'nextpc'
                elif name in ('trap_mstatus', 'trap_cause'):
                    row = next(x for x in rows if x['kind'] == 'trap');field = 'mstatus' if name == 'trap_mstatus' else 'cause'
                elif name == 'csr_state':
                    row = next(x for x in rows if x['kind'] == 'retire' and int(x['instr'], 16) >> 20 == 0x340);field = 'mscratch'
                else:
                    field = 'seq' if name == 'owner' else 'value'
                row[field] = f'{int(row[field], 16) ^ 1:08x}'
            with changed.open('w', newline='', encoding='ascii') as stream:
                writer = csv.DictWriter(stream, fieldnames=header, lineterminator='\n');writer.writeheader();writer.writerows(rows)
        else:
            lines = changed.read_text(encoding='ascii').splitlines();lines[3] = f'{int(lines[3], 16) ^ 1:08x}';changed.write_text('\n'.join(lines) + '\n', encoding='ascii')
        try:
            audit_case(destination, reference, terminal)
        except ValueError as error:
            require(reason in str(error), f'negative {name} unintended rejection: {error}')
            message = str(error)
        else:
            raise ValueError(f'negative {name} falsely accepted')
        require(changed.read_bytes() != (source / filename).read_bytes(), f'negative {name} unchanged')
        results.append(dict(name=name, status='REJECTED', reason=message, file=filename, good_sha256=hashlib.sha256((source / filename).read_bytes()).hexdigest(), bad_sha256=hashlib.sha256(changed.read_bytes()).hexdigest()))
    require(before == digest(), 'negative copies changed good evidence')
    result = dict(status='PASS', rejected_count=len(results), rejected=results, good_inputs_unchanged=True)
    (scratch / 'summary.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'build/cpu5_s7_csr_program')
    parser.add_argument('--decoder-only', action='store_true')
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()
    if args.decoder_only:
        print(json.dumps(selftest_decoder()));return
    result = analyze(args.directory)
    if args.selftest:
        result['negative_evidence_tests'] = selftest_evidence(args.directory)
    (args.directory / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status=result['status'], cases=result['case_count'], retired=result['total_retired'], traps=result['total_traps'], negative_evidence=result.get('negative_evidence_tests', {}).get('rejected_count', 0))))


if __name__ == '__main__':
    main()
