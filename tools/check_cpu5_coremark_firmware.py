"""Actual portable_init identity tests, C ABI guards, and compiler include closure.

The small native fixture executes the production CPU5 port against an allocated
identity page in its own process. It is not RV32 execution or benchmark timing.
The real RV32 wrong-image tests belong to the separate system suite.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import build_cpu5_coremark_images as builder

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/cpu5_s18_coremark_firmware_checks'
PORT='software/cpu5_coremark/core_portme_cpu5.c'
OLD_PORT='software/coremark_port/core_portme.c'
SOURCES=sorted(set(builder.source_hashes())|{'tools/check_cpu5_coremark_firmware.py'})


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')


def execute(command,directory,name,env=None):
    p=subprocess.run([str(x) for x in command],cwd=ROOT,capture_output=True,text=True,
        encoding='utf-8',errors='replace',env=env,timeout=90)
    stdout=directory/(name+'_stdout.log');stderr=directory/(name+'_stderr.log')
    stdout.write_text(p.stdout,encoding='utf-8',newline='');stderr.write_text(p.stderr,encoding='utf-8',newline='')
    return p,dict(command=[str(x) for x in command],exit_code=p.returncode,
        stdout_sha256=sha(stdout),stderr_sha256=sha(stderr))


def config(directory,d0=0,cache=0,overrides=None):
    values=builder.case_config(dict(case=d0*2+int(cache!=0),d0=d0,cache=cache))
    values.update(overrides or {})
    builder.write_config(directory,values,'FIXTURE ONLY; no benchmark timing',[])
    return values


def cpp_guards(cross):
    old_values=dict(COREMARK_PLATFORM_NAME='"schema3"',COREMARK_ENABLE_ICACHE=0,
        COREMARK_ENABLE_DCACHE=0,COREMARK_ENABLE_D0_BRAM=0,COREMARK_DATA_BACKEND_ID=0,
        COREMARK_AXI_STATS_BASE=0x30000000,COREMARK_AXI_STATS_ID=0x434d4158,
        COREMARK_AXI_CACHE_GEOMETRY=0x02040010,COREMARK_ENABLE_BRANCH_PRED=1,
        COREMARK_BTB_ENTRIES=16,COREMARK_AXI_BP_CONFIG=0x00100001,COREMARK_AXI_STATS_SCHEMA=3,
        COREMARK_AXI_CYCLE_PROFILE_SCHEMA=1,COREMARK_AXI_CYCLE_PROFILE_FIELDS=6,
        COREMARK_AXI_CYCLE_PROFILE_BITS=64,COREMARK_AXI_CYCLE_PROFILE_START_BANK=0x100,
        COREMARK_AXI_CYCLE_PROFILE_STOP_BANK=0x140,COREMARK_AXI_STATS_WINDOW_BYTES=512)
    specs=[(f'cpu5_good_{d0}_{cache}','new',d0,cache,{},0) for d0 in (0,1) for cache in (0,3)]
    specs += [(name,'new',0,0,changes,1) for name,changes in (
        ('reject_schema3',dict(CPU5_COREMARK_STATS_SCHEMA=3)),
        ('reject_profile1',dict(CPU5_COREMARK_PROFILE_SCHEMA=1)),
        ('reject_six_fields',dict(CPU5_COREMARK_PROFILE_FIELDS=6)),
        ('reject_32bit',dict(CPU5_COREMARK_PROFILE_BITS=32)),
        ('reject_small_window',dict(CPU5_COREMARK_WINDOW_BYTES=256)),
        ('reject_backend_mismatch',dict(CPU5_COREMARK_BACKEND_ID=1)),
        ('reject_split_cache',dict(CPU5_COREMARK_CACHE_ENABLE=1)),
        ('reject_btb_nonpower2',dict(CPU5_COREMARK_BTB_ENTRIES=3,CPU5_COREMARK_BP_CONFIG=0x30001)),
        ('reject_bp_config',dict(CPU5_COREMARK_BP_CONFIG=0x00100000)),
        ('reject_rv32i_image',dict(CPU5_COREMARK_ENABLE_M=0)),
    )]
    specs += [('schema3_good','old',0,0,{},0),
              ('old_rejects_schema4','old',0,0,dict(COREMARK_AXI_STATS_SCHEMA=4),1),
              ('old_rejects_profile2','old',0,0,dict(COREMARK_AXI_CYCLE_PROFILE_SCHEMA=2),1),
              ('old_rejects_ten','old',0,0,dict(COREMARK_AXI_CYCLE_PROFILE_FIELDS=10),1),
              ('old_rejects_cpu5_config','old_cpu5',0,0,{},1),
              ('cpu5_rejects_old_config','new_old',0,0,{},1)]
    records=[]
    for name,kind,d0,cache,overrides,wanted in specs:
        directory=OUT/'cpp'/name;directory.mkdir(parents=True,exist_ok=True)
        config(directory,d0,cache,overrides if kind=='new' else None)
        if kind in ('old','new_old'):
            values=old_values|overrides
            text='\n'.join(f'#define {k} {v}' for k,v in values.items())+'\n'
            text+='#define COREMARK_CLOCK_HZ 50000000\n#define COREMARK_UART_BAUD 5000000\n#define COREMARK_FORMAL 0\n#define ITERATIONS 1\n#define PERFORMANCE_RUN 1\n'
            (directory/'coremark_build_config.h').write_text(text,encoding='ascii',newline='\n')
        header='coremark_cpu5_stats.h' if kind in ('new','new_old') else 'coremark_axi_stats.h'
        source=directory/'guard.c';source.write_text('#include "coremark.h"\n#include "'+header+'"\n',encoding='ascii')
        command=[cross+'gcc','-E','-x','c','-I'+directory.relative_to(ROOT).as_posix(),
            '-Isoftware/cpu5_coremark','-Isoftware/coremark_port','-Ibenchmarks/coremark',str(source)]
        p,process=execute(command,directory,'preprocess')
        assert (p.returncode==0)==(wanted==0),(name,p.returncode,p.stderr)
        if wanted:assert '#error' in p.stderr,(name,'not a designated ABI guard rejection')
        records.append(dict(name=name,status='PASS' if wanted==0 else 'REJECTED',expected_exit_code=wanted,**process))
    return records


def include_closure(cross):
    directory=OUT/'include_closure';directory.mkdir(parents=True,exist_ok=True);config(directory)
    command=[cross+'gcc','-MM','-march=rv32im','-mabi=ilp32',
        '-I'+directory.relative_to(ROOT).as_posix(),'-Isoftware/cpu5_coremark',
        '-Isoftware/coremark_port','-Ibenchmarks/coremark','-Isoftware',PORT]
    p,process=execute(command,directory,'dependencies');assert p.returncode==0,p.stderr
    text=p.stdout.replace('\\\n',' ');assert ':' in text
    paths=text.split(':',1)[1].split();generated=directory/'coremark_build_config.h'
    dependencies=[];mapping=builder.source_hashes()
    for token in paths:
        path=(ROOT/token).resolve();assert path.is_file(),token
        if path==generated.resolve():continue
        assert path.is_relative_to(ROOT.resolve()),token
        rel=path.relative_to(ROOT).as_posix();assert rel in mapping,('actual compiler dependency missing from builder hashes',rel)
        assert sha(path)==mapping[rel];dependencies.append(rel)
    assert OLD_PORT in dependencies and PORT in dependencies
    return dict(status='PASS',compiler_dependencies=dependencies,
        generated_header_sha256=sha(generated),source_hashes_include_actual_base_c=True,process=process)


IO_HEADER='''#ifndef CPU5_NATIVE_FIXTURE_IO_H
#define CPU5_NATIVE_FIXTURE_IO_H
#include "mmio.h"
void fixture_putchar(char c);
void fixture_flush(void);
void fixture_tohost(ee_u32 value);
#define mmio_putchar fixture_putchar
#define mmio_uart_flush fixture_flush
#define COREMARK_TOHOST_WRITE(value) fixture_tohost(value)
#include "timer.h"
#endif
'''

NATIVE_SOURCE='''#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "PORT_SOURCE"
static char captured[4096];
static unsigned used=0;
static unsigned host_pointer_diagnostic=0;
void fixture_putchar(char c) {
    if(used+1u<sizeof(captured)) {
        static const char known[]="ERROR: ee_ptr_int cannot hold a pointer\\n";
        size_t n=sizeof(known)-1u;
        captured[used++]=c; captured[used]=0;
        /* The native fixture does not test the RV32 pointer ABI. Normalize
           ONLY this exact generic-host diagnostic, emitted before CPU5's
           identity probes. The CPU5 backend error line is never suppressed. */
        if(c=='\\n' && used>=n && strcmp(captured+used-n,known)==0) {
            ++host_pointer_diagnostic;
            coremark_failed=0;
        }
    }
}
void fixture_flush(void) { }
void fixture_tohost(ee_u32 value) { (void)value; }
int main(int argc,char **argv) {
    ee_u32 actual;
    volatile ee_u32 *identity;
    core_portable portable;
    int dummy_argc=0;
    char *dummy_argv[1]={0};
    int wanted_failure;
    if(argc!=2) return 44;
    actual=(ee_u32)strtoul(argv[1],0,10);
    identity=(volatile ee_u32 *)VirtualAlloc((void *)0x30000000u,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    if(identity!=(volatile ee_u32 *)0x30000000u) { puts("FIXTURE_ALLOCATION_FAILED"); return 43; }
    identity[0]=0x434d4158u;
    identity[2]=CPU5_COREMARK_CACHE_ENABLE;
    identity[3]=identity[4]=CPU5_COREMARK_CACHE_GEOMETRY;
    identity[5]=CPU5_COREMARK_BP_CONFIG;
    identity[6]=CPU5_COREMARK_STATS_SCHEMA;
    identity[7]=actual;
    portable_init(&portable,&dummy_argc,dummy_argv);
    if(host_pointer_diagnostic!=1u) { puts("FIXTURE_NATIVE_ABI_ASSUMPTION_FAILED"); return 45; }
    wanted_failure=actual!=CPU5_COREMARK_BACKEND_ID;
    if(cpu5_coremark_backend_seen!=actual ||
       cpu5_coremark_platform_failed!=(ee_u32)wanted_failure ||
       coremark_failed!=(ee_u32)wanted_failure ||
       (!!strstr(captured,"ERROR: CPU5 CoreMark data backend mismatch"))!=wanted_failure) {
        printf("BACKEND_INIT_FIXTURE_ASSERT image=%u actual=%u seen=%u failure=%u expected=%d\\n",
               (unsigned)CPU5_COREMARK_BACKEND_ID,(unsigned)actual,(unsigned)cpu5_coremark_backend_seen,
               (unsigned)coremark_failed,wanted_failure);
        return 41;
    }
    printf("BACKEND_INIT_FIXTURE_PASS image=%u actual=%u rejected=%d cache=%u\\n",
           (unsigned)CPU5_COREMARK_BACKEND_ID,(unsigned)actual,wanted_failure,(unsigned)CPU5_COREMARK_CACHE_ENABLE);
    VirtualFree((void *)identity,0,MEM_RELEASE);
    return 0;
}
'''


def native_tests(host_cc):
    host_cc=host_cc.resolve();assert host_cc.is_file()
    env=os.environ.copy();env['PATH']=str(host_cc.parent)+os.pathsep+env.get('PATH','')
    version=subprocess.check_output([str(host_cc),'--version'],text=True,encoding='utf-8',errors='replace',env=env)
    compiler=dict(path=str(host_cc),sha256=sha(host_cc),version=version)
    cases=[];compilations=[]
    source=(ROOT/PORT).read_text(encoding='utf-8')
    old='''    cpu5_coremark_backend_seen = cpu5_coremark_read(28u);
    if (cpu5_coremark_backend_seen != CPU5_COREMARK_BACKEND_ID) {
        cpu5_coremark_fail();
        ee_printf("ERROR: CPU5 CoreMark data backend mismatch\\n");
    }'''
    assert source.count(old)==1,'native regression anchor'
    bad='    if (CPU5_COREMARK_D0_BRAM) {\n'+old+'\n    }'
    variants=[(f'image_{d0}_{cache}',d0,cache,False) for d0 in (0,1) for cache in (0,3)]
    variants.append(('regression_old_one_way_guard',0,0,True))
    negative=None
    for name,d0,cache,mutant in variants:
        directory=OUT/'native'/name;directory.mkdir(parents=True,exist_ok=True);config(directory,d0,cache)
        (directory/'fixture_io.h').write_text(IO_HEADER,encoding='ascii',newline='\n')
        actual_port=ROOT/PORT
        if mutant:
            actual_port=directory/'bad_port.c';actual_port.write_text(source.replace(old,bad),encoding='utf-8',newline='\n')
        fixture=directory/'identity.c';fixture.write_text(NATIVE_SOURCE.replace('PORT_SOURCE',actual_port.as_posix()),encoding='utf-8',newline='\n')
        exe=directory/'identity.exe'
        command=[str(host_cc),'-O0','-Wall','-Wextra','-Werror','-Wno-int-to-pointer-cast',
            '-Wno-pointer-to-int-cast','-ffunction-sections','-fdata-sections','-Wl,--gc-sections','-static',
            '-DCOREMARK_PORT_TEST_INCLUDE="fixture_io.h"','-I'+directory.relative_to(ROOT).as_posix(),
            '-Isoftware/cpu5_coremark','-Isoftware/coremark_port','-Ibenchmarks/coremark','-Isoftware',
            str(fixture),'-o',str(exe)]
        p,compile_record=execute(command,directory,'compile',env)
        assert p.returncode==0 and not re.search(r'warning:|error:',p.stdout+p.stderr,re.I),(name,p.stdout,p.stderr)
        compilations.append(dict(name=name,status='PASS',exe_sha256=sha(exe),**compile_record))
        for hardware in ((1,) if mutant else (0,1)):
            p,run_record=execute([str(exe),str(hardware)],directory,'hardware'+str(hardware),env)
            if mutant:
                assert p.returncode==41 and 'BACKEND_INIT_FIXTURE_ASSERT' in p.stdout,(p.returncode,p.stdout,p.stderr)
                negative=dict(name=name,status='REJECTED',kind='c_semantic_regression',
                    expected_exit_code=41,expected_assertion='BACKEND_INIT_FIXTURE_ASSERT',
                    actual_assertion=p.stdout.strip(),changed_file=PORT,
                    good_sha256=sha(ROOT/PORT),bad_sha256=sha(actual_port),**run_record)
            else:
                assert p.returncode==0 and 'BACKEND_INIT_FIXTURE_PASS' in p.stdout,(p.returncode,p.stdout,p.stderr)
                cases.append(dict(image_backend=d0,hardware_backend=hardware,cache=cache,
                    status='REJECTED' if hardware!=d0 else 'ACCEPTED',**run_record))
    assert len(cases)==8 and sum(c['status']=='REJECTED' for c in cases)==4 and negative
    return dict(status='PASS',compiler=compiler,compilations=compilations,cases=cases,
        rejected_wrong_pairs=4,accepted_correct_pairs=4,semantic_regression=negative,
        scope='Native Windows execution of actual portable_init against an allocated identity page. Test UART normalizes only the exact generic ee_ptr_int-width diagnostic emitted before CPU5 probes on the 64-bit host; it never suppresses CPU5 mismatch errors. This tests backend identity, not RV32 ABI, CoreMark CRC, hardware timing, or a score.')


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--cross',default=builder.DEFAULT_CROSS)
    ap.add_argument('--host-cc',type=Path,default=Path(shutil.which('gcc') or 'gcc'));a=ap.parse_args()
    OUT.mkdir(parents=True,exist_ok=True);before={p:sha(ROOT/p) for p in SOURCES}
    snapshot=OUT/'tested_sources'
    for name,expected in before.items():
        target=snapshot/name;target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes((ROOT/name).read_bytes());assert sha(target)==expected
    cross_exe=Path(a.cross+'gcc.exe');assert cross_exe.is_file()
    guards=cpp_guards(a.cross);closure=include_closure(a.cross);native=native_tests(a.host_cc)
    assert before=={p:sha(ROOT/p) for p in SOURCES},'firmware-check inputs changed'
    assert all(sha(snapshot/name)==expected for name,expected in before.items())
    artifacts={p.relative_to(ROOT).as_posix():sha(p) for p in OUT.rglob('*') if p.is_file() and p.name!='verification.json'}
    result=dict(status='PASS',source_sha256=before,sources_unchanged=True,header_guards=guards,
        header_guard_cases=len(guards),header_guard_rejected=sum(g['status']=='REJECTED' for g in guards),
        compiler_include_closure=closure,native_backend=native,
        cross_compiler=dict(path=str(cross_exe),sha256=sha(cross_exe)),retained_artifact_sha256=artifacts)
    write(OUT/'verification.json',result)
    print(json.dumps(dict(status='PASS',header_guard_cases=len(guards),header_guard_rejected=result['header_guard_rejected'],
        native_identity_cases=8,wrong_pairs_rejected=4,one_way_regression_rejected=True,actual_include_dependencies=len(closure['compiler_dependencies']))))


if __name__=='__main__':main()
