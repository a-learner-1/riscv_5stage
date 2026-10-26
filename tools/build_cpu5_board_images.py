"""Build distinct CPU5 MES50HP smoke/formal images; never execute or download."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

import build_cpu5_coremark_images as shared
import cpu5_board_contract as contract

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19/firmware"
PROFILES={
 "smoke":dict(formal=0,validation=0,iterations=1),
 "smoke-validation":dict(formal=0,validation=1,iterations=1),
 "performance":dict(formal=1,validation=0,iterations=2000),
 "validation":dict(formal=1,validation=1,iterations=2000),
}
SOURCES=sorted(set(shared.source_hashes())|{
 "tools/build_cpu5_board_images.py","tools/cpu5_board_contract.py",contract.TOP})
MEMORY="Static; CPU5 RV32IM; D0 RAM 16 KiB; ROM 32 KiB; I/D Cache 2 KiB each; BTB64; schema4/profile2; clock=50MHz"


def sha(path):return shared.sha(path)


def config(profile):
    spec=PROFILES[profile]
    cfg=shared.case_config(dict(case=3,d0=1,cache=3))
    cfg.update(CPU5_COREMARK_BTB_ENTRIES=64,CPU5_COREMARK_BP_CONFIG=contract.BP_CONFIG,
        CPU5_COREMARK_CACHE_SETS=64,CPU5_COREMARK_CACHE_GEOMETRY=contract.CACHE_GEOMETRY,
        COREMARK_CLOCK_HZ=contract.CLOCK_HZ,COREMARK_UART_BAUD=contract.UART_BAUD,
        COREMARK_FORMAL=spec["formal"],ITERATIONS=spec["iterations"],
        PERFORMANCE_RUN=1-spec["validation"],VALIDATION_RUN=spec["validation"],
        COREMARK_PROFILE_NAME=json.dumps("cpu5-board-"+profile),
        COREMARK_BUILD_ITERATIONS=spec["iterations"],MEM_LOCATION=json.dumps(MEMORY))
    return cfg


def source_hashes():return {p:sha(ROOT/p) for p in SOURCES}


def build(profile,cross):
    contract.validate_top((ROOT/contract.TOP).read_text(encoding="utf-8"))
    before=source_hashes();spec=PROFILES[profile];directory=OUT/profile;directory.mkdir(parents=True,exist_ok=True)
    cfg=config(profile)
    flags=["-march=rv32im","-mabi=ilp32","-O2","-ffreestanding","-fno-builtin","-fno-stack-protector","-fno-pic",
           "-msmall-data-limit=0","-mno-relax","-ffunction-sections","-fdata-sections","-Wall","-Wextra",
           "-Wno-maybe-uninitialized",f"-DITERATIONS={spec['iterations']}",
           f"-DPERFORMANCE_RUN={1-spec['validation']}",f"-DVALIDATION_RUN={spec['validation']}","-DTOTAL_DATA_SIZE=2000",
           "-I"+directory.relative_to(ROOT).as_posix(),"-Isoftware/cpu5_coremark","-Isoftware/coremark_port","-Ibenchmarks/coremark","-Isoftware"]
    link=["-nostdlib","-nostartfiles","-static","-Wl,-T,software/cpu5_coremark/link.ld","-Wl,--gc-sections","-Wl,--no-relax",
          "-Wl,-Map,"+(directory/"program.map").relative_to(ROOT).as_posix()]
    tools=shared.toolchain_identity(cross);version=tools["compiler_version_full"].splitlines()[0]
    shared.write_config(directory,cfg,version,flags)
    elf=(directory/"program.elf").relative_to(ROOT).as_posix()
    commands=[
      [cross+"gcc",*flags,*link,*shared.COMPILE_SOURCES,"-lgcc","-o",elf],
      [cross+"objcopy","-O","binary","-j",".text",elf,(directory/"program_text.bin").relative_to(ROOT).as_posix()],
      [cross+"objcopy","-O","binary","-j",".data",elf,(directory/"program_data.bin").relative_to(ROOT).as_posix()],
      [cross+"objdump","-d","-S",elf],[cross+"nm","-n",elf],[cross+"size",elf]]
    steps=[];outputs={}
    for n,command in enumerate(commands):
        result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding="utf-8",errors="replace",timeout=120)
        for stream in ("stdout","stderr"):(directory/f"command{n}_{stream}.log").write_text(getattr(result,stream),encoding="utf-8",newline="")
        if result.returncode or re.search("warning:|error:",result.stdout+result.stderr,re.I):
            raise RuntimeError(f"CPU5 board {profile} command{n}: "+result.stdout+result.stderr)
        outputs[n]=result.stdout
        steps.append(dict(command=command,exit_code=0,stdout_sha256=sha(directory/f"command{n}_stdout.log"),stderr_sha256=sha(directory/f"command{n}_stderr.log")))
    (directory/"program.lst").write_text(outputs[3],encoding="utf-8",newline="")
    symbols={}
    for line in outputs[4].splitlines():
        fields=line.split()
        if len(fields)==3 and re.fullmatch("[0-9a-fA-F]+",fields[0]):symbols[fields[2]]=int(fields[0],16)
    for name in shared.REQUIRED_SYMBOLS:
        if name not in symbols:raise RuntimeError("missing CPU5 board symbol: "+name)
    if symbols["_start"]!=0 or symbols["tohost"]!=0x13ffc:raise RuntimeError("CPU5 board reset/tohost map changed")
    headroom=symbols["__stack_top"]-symbols["__bss_end"]
    if headroom<2048:raise RuntimeError("CPU5 board stack headroom")
    text=(directory/"program_text.bin").read_bytes();data=(directory/"program_data.bin").read_bytes()
    shared.validate_text(text)
    shared.image(text,directory/"program.hex",8192,0x13);shared.image(data,directory/"program_data.hex",4096,0)
    if source_hashes()!=before:raise RuntimeError("CPU5 board firmware source changed during build")
    artifact_names=["coremark_build_config.h","program.elf","program_text.bin","program_data.bin","program.hex","program_data.hex","program.map","program.lst"]+[
        f"command{n}_{stream}.log" for n in range(6) for stream in ("stdout","stderr")]
    result=dict(status="BUILT_NOT_EXECUTED",profile=profile,formal_image=bool(spec["formal"]),seed_profile="validation" if spec["validation"] else "performance",
        iterations=spec["iterations"],hardware=contract.CONFIG,config={k:str(v) for k,v in cfg.items()},
        compiler=version,compiler_flags=flags,linker_flags=link,toolchain=tools,
        sources_sha256=before,steps=steps,compiler_warnings=0,text_bytes=len(text),data_bytes=len(data),
        bss_bytes=symbols["__bss_end"]-symbols["__bss_start"],stack_headroom_bytes=headroom,
        symbols={k:f"0x{v:08x}" for k,v in sorted(symbols.items())},artifacts_sha256={name:sha(directory/name) for name in artifact_names},
        formal_score_measured=False,hardware_download_performed=False)
    (directory/"build.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
    return result


def validate_build(profile,root=ROOT):
    directory=root/"build/cpu5_s19/firmware"/profile
    r=json.loads((directory/"build.json").read_text(encoding="utf-8"))
    if r["profile"]!=profile or r["config"]!={k:str(v) for k,v in config(profile).items()} or r["hardware"]!=contract.CONFIG:
        raise ValueError("CPU5 board firmware configuration")
    for p,expected in r["sources_sha256"].items():
        if sha(root/p)!=expected:raise ValueError("CPU5 board firmware stale source: "+p)
    for name,expected in r["artifacts_sha256"].items():
        if sha(directory/name)!=expected:raise ValueError("CPU5 board firmware artifact: "+name)
    if r["status"]!="BUILT_NOT_EXECUTED" or r["formal_score_measured"] or r["hardware_download_performed"]:
        raise ValueError("CPU5 board firmware scope")
    return r


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cross",default=shared.DEFAULT_CROSS);ap.add_argument("--profile",choices=list(PROFILES)+["all"],default="all")
    args=ap.parse_args()
    for profile in (PROFILES if args.profile=="all" else [args.profile]):
        r=build(profile,args.cross)
        print(json.dumps(dict(profile=profile,status=r["status"],text_bytes=r["text_bytes"],iterations=r["iterations"],uart_baud=115200)),flush=True)


if __name__=="__main__":main()
