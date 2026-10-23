"""Independent IRQ program/event and two-flop/old-arm software oracle.

The frozen CSR and integer-M machine-word interpreters supply arithmetic, not
fixture encoders or RTL values. Three interrupts are specified by the device
fixture: all sources rise after the first DIV starts; service removes only that
raw source. Expected mepc comes from independent instruction execution.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil
from cpu5_csr_reference import Machine as CSRMachine
from cpu5_m_reference import m_result

ROOT = Path(__file__).resolve().parents[1]
MASK = 0xffffffff
CSRS = ('mstatus', 'mtvec', 'mscratch', 'mepc', 'mcause', 'mtval', 'mie')
FIELDS = ('kind', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc', 'cause', 'tval') + CSRS
EVENT_HEADER = ('kind', 'cycle', 'index', 'seq') + FIELDS[1:] + ('instret',)
WB_HEADER = ('cycle', 'index', 'seq', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc')
ACCEPT_HEADER = ('cycle', 'seq', 'pc', 'instr')
M_HEADER = ('event', 'cycle', 'seq', 'pc', 'value')
D_HEADER = ('event', 'cycle', 'seq', 'pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write', 'rdata')
IF_HEADER = ('event', 'cycle', 'addr', 'error')
CYCLE_HEADER = ('cycle', 'raw_ext', 'raw_sw', 'raw_timer', 'pending', 'arm', 'eligible', 'take', 'mstatus', 'mie')
HEX_FIELDS = {'seq', 'pc', 'instr', 'value', 'nextpc', 'cause', 'tval', 'addr', 'wdata', 'wstrb', 'rdata', 'pending', *CSRS}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read_hex(path):
    rows = path.read_text(encoding='ascii').splitlines()
    require(rows and all(len(x) == 8 and all(c in '0123456789abcdefABCDEF' for c in x) for x in rows), f'{path.name}: exact 32-bit hex required')
    return [int(x, 16) for x in rows]


def read_csv(path, header):
    result = []
    with path.open(newline='', encoding='ascii') as stream:
        source = csv.DictReader(stream)
        require(tuple(source.fieldnames or ()) == header, f'{path.name}: incorrect header')
        for number, record in enumerate(source):
            require(None not in record and all(x is not None and x and x == x.strip() for x in record.values()), f'{path.name} row{number}: malformed row')
            row = {}
            for field, value in record.items():
                if field in ('event', 'kind'):
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


class Machine(CSRMachine):
    def __init__(self, initial):
        super().__init__()
        self.mie = self.pending = 0
        self.memory = bytearray(b''.join(word.to_bytes(4, 'little') for word in initial))

    def step(self, word):
        opcode, function = word & 127, (word >> 12) & 7
        rd, rs1, rs2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        address = word >> 20
        pc, value, access = self.pc, 0, None
        if opcode == 0x33 and word >> 25 == 1:
            value = m_result(function, self.operand(rs1), self.operand(rs2))
        elif opcode in (3, 0x23) and function == 2:
            store = opcode == 0x23
            displacement = (((word >> 25) << 5) | ((word >> 7) & 31)) if store else word >> 20
            if displacement & 2048:
                displacement -= 4096
            target = (self.operand(rs1) + displacement) & MASK
            require(target % 4 == 0 and 0x10000 <= target <= 0x10000 + len(self.memory) - 4, 'reference RAM range/alignment')
            offset = target - 0x10000
            raw = int.from_bytes(self.memory[offset:offset + 4], 'little')
            data = self.operand(rs2) if store else 0
            access = dict(pc=pc, instr=word, addr=target, wdata=data, wstrb=15 if store else 0, size=2, is_write=int(store), rdata=raw)
            if store:
                self.memory[offset:offset + 4] = data.to_bytes(4, 'little');rd = 0
            else:
                value = raw
        elif opcode == 0x73 and function in (1, 2, 3, 5, 6, 7) and address in (0x304, 0x344, 0x301):
            value = self.mie if address == 0x304 else self.pending if address == 0x344 else 0x40001100
            source = rs1 if function & 4 else self.operand(rs1)
            intent = function in (1, 5) or rs1 != 0
            if intent and address == 0x304:
                replacement = source if (function & 3) == 1 else value | source if (function & 3) == 2 else value & ~source
                self.mie = replacement & 0x888
        else:
            event = super().step(word)
            require(event['kind'] == 'retire', f'unexpected architectural synchronous fault {word:08x} at {pc:x}')
            return dict(**event, mie=self.mie, access=None)
        value &= MASK
        if rd:
            self.gpr[rd] = value
        self.pc = (pc + 4) & MASK;self.instret += 1
        return dict(kind='retire', pc=pc, instr=word, rd=rd, value=value, writes=int(rd != 0), nextpc=self.pc,
                    cause=0, tval=0, **self.csr, mie=self.mie, access=access)

    def interrupt(self, cause):
        pc, status = self.pc, self.csr['mstatus']
        require(status & 8, 'reference interrupt requires committed MIE')
        self.csr.update(mstatus=0x1800 | ((status & 8) << 4), mepc=pc, mcause=cause, mtval=0)
        self.pc = self.csr['mtvec']
        return dict(kind='irq', pc=pc, instr=0, rd=0, value=0, writes=0, nextpc=self.pc, cause=cause, tval=0,
                    **self.csr, mie=self.mie, access=None)


def simulate(program, initial, div_pc, limit=256):
    machine, events, accesses, interrupts = Machine(initial), [], [], 0
    causes = (0x8000000b, 0x80000003, 0x80000007)
    while len(events) < limit:
        require(machine.pc % 4 == 0 and 0 <= machine.pc < len(program) * 4, 'reference PC outside ROM')
        if machine.pc == div_pc and interrupts < 3:
            event = machine.interrupt(causes[interrupts]);interrupts += 1
        else:
            event = machine.step(program[machine.pc // 4])
        events.append(event)
        if event['access']:
            accesses.append(dict(**event['access'], event_index=len(events) - 1))
    return dict(events=events, accesses=accesses, gpr=machine.gpr,
                memory=[int.from_bytes(machine.memory[i:i + 4], 'little') for i in range(0, len(machine.memory), 4)])


def decoder_selftest():
    machine = Machine([0] * 16)
    count = 0
    def check(word, expected):
        nonlocal count
        event = machine.step(word)
        require(all(event[key] == value for key, value in expected.items()), f'fixed IRQ machine word {word:08x}: {event}')
        count += 1
    check(0xfff00093, dict(value=MASK))
    check(0x30409073, dict(value=0, mie=0x888, writes=0))
    check(0x30402173, dict(value=0x888, rd=2))
    machine.pending = 0x888
    check(0x34401073, dict(value=0x888, writes=0))
    check(0x344021f3, dict(value=0x888, rd=3))
    check(0x30045073, dict(mstatus=0x1808))
    event = machine.interrupt(0x8000000b)
    require(event['pc'] == 24 and event['mepc'] == 24 and event['mcause'] == 0x8000000b and event['mstatus'] == 0x1880 and event['nextpc'] == 0x100, 'fixed asynchronous entry saves pre-state PC');count += 1
    check(0x30200073, dict(mstatus=0x1888, nextpc=24, writes=0))
    check(0x30102f73, dict(value=0x40001100, rd=30))
    for pending, expected in ((0x888, 0x8000000b), (0x88, 0x80000003), (0x80, 0x80000007)):
        cause = 0x8000000b if pending & 0x800 else 0x80000003 if pending & 8 else 0x80000007
        require(cause == expected, 'fixed external/software/timer priority');count += 1
    return dict(status='PASS', fixed_word_checks=count)


def audit_cycles(cycles, events, mrows, div_pc):
    by_cycle = {event['cycle']: event for event in events}
    starts = [row for row in mrows if row['event'] == 'start' and row['pc'] == div_pc]
    require(len(starts) == 2, 'interrupted DIV must start once killed and once resumed')
    first_start = starts[0]['cycle']
    raw = pending1 = pending2 = 0
    arm, status, mie, count = 0, 0x1800, 0, 0
    for number, row in enumerate(cycles):
        require(row['cycle'] == number + 1, 'complete contiguous per-cycle observations required')
        observed_raw = (0x800 if row['raw_ext'] else 0) | (8 if row['raw_sw'] else 0) | (0x80 if row['raw_timer'] else 0)
        require(all(row[field] in (0, 1) for field in ('raw_ext', 'raw_sw', 'raw_timer', 'arm', 'eligible', 'take')), 'cycle boolean malformed')
        require(observed_raw == raw, f'device raw source schedule cycle{number + 1}')
        require(row['pending'] == pending2, f'two-flop pending mismatch cycle{number + 1}')
        require(row['mstatus'] == status and row['mie'] == mie, f'committed CSR pre-state mismatch cycle{number + 1}')
        eligible = int(bool(status & 8 and pending2 & mie))
        require(row['arm'] == arm and row['eligible'] == eligible, f'old arm/current eligibility mismatch cycle{number + 1}')
        # This program raises pending only during a live EX DIV with empty MEM;
        # handler memory transactions run with MIE=0. All eligible edges are
        # therefore independently known safe, including the post-MRET edge.
        take = int(bool(arm and eligible))
        require(row['take'] == take, f'IRQ first safe edge mismatch cycle{number + 1}')
        event = by_cycle.get(row['cycle'])
        if take:
            expected = 0x8000000b if pending2 & mie & 0x800 else 0x80000003 if pending2 & mie & 8 else 0x80000007
            require(event and event['kind'] == 'irq' and event['cause'] == expected, 'eligible source priority/event mismatch')
            count += 1
        elif event:
            require(event['kind'] == 'retire', 'IRQ event without old armed eligible state')
        if event:
            status, mie = event['mstatus'], event['mie']
        arm = int(bool(status & 8 and pending2 & mie))
        pending2, pending1 = pending1, raw
        if row['cycle'] == first_start:
            raw = 0x888
        if take:
            raw &= ~(0x800 if event['cause'] == 0x8000000b else 8 if event['cause'] == 0x80000003 else 0x80)
    require(count == 3 and raw == pending1 == pending2 == arm == 0, 'source and arm state not drained')
    irq_events = [event for event in events if event['kind'] == 'irq']
    for event in irq_events[1:]:
        previous = by_cycle.get(event['cycle'] - 1)
        require(previous and previous['instr'] == 0x30200073 and previous['kind'] == 'retire', 'continuous pending not taken immediately after MRET')
    return dict(status='PASS', cycles=len(cycles), exact_irq_edges=count, synchronizer_stages=2, immediate_post_mret_irqs=2)


def audit_case(directory, reference, fixture):
    events = read_csv(directory / 'events.csv', EVENT_HEADER)
    accepts = read_csv(directory / 'accept.csv', ACCEPT_HEADER)
    wb = read_csv(directory / 'wb.csv', WB_HEADER)
    mrows = read_csv(directory / 'm.csv', M_HEADER)
    drows = read_csv(directory / 'd.csv', D_HEADER)
    ifrows = read_csv(directory / 'if.csv', IF_HEADER)
    cycles = read_csv(directory / 'cycles.csv', CYCLE_HEADER)
    metrics = json.loads((directory / 'metrics.json').read_text())
    owners = {}
    for number, row in enumerate(accepts):
        require(row['seq'] not in owners and (not number or row['seq'] > accepts[number - 1]['seq']), 'accepted owner age/identity')
        owners[row['seq']] = row
    require(events and len(events) <= len(reference['events']), 'event prefix missing/overflow')
    retired, irqs, previous_cycle, previous_seq, instret = [], [], 0, -1, 0
    for number, row in enumerate(events):
        require(row['index'] == number and row['cycle'] > previous_cycle, f'event cycle/index row{number}');previous_cycle = row['cycle']
        for field in FIELDS:
            require(row[field] == reference['events'][number][field], f'event {field} mismatch row{number}')
        if row['kind'] == 'retire':
            require(row['seq'] > previous_seq and row['seq'] in owners and all(owners[row['seq']][field] == row[field] for field in ('pc', 'instr')) and owners[row['seq']]['cycle'] < row['cycle'], f'retirement accepted owner row{number}')
            previous_seq = row['seq'];retired.append(row);instret += 1
        else:
            irqs.append(row)
        require(row['instret'] == instret, f'IRQ excluded from instret row{number}')
    require([row['cause'] for row in irqs] == [0x8000000b, 0x80000003, 0x80000007], 'three prioritized IRQs required')
    require(all(row['pc'] == fixture['div_pc'] for row in irqs), 'IRQ pre-architectural PC differs from independent DIV boundary')
    require(any(row['pc'] == fixture['terminal_pc'] for row in retired), 'terminal JAL not retired')
    require(len(wb) == len(retired), 'WB ledger not drained')
    retired_by_seq = {row['seq']: row for row in retired}
    for number, (row, old) in enumerate(zip(wb, retired)):
        require(row['index'] == number and row['cycle'] > old['cycle'], f'WB retirement order row{number}')
        for field in ('seq', 'pc', 'instr', 'rd', 'value', 'writes', 'nextpc'):
            require(row[field] == old[field], f'WB {field} mismatch row{number}')
    issues, starts, completed, drained, last_cycle = {}, {}, {}, {}, 0
    for row in mrows:
        seq = row['seq'];require(row['event'] in ('issue', 'start', 'complete', 'drain') and row['cycle'] >= last_cycle, 'M event kind/order');last_cycle = row['cycle']
        require(seq in owners and owners[seq]['pc'] == row['pc'], 'M accepted owner PC')
        ledger = {'issue': issues, 'start': starts, 'complete': completed, 'drain': drained}[row['event']]
        require(seq not in ledger, 'M repeated generation event');ledger[seq] = row
        if row['event'] == 'issue':
            require(row['value'] == 0 and owners[seq]['cycle'] < row['cycle'], 'M issue ownership/value')
        elif row['event'] == 'start':
            require(seq in issues and issues[seq]['cycle'] == row['cycle'] and row['value'] == 0, 'M start generation')
        elif row['event'] == 'complete':
            require(seq in starts and seq in retired_by_seq and starts[seq]['cycle'] < row['cycle'] < retired_by_seq[seq]['cycle'] and row['value'] == retired_by_seq[seq]['value'], 'M completion generation/result')
        else:
            require(seq in starts and seq not in retired_by_seq and row['pc'] == fixture['div_pc'] and row['value'] == 0xffffffef and starts[seq]['cycle'] < irqs[0]['cycle'] < row['cycle'], 'killed DIV drain ownership/result')
    require(len(issues) == len(starts) == 5 and len(completed) == 4 and len(drained) == 1 and set(completed) | set(drained) == set(starts), 'M live/killed generation ledgers not closed')
    require(irqs[0]['cycle'] < min(row['cycle'] for row in drained.values()), 'IRQ waited for busy DIV instead of killing it')
    requests, responses, pending, ordinal = {}, {}, None, 0
    for row in drows:
        seq = row['seq'];require(row['event'] in ('req', 'rsp') and seq in retired_by_seq, 'D retirement owner/event')
        if row['event'] == 'req':
            require(pending is None and seq not in requests and ordinal < len(reference['accesses']), 'D duplicate request/overwrite')
            gold = reference['accesses'][ordinal];ordinal += 1
            require(retired_by_seq[seq]['index'] == gold['event_index'] and row['cycle'] < retired_by_seq[seq]['cycle'], 'D event owner/order')
            pending = (seq, gold);requests[seq] = row
        else:
            require(pending and pending[0] == seq and seq not in responses, 'D response owner')
            _, gold = pending;pending = None;responses[seq] = row
            require(row['rdata'] == gold['rdata'] and requests[seq]['cycle'] <= row['cycle'] <= retired_by_seq[seq]['cycle'], 'D response word/lifetime')
        for field in ('pc', 'addr', 'wdata', 'wstrb', 'size', 'is_write'):
            require(row[field] == gold[field], f'D {field} mismatch')
    require(pending is None and set(requests) == set(responses) and ordinal == len(reference['accesses']), 'D ledgers not closed')
    require(read_hex(directory / 'actual_ram_final.hex') == reference['memory'], 'complete RAM mismatch')
    final = (directory / 'actual_gpr_final.hex').read_text(encoding='ascii').splitlines()
    require(len(final) == 32, 'complete GPR observation required')
    for register, value in enumerate(reference['gpr']):
        require(final[register].lower() == ('xxxxxxxx' if value is None else f'{value:08x}'), f'final GPR x{register} mismatch')
    pending, iq, ir, stale_errors = [], 0, 0, 0
    for row in ifrows:
        if row['event'] == 'req':
            require(not pending and row['error'] == 0, 'IF request overwrite/error');pending.append(row['addr']);iq += 1
        else:
            require(row['event'] == 'rsp' and pending and pending.pop(0) == row['addr'], 'IF response owner');ir += 1
            if row['error']:
                require(row['error'] == 1 and row['addr'] == fixture['held_if_pc'] and row['cycle'] > irqs[0]['cycle'], 'IF error not stale after IRQ');stale_errors += 1
    require(not pending and iq == ir and stale_errors == 1, 'held stale IF error/request ledgers not closed')
    cycle_audit = audit_cycles(cycles, events, mrows, fixture['div_pc'])
    counts = dict(events=len(events), retired=len(retired), wb_packets=len(wb), irqs=len(irqs), accepted=len(accepts), m_issues=len(issues), m_starts=len(starts), m_completions=len(completed), m_drains=len(drained), d_requests=len(requests), d_responses=len(responses), requests=iq, responses=ir, stale_if_errors=stale_errors)
    for field, value in counts.items():
        require(type(metrics.get(field)) is int and metrics[field] == value, f'metric {field} mismatch')
    require(metrics.get('held_if_cycles', 0) > 0 and metrics['cycles'] == len(cycles), 'held IF cycle coverage/final cycle mismatch')
    return dict(status='PASS', **counts, cycle_audit=cycle_audit, cycles=metrics['cycles'], held_if_cycles=metrics['held_if_cycles'], defined_gpr=sum(x is not None for x in reference['gpr']), unchanged_unknown_gpr=sum(x is None for x in reference['gpr']))


def analyze(directory):
    fixture = json.loads((directory / 'fixture.json').read_text())
    reference = simulate(read_hex(directory / 'program.hex'), read_hex(directory / 'ram_initial.hex'), fixture['div_pc'])
    for field in FIELDS:
        require(read_hex(directory / f'expected_{field}.hex') == [int(row[field] == 'irq') if field == 'kind' else row[field] for row in reference['events']], f'expected {field} differs from independent execution')
    paths = sorted((directory / 'cases').glob('case*'), key=lambda path: int(path.name[4:]))
    require([path.name for path in paths] == [f'case{i}' for i in range(16)], 'all sixteen IRQ program cases required')
    cases = [dict(case=i, id_mode=i % 2, predict=(i // 2) % 2, wait=(i // 4) % 2, forwarding=i // 8, **audit_case(path, reference, fixture)) for i, path in enumerate(paths)]
    return dict(status='PASS', scope='CPU5 synchronized machine IRQ real IF program', case_count=len(cases), cases=cases,
                total_retired=sum(row['retired'] for row in cases), total_wb_packets=sum(row['wb_packets'] for row in cases), total_irqs=sum(row['irqs'] for row in cases),
                total_m_issues=sum(row['m_issues'] for row in cases), total_m_drains=sum(row['m_drains'] for row in cases),
                total_d_requests=sum(row['d_requests'] for row in cases), total_d_responses=sum(row['d_responses'] for row in cases),
                total_i_requests=sum(row['requests'] for row in cases), total_i_responses=sum(row['responses'] for row in cases),
                total_stale_if_errors=sum(row['stale_if_errors'] for row in cases), decoder_selftest=decoder_selftest(),
                limitation='Raw device fixture only; no MMIO, timer device, cache/AXI/SoC, STA, board or performance claim')


def selftest_evidence(directory):
    fixture = json.loads((directory / 'fixture.json').read_text());reference = simulate(read_hex(directory / 'program.hex'), read_hex(directory / 'ram_initial.hex'), fixture['div_pc'])
    source = directory / 'cases/case0';scratch = directory.parent / (directory.name + '_negative_evidence');scratch.mkdir(parents=True, exist_ok=True)
    protected = [path for path in directory.rglob('*') if path.is_file() and path.name not in ('verification.json', 'analysis.json')]
    def hashes():
        return {path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in protected}
    before, rejected = hashes(), []
    tests = [('irq_mepc', 'events.csv', 'event pc mismatch'), ('irq_cause', 'events.csv', 'event cause mismatch'), ('irq_status', 'events.csv', 'event mstatus mismatch'),
             ('mret_pc', 'events.csv', 'event nextpc mismatch'), ('sync_pending', 'cycles.csv', 'two-flop pending mismatch'), ('arm', 'cycles.csv', 'old arm/current eligibility mismatch'),
             ('take', 'cycles.csv', 'IRQ first safe edge mismatch'), ('killed_m_result', 'm.csv', 'killed DIV drain ownership/result'),
             ('stale_if_error', 'if.csv', 'held stale IF error/request ledgers not closed'), ('final_ram', 'actual_ram_final.hex', 'complete RAM mismatch'), ('final_gpr', 'actual_gpr_final.hex', 'final GPR x7 mismatch')]
    for name, filename, reason in tests:
        target = scratch / name;shutil.copytree(source, target, dirs_exist_ok=True);changed = target / filename
        if filename.endswith('.csv'):
            with changed.open(newline='', encoding='ascii') as stream:
                reader = csv.DictReader(stream);header = reader.fieldnames;rows = list(reader)
            if name.startswith('irq_'):
                row = next(row for row in rows if row['kind'] == 'irq');field = {'irq_mepc': 'pc', 'irq_cause': 'cause', 'irq_status': 'mstatus'}[name]
            elif name == 'mret_pc':
                row = next(row for row in rows if row['instr'] == '30200073');field = 'nextpc'
            elif name in ('sync_pending', 'arm', 'take'):
                row = next(row for row in rows if row['take'] == '1');field = {'sync_pending': 'pending', 'arm': 'arm', 'take': 'take'}[name]
            elif name == 'killed_m_result':
                row = next(row for row in rows if row['event'] == 'drain');field = 'value'
            else:
                row = next(row for row in rows if row['event'] == 'rsp' and row['error'] == '1');field = 'error'
            row[field] = f'{int(row[field], 16) ^ 1:08x}' if field in HEX_FIELDS else str(int(row[field]) ^ 1)
            with changed.open('w', newline='', encoding='ascii') as stream:
                writer = csv.DictWriter(stream, fieldnames=header, lineterminator='\n');writer.writeheader();writer.writerows(rows)
        else:
            rows = changed.read_text(encoding='ascii').splitlines();index = 7 if name == 'final_gpr' else 4;rows[index] = f'{int(rows[index], 16) ^ 1:08x}';changed.write_text('\n'.join(rows) + '\n', encoding='ascii')
        try:
            audit_case(target, reference, fixture)
        except ValueError as error:
            require(reason in str(error), f'negative {name} unintended rejection: {error}');message = str(error)
        else:
            raise ValueError(f'negative {name} falsely accepted')
        require(changed.read_bytes() != (source / filename).read_bytes(), f'negative {name} unchanged')
        rejected.append(dict(name=name, status='REJECTED', reason=message, good_sha256=hashlib.sha256((source / filename).read_bytes()).hexdigest(), bad_sha256=hashlib.sha256(changed.read_bytes()).hexdigest()))
    require(before == hashes(), 'negative copies changed original good evidence')
    result = dict(status='PASS', rejected_count=len(rejected), rejected=rejected, good_inputs_unchanged=True)
    (scratch / 'summary.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__);parser.add_argument('--directory', type=Path, default=ROOT / 'build/cpu5_s9_irq_program')
    parser.add_argument('--decoder-only', action='store_true');parser.add_argument('--selftest', action='store_true');args = parser.parse_args()
    if args.decoder_only:
        print(json.dumps(decoder_selftest()));return
    result = analyze(args.directory)
    if args.selftest:
        result['negative_evidence_tests'] = selftest_evidence(args.directory)
    (args.directory / 'analysis.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(status='PASS', cases=result['case_count'], retired=result['total_retired'], irqs=result['total_irqs'], bad_evidence_rejected=result.get('negative_evidence_tests', {}).get('rejected_count', 0))))


if __name__ == '__main__':
    main()
