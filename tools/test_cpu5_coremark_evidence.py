"""Two layers of negative evidence: receipts and independent raw semantics.

Semantic specimens deliberately bypass container hashes. A rejection must match
the designated semantic assertion; a random parse/hash failure does not count.
"""
import copy
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil

import cpu5_coremark_reference as ref
import run_cpu5_coremark as runner


def write_json(path,value):runner.write(path,value)


def edit_json(directory,callback):
    path=directory/"summary.json";data=ref.read_json(path);callback(data);write_json(path,data)


def edit_csv(directory,name,select,callback):
    path=directory/(name+".csv");zipped=False
    if not path.exists():path=directory/(name+".csv.gz");zipped=True
    opener=gzip.open if zipped else open
    with opener(path,"rt",encoding="ascii",newline="") as stream:
        reader=csv.DictReader(stream);header=reader.fieldnames;data=list(reader)
    target=next(row for row in data if select(row));callback(target)
    output=io.StringIO(newline="");writer=csv.DictWriter(output,fieldnames=header,lineterminator="\n")
    writer.writeheader();writer.writerows(data)
    if zipped:
        with gzip.open(path,"wb") as stream:stream.write(output.getvalue().encode("ascii"))
    else:path.write_bytes(output.getvalue().encode("ascii"))


def inc_hex(row,key):row[key]=f"{int(row[key],16)+1:0{len(row[key])}x}"


def console_set(directory,key,change):
    path=directory/"console.txt";text=path.read_text(encoding="ascii")
    pattern=r"(?m)^(COREMARK "+re.escape(key)+r"=)([^\r\n]*)$"
    matches=list(re.finditer(pattern,text));ref.check(len(matches)==1,"MUTATION_TARGET",key)
    new=re.sub(pattern,lambda match:match[1]+str(change(match[2])),text)
    path.write_bytes(new.encode("ascii"))


def isa_selftest():
    vectors=[
      (0,0xffffffff,2,0xfffffffe),(1,0xffffffff,2,0xffffffff),
      (2,0xffffffff,0xffffffff,0xffffffff),(3,0xffffffff,0xffffffff,0xfffffffe),
      (4,0xfffffff9,3,0xfffffffe),(6,0xfffffff9,3,0xffffffff),
      (4,7,0xfffffffd,0xfffffffe),(6,7,0xfffffffd,1),
      (5,0xffffffff,2,0x7fffffff),(7,0xffffffff,2,1),
      (4,0x12345678,0,0xffffffff),(5,0x12345678,0,0xffffffff),
      (6,0x12345678,0,0x12345678),(7,0x12345678,0,0x12345678),
      (4,0x80000000,0xffffffff,0x80000000),(6,0x80000000,0xffffffff,0),
      (1,0x80000000,0x80000000,0x40000000),(2,0x80000000,0xffffffff,0x80000000),
    ]
    checked=0
    for f,a,b,value in vectors:
        word=(1<<25)|(2<<20)|(1<<15)|(f<<12)|(3<<7)|0x33
        model=ref.Architecture([word]);model.reg[1]=a;model.reg[2]=b
        row=dict(pc=0,instr=word,rd=3,writes=1,value=value,seq=0)
        model.retire(row,None);ref.check(model.reg[3]==value,"ISA_SELFTEST");checked+=1
        bad=dict(row,value=value^1)
        try:
            model=ref.Architecture([word]);model.reg[1]=a;model.reg[2]=b;model.retire(bad,None)
        except ValueError as error:ref.check(str(error).startswith("ISA_RESULT"),"ISA_SELFTEST_REJECTION")
        else:raise ValueError("incorrect arithmetic reference accepted")
    for word,value in ((0x00108183,0xffffffa5),(0x0010c183,0xa5)):
        model=ref.Architecture([word]);model.reg[1]=0x10000
        model.retire(dict(pc=0,instr=word,rd=3,writes=1,value=value,seq=0),
            dict(pc=0,seq=0,addr=0x10001,size=0,is_write=0,wstrb=0,wdata=0,rdata=0xa500))
        ref.check(model.reg[3]==value,"ISA_LOAD_SELFTEST");checked+=1
    model=ref.Architecture([0x002080a3]);model.reg[1]=0x10000;model.reg[2]=0xa5
    model.retire(dict(pc=0,instr=0x002080a3,rd=0,writes=0,value=0,seq=0),
        dict(pc=0,seq=0,addr=0x10001,size=0,is_write=1,wstrb=2,wdata=0xa500,rdata=0));checked+=1
    for equal in (False,True):
        model=ref.Architecture([0x00208463]);model.reg[1]=1;model.reg[2]=1 if equal else 2
        model.retire(dict(pc=0,instr=0x00208463,rd=0,writes=0,value=0,seq=0),None)
        ref.check(model.pc==(8 if equal else 4),"ISA_BRANCH_SELFTEST");checked+=1
    return dict(status="PASS",positive_vectors=checked,incorrect_m_results_rejected=len(vectors))


