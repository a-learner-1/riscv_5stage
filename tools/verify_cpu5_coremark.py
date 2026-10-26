"""Audit CPU5 CoreMark raw receipts, independently replay RV32IM, and reject bad evidence."""
import argparse
import copy
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import uuid
from datetime import datetime,timezone

import build_cpu5_coremark_images as builder
import run_cpu5_coremark as runner
from cpu5_coremark_reference import (audit_case as reference_case, check, precheck, read_json, rows, parse_console)

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s18_coremark"
SOURCES=("tools/verify_cpu5_coremark.py","tools/cpu5_coremark_reference.py","tools/test_cpu5_coremark_evidence.py")


def sha(path):return runner.sha(path)
def write(path,value):runner.write(path,value)


def local(root,path):
    check(isinstance(path,str) and "\\" not in path and ":" not in path and
          not path.startswith("/") and str(PurePosixPath(path))==path and
          ".." not in PurePosixPath(path).parts,"RECEIPT_PATH",path)
    return root/path


def expect_hash(path,expected,label="RECEIPT_HASH"):
    check(re.fullmatch(r"[0-9a-f]{64}",expected) is not None and path.is_file() and sha(path)==expected,label,str(path))


def validate_receipts(record,root=ROOT,full_required=True,check_run_copy=True):
    check(record.get("schema")==2,"RECORD_SCHEMA")
    count=record.get("configurations")
    check(type(count) is int and 1<=count<=4,"SCOPE_CASE_COUNT")
    check(not full_required or count==4,"SCOPE_FULL_FOUR_REQUIRED")
    check(record.get("status")==("SIMULATED" if count==4 else "PARTIAL SIMULATED"),"SCOPE_SIMULATED_REQUIRED")
    check(record.get("metrics_claimed")=="NONE" and record.get("formal_score_measured") is False and
          record.get("hardware_download_performed") is False,"SCOPE_NO_SCORE")
    rid=record.get("run_id","");check(re.fullmatch(r"[0-9]{8}T[0-9]{12}Z_[0-9a-f]{8}",rid) is not None,"RUN_ID")
    prefix="build/cpu5_s18_coremark/runs/"+rid
    check(record["case_directory"]==prefix+"/raw/cases" and record["positive"]["directory"]==prefix+"/good_reference"
          and record["firmware_directory"]==prefix+"/good_reference/build/cpu5_s18_coremark/firmware","RUN_DIRECTORIES")
    stage=local(root,record["positive"]["directory"]);cases=local(root,record["case_directory"])
    firmware=local(root,record["firmware_directory"])
    check(record["artifact_storage"]["logical"]=="build/cpu5_s18_coremark/runs","STORAGE_LOGICAL_PATH")
    # Either ordinary extracted build files, or the explicitly declared junction.
    physical=Path(record["artifact_storage"]["physical"]).resolve()
    actual=local(root,"build/cpu5_s18_coremark/runs").resolve()
    check(actual==physical or actual.is_relative_to(root.resolve()/"build"),"STORAGE_JUNCTION_TARGET")
    check(record["baseline_commit"]==runner.BASELINE and record["mapped_baseline_commit"]==runner.MAPPED_BASELINE,"BASELINE_ID")
    sources=record["source_sha256"];lf=record["source_lf_sha256"]
    check(set(sources)==set(lf)==set(runner.SOURCES) and record["positive"]["source_sha256"]==sources and record["sources_unchanged"] is True,"SOURCE_CLOSURE")
    current_raw_differences=[]
    for path,expected in sources.items():
        original=local(root,path);snapshot=stage/path
        expect_hash(snapshot,expected,"SNAPSHOT_HASH")
        data=original.read_bytes()
        check(hashlib.sha256(data.replace(b"\r\n",b"\n")).hexdigest()==lf[path] and
              hashlib.sha256(snapshot.read_bytes().replace(b"\r\n",b"\n")).hexdigest()==lf[path],"SOURCE_LF_IDENTITY",path)
        if sha(original)!=expected:current_raw_differences.append(path)
    required={"compile.do","simulate.do","compile_console.log","compile_transcript.log","modelsim.ini",
              "simulate_console.log","simulation_transcript.log","system.wlf"}
    check(set(record["positive"]["retained_artifact_sha256"])==required and record["positive"]["status"]==record["status"],"PROCESS_ARTIFACT_CLOSURE")
    for path,expected in record["positive"]["retained_artifact_sha256"].items():expect_hash(stage/path,expected)
    check((stage/"system.wlf").stat().st_size>=128,"WAVEFORM_EMPTY")
    processes=record["processes"]
    check([p["name"] for p in processes]==["compile.do","simulate.do"] and all(p["exit_code"]==0 and p["elapsed_seconds"]>0 for p in processes),"PROCESS_STATUS")
    for process in processes:
        expected=record["positive"]["directory"]+"/"+process["name"].split(".")[0]+"_console.log"
        check(process["console"]==expected and process["command"]==[record["toolchain"]["simulator"],"-c","-do",process["name"]],"PROCESS_COMMAND")
        expect_hash(local(root,process["console"]),process["console_sha256"])
        text=local(root,process["console"]).read_text(encoding="utf-8",errors="strict")
        check(not runner.DIAGNOSTIC.search(text),"PROCESS_DIAGNOSTIC")
        marker="CPU5 COREMARK CLEAN COMPILE PASS" if process["name"]=="compile.do" else "CPU5 COREMARK REFERENCE PASS"
        check(marker in text,"PROCESS_MARKER")
    sim=(stage/"simulate_console.log").read_text(encoding="utf-8")
    check("CPU5 COREMARK SYSTEM PASS cases="+str(count) in sim,"SYSTEM_CASE_MARKER")
    script=(stage/"simulate.do").read_text(encoding="utf-8")
    check("-gCASES="+str(count)+" -gQUICK_PROBE=0" in script and "+RUN_ID="+rid in script and
          record["case_directory"] in script,"SIMULATION_SCRIPT_IDENTITY")
    raw=record["raw_artifact_sha256"];compression=record["compressed_artifacts"]
    expected_raw=set();expected_compressed=set()
    for number in range(count):
        base=record["case_directory"]+f"/case{number}/"
        for name in runner.CASE_FILES:
            expected_raw.add(base+name+(".gz" if name.endswith(".csv") else ""))
            if name.endswith(".csv"):expected_compressed.add(base+name)
    check(set(raw)==expected_raw and set(compression)==expected_compressed,"RAW_ARTIFACT_CLOSURE")
    check(set(p.name for p in cases.iterdir())=={f"case{n}" for n in range(count)},"CASE_DIRECTORY_CLOSURE")
    for number in range(count):
        expected_names={name+(".gz" if name.endswith(".csv") else "") for name in runner.CASE_FILES}
        check(set(p.name for p in (cases/f"case{number}").iterdir())==expected_names,"CASE_FILE_CLOSURE")
    for path,expected in raw.items():expect_hash(local(root,path),expected)
    for path,item in compression.items():
        check(item["path"]==path+".gz" and raw[item["path"]]==item["sha256"] and
              not local(root,path).exists(),"COMPRESSION_IDENTITY")
        h=hashlib.sha256();size=0
        with gzip.open(local(root,item["path"]),"rb") as stream:
            while chunk:=stream.read(1024*1024):h.update(chunk);size+=len(chunk)
        check(h.hexdigest()==item["raw_sha256"] and size==item["raw_bytes"],"COMPRESSION_RAW_HASH")
    fw_map=record["firmware_artifact_sha256"]
    expected_fw={p.relative_to(root).as_posix() for p in firmware.rglob("*") if p.is_file()}
    check(set(fw_map)==expected_fw,"FIRMWARE_ARTIFACT_CLOSURE")
    for path,expected in fw_map.items():expect_hash(local(root,path),expected)
    check(len(record["firmware"])==4 and len(record["cases"])==count,"CASE_RECORD_COUNT")
    for number,build in enumerate(record["firmware"]):
        check(build==read_json(firmware/f"case{number}/build.json"),"FIRMWARE_BUILD_RECORD")
        check((build["case"],build["d0"],build["cache"])==(number,number//2,3 if number%2 else 0),"FIRMWARE_CASE")
        check(build["sources_sha256"]=={p:sources[p] for p in builder.source_hashes()},"FIRMWARE_SOURCE_CLOSURE")
        check(build["config"]=={k:str(v) for k,v in builder.case_config(builder.CASES[number]).items()},"FIRMWARE_CONFIG")
        check(build["formal"]==0 and build["iterations"]==1 and build["seed_profile"]=="performance"
              and build["compiler_generated_warnings"]==0 and all(s["exit_code"]==0 for s in build["steps"]),"FIRMWARE_SCOPE")
        check(build["toolchain"]["multilib_entry"].endswith(";@march=rv32im@mabi=ilp32")
              or build["toolchain"]["multilib_entry"].endswith(";@mabi=ilp32@march=rv32im"),"FIRMWARE_MULTILIB")
        for path,expected in build["artifact_sha256"].items():
            short=PurePosixPath(path).relative_to("build/cpu5_s18_coremark/firmware")
            target=firmware/short;expect_hash(target,expected)
        expect_hash(firmware/f"case{number}/coremark_build_config.h",build["generated_config_sha256"])
    for number,summary in enumerate(record["cases"]):
        check(summary==read_json(cases/f"case{number}/summary.json"),"CASE_SUMMARY_RECORD")
        check(summary["run_id"]==rid and summary["quick_probe"]==0,"CASE_RUNTIME_IDENTITY")
        marker=f"CPU5 COREMARK CASE PASS case={number} d0={number//2} cache={3 if number%2 else 0} cycles={summary['compute_cycles']} retired={summary['retired']} window={summary['window']['snapshot_cycle_delta']}"
        check(marker in sim,"CASE_LOG_MARKER")
    if check_run_copy:check(read_json(root/prefix/"verification.json")==record,"RECORD_RUN_COPY")
    return dict(status="VERIFIED",sources=len(sources),case_files=len(raw),compressed_files=len(compression),
                firmware_files=len(fw_map),canonical_lf_identity_verified=True,current_raw_line_ending_differences=current_raw_differences)


def audit_case_semantics(directory,number,record=None,root=ROOT):
    if record is None:record=read_json(root/"build/cpu5_s18_coremark/verification.json")
    result=reference_case(directory,number,local(root,record["firmware_directory"])/f"case{number}",record["run_id"])
    values=parse_console((directory/"console.txt").read_text(encoding="ascii"))
    build=record["firmware"][number]
    for key,expected in {"compiler":build["compiler"],"flags":" ".join(build["compiler_flags"]+["-lgcc"]),"memory":builder.MEM_LOCATION}.items():
        check(values[key]==expected,"CONSOLE_BUILD_METADATA",key)
    return result


def observations(cases):
    cycles={c["case"]:c["window_cycles"] for c in cases}
    return dict(window_cycles_by_case=cycles,
                cache_cycle_cost={f"{a}->{b}":cycles[b]-cycles[a] for a,b in ((0,1),(2,3)) if a in cycles and b in cycles},
                d0_cycle_saving={f"{a}->{b}":cycles[a]-cycles[b] for a,b in ((0,2),(1,3)) if a in cycles and b in cycles},
                correctness_gate=False)


def audit_complete(record,root=ROOT,full_required=True):
    receipt=validate_receipts(record,root,full_required)
    cases=[]
    for n in range(record["configurations"]):
        print("CPU5 independent audit case"+str(n),flush=True)
        cases.append(audit_case_semantics(local(root,record["case_directory"])/f"case{n}",n,record,root))
    return dict(status="PASS" if len(cases)==4 else "PARTIAL VERIFIED",run_id=record["run_id"],configurations=len(cases),
                receipt=receipt,cases=cases,observations=observations(cases),metrics_claimed="NONE",
                total_cycles=sum(c["cycles"] for c in cases),total_retired=sum(c["retired"] for c in cases),
                total_window_cycles=sum(c["window_cycles"] for c in cases),
                total_window_retired=sum(c["window_retired"] for c in cases),total_console_bytes=sum(c["console_bytes"] for c in cases))


def source_identity_chain(record,root=ROOT,source_commit=None,audit_sources=None):
    sources={**record["source_lf_sha256"]}
    for path in audit_sources or SOURCES:
        sources[path]=hashlib.sha256((root/path).read_bytes().replace(b"\r\n",b"\n")).hexdigest()
    if source_commit:
        check(re.fullmatch("[0-9a-f]{40}",source_commit) is not None,"SOURCE_COMMIT_FORMAT")
        exists=subprocess.run(["git","--no-replace-objects","cat-file","-e",source_commit+"^{commit}"],cwd=root,capture_output=True)
        check(exists.returncode==0,"SOURCE_COMMIT_MISSING")
        for path,expected in sources.items():
            blob=subprocess.check_output(["git","--no-replace-objects","show",source_commit+":"+path],cwd=root)
            check(hashlib.sha256(blob).hexdigest()==expected,"SOURCE_COMMIT_BLOB",path)
    return dict(mode="COMMITTED" if source_commit else "RUNTIME_AND_PRIVATE_SNAPSHOT",
                source_commit=source_commit,canonical_lf_sources=len(sources),index_used=False,
                no_commit_claim_for_uncommitted_sources=not bool(source_commit))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root",type=Path,default=ROOT)
    parser.add_argument("--record",type=Path)
    parser.add_argument("--source-commit")
    parser.add_argument("--allow-partial",action="store_true")
    parser.add_argument("--skip-negative",action="store_true",help="diagnostic audit only; not freezeable")
    args=parser.parse_args()
    root=args.root.resolve();record_path=args.record or root/"build/cpu5_s18_coremark/verification.json"
    record=read_json(record_path);before_record=sha(record_path)
    audit_id=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ_")+uuid.uuid4().hex[:8]
    out=local(root,"build/cpu5_s18_coremark/runs/"+record["run_id"])/"audits"/audit_id
    out.mkdir(parents=True,exist_ok=True)
    before={p:sha(root/p) for p in SOURCES}
    for path in SOURCES:
        target=out/"tested_sources"/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((root/path).read_bytes())
    result=audit_complete(record,root,not args.allow_partial)
    if args.skip_negative:
        result["status"]="DIAGNOSTIC VERIFIED"
        result["negative_evidence"]={"status":"NOT RUN"}
    elif record["configurations"]<4:
        result["negative_evidence"]={"status":"NOT RUN: partial scope"}
    else:
        from test_cpu5_coremark_evidence import run_negative_evidence
        result["negative_evidence"]=run_negative_evidence(record,out/"negative_evidence",root)
    result["source_identity"]=source_identity_chain(record,root,args.source_commit)
    check(before=={p:sha(root/p) for p in SOURCES} and sha(record_path)==before_record,"AUDIT_INPUT_CHANGED")
    result.update(audit_source_sha256=before,audit_sources_unchanged=True,record_sha256=before_record,
                  audit_directory=out.relative_to(root).as_posix(),simulations_rerun=False,
                  source_commit_required_for_delivery=args.source_commit is None)
    write(out/"audit.json",result);write(root/"build/cpu5_s18_coremark/audit.json",result)
    print(json.dumps({k:result[k] for k in ("status","configurations","total_retired","total_window_cycles","total_console_bytes")},indent=2))


if __name__=="__main__":main()

