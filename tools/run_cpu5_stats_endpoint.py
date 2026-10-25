"""Fresh CPU5 schema4/profile2 endpoint and unchanged schema3/profile1 tests."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_stats_endpoint'
RTL=['rtl/axi_lite_coremark_stats.v','rtl/axi_lite_cpu5_stats.v']
TB=['tb/axi_lite_coremark_stats_tb.v','tb/axi_lite_cpu5_stats_tb.v']
COPIES=RTL+TB
SOURCES=COPIES+['tools/run_cpu5_stats_endpoint.py','run_cpu5_stats_endpoint.do','docs/cpu5_cycle_profile_contract.json']
DIAGNOSTIC=re.compile(r'\*\*\s+(?:Warning|Error)\b|^Traceback \(',re.MULTILINE)


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def process(vsim,path,script,name):
    p=subprocess.run([str(vsim),'-c','-do',script],cwd=path,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
    output=p.stdout+p.stderr;log=path/(name+'_console.log');log.write_text(output,encoding='utf-8',newline='')
    return p.returncode,output,log


def specs():
    return [
        dict(name='schema4_replaced_by_schema3',kind='rtl_semantic',old="32'h18: s_axi_rdata <= 32'd4;",new="32'h18: s_axi_rdata <= 32'd3;",expected_assertion='CPU5 Stats cache='),
        dict(name='start_omits_registered_edge_event',kind='rtl_semantic',old='cycle_start_snapshot[index] <= profile_next[index];',new='cycle_start_snapshot[index] <= profile_count[index];',expected_assertion='CPU5 Stats cache='),
        dict(name='stop_omits_registered_edge_event',kind='rtl_semantic',old='cycle_stop_snapshot[index] <= profile_next[index];',new='cycle_stop_snapshot[index] <= profile_count[index];',expected_assertion='CPU5 Stats cache='),
        dict(name='mul_start_aliases_div_start',kind='rtl_semantic',old="32'h180: s_axi_rdata <= cycle_start_snapshot[6][31:0];",new="32'h180: s_axi_rdata <= cycle_start_snapshot[7][31:0];",expected_assertion='CPU5 Stats cache='),
        dict(name='hazard_stop_high_reads_low',kind='rtl_semantic',old="32'h1dc: s_axi_rdata <= cycle_stop_snapshot[9][63:32];",new="32'h1dc: s_axi_rdata <= cycle_stop_snapshot[9][31:0];",expected_assertion='CPU5 Stats cache='),
        dict(name='extra_hazard_events_discarded',kind='rtl_semantic',old='(perf_cycle_events[profile_index] ? 64\'d1 : 64\'d0);',new='((profile_index<8 && perf_cycle_events[profile_index]) ? 64\'d1 : 64\'d0);',expected_assertion='CPU5 Stats profile count oracle'),
        dict(name='reject_unaligned_base',kind='parameter_guard',top='cpu5_stats_base_guard_tb',expected_assertion='CPU5 statistics base must be word aligned'),
        dict(name='reject_nonboolean_cache',kind='parameter_guard',top='cpu5_stats_boolean_guard_tb',expected_assertion='CPU5 statistics Cache/predictor switches must be zero or one'),
    ]


def verify_one(vsim,path,spec,originals):
    path.mkdir(parents=True,exist_ok=False)
    for rel,data in originals.items():
        p=path/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
    (path/'build/cpu5_s16_stats_endpoint').mkdir(parents=True)
    change=None
    if spec and spec['kind']=='rtl_semantic':
        p=path/RTL[1];text=p.read_text(encoding='utf-8');assert text.count(spec['old'])==1,(spec['name'],'anchor count')
        p.write_text(text.replace(spec['old'],spec['new']),encoding='utf-8',newline='\n')
        change=dict(path=RTL[1],good_sha256=hashlib.sha256(originals[RTL[1]]).hexdigest(),bad_sha256=sha(p),old=spec['old'],new=spec['new'])
        assert change['good_sha256']!=change['bad_sha256']
    (path/'compile.do').write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap stats_endpoint_work work',
        'vlog -sv -work stats_endpoint_work '+' '.join(RTL+TB),'echo "CPU5 STATS ENDPOINT CLEAN COMPILE PASS"','quit -code 0 -f','']),encoding='utf-8')
    code,output,clog=process(vsim,path,'compile.do','compile')
    assert code==0 and 'CPU5 STATS ENDPOINT CLEAN COMPILE PASS' in output and not DIAGNOSTIC.search(output),('clean compile',path.name,output[-12000:])
    tops=[spec.get('top','axi_lite_cpu5_stats_tb')] if spec else ['axi_lite_coremark_stats_tb','cpu5_stats_legacy_holes_tb','axi_lite_cpu5_stats_tb']
    outputs=[];actual=None
    for top in tops:
        tail=['quit -code 1 -f'] if spec and spec['kind']=='parameter_guard' else [f'if {{[examine -radix unsigned sim:/{top}/test_pass] != 1}} {{quit -code 1 -f}}','echo "CPU5 STATS ENDPOINT REFERENCE PASS"','quit -code 0 -f']
        script=top+'_simulate.do'
        (path/script).write_text('\n'.join(['onerror {quit -code 1 -f}','transcript file '+top+'_transcript.log','vmap stats_endpoint_work work',f'vsim -voptargs="+acc" -onfinish stop -wlf {top}.wlf stats_endpoint_work.{top}','log -r sim:/*','run -all',*tail,'']),encoding='utf-8')
        code,output,_=process(vsim,path,script,top);outputs.append(output)
        assert not DIAGNOSTIC.search(output),('simulation infrastructure',path.name,output[-12000:])
        actual=next((line.strip() for line in output.splitlines() if '** Fatal:' in line),None)
        if spec:assert code!=0 and actual and spec['expected_assertion'] in actual,('semantic rejection',path.name,output[-12000:])
        else:assert code==0 and not actual and 'CPU5 STATS ENDPOINT REFERENCE PASS' in output,('positive',top,output[-12000:])
    slog=path/'simulation_console.log';slog.write_text('\n'.join(outputs),encoding='utf-8',newline='')
    retained={p.relative_to(path).as_posix():sha(p) for p in path.rglob('*') if p.is_file() and 'work' not in p.relative_to(path).parts and p.suffix in ('.do','.log','.wlf','.ini','.csv','.json')}
    result=dict(name=path.name,kind=spec['kind'] if spec else 'good_reference',status='REJECTED' if spec else 'PASS',directory=path.relative_to(ROOT).as_posix(),
        compile=dict(status='PASS',exit_code=0,warnings=0,errors=0,console_sha256=sha(clog)),simulation_exit_code=code,
        expected_assertion=spec['expected_assertion'] if spec else None,actual_assertion=actual,changed_source=change,
        source_sha256={p:sha(path/p) for p in originals},simulation_console_sha256=sha(slog),retained_artifact_sha256=retained)
    if not spec:
        cases=[json.loads((path/f'build/cpu5_s16_stats_endpoint/case{i}_summary.json').read_text()) for i in range(3)]
        for i,c in enumerate(cases):assert c['status']=='PASS' and c['case']==i and c['carry_checks']==c['wrap_checks']==10 and c['edge_checks']>0
        result['cases']=cases;result['legacy']='FRESH PASS: unchanged schema3/profile1 RTL and original three-case TB plus all sixteen new offsets remain reserved SLVERR'
    (path/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(path.name,result['status'],flush=True);return result


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reference-only',action='store_true');a=ap.parse_args()
    originals={p:(ROOT/p).read_bytes() for p in SOURCES};before={p:sha(ROOT/p) for p in SOURCES}
    rid=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8];run=OUT/'runs'/rid;run.mkdir(parents=True)
    (OUT/'verification.json').write_text(json.dumps(dict(status='RUNNING',run_id=rid,source_sha256=before),indent=2)+'\n',encoding='utf-8')
    positive=verify_one(a.vsim,run/'good_reference',None,originals)
    records=[] if a.reference_only else [verify_one(a.vsim,run/s['name'],s,originals) for s in specs()]
    assert before=={p:sha(ROOT/p) for p in SOURCES},'source changed during endpoint verification'
    result=dict(status='PARTIAL' if a.reference_only else 'PASS',run_id=rid,source_sha256=before,sources_unchanged=True,
        positive=positive,cases=positive['cases'],configurations=3,specimens=records,
        rtl_semantic_rejected=sum(s['kind']=='rtl_semantic' for s in records),parameter_guards_rejected=sum(s['kind']=='parameter_guard' for s in records),
        compile_zero_warning_error=True,legacy=positive['legacy'],scope='Synthetic registered ten-bit events; independent increment/snapshot/address oracle; not CPU classification or full CoreMark')
    rendered=json.dumps(result,indent=2)+'\n';(run/'verification.json').write_text(rendered,encoding='utf-8');(OUT/'verification.json').write_text(rendered,encoding='utf-8')
    print(json.dumps({k:result[k] for k in ('status','configurations','rtl_semantic_rejected','parameter_guards_rejected')}))


if __name__=='__main__':main()