def run_negative_evidence(record,out,root):
    import verify_cpu5_coremark as verifier
    out.mkdir(parents=True,exist_ok=False)
    record_before=json.dumps(record,sort_keys=True)
    runtime_before={p:runner.sha(root/p) for p in record["source_sha256"]}
    probe=ref.read_json(root/"build/cpu5_s18_coremark/probe_verification.json")
    ref.check(probe["status"]=="PASS" and probe["sources_unchanged"] and len(probe["cases"])==4,"NEGATIVE_PROBE_INPUT")
    good=root/probe["case_directory"]/"case0";firmware=root/probe["firmware_directory"]/"case0"
    probe_before={p.relative_to(good).as_posix():runner.sha(p) for p in good.rglob("*") if p.is_file()}
    original=ref.audit_case(good,0,firmware,probe["run_id"],allow_probe=True)
    rejected=[]
    def reject(name,phase,reason,action,directory=None):
        try:action()
        except (ValueError,KeyError,AssertionError) as error:
            ref.check(str(error).startswith(reason),"NEGATIVE_WRONG_REASON",name+": "+str(error))
            rejected.append(dict(name=name,phase=phase,status="REJECTED",expected_assertion=reason,actual_assertion=str(error),
                                 directory=directory.relative_to(root).as_posix() if directory else None))
        else:raise ValueError("NEGATIVE_ACCEPTED: "+name)
    receipt_specs=[
      ("zero_cases","SCOPE_CASE_COUNT",lambda r:r.update(configurations=0)),
      ("partial_disguised_full","SCOPE_FULL_FOUR_REQUIRED",lambda r:r.update(configurations=3)),
      ("label_only_pass","SCOPE_SIMULATED_REQUIRED",lambda r:r.update(status="PASS")),
      ("mixed_run_id","RUN_DIRECTORIES",lambda r:r.update(run_id="20260101T000000000000Z_00000000")),
      ("stale_case_directory","RUN_DIRECTORIES",lambda r:r.update(case_directory="build/cpu5_s17_coremark/cases")),
      ("formal_score_claim","SCOPE_NO_SCORE",lambda r:r.update(metrics_claimed="CoreMark/MHz")),
      ("source_closure_missing","SOURCE_CLOSURE",lambda r:r["source_sha256"].pop(next(iter(r["source_sha256"])))),
      ("bad_snapshot_hash","SNAPSHOT_HASH",lambda r:(r["source_sha256"].update({next(iter(r["source_sha256"])):"0"*64}),
                            r["positive"]["source_sha256"].update({next(iter(r["source_sha256"])):"0"*64}))),
      ("missing_case_receipt","RAW_ARTIFACT_CLOSURE",lambda r:r["raw_artifact_sha256"].pop(next(iter(r["raw_artifact_sha256"])))),
      ("bad_case_receipt_hash","RECEIPT_HASH",lambda r:r["raw_artifact_sha256"].update({next(iter(r["raw_artifact_sha256"])):"0"*64})),
      ("bad_compressed_raw_identity","COMPRESSION_RAW_HASH",lambda r:next(iter(r["compressed_artifacts"].values())).update(raw_sha256="0"*64)),
      ("bad_firmware_receipt","RECEIPT_HASH",lambda r:r["firmware_artifact_sha256"].update({next(iter(r["firmware_artifact_sha256"])):"0"*64})),
      ("process_exit_nonzero","PROCESS_STATUS",lambda r:r["processes"][1].update(exit_code=1)),
    ]
    for name,reason,mutate in receipt_specs:
        bad=copy.deepcopy(record);mutate(bad);path=out/"receipts"/(name+".json");write_json(path,bad)
        reject(name,"receipt",reason,lambda bad=bad:verifier.validate_receipts(bad,root,check_run_copy=False),path.parent)
    def json_bump(key,delta=1):
        return lambda d:edit_json(d,lambda s:s.update({key:s[key]+delta}))
    def csv_bump(name,select,key):
        return lambda d:edit_csv(d,name,select,lambda row:inc_hex(row,key))
    def coherent_retire_value(d):
        for event in ("retire","wb"):
            edit_csv(d,"retire",lambda row,event=event:row["event"]==event,
                     lambda row:inc_hex(row,"value"))
    def coherent_retire_pc(d):
        for event in ("retire","wb"):
            edit_csv(d,"retire",lambda row,event=event:row["event"]==event,
                     lambda row:row.update(pc="00000004"))
    def duplicate_summary(d):
        path=d/"summary.json";raw=path.read_text();path.write_text(raw.replace("{",'{"retired":18,',1))
    specs=[
      ("summary_total_balanced_forgery","TOTAL_RETIRE_WB",lambda d:edit_json(d,lambda s:s.update(retired=s["retired"]+1,writebacks=s["writebacks"]+1))),
      ("summary_timer_forgery","RAW_TIMER_SUMMARY",lambda d:edit_json(d,lambda s:s["timer"].update(raw_ticks=s["timer"]["raw_ticks"]+1))),
      ("summary_window_forgery","RAW_WINDOW_SUMMARY",lambda d:edit_json(d,lambda s:s["window"].update(snapshot_cycle_delta=s["window"]["snapshot_cycle_delta"]+1))),
      ("summary_class_forgery","RAW_PROFILE_SUMMARY",lambda d:edit_json(d,lambda s:s["profile"]["delta"].__setitem__(0,s["profile"]["delta"][0]+1))),
      ("terminal_seq_forgery","TERMINAL_DESCRIPTOR",csv_bump("terminal",lambda row:row["event"]=="wb","seq")),
      ("terminal_failure_value","TERMINAL_VALUE",lambda d:edit_csv(d,"terminal",lambda r:r["event"]=="req",lambda r:r.update(value="00000002"))),
      ("native_rsp_seq_forgery","NATIVE_DESCRIPTOR",csv_bump("native",lambda row:row["event"]=="rsp","seq")),
      ("timer_data_forgery","TIMER_DATA",csv_bump("timer",lambda row:True,"data")),
      ("timer_clock_forgery","TIMER_INDEPENDENT_CLOCK",csv_bump("timer",lambda row:True,"mtime")),
      ("wb_packet_forgery","WB_PACKET",csv_bump("retire",lambda row:row["event"]=="wb","value")),
      ("retire_wb_coherent_value_forgery","ISA_RESULT",coherent_retire_value),
      ("retire_wb_coherent_pc_forgery","ISA_PC_INSTRUCTION",coherent_retire_pc),
      ("edge_instret_forgery","EDGE_COUNTER",lambda d:edit_csv(d,"edges",lambda row:True,lambda r:r.update(instret="1"))),
      ("edge_counter_forgery","EDGE_COUNTER",lambda d:edit_csv(d,"edges",lambda row:True,lambda r:r.update(count="1"))),
      ("non_one_hot_event","EVENT_ONE_HOT",lambda d:edit_csv(d,"edges",lambda row:row["cycle"]=="2",lambda r:r.update(events="003"))),
      ("trigger_owner_forgery","TRIGGER_NATIVE_OWNER",csv_bump("triggers",lambda row:True,"d_seq")),
      ("trigger_event_gold_forgery","TRIGGER_GOLD",lambda d:edit_csv(d,"triggers",lambda row:True,lambda r:r.update(p0=str(int(r["p0"])+1)))),
      ("stats_frozen_data_forgery","STATS_BANK_DATA",csv_bump("stats",lambda row:row["event"]=="rsp","data")),
      ("final_ram_forgery","RAM_FINAL_IMAGE",lambda d:(d/"actual_ram.hex").write_text("00000000\n"*4096)),
      ("uart_serial_forgery","UART_PIN_NATIVE_MATCH",lambda d:(d/"uart_serial.txt").write_bytes(b"junk")),
      ("if_drain_forgery","DRAIN_STRUCTURE",lambda d:edit_json(d,lambda s:s["drain"].update(if_returned=s["drain"]["if_returned"]-1))),
      ("drain_tail_forgery","DRAIN_TAIL",lambda d:edit_json(d,lambda s:s["drain"].update(tail_cycles=s["drain"]["tail_cycles"]+1))),
      ("summary_terminal_seq_forgery","SUMMARY_TOHOST_IDENTITY",lambda d:edit_json(d,lambda s:s["tohost"].update(seq="0000000000000011"))),
      ("quick_probe_disguised_full","QUICK_PROBE_SCOPE",lambda d:edit_json(d,lambda s:s.update(quick_probe=0))),
      ("duplicate_summary_key","JSON_DUPLICATE",duplicate_summary),
    ]
    for name,reason,mutate in specs:
        directory=out/"semantic"/name;shutil.copytree(good,directory);mutate(directory)
        reject(name,"semantic_fixture",reason,lambda directory=directory:ref.audit_case(directory,0,firmware,probe["run_id"],allow_probe=True),directory)
    real=root/record["case_directory"]/"case0";full_fw=root/record["firmware_directory"]/"case0"
    def full_test(name,reason,mutate,consistent=False):
        directory=out/"semantic_full"/name;shutil.copytree(real,directory);mutate(directory)
        if consistent:ref.precheck(directory,0,record["run_id"])
        reject(name,"semantic_real_coremark",reason,lambda:ref.audit_case(directory,0,full_fw,record["run_id"]),directory)
    def coherent_counter(d):
        edit_json(d,lambda s:(s["window"].update(stop_cycle=s["window"]["stop_cycle"]+1,
                       snapshot_cycle_delta=s["window"]["snapshot_cycle_delta"]+1),
                       s["profile"]["stop"].__setitem__(0,s["profile"]["stop"][0]+1),
                       s["profile"]["delta"].__setitem__(0,s["profile"]["delta"][0]+1)))
        for key in ("counter_cycles","cycle_work_other","cycle_profile_sum","window_tick_gap"):console_set(d,key,lambda value:int(value)+1)
        window=ref.read_json(d/"summary.json")["window"]
        console_set(d,"counter_cpi",lambda value:f"{window['snapshot_cycle_delta']/window['snapshot_instret_delta']:.9f}")
        edit_csv(d,"triggers",lambda r:r["kind"]=="stop",lambda r:r.update(count=str(int(r["count"])+1),p0=str(int(r["p0"])+1)))
    full_test("coherent_console_summary_trigger_forgery","TRIGGER_GOLD",coherent_counter,consistent=True)
    def coherent_ticks(d):
        edit_json(d,lambda s:s["timer"].update(stop_ticks=s["timer"]["stop_ticks"]+1,raw_ticks=s["timer"]["raw_ticks"]+1))
        console_set(d,"raw_ticks",lambda value:int(value)+1);console_set(d,"window_tick_gap",lambda value:int(value)-1)
    full_test("coherent_ticks_and_gap_forgery","RAW_TIMER_SUMMARY",coherent_ticks)
    full_test("duplicate_console_key","CONSOLE_DUPLICATE",lambda d:(d/"console.txt").write_bytes((d/"console.txt").read_bytes()+b"COREMARK raw_ticks=1\n"))
    full_test("junk_console_record","CONSOLE_SYNTAX",lambda d:(d/"console.txt").write_bytes((d/"console.txt").read_bytes()+b"COREMARK broken-record\n"))
    full_test("numeric_console_junk","RAW_CONSOLE_VALUE",lambda d:console_set(d,"raw_ticks",lambda value:value+"x"))
    # A performance improvement must not trip a correctness assertion.
    sample=[dict(case=0,window_cycles=100),dict(case=1,window_cycles=50),
            dict(case=2,window_cycles=120),dict(case=3,window_cycles=60)]
    observed=verifier.observations(sample)
    ref.check(observed["cache_cycle_cost"]=={"0->1":-50,"2->3":-60} and not observed["correctness_gate"],"PERFORMANCE_ORDER_GATE")
    arithmetic=isa_selftest()
    ref.check(record_before==json.dumps(record,sort_keys=True) and runtime_before=={p:runner.sha(root/p) for p in runtime_before},"NEGATIVE_INPUT_CHANGED")
    ref.check(probe_before=={p.relative_to(good).as_posix():runner.sha(p) for p in good.rglob("*") if p.is_file()},"NEGATIVE_GOOD_FIXTURE_CHANGED")
    # Recheck untouched raw receipt hashes after every specimen has finished.
    for p,expected in record["raw_artifact_sha256"].items():ref.check(runner.sha(root/p)==expected,"NEGATIVE_GOOD_RAW_CHANGED")
    result=dict(status="PASS",rejected=len(rejected),receipt_rejected=sum(r["phase"]=="receipt" for r in rejected),
        semantic_rejected=sum(r["phase"]!="receipt" for r in rejected),specimens=rejected,
        common_mode_metadata_consistent_but_raw_edges_rejected=True,arithmetic_reference=arithmetic,
        performance_ordering_observational=True,good_inputs_unchanged=True,quick_fixture_positive=original)
    write_json(out/"verification.json",result)
    return result

