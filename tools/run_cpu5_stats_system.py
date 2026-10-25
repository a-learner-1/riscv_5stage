"""Build real RV32IM C firmware and run CPU5-owned AXI Stats snapshot smoke."""
import argparse
import csv
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import uuid
from run_cpu5_d0_program import SOURCES as D0_SOURCES
from cpu5_stats_abi import analyze_snapshot

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s16_stats_system'
RTL=list(dict.fromkeys([p for p in D0_SOURCES if p.endswith('.v') and p.startswith('rtl/')]+['rtl/soc_instr_mem.v','rtl/axi_lite_1x2.v','rtl/axi_lite_cpu5_stats.v','rtl/cpu5_stats_axi_lite_top.v']))
COPIES=RTL+['rtl/cpu5_pipeline_types.vh','programs/data_handshake_blank.hex','tb/cpu5_stats_system_tb.v']
FIRMWARE=['software/cpu5_stats/'+name for name in ('cpu5_stats.h','smoke.c','start.S','link.ld')]
SOURCES=sorted(set(COPIES+FIRMWARE+['tools/run_cpu5_stats_system.py','run_cpu5_stats_system.do','tools/cpu5_stats_abi.py','tools/run_cpu5_d0_program.py']))
DIAGNOSTIC=re.compile(r'\*\*\s+(?:Warning|Error)\b|^Traceback \(',re.MULTILINE)
DEFAULT_CROSS=r'D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin\riscv-none-elf-'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):return json.loads(path.read_text(encoding='utf-8'))
def write(path,obj):path.write_text(json.dumps(obj,indent=2)+'\n',encoding='utf-8',newline='\n')


