"""Independent machine-word RV32IM interpreter and real-log audit for CPU5.

No RTL or fixture encoder is imported. Signed divide uses integer magnitudes
and truncation toward zero, never host float division. Unknown physical GPRs
remain unknown until written. Byte RAM is updated only by interpreted stores.
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
FIELDS = ('pc', 'instr', 'rd', 'value', 'writes', 'nextpc')
TRACE_HEADER = ('cycle', 'index', 'seq') + FIELDS + ('instret',)
WB_HEADER = ('cycle', 'index', 'seq') + FIELDS
ACCEPT_HEADER = ('cycle', 'seq', 'pc', 'instr')
M_HEADER = ('event', 'cycle', 'seq', 'value')
D_HEADER = ('event', 'cycle', 'seq', 'pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write', 'rdata')
IF_HEADER = ('event', 'cycle', 'addr')
HEX_FIELDS = {'seq', 'pc', 'instr', 'value', 'nextpc', 'addr', 'wdata', 'wstrb', 'rdata'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signed(value):
    return value - 0x100000000 if value & 0x80000000 else value


def m_result(function, left, right):
    if function == 0:
        return left * right & MASK
    if function == 1:
        return (signed(left) * signed(right) >> 32) & MASK
    if function == 2:
        return (signed(left) * right >> 32) & MASK
    if function == 3:
        return (left * right >> 32) & MASK
    if right == 0:
        return MASK if function in (4, 5) else left
    if function in (5, 7):
        return left // right if function == 5 else left % right
    lhs, rhs = signed(left), signed(right)
    quotient = abs(lhs) // abs(rhs)
    if (lhs < 0) != (rhs < 0):
        quotient = -quotient
    return (quotient if function == 4 else lhs - quotient * rhs) & MASK


class Machine:
    def __init__(self, initial):
        self.pc = 0
        self.gpr = [None] * 32
        self.gpr[0] = 0
        self.ram = bytearray(b''.join(word.to_bytes(4, 'little') for word in initial))

    def read(self, register):
        require(self.gpr[register] is not None, f'uninitialized GPR x{register} read at {self.pc:x}')
        return self.gpr[register]

    def step(self, instruction):
        pc, nextpc = self.pc, self.pc + 4
        opcode, function = instruction & 127, (instruction >> 12) & 7
        rd, rs1, rs2 = (instruction >> 7) & 31, (instruction >> 15) & 31, (instruction >> 20) & 31
        value, access, is_m = 0, None, False
        if opcode == 0x33 and instruction >> 25 == 1:
            value = m_result(function, self.read(rs1), self.read(rs2));is_m = True
        elif opcode == 0x37:
            value = instruction & 0xfffff000
        elif opcode == 0x13 and function == 0:
            offset = instruction >> 20
            if offset & 2048:
                offset -= 4096
            value = self.read(rs1) + offset
        elif opcode == 0x33 and instruction >> 25 == 0 and function == 0:
            value = self.read(rs1) + self.read(rs2)
        elif opcode == 0x63 and function == 0:
            displacement = ((instruction >> 31) << 12) | (((instruction >> 7) & 1) << 11) | (((instruction >> 25) & 63) << 5) | (((instruction >> 8) & 15) << 1)
            if displacement & 4096:
                displacement -= 8192
            nextpc = pc + displacement if self.read(rs1) == self.read(rs2) else nextpc
            rd = 0
        elif opcode == 0x6f:
            displacement = ((instruction >> 31) << 20) | (((instruction >> 12) & 255) << 12) | (((instruction >> 20) & 1) << 11) | (((instruction >> 21) & 1023) << 1)
            if displacement & (1 << 20):
                displacement -= 1 << 21
            value, nextpc = nextpc, pc + displacement
        elif opcode in (3, 0x23) and function == 2:
            store = opcode == 0x23
            offset = (((instruction >> 25) << 5) | ((instruction >> 7) & 31)) if store else instruction >> 20
            if offset & 2048:
                offset -= 4096
            address = (self.read(rs1) + offset) & MASK
            require(address % 4 == 0 and 0x10000 <= address <= 0x10000 + len(self.ram) - 4, f'RAM range/alignment at {pc:x}')
            offset = address - 0x10000
            raw = int.from_bytes(self.ram[offset:offset + 4], 'little')
            data = self.read(rs2) if store else 0
            access = dict(pc=pc, instr=instruction, addr=address, wdata=data, wstrb=15 if store else 0, size=2, is_write=int(store), rdata=raw)
            if store:
                self.ram[offset:offset + 4] = data.to_bytes(4, 'little');rd = 0
            else:
                value = raw
        elif instruction == 0x30102f73:
            value = 0x40001100  # RV32IM; current core still runs only M mode.
        else:
            raise ValueError(f'independent decoder illegal instruction {instruction:08x} at {pc:x}')
        value &= MASK;nextpc &= MASK
        writes = int(rd != 0)
        if writes:
            self.gpr[rd] = value
        self.pc = nextpc
        return dict(pc=pc, instr=instruction, rd=rd, value=value, writes=writes, nextpc=nextpc, is_m=is_m, access=access)


def read_hex(path):
    rows = path.read_text(encoding='ascii').splitlines()
    require(rows and all(len(row) == 8 and all(x in '0123456789abcdefABCDEF' for x in row) for row in rows), f'{path}: exact 32-bit hex required')
    return [int(row, 16) for row in rows]


def read_csv(path, header):
    result = []
    with path.open(newline='', encoding='ascii') as stream:
        reader = csv.DictReader(stream)
        require(tuple(reader.fieldnames or ()) == header, f'{path.name}: incorrect header')
        for number, record in enumerate(reader):
            require(None not in record and all(x is not None and x and x == x.strip() for x in record.values()), f'{path.name} row{number}: malformed row')
            row = {}
            for field, value in record.items():
                if field == 'event':
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


def simulate(program, initial, limit=256):
    machine, events, accesses = Machine(initial), [], []
    for _ in range(limit):
        require(machine.pc % 4 == 0 and 0 <= machine.pc < len(program) * 4, 'reference PC outside ROM')
        event = machine.step(program[machine.pc // 4]);events.append(event)
        if event['access']:
            accesses.append(dict(**event['access'], retire_index=len(events) - 1))
    return dict(events=events, accesses=accesses, gpr=machine.gpr, memory=[int.from_bytes(machine.ram[i:i + 4], 'little') for i in range(0, len(machine.ram), 4)])


def decoder_selftest():
    # Fixed machine words for all eight functions, x4 <- x2 op x3.
    instructions = (0x02310233, 0x02311233, 0x02312233, 0x02313233, 0x02314233, 0x02315233, 0x02316233, 0x02317233)
    samples = [
        (0xfffffff9, 3, (0xffffffeb, MASK, MASK, 2, 0xfffffffe, 0x55555553, MASK, 0)),
        (0x80000000, MASK, (0x80000000, 0, 0x80000000, 0x7fffffff, 0x80000000, 0, 0, 0x80000000)),
        (MASK, MASK, (1, 0, MASK, 0xfffffffe, 1, 1, 0, 0)),
        (0xfffffff9, 0, (0, 0, 0, 0, MASK, MASK, 0xfffffff9, 0xfffffff9)),
        (7, 0xfffffffd, (0xffffffeb, MASK, 6, 6, 0xfffffffe, 0, 1, 7)),
    ]
    count = 0
    for left, right, expected in samples:
        for instruction, value in zip(instructions, expected):
            machine = Machine([0] * 8);machine.gpr[2] = left;machine.gpr[3] = right
            event = machine.step(instruction)
            require(event['is_m'] and event['value'] == value and machine.gpr[4] == value and event['nextpc'] == 4, f'fixed M word selftest {instruction:08x}, {left:08x}, {right:08x}: {event}')
            count += 1
    machine = Machine([0] * 8)
    require(machine.step(0x30102f73)['value'] == 0x40001100, 'truthful RV32IM misa fixed word');count += 1
    machine = Machine([0] * 8)
    try:
        machine.step(instructions[0])
    except ValueError as error:
        require('uninitialized GPR x2' in str(error), 'uninitialized M source rejection reason');count += 1
    else:
        raise ValueError('uninitialized M source falsely accepted')
    return dict(status='PASS', fixed_word_checks=count)


def audit_case(directory, reference, terminal_pc):
    rows = read_csv(directory / 'trace.csv', TRACE_HEADER)
    wb = read_csv(directory / 'wb.csv', WB_HEADER)
    accepts = read_csv(directory / 'accept.csv', ACCEPT_HEADER)
    mrows = read_csv(directory / 'm.csv', M_HEADER)
    drows = read_csv(directory / 'd.csv', D_HEADER)
    ifrows = read_csv(directory / 'if.csv', IF_HEADER)
    metrics = json.loads((directory / 'metrics.json').read_text())
    owners = {}
    for number, row in enumerate(accepts):
        require(row['cycle'] > 0 and row['seq'] not in owners and (not number or row['seq'] > accepts[number - 1]['seq']), 'accepted owner order/identity')
        owners[row['seq']] = row
    require(rows and len(rows) <= len(reference['events']), 'retirement prefix missing/overflow')
    retired, previous_seq, previous_cycle = {}, -1, 0
    for number, row in enumerate(rows):
        require(row['index'] == number and row['instret'] == number + 1, f'retirement index/count row{number}')
        require(row['seq'] > previous_seq and row['cycle'] > previous_cycle, f'retirement age/cycle row{number}')
        previous_seq, previous_cycle = row['seq'], row['cycle']
        require(row['seq'] in owners and all(owners[row['seq']][field] == row[field] for field in ('pc', 'instr')) and owners[row['seq']]['cycle'] < row['cycle'], f'retirement accepted owner row{number}')
        for field in FIELDS:
            require(row[field] == reference['events'][number][field], f'retirement {field} mismatch row{number}')
        retired[row['seq']] = row
    require(len(wb) == len(rows), 'physical WB ledger not drained')
    for number, (row, old) in enumerate(zip(wb, rows)):
        require(row['index'] == number and row['cycle'] > old['cycle'], f'WB retirement order row{number}')
        for field in ('seq',) + FIELDS:
            require(row[field] == old[field], f'WB {field} mismatch row{number}')
    require(any(row['pc'] == terminal_pc for row in rows), 'terminal JAL not retired')
    issues, starts, completions, last_cycle = {}, {}, {}, 0
    for row in mrows:
        require(row['cycle'] >= last_cycle and row['cycle'] > 0 and row['event'] in ('issue', 'start', 'complete'), 'M event kind/order')
        last_cycle = row['cycle'];seq = row['seq']
        require(seq in retired and reference['events'][retired[seq]['index']]['is_m'], 'M event unretired/non-M owner')
        ledger = issues if row['event'] == 'issue' else starts if row['event'] == 'start' else completions
        require(seq not in ledger, 'M owner repeated event')
        ledger[seq] = row
        if row['event'] == 'issue':
            require(owners[seq]['cycle'] < row['cycle'] < retired[seq]['cycle'] and row['value'] == 0, 'M issue owner lifetime')
        elif row['event'] == 'start':
            require(seq in issues and issues[seq]['cycle'] <= row['cycle'] and row['value'] == 0, 'M start lacks generation owner')
        else:
            require(seq in starts and starts[seq]['cycle'] < row['cycle'] <= retired[seq]['cycle'], 'M completion before start/after retirement')
            require(row['value'] == retired[seq]['value'], 'M completion result mismatch')
    expected_m = {seq for seq, row in retired.items() if reference['events'][row['index']]['is_m']}
    require(set(issues) == set(starts) == set(completions) == expected_m, 'M generation ledgers not closed')
    requests, responses, pending, ordinal, last_cycle = {}, {}, None, 0, 0
    for row in drows:
        require(row['event'] in ('req', 'rsp') and row['cycle'] >= last_cycle, 'D event kind/order');last_cycle = row['cycle']
        seq = row['seq']
        require(seq in retired and row['pc'] == retired[seq]['pc'], 'D retirement owner PC')
        if row['event'] == 'req':
            require(pending is None and seq not in requests and ordinal < len(reference['accesses']), 'D duplicate request/owner overwrite')
            gold = reference['accesses'][ordinal];ordinal += 1
            require(retired[seq]['index'] == gold['retire_index'] and owners[seq]['cycle'] < row['cycle'] < retired[seq]['cycle'], 'D instruction owner/order')
            pending = (seq, gold);requests[seq] = row
        else:
            require(pending and pending[0] == seq and seq not in responses, 'D response lacks owner')
            _, gold = pending;pending = None;responses[seq] = row
            require(row['rdata'] == gold['rdata'], 'D raw response mismatch')
            require(requests[seq]['cycle'] <= row['cycle'] <= retired[seq]['cycle'], 'D response owner lifetime')
        for field in ('pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write'):
            require(row[field] == gold[field], f'D {field} mismatch')
    require(pending is None and set(requests) == set(responses) and ordinal == len(reference['accesses']), 'D ledgers not closed')
    require(read_hex(directory / 'actual_ram_final.hex') == reference['memory'], 'complete RAM mismatch')
    final = (directory / 'actual_gpr_final.hex').read_text(encoding='ascii').splitlines()
    require(len(final) == 32, 'complete GPR observation required')
    for register, value in enumerate(reference['gpr']):
        require(final[register].lower() == ('xxxxxxxx' if value is None else f'{value:08x}'), f'final GPR x{register} mismatch')
    pending, iq, ir, last_cycle = [], 0, 0, 0
    for row in ifrows:
        require(row['event'] in ('req', 'rsp') and row['cycle'] >= last_cycle, 'IF event kind/order');last_cycle = row['cycle']
        if row['event'] == 'req':
            require(not pending, 'IF request owner overwrite');pending.append(row['addr']);iq += 1
        else:
            require(pending and pending.pop(0) == row['addr'], 'IF response owner mismatch');ir += 1
    require(not pending and iq == ir, 'IF ledgers not closed')
    counts = dict(retired=len(rows), wb_packets=len(wb), accepted=len(accepts), m_issues=len(issues), m_starts=len(starts), m_completions=len(completions), d_requests=len(requests), d_responses=len(responses), requests=iq, responses=ir)
    for field, value in counts.items():
        require(type(metrics.get(field)) is int and metrics[field] == value, f'metric {field} mismatch')
    require(metrics['cycles'] > max(row['cycle'] for row in rows + wb + mrows + drows + ifrows), 'final cycle does not cover drain')
    return dict(status='PASS', **counts, cycles=metrics['cycles'], defined_gpr=sum(x is not None for x in reference['gpr']), unchanged_unknown_gpr=sum(x is None for x in reference['gpr']))


def analyze(directory):
    reference = simulate(read_hex(directory / 'program.hex'), read_hex(directory / 'ram_initial.hex'))
    fixture = json.loads((directory / 'fixture.json').read_text())
    for field in FIELDS:
        require(read_hex(directory / f'expected_{field}.hex') == [row[field] for row in reference['events']], f'expected {field} differs from independent machine execution')
    paths = sorted((directory / 'cases').glob('case*'), key=lambda path: int(path.name[4:]))
    require([path.name for path in paths] == [f'case{i}' for i in range(16)], 'all sixteen M program cases required')
    cases = [dict(case=i, id_mode=i % 2, predict=(i // 2) % 2, wait=(i // 4) % 2, forwarding=i // 8, **audit_case(path, reference, fixture['terminal_pc'])) for i, path in enumerate(paths)]
    return dict(status='PASS', scope='CPU5 RV32M owner real IF end-to-end program', case_count=len(cases), cases=cases,
                total_retired=sum(x['retired'] for x in cases), total_wb_packets=sum(x['wb_packets'] for x in cases),
                total_m_issues=sum(x['m_issues'] for x in cases), total_m_starts=sum(x['m_starts'] for x in cases), total_m_completions=sum(x['m_completions'] for x in cases),
                total_d_requests=sum(x['d_requests'] for x in cases), total_d_responses=sum(x['d_responses'] for x in cases),
                total_i_requests=sum(x['requests'] for x in cases), total_i_responses=sum(x['responses'] for x in cases), decoder_selftest=decoder_selftest(),
                limitation='No IRQ, MMIO, cache/AXI/SoC integration, STA, board or performance claim')


def selftest_evidence(directory):
    reference = simulate(read_hex(directory / 'program.hex'), read_hex(directory / 'ram_initial.hex'))
    terminal = json.loads((directory / 'fixture.json').read_text())['terminal_pc']
    source = directory / 'cases/case0';scratch = directory.parent / (directory.name + '_negative_evidence')
    scratch.mkdir(parents=True, exist_ok=True)
    protected = [x for x in directory.rglob('*') if x.is_file() and x.name not in ('analysis.json', 'verification.json')]
    def hashes():
        return {path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in protected}
    before, rejected = hashes(), []
    tests = [('m_value', 'trace.csv', 'retirement value mismatch'), ('retire_nextpc', 'trace.csv', 'retirement nextpc mismatch'),
             ('m_result', 'm.csv', 'M completion result mismatch'), ('m_owner', 'm.csv', 'M event unretired/non-M owner'),
             ('m_duplicate_start', 'm.csv', 'M owner repeated event'), ('missing_wb', 'wb.csv', 'physical WB ledger not drained'),
             ('d_raw', 'd.csv', 'D raw response mismatch'), ('final_ram', 'actual_ram_final.hex', 'complete RAM mismatch'),
             ('final_gpr', 'actual_gpr_final.hex', 'final GPR x4 mismatch')]
    for name, filename, reason in tests:
        destination = scratch / name;shutil.copytree(source, destination, dirs_exist_ok=True);changed = destination / filename
        if filename.endswith('.csv'):
            with changed.open(newline='', encoding='ascii') as stream:
                reader = csv.DictReader(stream);header = reader.fieldnames;rows = list(reader)
            if name == 'missing_wb':
                rows.pop(0)
            elif name == 'm_duplicate_start':
                position = next(i for i, row in enumerate(rows) if row['event'] == 'start');rows.insert(position + 1, dict(rows[position]))
            else:
                if name in ('m_value', 'retire_nextpc'):
                    row = next(row for row in rows if int(row['instr'], 16) & 0xfe00007f == 0x02000033);field = 'value' if name == 'm_value' else 'nextpc'
                elif name in ('m_result', 'm_owner'):
                    row = next(row for row in rows if row['event'] == 'complete');field = 'value' if name == 'm_result' else 'seq'
                else:
                    row = next(row for row in rows if row['event'] == 'rsp');field = 'rdata'
                row[field] = f'{int(row[field], 16) ^ (1 if field != "seq" else 0x1000000000000000):08x}'
            with changed.open('w', newline='', encoding='ascii') as stream:
                writer = csv.DictWriter(stream, fieldnames=header, lineterminator='\n');writer.writeheader();writer.writerows(rows)
        else:
            rows = changed.read_text(encoding='ascii').splitlines();index = 4 if name == 'final_gpr' else 0;rows[index] = f'{int(rows[index], 16) ^ 1:08x}';changed.write_text('\n'.join(rows) + '\n', encoding='ascii')
        try:
            audit_case(destination, reference, terminal)
        except ValueError as error:
            require(reason in str(error), f'negative {name} rejected for unintended reason: {error}');message = str(error)
        else:
            raise ValueError(f'negative {name} falsely accepted')
        require(changed.read_bytes() != (source / filename).read_bytes(), f'negative {name} unchanged')
        rejected.append(dict(name=name, status='REJECTED', error=message, file=filename, good_sha256=hashlib.sha256((source / filename).read_bytes()).hexdigest(), bad_sha256=hashlib.sha256(changed.read_bytes()).hexdigest()))
    require(before == hashes(), 'bad evidence copies changed original good evidence')
    result = dict(status='PASS', rejected_count=len(rejected), rejected=rejected, good_inputs_unchanged=True)
    (scratch / 'summary.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'build/cpu5_s8_m_program')
    parser.add_argument('--decoder-only', action='store_true');parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()
    if args.decoder_only:
        print(json.dumps(decoder_selftest()));return
    result = analyze(args.directory)
    if args.selftest:
        result['negative_evidence_tests'] = selftest_evidence(args.directory)
    (args.directory / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='PASS', cases=result['case_count'], retired=result['total_retired'], m_issues=result['total_m_issues'], bad_evidence_rejected=result.get('negative_evidence_tests', {}).get('rejected_count', 0))))


if __name__ == '__main__':
    main()
