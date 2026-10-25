"""Schema4/profile2 CPU5 snapshot reader. Independent of the legacy six-field reader."""
from __future__ import annotations
import argparse
import json
from pathlib import Path

MASK=(1<<64)-1
NAMES=('work_other','ifetch_wait','data_read_wait','data_write_wait','local_mmio_wait',
       'redirect_wait','mul_wait','div_wait','load_use_wait','id_hazard_wait')


def require(ok,message):
    if not ok:raise ValueError(message)


def profile_offsets(index):
    require(type(index) is int and 0<=index<10,'profile index')
    start=(0x100+8*index) if index<6 else (0x180+8*(index-6))
    stop=(0x140+8*index) if index<6 else (0x1c0+8*(index-6))
    return start,start+4,stop,stop+4


def uint64(value,label):
    require(type(value) is int and 0<=value<=MASK,label+' unsigned 64-bit integer')
    return value


def analyze_snapshot(record):
    require(isinstance(record,dict),'snapshot object')
    for key,value in (('hardware_schema',4),('cycle_profile_schema',2),('event_width',10),('counter_bits',64),('window_bytes',0x200)):
        require(type(record.get(key)) is int and record[key]==value,'CPU5 '+key+' mismatch')
    require(type(record.get('raw_start')) is int and record['raw_start']>=1,'START lifecycle')
    require(record.get('selected_start')==1 and type(record['selected_start']) is int,'selected START lifecycle')
    require(record.get('selected_epoch')==record['raw_start'] and type(record['selected_epoch']) is int,'latest START epoch')
    require(record.get('stop')==1 and type(record['stop']) is int,'STOP lifecycle')
    spans={}
    for key in ('cycles','instret'):
        pair=record.get(key)
        require(isinstance(pair,dict) and set(pair)=={'start','stop'},key+' snapshot pair')
        spans[key]=(uint64(pair['stop'],key+' stop')-uint64(pair['start'],key+' start'))&MASK
    require(spans['cycles']>0,'nonempty cycle window')
    require(spans['instret']<=spans['cycles'],'retirement window exceeds cycles')
    profile=record.get('profile')
    require(isinstance(profile,dict) and set(profile)=={'start','stop'},'profile snapshot pair')
    for key in ('start','stop'):
        require(isinstance(profile[key],list) and len(profile[key])==10,'ten profile counters')
        for i,value in enumerate(profile[key]):uint64(value,f'profile {key} {i}')
    delta=[(b-a)&MASK for a,b in zip(profile['start'],profile['stop'])]
    require(sum(delta)==spans['cycles'],'ten-class sum differs from counted cycle window')
    return dict(status='PASS',hardware_schema=4,cycle_profile_schema=2,fields=10,
                raw_start=record['raw_start'],selected_epoch=record['selected_epoch'],
                window_cycles=spans['cycles'],window_instret=spans['instret'],
                cycle_classes=dict(zip(NAMES,delta)),offset_words=[list(profile_offsets(i)) for i in range(10)])


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('snapshot',type=Path);a=ap.parse_args()
    result=analyze_snapshot(json.loads(a.snapshot.read_text(encoding='utf-8')))
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