def build_firmware(cross):
    version=subprocess.check_output([cross+'gcc.exe','--version'],text=True)
    records=[]
    for case in range(8):
        path=OUT/f'firmware/case{case}';path.mkdir(parents=True,exist_ok=True)
        config=dict(CPU5_STATS_HW_SCHEMA=4,CPU5_STATS_PROFILE_SCHEMA=2,CPU5_STATS_FIELDS=10,CPU5_STATS_COUNTER_BITS=64,
                    CPU5_STATS_WINDOW_BYTES=512,CPU5_STATS_CACHE_ENABLE=(case//2)%2,CPU5_STATS_BACKEND_ID=case//4)
        (path/'config.h').write_text(''.join(f'#define {k} {v}\n' for k,v in config.items()),encoding='ascii')
        commands=[
            [cross+'gcc.exe','-march=rv32im','-mabi=ilp32','-mcmodel=medany','-mno-relax','-Os','-Wall','-Wextra','-Werror','-ffreestanding','-fno-builtin','-fno-common','-fno-unwind-tables','-fno-asynchronous-unwind-tables','-nostdlib','-nostartfiles','-static',
             '-include',str(path/'config.h'),'-Isoftware/cpu5_stats','-Wl,-T,software/cpu5_stats/link.ld','-Wl,-Map,'+str(path/'program.map'),'-o',str(path/'program.elf'),'software/cpu5_stats/start.S','software/cpu5_stats/smoke.c'],
            [cross+'objcopy.exe','-O','binary',str(path/'program.elf'),str(path/'program.bin')],
            [cross+'objdump.exe','-dr',str(path/'program.elf')],
        ]
        steps=[]
        for index,command in enumerate(commands):
            p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace')
            (path/f'command{index}_stdout.log').write_text(p.stdout,encoding='utf-8');(path/f'command{index}_stderr.log').write_text(p.stderr,encoding='utf-8')
            assert p.returncode==0 and not re.search(r'warning:|error:',p.stdout+p.stderr,re.I),(case,index,p.stdout+p.stderr)
            if index==2:(path/'program.lst').write_text(p.stdout,encoding='utf-8')
            steps.append(dict(command=command,exit_code=p.returncode))
        binary=(path/'program.bin').read_bytes();assert len(binary)%4==0 and len(binary)<=32768
        words=[int.from_bytes(binary[i:i+4],'little') for i in range(0,len(binary),4)]
        (path/'program.hex').write_text(''.join(f'{w:08x}\n' for w in words+[0x0000006f]*(8192-len(words))),encoding='ascii')
        record=dict(case=case,configuration=config,text_bytes=len(binary),compiler_version=version,steps=steps,
                    source_sha256={p:sha(ROOT/p) for p in FIRMWARE},artifact_sha256={p.name:sha(p) for p in path.iterdir() if p.is_file() and p.name!='build.json'})
        write(path/'build.json',record);records.append(record)
    return records


def analyze(directory):
    cases=[]
    for number in range(8):
        path=directory/f'cases/case{number}';summary=read(path/'summary.json');snapshot=read(path/'snapshot.json')
        assert summary['status']=='PASS' and summary['case']==number and summary['d0']==number//4 and summary['cache']==(number//2)%2 and summary['wait']==number%2
        rows=list(csv.DictReader((path/'edges.csv').open(newline='',encoding='ascii')))
        counts=[0]*10;start=None;stop=None;starts=stops=retired=wb=0;pending=None;stats=[]
        def expected_word(offset):
            fixed={0:0x434d4158,4:0x434d4158,8:3 if (number//2)%2 else 0,12:0x02040010,16:0x02040010,20:0x00100001,24:4,28:number//4}
            if offset in fixed:return fixed[offset]
            for base,bank in ((0x40,start),(0x80,stop)):
                if base<=offset<base+16:
                    value=bank['cycle'] if offset<base+8 else bank['instret']
                    return (value>>(32 if offset&4 else 0))&0xffffffff
            for base,bank,first,n in ((0x100,start,0,6),(0x140,stop,0,6),(0x180,start,6,4),(0x1c0,stop,6,4)):
                if base<=offset<base+8*n:
                    return (bank['profile'][first+(offset-base)//8]>>(32 if offset&4 else 0))&0xffffffff
            assert offset in (0x50,0x54,0x58,0x5c),'unexpected firmware Stats read'
            # Four additional cache counters are checked by the independent
            # endpoint scoreboard against the frozen cache output ports.
            return None
        for index,row in enumerate(rows):
            cycle=index+1;assert int(row['cycle'])==cycle and int(row['cycle_count'])==cycle-1 and int(row['instret'])==retired
            bits=int(row['events'],16);assert bits==0 if cycle==1 else bits>0 and bits&(bits-1)==0 and bits<1024
            for i in range(10):counts[i]+=(bits>>i)&1
            assert sum(counts)==cycle-1
            if int(row['rvalid']):
                assert pending is not None and int(row['rresp'])==0
                gold=expected_word(pending)
                if gold is not None:assert int(row['rdata'],16)==gold,'independent raw Stats read word'
                if int(row['rready']):stats.append(('rsp',cycle,pending,int(row['rdata'],16)));pending=None
            if int(row['arvalid']) and int(row['arready']):
                assert pending is None;offset=int(row['araddr'],16)-0x30000000;pending=offset
                stats.append(('req',cycle,offset,0))
                if offset==0:starts+=1;start=dict(cycle=cycle-1,instret=retired,profile=list(counts))
                if offset==4:stops+=1;stop=dict(cycle=cycle-1,instret=retired,profile=list(counts))
            retired+=int(row['retire']);wb+=int(row['wb'])
        assert pending is None and starts==2 and stops==1 and start and stop
        assert snapshot['cycles']==dict(start=start['cycle'],stop=stop['cycle'])
        assert snapshot['instret']==dict(start=start['instret'],stop=stop['instret'])
        assert snapshot['profile']==dict(start=start['profile'],stop=stop['profile'])
        host=analyze_snapshot(snapshot)
        ram=[int(line,16) for line in (path/'actual_ram.hex').read_text().splitlines()];assert len(ram)==4096
        assert ram[0]==0x600d5005 and ram[1]==0 and ram[2:9]==[4,0x434d4158,3 if (number//2)%2 else 0,0x02040010,0x02040010,0x00100001,number//4]
        def pair(at):return ram[at]|ram[at+1]<<32
        assert [pair(i) for i in (9,11,13,15)]==[start['cycle'],start['instret'],stop['cycle'],stop['instret']]
        assert pair(17)==pair(19)==host['window_cycles']
        for i in range(10):
            assert pair(32+i*2)==pair(72+i*2)==start['profile'][i]
            assert pair(52+i*2)==pair(92+i*2)==stop['profile'][i]
        memory=[i+11 for i in range(16)];checksum=0
        for i in range(24):
            a=memory[i&15];b=i+3;m=(a*b)&0xffffffff;d=m//b
            memory[(i+1)&15]=(d+i)&0xffffffff;checksum=(checksum+(m^d))&0xffffffff
        assert ram[128:144]==memory and ram[21]==checksum
        expected_ram=[0]*4096
        ordinary=[start['cycle'],start['instret'],stop['cycle'],stop['instret']]
        flat=[word for value in ordinary for word in (value&0xffffffff,value>>32)]
        span=host['window_cycles']
        expected_ram[:22]=[0x600d5005,0,4,0x434d4158,3 if (number//2)%2 else 0,0x02040010,0x02040010,0x00100001,number//4]+flat+[span&0xffffffff,span>>32,span&0xffffffff,span>>32,checksum]
        for base,values in ((32,start['profile']),(52,stop['profile']),(72,start['profile']),(92,stop['profile'])):
            expected_ram[base:base+20]=[word for value in values for word in (value&0xffffffff,value>>32)]
        expected_ram[128:144]=memory
        # Startup explicitly initializes callee-save GPRs before C saves them;
        # unused RAM and the saved caller stack therefore retain known zeros.
        assert ram==expected_ram,'independent complete physical RAM image'
        assert summary['retired']==retired and summary['wb']==wb and summary['stats_reads']==summary['stats_responses']==101
        trace=list(csv.DictReader((path/'stats.csv').open(newline='',encoding='ascii')));assert len(trace)==202
        expected=[]
        for action,cycle,offset,data in stats:
            expected.append((action,cycle,offset,data))
        assert len(stats)==202
        for actual,gold in zip(trace,expected):
            assert (actual['event'],int(actual['cycle']),int(actual['offset'],16))==gold[:3] and int(actual['response'])==0
            if actual['event']=='rsp':assert int(actual['data'],16)==gold[3]
        assert host['cycle_classes']['mul_wait']>0 and host['cycle_classes']['div_wait']>0
        cases.append(dict(**summary,window=host,raw_edge_checks=len(rows),ram_words_checked=4096,firmware_profile_words_checked=80))
    return dict(status='PASS',configurations=8,cases=cases,total_cycles=sum(c['cycles'] for c in cases),total_retired=sum(c['retired'] for c in cases),
                total_stats_reads=sum(c['stats_reads'] for c in cases),total_profile_words_checked=640,scope='Real compiled C on CPU5 system: self-issued AXI Stats reads; D0 x coupled I/D cache x waits; BP enabled, ID follows wait. Not full feature matrix, CoreMark, UART, FPGA STA or board.')


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--vsim',type=Path,default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'));ap.add_argument('--cross',default=DEFAULT_CROSS);ap.add_argument('--generate-only',action='store_true');a=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    before={p:sha(ROOT/p) for p in SOURCES};firmware=build_firmware(a.cross)
    if a.generate_only:print(json.dumps(dict(status='FIRMWARE BUILT',cases=8)));return
    rid=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_')+uuid.uuid4().hex[:8];run=OUT/'runs'/rid;stage=run/'good_reference';stage.mkdir(parents=True)
    write(OUT/'verification.json',dict(status='RUNNING',run_id=rid,source_sha256=before))
    for name in SOURCES:
        p=stage/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes((ROOT/name).read_bytes())
    staged_out=stage/'build/cpu5_s16_stats_system';staged_out.mkdir(parents=True)
    shutil.copytree(OUT/'firmware',staged_out/'firmware')
    for i in range(8):(staged_out/f'cases/case{i}').mkdir(parents=True)
    scripts={'compile.do':['onerror {quit -code 1 -f}','transcript file compile_transcript.log','vmap -c','vlib work','vmap cpu5_system_work work','vlog -sv +incdir+. -work cpu5_system_work '+' '.join(RTL+['tb/cpu5_stats_system_tb.v']),'echo "CPU5 SYSTEM CLEAN COMPILE PASS"','quit -code 0 -f'],
             'simulate.do':['onerror {quit -code 1 -f}','transcript file simulation_transcript.log','vmap cpu5_system_work work','vsim -voptargs="+acc" -onfinish stop -wlf system.wlf cpu5_system_work.cpu5_stats_system_tb',
                 'log -r sim:/cpu5_stats_system_tb/*','run -all','if {[examine -radix unsigned sim:/cpu5_stats_system_tb/test_pass] != 1} {quit -code 1 -f}','echo "CPU5 SYSTEM REFERENCE PASS"','quit -code 0 -f']}
    logs={}
    for name,lines in scripts.items():
        (stage/name).write_text('\n'.join(lines)+'\n',encoding='utf-8')
        p=subprocess.run([str(a.vsim),'-c','-do',name],cwd=stage,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=600)
        output=p.stdout+p.stderr;log=stage/(name.split('.')[0]+'_console.log');log.write_text(output,encoding='utf-8',newline='');logs[name]=log
        assert p.returncode==0 and not DIAGNOSTIC.search(output) and '** Fatal:' not in output,(name,p.returncode,output[-16000:])
    for i in range(8):shutil.copytree(staged_out/f'cases/case{i}',OUT/f'cases/case{i}',dirs_exist_ok=True)
    result=analyze(OUT)
    assert before=={p:sha(ROOT/p) for p in SOURCES},'system sources changed during run'
    raw_artifacts={p.relative_to(ROOT).as_posix():sha(p) for folder in (OUT/'cases',OUT/'firmware') for p in folder.rglob('*') if p.is_file()}
    # Keep one canonical raw set. Remove only the checked duplicate created by
    # this run beneath its own simulator staging directory.
    for folder in ('cases','firmware'):
        duplicate=staged_out/folder
        assert duplicate.resolve().is_relative_to(stage.resolve())
        assert all(sha(p)==sha(OUT/folder/p.relative_to(duplicate)) for p in duplicate.rglob('*') if p.is_file())
        shutil.rmtree(duplicate)
    retained={p.relative_to(stage).as_posix():sha(p) for p in stage.rglob('*') if p.is_file() and 'work' not in p.relative_to(stage).parts and p.suffix in ('.do','.log','.wlf','.ini','.csv','.json','.hex','.elf','.bin','.lst','.map','.h')}
    positive=dict(name='good_reference',kind='good_reference',status='PASS',directory=stage.relative_to(ROOT).as_posix(),compile=dict(status='PASS',exit_code=0,warnings=0,errors=0,console_sha256=sha(logs['compile.do'])),
                  simulation_exit_code=0,source_sha256=before,simulation_console_sha256=sha(logs['simulate.do']),retained_artifact_sha256=retained)
    result.update(run_id=rid,source_sha256=before,sources_unchanged=True,positive=positive,firmware=firmware,raw_artifact_sha256=raw_artifacts,compile_zero_warning_error=True,processes=[dict(name='firmware',status='PASS',exit_code=0),dict(name='simulation',status='PASS',exit_code=0)])
    write(run/'verification.json',result);write(OUT/'verification.json',result)
    print(json.dumps({k:result[k] for k in ('status','configurations','total_cycles','total_retired','total_stats_reads')}))


if __name__=='__main__':main()
