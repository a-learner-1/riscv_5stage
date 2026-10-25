"""Test the new ten-field host reader and independently compile new/legacy C ABI guards."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
from cpu5_stats_abi import MASK,NAMES,profile_offsets,analyze_snapshot
from build_coremark_images import prefix

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_stats_abi'
SOURCES=['tools/cpu5_stats_abi.py','tools/check_cpu5_stats_abi.py','tools/build_coremark_images.py',
         'software/cpu5_stats/cpu5_stats.h','software/coremark_port/coremark_axi_stats.h',
         'docs/cpu5_cycle_profile_contract.json']


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def reader_tests():
    starts=[MASK-i for i in range(10)]
    good=dict(hardware_schema=4,cycle_profile_schema=2,event_width=10,counter_bits=64,window_bytes=512,
              raw_start=2,selected_start=1,selected_epoch=2,stop=1,cycles=dict(start=MASK-10,stop=44),
              instret=dict(start=MASK-3,stop=7),profile=dict(start=starts,stop=[(a+i+1)&MASK for i,a in enumerate(starts)]))
    result=analyze_snapshot(good);assert result['window_cycles']==55 and result['window_instret']==11
    assert list(result['cycle_classes'])==list(NAMES) and list(result['cycle_classes'].values())==list(range(1,11))
    mutations=[
        ('hardware_schema',lambda r:r.update(hardware_schema=3),'hardware_schema mismatch'),
        ('profile_schema',lambda r:r.update(cycle_profile_schema=1),'cycle_profile_schema mismatch'),
        ('six_fields',lambda r:r.update(event_width=6),'event_width mismatch'),
        ('counter_width',lambda r:r.update(counter_bits=32),'counter_bits mismatch'),
        ('small_window',lambda r:r.update(window_bytes=256),'window_bytes mismatch'),
        ('no_start',lambda r:r.update(raw_start=0),'START lifecycle'),
        ('two_selected_starts',lambda r:r.update(selected_start=2),'selected START lifecycle'),
        ('superseded_epoch',lambda r:r.update(selected_epoch=1),'latest START epoch'),
        ('two_stops',lambda r:r.update(stop=2),'STOP lifecycle'),
        ('sum_mismatch',lambda r:r['profile']['stop'].__setitem__(0,r['profile']['stop'][0]^1),'ten-class sum'),
        ('empty_window',lambda r:r['cycles'].update(stop=r['cycles']['start']),'nonempty cycle window'),
        ('too_many_retirements',lambda r:r['instret'].update(start=0,stop=56),'retirement window'),
        ('missing_tenth_field',lambda r:r['profile']['stop'].pop(),'ten profile counters'),
        ('negative_counter',lambda r:r['profile']['start'].__setitem__(0,-1),'unsigned 64-bit'),
        ('overflow_counter',lambda r:r['profile']['stop'].__setitem__(9,1<<64),'unsigned 64-bit'),
        ('boolean_counter',lambda r:r['profile']['stop'].__setitem__(9,True),'unsigned 64-bit'),
        ('string_counter',lambda r:r['cycles'].update(start='42'),'unsigned 64-bit'),
    ]
    rejected=[]
    for name,change,reason in mutations:
        bad=copy.deepcopy(good);change(bad)
        try:analyze_snapshot(bad)
        except ValueError as e:
            assert reason in str(e),(name,str(e));rejected.append(dict(name=name,status='REJECTED',reason=str(e)))
        else:raise AssertionError('bad snapshot accepted: '+name)
        (OUT/(name+'.json')).write_text(json.dumps(bad,indent=2)+'\n',encoding='utf-8')
    contract=json.loads((ROOT/'docs/cpu5_cycle_profile_contract.json').read_text())
    expected=[tuple(int(c[k],0) for k in ('start_low','start_high','stop_low','stop_high')) for c in contract['classes']]
    actual=[profile_offsets(i) for i in range(10)]
    assert actual==expected and len({v for row in actual for v in row})==40
    (OUT/'good_snapshot.json').write_text(json.dumps(good,indent=2)+'\n',encoding='utf-8')
    (OUT/'good_analysis.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return dict(status='PASS',positive_wrap_window=result,rejected=rejected,rejected_count=len(rejected),offset_words=40)


def c_guards(cc):
    new_config=dict(CPU5_STATS_HW_SCHEMA=4,CPU5_STATS_PROFILE_SCHEMA=2,CPU5_STATS_FIELDS=10,
                    CPU5_STATS_COUNTER_BITS=64,CPU5_STATS_WINDOW_BYTES=0x200)
    old_config=dict(COREMARK_PLATFORM_NAME='"legacy"',COREMARK_ENABLE_ICACHE=0,COREMARK_ENABLE_DCACHE=0,
        COREMARK_ENABLE_D0_BRAM=0,COREMARK_DATA_BACKEND_ID=0,COREMARK_AXI_STATS_BASE=0x30000000,COREMARK_AXI_STATS_ID=0x434d4158,
        COREMARK_AXI_CACHE_GEOMETRY=0,COREMARK_ENABLE_BRANCH_PRED=0,COREMARK_BTB_ENTRIES=64,COREMARK_AXI_BP_CONFIG=64<<16,
        COREMARK_AXI_STATS_SCHEMA=3,COREMARK_AXI_CYCLE_PROFILE_SCHEMA=1,COREMARK_AXI_CYCLE_PROFILE_FIELDS=6,
        COREMARK_AXI_CYCLE_PROFILE_BITS=64,COREMARK_AXI_CYCLE_PROFILE_START_BANK=0x100,COREMARK_AXI_CYCLE_PROFILE_STOP_BANK=0x140,
        COREMARK_AXI_STATS_WINDOW_BYTES=0x200)
    cases=[('new_good','new',{},0),('new_reject_hw3','new',dict(CPU5_STATS_HW_SCHEMA=3),1),
           ('new_reject_profile1','new',dict(CPU5_STATS_PROFILE_SCHEMA=1),1),('new_reject_six','new',dict(CPU5_STATS_FIELDS=6),1),
           ('new_reject_32bit','new',dict(CPU5_STATS_COUNTER_BITS=32),1),('new_reject_smallwindow','new',dict(CPU5_STATS_WINDOW_BYTES=256),1),
           ('old_good','old',{},0),('old_reject_hw4','old',dict(COREMARK_AXI_STATS_SCHEMA=4),1),
           ('old_reject_profile2','old',dict(COREMARK_AXI_CYCLE_PROFILE_SCHEMA=2),1),
           ('old_reject_ten','old',dict(COREMARK_AXI_CYCLE_PROFILE_FIELDS=10),1),
           ('old_reject_cpu5','old',dict(COREMARK_AXI_STATS_SCHEMA=4,COREMARK_AXI_CYCLE_PROFILE_SCHEMA=2,COREMARK_AXI_CYCLE_PROFILE_FIELDS=10),1)]
    records=[]
    for name,kind,overrides,wanted in cases:
        macros=(new_config if kind=='new' else old_config)|overrides
        header='software/cpu5_stats/cpu5_stats.h' if kind=='new' else 'software/coremark_port/coremark_axi_stats.h'
        text='\n'.join(f'#define {k} {v}' for k,v in macros.items())+'\n'
        text+='typedef unsigned int ee_u32; typedef unsigned long long ee_u64; typedef unsigned int ee_ptr_int;\n'
        text+=f'#include "{(ROOT/header).as_posix()}"\n'
        source=OUT/(name+'.c');source.write_text(text,encoding='utf-8',newline='\n')
        command=[str(cc),'-E','-x','c',str(source)]
        p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace')
        log=OUT/(name+'_stderr.log');log.write_text(p.stderr,encoding='utf-8',newline='')
        assert (p.returncode==0)==(wanted==0),(name,p.returncode,p.stderr)
        if wanted:assert '#error' in p.stderr,(name,'not a designated C guard rejection')
        records.append(dict(name=name,status='PASS' if not wanted else 'REJECTED',exit_code=p.returncode,expected_exit_code=wanted,
                            command=command,source_sha256=sha(source),stderr_sha256=sha(log)))
    return records


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--cc',type=Path);a=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True);before={p:sha(ROOT/p) for p in SOURCES}
    reader=reader_tests();cc=a.cc or Path(prefix()+'gcc.exe')
    guards=c_guards(cc)
    assert before=={p:sha(ROOT/p) for p in SOURCES}
    result=dict(status='PASS',reader=reader,c_guards=guards,source_sha256=before,sources_unchanged=True,
                retained_artifact_sha256={p.relative_to(ROOT).as_posix():sha(p) for p in OUT.iterdir() if p.is_file() and p.name!='verification.json'})
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps(dict(status='PASS',reader_negative_rejected=len(reader['rejected']),c_guard_cases=len(guards))))


if __name__=='__main__':main()
