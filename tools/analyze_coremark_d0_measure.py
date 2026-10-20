"""Independently audit native D0 STORE timestamps and the final START epoch."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

def require(condition,message):
    if not condition: raise ValueError(message)

def read_csv(path,columns):
    with path.open(encoding='utf-8-sig',newline='') as stream:
        reader=csv.DictReader(stream)
        require(reader.fieldnames is not None and len(reader.fieldnames)==len(set(reader.fieldnames)) and set(reader.fieldnames)==set(columns),'unexpected CSV header: '+path.name)
        rows=list(reader)
    require(all(None not in row and None not in row.values() for row in rows),'malformed CSV row')
    return rows

def analyze(directory,profile):
    paths=[directory/f'coremark_d0_{profile}_{name}.csv' for name in ('transactions','window')]
    tx=read_csv(paths[0],('profile','transaction','epoch','in_window','pc','addr','wdata','wstrb','size','hit','launch','cpu_accept','backend_accept','commit','cpu_response','retire','effects','data_write_wait','total_cycles'))
    window_rows=read_csv(paths[1],('key','value'))
    w={r['key']:r['value'] for r in window_rows}
    require(len(w)==len(window_rows) and w['profile']==profile,'mixed or duplicated window keys')
    n={k:int(v) for k,v in w.items() if k!='profile'}
    require(all(v>=0 for v in n.values()),'negative window counters')
    require(n['start_triggers']>=1 and n['selected_start_triggers']==1 and n['epoch']==n['start_triggers'] and n['stop_triggers']==1,'latest-START lifecycle invalid')
    require(n['boundary_crossings']==n['errors']==n['canceled']==0,'nonzero boundary/error/cancel ledger')
    require(n['stop_edge']-n['start_edge']==n['stop_counter']-n['start_counter']==n['window_cycles']>0,'cycle edge/counter mismatch')
    require(0<n['window_instret']<=n['window_cycles'],'retirement window invalid')
    require(sum(n[f'cycle_class_{i}'] for i in range(6))==n['window_cycles'],'six classes do not partition window')
    require(tx and [int(r['transaction']) for r in tx]==list(range(1,len(tx)+1)),'transaction IDs missing or repeated')
    selected=[];prior=-1;unknown=0;latencies=[]
    for row in tx:
        require(row['profile']==profile and row['in_window'] in ('0','1') and row['hit'] in ('0','1'),'invalid transaction profile/flags')
        numbers={k:int(row[k]) for k in ('epoch','size','launch','cpu_accept','backend_accept','commit','cpu_response','retire','effects','data_write_wait','total_cycles')}
        require(all(v>=0 for v in numbers.values()),'missing/negative native timestamp')
        require(0<=numbers['epoch']<=n['epoch'],'invalid transaction epoch')
        require(prior<=numbers['launch']<=numbers['cpu_accept']<=numbers['backend_accept']==numbers['commit']<numbers['cpu_response']==numbers['retire'],'native transaction ordering or owner mismatch')
        prior=numbers['retire']
        require(numbers['retire']-numbers['launch']==numbers['total_cycles']==numbers['data_write_wait']==2 and numbers['effects']==1,'D0 STORE timing/write-effect mismatch')
        require(re.fullmatch('[0-9a-fA-FxXzZ]{8}',row['wdata']) is not None,'invalid four-state STORE payload')
        addr=int(row['addr'],16);pc=int(row['pc'],16);strb=int(row['wstrb'],16);size=numbers['size']
        require(0x10000<=addr<0x14000 and 0<=pc<32768 and pc%4==0 and size in (0,1,2),'STORE address/PC/size out of bounds')
        require((size==0 or addr%(1<<size)==0) and strb==((1<<(1<<size))-1)<<(addr%4),'STORE lane mask/alignment invalid')
        inside=row['in_window']=='1' and numbers['epoch']==n['epoch']
        require(inside==(n['start_edge']<=numbers['launch']<n['stop_edge']),'selected window membership mismatch')
        require(not(numbers['launch']<n['start_edge']<=numbers['retire'] or numbers['launch']<n['stop_edge']<=numbers['retire']),'transaction crosses frozen boundary')
        if numbers['epoch']<n['epoch']: require(numbers['retire']<n['start_edge'],'superseded epoch leaked')
        if inside:selected.append(row);latencies.append(numbers['total_cycles']);unknown+=int(any(c in row['wdata'].lower() for c in 'xz'))
    require(len(tx)==n['stores_total']==n['effects_total'],'lifetime stores/physical writes mismatch')
    require(len(selected)==n['stores_window']==n['effects_window']>0,'window store/effect mismatch')
    waits=sum(int(r['data_write_wait']) for r in selected)
    require(waits==n['measured_data_write_wait']==n['frozen_data_write_wait']==n['cycle_class_3'],'frozen write-wait closure failed')
    require(n['dcache_access']==n['dcache_hit']+n['dcache_miss']+n['dcache_write']+n['dcache_bypass'],'D-cache partition does not close')
    require(n['dcache_hit']>0 and n['dcache_miss']>0 and n['dcache_refill_words']>0 and n['dcache_write']==len(selected) and n['dcache_errors']==0,'D0 bypassed/disabled D-cache or reported errors')
    return {'profile':profile,'verification':'PASS','window_cycles':n['window_cycles'],'window_instret':n['window_instret'],
        'stores_window':len(selected),'data_write_wait':waits,'store_latency':{'minimum':min(latencies),'maximum':max(latencies),'mean':sum(latencies)/len(latencies)},
        'unknown_data_stores_window':unknown,'start_triggers':n['start_triggers'],'selected_epoch':n['epoch'],
        'dcache':{k.removeprefix('dcache_'):v for k,v in n.items() if k.startswith('dcache_')},
        'csv_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--directory',type=Path,default=Path('build/verification'));p.add_argument('--output',type=Path)
    args=p.parse_args()
    result={'schema_version':1,'verification':'PASS','profiles':[analyze(args.directory,name) for name in ('smoke','smoke-validation')]}
    if args.output:args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('COREMARK D0 CSV VERIFY PASS');print(json.dumps(result,indent=2))

if __name__=='__main__':main()
