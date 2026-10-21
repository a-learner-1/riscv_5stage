#!/usr/bin/env python3
"""Audit passive three-stage RV32IM owner/event traces, not CPU5 counters.

Pre-edge CPU events and post-NBA unit done carry the edge that produced them.
The statistics window is [last START edge, STOP edge); event counts remain
separate from the six mutually exclusive cycle totals.
"""
import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path

OPS = ('MUL', 'MULH', 'MULHSU', 'MULHU', 'DIV', 'DIVU', 'REM', 'REMU')
FIELDS = {'start':'start_edge', 'unit_done':'unit_done_edge',
          'cpu_complete':'cpu_complete_edge', 'retire':'retire_edge'}
HEX = {'pc', 'lhs', 'rhs', 'result'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signed(x):
    return x - (1 << 32) if x & (1 << 31) else x


def oracle(op, a, b):
    """ISA result using mathematical integers; no DUT division recurrence."""
    if op == 0:
        value = a * b
    elif op == 1:
        value = (signed(a) * signed(b)) >> 32
    elif op == 2:
        value = (signed(a) * b) >> 32
    elif op == 3:
        value = (a * b) >> 32
    else:
        x, y = (signed(a), signed(b)) if op in (4, 6) else (a, b)
        q = -1 if y == 0 else (abs(x) // abs(y)) * (-1 if (x < 0) != (y < 0) else 1)
        value = (x if y == 0 else x - q * y) if op >= 6 else q
    return value & 0xffffffff


def validate_owner(row):
    op, a, b = row['op'], row['lhs'], row['rhs']
    require(0 <= op < 8, 'unknown M operation')
    require(row['result'] == oracle(op, a, b), f"arithmetic owner={row['owner']}")
    expected = 2 if op < 4 else (0 if b == 0 or (op in (4,6) and a == 0x80000000 and b == 0xffffffff) else 32)
    require(row['unit_done_edge'] - row['start_edge'] == expected, 'unit latency')
    require(row['cpu_complete_edge'] == row['unit_done_edge'] + 1, 'CPU completion edge')
    require(row['retire_edge'] == row['cpu_complete_edge'] + 1, 'retirement edge')
    require(row['wait_cycles'] == row['cpu_complete_edge'] - row['start_edge'], 'actual CPU waits')
    return expected


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def analyze(directory, root):
    with (directory/'observer_metadata.csv').open(newline='') as f:
        meta = dict(csv.reader(f)); meta.pop('key')
    ints = {k:int(v) for k,v in meta.items() if k != 'profile'}
    S,T = ints['start_edge'], ints['stop_edge']
    require(ints['raw_starts'] >= 1 and ints['selected_epoch'] == ints['raw_starts'] and
            ints['stop_triggers'] == 1 and ints['original_workload_pass'] == 1, 'window gate')
    require(T-S == ints['frozen_cycles'], 'counter/window delta')
    with (directory/'window_endpoints.csv').open(newline='') as f:
        endpoints=list(csv.DictReader(f))
    starts=[r for r in endpoints if r['kind']=='START']
    stops=[r for r in endpoints if r['kind']=='STOP']
    require(len(starts)==ints['raw_starts'] and len(stops)==1 and endpoints[-1]==stops[0], 'raw endpoint count/order')
    require(int(starts[-1]['edge'])==S and int(stops[0]['edge'])==T and
            int(starts[-1]['epoch'])==ints['selected_epoch'], 'selected endpoint')
    require(int(stops[0]['cycle_pre'])-int(starts[-1]['cycle_pre'])==ints['frozen_cycles'] and
            int(stops[0]['instret_pre'])-int(starts[-1]['instret_pre'])==ints['frozen_retired'], 'endpoint/frozen counter deltas')
    classes = [ints[f'cycle_class_{i}'] for i in range(6)]
    require(sum(classes) == ints['frozen_cycles'], 'six-class sum')
    with (directory/'m_owners.csv').open(newline='') as f:
        owners = [{k:int(v, 16 if k in HEX else 10) for k,v in r.items()} for r in csv.DictReader(f)]
    require(len(owners) == ints['all_owners'], 'unfinished owner')
    by_id = {}
    stats = [{k:0 for k in ('start','unit_done','cpu_complete','retire','wait')} for _ in OPS]
    latency = [collections.Counter() for _ in OPS]
    boundary = []
    previous_retire = 0
    for owner in owners:
        oid, op = owner['owner'], owner['op']
        require(oid == len(by_id)+1, 'duplicate/out-of-order owner')
        require(owner['start_edge'] >= previous_retire, 'overlapping M owners')
        previous_retire = owner['retire_edge']
        validate_owner(owner); by_id[oid] = owner
        for event,field in FIELDS.items():
            if S <= owner[field] < T:
                stats[op][event] += 1
        stats[op]['wait'] += max(0, min(T,owner['cpu_complete_edge'])-max(S,owner['start_edge']))
        if S <= owner['start_edge'] < T:
            latency[op][(owner['unit_done_edge']-owner['start_edge'],
                         owner['cpu_complete_edge']-owner['start_edge'],
                         owner['retire_edge']-owner['start_edge'],owner['wait_cycles'])] += 1
        if owner['start_edge'] < S <= owner['retire_edge'] or owner['start_edge'] < T <= owner['retire_edge']:
            boundary.append(oid)
    seen = set()
    with (directory/'m_events.csv').open(newline='') as f:
        for event in csv.DictReader(f):
            kind, oid, e = event['kind'], int(event['owner']), int(event['edge'])
            require(kind in FIELDS and oid in by_id, 'unknown event/owner')
            require((oid,kind) not in seen, 'duplicate event')
            seen.add((oid,kind))
            require(by_id[oid][FIELDS[kind]] == e and by_id[oid]['op'] == int(event['op']), 'event ownership/edge')
            if S <= e < T:
                require(int(event['epoch']) == ints['selected_epoch'] and int(event['live']) == 1, 'event wrong epoch')
    require(len(seen) == 4*len(owners), 'missing event')
    for op in range(8):
        for event,key in [('start','start'),('unit_done','done'),('cpu_complete','complete'),('retire','retire'),('wait','wait')]:
            require(stats[op][event] == ints[f'op_{op}_{key}'], f'op{op} {event} count')
    contingency = [ints[f'contingency_{i}'] for i in range(24)]
    require(sum(contingency) == T-S, 'contingency cycle sum')
    require(sum(contingency[i] for i in range(24) if i%4 >= 2) == ints['frozen_retired'], 'contingency retired')
    require(sum(contingency[i] for i in range(24) if i%2) == sum(s['wait'] for s in stats), 'contingency M wait')
    for i in range(6):
        require(sum(contingency[i*4:i*4+4]) == classes[i], 'contingency class sum')
    report_path = root/'build/coremark'/f'd0_m_cache_on_btb_{directory.name}'/'build_report.json'
    build = json.loads(report_path.read_text())
    sources = {str(p.relative_to(root)).replace('\\','/'):sha(p) for p in sorted((root/'rtl').glob('*.v'))}
    for rel in ('tb/coremark_d0_workload_tb.v','tb/cpu5_m_breakdown_tb.v','run_cpu5_m_breakdown.do','tools/analyze_cpu5_m_breakdown.py',
                'tb/cpu5_m_unit_timing_tb.v','run_cpu5_m_unit_timing.do',
                'tb/cpu5_m_cpu_timing_tb.v','run_cpu5_m_cpu_timing.do',
                'tb/rv32m_cpu_tb.v','tools/generate_rv32m_vectors.py'):
        sources[rel] = sha(root/rel)
    require(isinstance(build.get('sources_sha256'),dict) and len(build['sources_sha256']) > 30, 'build source manifest missing')
    for rel,digest in build['sources_sha256'].items():
        require(sha(root/rel) == digest, f'firmware build source changed: {rel}')
    output = {
        'status':'PASS', 'scope':'passive existing three-stage RV32IM, one-iteration smoke; not CPU5 implementation or formal board score',
        'profile':meta['profile'], 'window':{'start':S,'stop':T,'raw_starts':ints['raw_starts'],
            'selected_start':1,'selected_epoch':ints['selected_epoch'],'stop_triggers':ints['stop_triggers'],
            'endpoint_rows':ints['raw_starts']+ints['stop_triggers'],'interval':'[S,T)','crossing_owners':boundary},
        'cycles':T-S,'retired':ints['frozen_retired'], 'six_classes':dict(zip(('work_other','ifetch_wait','data_read_wait','data_write_wait','local_mmio_wait','redirect_wait'),classes)),
        'ops':{name:dict(stats[op],latency_histogram=[{'unit_done':l[0],'cpu_complete':l[1],'retire':l[2],'wait':l[3],'count':n} for l,n in sorted(latency[op].items())]) for op,name in enumerate(OPS)},
        'families':{name:{k:sum(stats[op][k] for op in indices) for k in stats[0]} for name,indices in [('mul',range(4)),('div_quotient',range(4,6)),('rem',range(6,8)),('div_including_rem',range(4,8))]},
        'work_minus_retired':classes[0]-ints['frozen_retired'],
        'work_minus_retired_minus_m_wait':classes[0]-ints['frozen_retired']-sum(s['wait'] for s in stats),
        'contingency_class_retire_mwait':{f'class_{i//4}_retire_{(i%4)//2}_mwait_{i%2}':v for i,v in enumerate(contingency)},
        'owner_rows_total':len(owners), 'validated_event_rows_total':len(seen),
        'sampling':{'start':'pre-edge accepted command; unit state IDLE asserted', 'unit_done':'first post-NBA done for new owner, even if old sticky done was high before start', 'cpu_complete':'pre-edge m_complete_x', 'retire':'following pre-edge retire_valid/wb_pc feeding instret_count', 'wait':'pre-edge m_wait_x; includes launch, excludes CPU completion edge'},
        'build_report_sha256':sha(report_path), 'build_sources_sha256':build['sources_sha256'],
        'source_sha256':sources,
        'raw_sha256':{p.name:sha(p) for p in sorted(directory.glob('*.csv'))},
    }
    (directory/'summary.json').write_text(json.dumps(output,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    return output


def analyze_directed(directory):
    with (directory/'unit_directed/unit_directed.csv').open(newline='') as f:
        unit=[{k:int(v,16 if k in HEX else 10) for k,v in r.items()} for r in csv.DictReader(f)]
    require(len(unit)==14,'unit directed case coverage')
    for row in unit:
        require(row['result']==oracle(row['op'],row['lhs'],row['rhs']),'unit directed oracle')
        op,a,b=row['op'],row['lhs'],row['rhs']
        expected=2 if op<4 else (0 if b==0 or (op in (4,6) and a==0x80000000 and b==0xffffffff) else 32)
        require(row['start_to_unit_done_edges']==expected,'directed unit timing')
    with (directory/'cpu_directed/m_owners.csv').open(newline='') as f:
        cpu=[{k:int(v,16 if k in HEX else 10) for k,v in r.items()} for r in csv.DictReader(f)]
    counts=collections.Counter()
    for row in cpu:
        validate_owner(row)
        counts[(OPS[row['op']],row['unit_done_edge']-row['start_edge'],row['cpu_complete_edge']-row['start_edge'],row['retire_edge']-row['start_edge'],row['wait_cycles'])]+=1
    require({row['op'] for row in cpu}==set(range(8)),'CPU directed op coverage')
    for op in range(4,8):
        require(any(r['op']==op and r['rhs']==0 and r['unit_done_edge']==r['start_edge'] for r in cpu),'CPU DIV0 coverage')
        require(any(r['op']==op and r['unit_done_edge']-r['start_edge']==32 for r in cpu),'CPU normal divide/rem coverage')
    for op in (4,6):
        require(any(r['op']==op and r['lhs']==0x80000000 and r['rhs']==0xffffffff and r['unit_done_edge']==r['start_edge'] for r in cpu),'CPU signed overflow coverage')
    for dirname in ('unit_directed','cpu_directed'):
        require(json.loads((directory/dirname/'process_result.json').read_text())['exit_code']==0,'directed process exit')
    result={'status':'PASS','unit_cases':len(unit),'cpu_owners':len(cpu),
            'latency_histogram':[dict(op=k[0],unit_done=k[1],cpu_complete=k[2],retire=k[3],wait=k[4],count=v) for k,v in sorted(counts.items())],
            'scope':'existing three-stage CPU and rv32m_unit only; CPU5 killed/drain owner is not implemented or tested',
            'raw_sha256':{str(p.relative_to(directory)).replace('\\','/'):sha(p) for p in sorted(directory.rglob('*.csv')) if p.parent.name in ('unit_directed','cpu_directed')}}
    (directory/'directed_summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result


def selftest():
    # Independently specified ISA examples, including signed truncation/overflow.
    examples=[(0,0xffffffff,3,0xfffffffd),(1,0xffffffff,3,0xffffffff),
              (2,0xffffffff,0xffffffff,0xffffffff),(3,0xffffffff,0xffffffff,0xfffffffe),
              (4,0xfffffff9,3,0xfffffffe),(5,0xfffffff9,3,1431655763),
              (6,0xfffffff9,3,0xffffffff),(7,0xfffffff9,3,0),
              (4,123,0,0xffffffff),(5,123,0,0xffffffff),(6,123,0,123),(7,123,0,123),
              (4,0x80000000,0xffffffff,0x80000000),(6,0x80000000,0xffffffff,0)]
    tested=0
    for op,a,b,expected in examples:
        require(oracle(op,a,b)==expected,'hand-computed arithmetic self-test')
        latency=2 if op<4 else (0 if b==0 or (op in (4,6) and a==0x80000000 and b==0xffffffff) else 32)
        row=dict(owner=1,op=op,lhs=a,rhs=b,result=expected,start_edge=10,unit_done_edge=10+latency,cpu_complete_edge=11+latency,retire_edge=12+latency,wait_cycles=latency+1)
        validate_owner(row);tested+=1
        for field in ('result','unit_done_edge','cpu_complete_edge','retire_edge','wait_cycles'):
            bad=dict(row);bad[field]+=1
            try:validate_owner(bad)
            except ValueError:tested+=1
            else:raise ValueError(f'negative selftest did not reject {field}')
    print(f'M BREAKDOWN ANALYZER SELFTEST PASS checks={tested}')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--directory',type=Path)
    parser.add_argument('--directed-root',type=Path)
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    if args.self_test:selftest()
    if args.directed_root:
        result=analyze_directed(args.directed_root)
        print(json.dumps(result))
    if args.directory:
        summary=analyze(args.directory,args.root)
        print(json.dumps({k:summary[k] for k in ('status','profile','cycles','retired','families','work_minus_retired','work_minus_retired_minus_m_wait')},ensure_ascii=False))
