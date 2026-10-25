"""Real MUL/DIV/fast/killed owners cross independently golded Stats windows."""
import argparse,csv,hashlib,json,re,subprocess,uuid
from datetime import datetime,timezone
from pathlib import Path
from run_cpu5_cycle_profile import RTL as CORE_RTL

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_m_stats_window'
RTL=CORE_RTL+['rtl/axi_lite_cpu5_stats.v']
TB='tb/cpu5_m_stats_window_tb.v'
SOURCES=RTL+['rtl/cpu5_pipeline_types.vh',TB,'tools/run_cpu5_m_stats_window.py','tools/run_cpu5_cycle_profile.py']
BAD=re.compile(r'\*\*\s+(?:Warning|Error)\b|^Traceback \(',re.M)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))

def analyze(folder):
    cases=[]
    for number in range(4):
        c=read(folder/f'case{number}_summary.json');rows=list(csv.DictReader((folder/f'case{number}.csv').open(newline='',encoding='ascii')))
        assert c['status']=='PASS' and c['case']==number and c['fast']==(number==2) and c['killed']==(number==3)
        assert len(rows)==c['cycles'] and c['retired']==c['wb']==3 and c['reads']==98 and c['owner_starts']==c['owner_completions']==1
        starts=[];stops=[];delta=[0]*10;window=c['window'];all_counts=[0]*10
        for index,row in enumerate(rows):
            assert int(row['edge_id'])==index and int(row['cycle_count'])==index+1
            gold=int(row['gold_event'],16);actual=int(row['actual_event'],16)
            assert gold==actual and gold and gold&(gold-1)==0
            category=gold.bit_length()-1;all_counts[category]+=1
            if window['start']<=index<window['stop']:delta[category]+=1
            if row['start']=='1':starts.append(row);assert index==window['start']
            if row['stop']=='1':stops.append(row);assert index==window['stop']
        assert len(starts)==len(stops)==1 and sum(all_counts)==c['cycles']
        assert delta==window['profile_delta'] and sum(delta)==window['cycles']==window['stop']-window['start']
        a,b=starts[0],stops[0];assert b['owner_valid']=='1' and int(b['owner_seq'],16)==int(window['owner_seq'],16) and int(b['owner_generation'],16)==window['owner_generation']==0
        if number==2:
            assert a['owner_valid']=='0' and a['unit_start']=='1' and int(a['ex_seq'],16)==int(window['owner_seq'],16) and delta[7]==1
        else:assert a['owner_valid']=='1' and int(a['owner_seq'],16)==int(window['owner_seq'],16)
        assert int(a['owner_killed'])==int(b['owner_killed'])==int(number==3)
        if number==3:assert delta[6]==delta[7]==0
        else:assert delta[6 if number==0 else 7]>0
        cases.append(c)
    return dict(status='PASS',configurations=4,cases=cases,total_cycles=sum(c['cycles'] for c in cases),total_window_cycles=sum(c['window']['cycles'] for c in cases),
        total_reads=sum(c['reads'] for c in cases),total_retired=sum(c['retired'] for c in cases),
        total_owner_crossings=4,fast_allocation_boundary=1,normal_live_crossings=2,killed_background_crossings=1,
        scope='Real core and schema4 Stats. MUL and normal DIV START/STOP while owner exists; fast DIV START exactly at owner allocation and STOP while result owner exists; killed DIV window has no new M and must contain no M-wait classes. Independent latency/ISA/owner/event model and half-open edge ledger; 98 actual Stats reads per case, banks reread unchanged.')

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'));a=ap.parse_args()
    before={p:sha(ROOT/p) for p in SOURCES};rid=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8]
    folder=OUT/'runs'/rid/'good_reference';folder.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=rid),indent=2)+'\n')
    for name in SOURCES:
        p=folder/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/name).read_bytes())
    raw=folder/'build/cpu5_s16_m_stats_window';raw.mkdir(parents=True)
    scripts=dict(compile=['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap m_window_work work',
        'vlog -sv +incdir+. -work m_window_work '+' '.join(RTL+[TB]),'echo "M STATS WINDOW CLEAN COMPILE PASS"','quit -code 0 -f'],
        simulation=['onerror {quit -code 1 -f}','transcript file simulation_transcript.log','vmap m_window_work work',
        'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf m_window_work.cpu5_m_stats_window_tb','log -r sim:/*','run -all',
        'if {[examine -radix unsigned sim:/cpu5_m_stats_window_tb/test_pass] != 1} {quit -code 1 -f}','echo "M STATS WINDOW REFERENCE PASS"','quit -code 0 -f'])
    for name,lines in scripts.items():
        script=folder/(name+'.do');script.write_text('\n'.join(lines)+'\n',encoding='utf-8')
        p=subprocess.run([str(a.vsim),'-c','-do',script.name],cwd=folder,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
        output=p.stdout+p.stderr;(folder/(name+'_console.log')).write_text(output,encoding='utf-8',newline='')
        assert p.returncode==0 and not BAD.search(output) and '** Fatal:' not in output,(name,p.returncode,output[-12000:])
        assert ('M STATS WINDOW CLEAN COMPILE PASS' if name=='compile' else 'M STATS WINDOW REFERENCE PASS') in output
    result=analyze(raw)
    assert before=={p:sha(ROOT/p) for p in SOURCES},'M window sources changed'
    retained={p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file() and 'work' not in p.relative_to(folder).parts and p.suffix in ('.do','.log','.csv','.json','.wlf','.ini')}
    positive=dict(name='good_reference',kind='good_reference',status='PASS',directory=folder.relative_to(ROOT).as_posix(),
        compile=dict(status='PASS',exit_code=0,warnings=0,errors=0,console_sha256=sha(folder/'compile_console.log')),
        simulation_exit_code=0,simulation_console_sha256=sha(folder/'simulation_console.log'),source_sha256=before,retained_artifact_sha256=retained)
    result.update(run_id=rid,source_sha256=before,sources_unchanged=True,compile_zero_warning_error=True,positive=positive)
    text=json.dumps(result,indent=2)+'\n';(folder.parent/'verification.json').write_text(text,encoding='utf-8');(OUT/'verification.json').write_text(text,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','configurations','total_cycles','total_window_cycles','total_reads','total_retired','total_owner_crossings')}))

if __name__=='__main__':main()
