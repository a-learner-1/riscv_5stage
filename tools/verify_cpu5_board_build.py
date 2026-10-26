"""Independently recheck CPU5 timing/bitstream receipts and board smoke evidence."""
import argparse,hashlib,json,re,subprocess
from pathlib import Path,PurePosixPath
import build_cpu5_pds as build
import cpu5_board_contract as contract
import build_cpu5_board_images as firmware
import run_cpu5_board_smoke as smoke
import run_cpu5_board_regressions as controls
from build_pds_board import read_final_sta_report,read_post_route_timing_report
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s19"
FDC_LF_SHA="1792b2880f9ef18991ea6a43fb85acf6d06952606b7dec8526cc99be9de4bec0"
sha=build.sha
read=lambda p:json.loads(p.read_text(encoding="utf-8"))

def require(ok,label):
    if not ok:raise ValueError(label)

def local(root,name):
    require(isinstance(name,str) and "\\" not in name and ":" not in name and not name.startswith("/") and
        ".." not in PurePosixPath(name).parts and str(PurePosixPath(name))==name,"receipt relative path")
    return root/name

def fixed_constraints(text):
    require(hashlib.sha256(text.replace("\r\n","\n").encode()).hexdigest()==FDC_LF_SHA,
        "CPU5 fixed 50 MHz pins and timing exceptions")
    build.validate_constraints(text)

def hashes(root,mapping):
    require(bool(mapping),"empty artifact receipt")
    for name,expected in mapping.items():
        p=local(root,name)
        require(re.fullmatch("[0-9a-f]{64}",expected) is not None and p.is_file() and sha(p)==expected,"artifact "+name)

def sources(root,stage,mapping,expected):
    require(set(mapping)==set(expected),"source closure")
    for name,h in mapping.items():
        snapshot=stage/"tested_sources"/name
        require(snapshot.is_file() and sha(snapshot)==h,"source snapshot "+name)
        require(local(root,name).read_bytes().replace(b"\r\n",b"\n")==snapshot.read_bytes().replace(b"\r\n",b"\n"),
            "current source "+name)

def audit_pds(root,record,bit=False):
    require(record["status"]==("BITSTREAM_VERIFIED_NOT_DOWNLOADED" if bit else "TIMING_VERIFIED"),"PDS status")
    require(record["sources_unchanged"] and not record["hardware_download_performed"] and not record["formal_score_measured"],"PDS scope")
    require(record["hardware"]==contract.CONFIG,"PDS hardware")
    stage=local(root,record["directory"])
    expected=build.SOURCES+ (["tools/build_cpu5_bitstream.py"] if bit else [])
    sources(root,stage,record["source_sha256"],expected)
    hashes(stage,record["retained_artifact_sha256"]);hashes(stage,record["firmware_artifact_sha256"])
    fixed_constraints((stage/"tested_sources/pds/board_top.fdc").read_text())
    top=(stage/"board_top.sv").read_text()
    paths=[re.findall(r'localparam '+key+r' = "([^"]+)";',top) for key in ("PROGRAM_FILE","DATA_FILE")]
    require(all(len(p)==1 for p in paths),"PDS image constants")
    for p,name in zip(paths,("program.hex","program_data.hex")):
        require(p[0].endswith("/"+record["run_id"]+"/firmware/"+name),"PDS own image directory")
    expected_top=contract.bind_top((stage/"tested_sources"/contract.TOP).read_text(),*[Path(p[0]) for p in paths])
    require(top==expected_top and sha(stage/"board_top.sv")==record["generated_top_sha256"],"PDS exact generated top")
    report=stage/"report_timing/board_top.rtr"
    rows,pulse=read_final_sta_report(report,0)
    router=read_post_route_timing_report(stage/"place_route/board_top_timing_summary_after_hold_fix.txt",0)
    rows,pulse,router=([list(row) for row in table] for table in (rows,pulse,router))
    require(rows==record["final_sta_rows"] and pulse==record["final_sta_pulse_width_rows"] and
        router==record["post_route_timing_rows"],"PDS timing rows")
    require(sha(report)==record["final_sta_report_sha256"] and sha(stage/"place_route/board_top_pnr.adf")==record["route_sha256"],"PDS route/STA binding")
    log=(stage/("bitstream_generation.log" if bit else "pds_console.log")).read_text(errors="replace")
    require(not re.search(r"STA-3001|(?m:^\s*E:)|Program Error Out",log),"PDS errors/auto timing cut")
    resources=build.resources(log)
    if not bit:require(resources==record["synthesis_resources"],"synthesis resource receipt")
    netlist=(stage/"place_route/board_top_pnr.netlist").read_text(errors="replace")
    d0=re.findall(r"(?m)^u_soc/u_core/u_backend/g_d0\.u_ram/u_data_mem/mem[^;]+;gopDRM$",netlist)
    require(len(d0)==8,"actual D0 RAM must map to eight DRM18K instances")
    mapping=(stage/"synthesize/apm_drm_lutram_utilization.log").read_text(errors="replace")
    require("u_soc/u_core/u_backend/g_d0.u_ram/u_data_mem/mem" in mapping and mapping.count("SIMPLE_DUAL_PORT")>=8,"D0 mapping proof")
    fw=read(stage/"firmware/build.json")
    require(fw["profile"]==record["profile"] and fw["hardware"]==contract.CONFIG and
        fw["config"]=={k:str(v) for k,v in firmware.config(record["profile"]).items()},"PDS firmware configuration")
    require(set(fw["sources_sha256"])==set(firmware.SOURCES),"firmware source closure")
    for p,h in fw["sources_sha256"].items():require(sha(stage/"tested_sources"/p)==h,"firmware source "+p)
    hashes(stage/"firmware",fw["artifacts_sha256"])
    if bit:
        timing_path=local(root,record["timing_input_record"])
        timing=read(timing_path)
        require(sha(timing_path)==record["timing_input_sha256"] and
            timing["run_id"]==record["timing_input_run_id"] and timing["profile"]==record["profile"] and
            timing["route_sha256"]==record["timing_input_route_sha256"],"bitstream timing input chain")
        require(record["bitstream_generated"] and record["final_sta_from_bitstream_flow"],"bitstream timing scope")
        require(set(record["bitstreams"])=={"generate_bitstream/board_top.sbit","generate_bitstream/board_top.bin"},"SBIT/BIN closure")
        hashes(stage,record["bitstreams"])
    return dict(profile=record["profile"],bitstream=bit,run_id=record["run_id"],resources=resources,
        setup_wns_ns=float(rows[0][0]),hold_whs_ns=float(rows[5][0]),d0_drm18k_instances=len(d0))

def audit_smoke(root,record):
    require(record["status"]=="PASS" and record["sources_unchanged"] and record["hardware"]==contract.CONFIG,"board smoke status")
    require(not record["hardware_download_performed"] and not record["formal_score_measured"],"board smoke scope")
    stage=local(root,record["directory"])
    sources(root,stage,record["source_sha256"],smoke.SOURCES)
    hashes(stage,record["retained_sha256"])
    result=[smoke.audit_case(stage/"raw"/p,p) for p in smoke.PROFILES]
    require(result==record["cases"],"independently parsed board smoke cases")
    return [dict(profile=c["profile"],cycles=c["summary"]["cycles"],window_cycles=c["summary"]["window_cycles"],
        uart_frames=c["summary"]["uart_frames"],crc=c["console_values"]["seedcrc"]) for c in result]

def audit_controls(root,record):
    require(record["status"]=="PASS" and record["sources_unchanged"],"control regression status")
    stage=local(root,record["directory"])
    sources(root,stage,record["source_sha256"],controls.SOURCES)
    hashes(root,record["retained_artifact_sha256"])
    groups=record["groups"]
    require([g["name"] for g in groups]==["ram","trap","run_cpu5_csr_control","run_cpu5_irq_control","run_cpu5_m_control","run_cpu5_fence_control"],"six control groups")
    for group in groups:
        require(group["status"]=="PASS","control group")
        if "verification" in group:
            path=local(root,group["verification"]);require(sha(path)==group["verification_sha256"],"control verification receipt")
            v=read(path);require(v["status"]=="PASS" and v["sources_unchanged"],"control child result")
    return [g["name"] for g in groups]

def audit_guards(root,record):
    import test_cpu5_board_delivery as guards
    require(record["status"]=="PASS" and record["sources_unchanged"],"board guards status")
    stage=local(root,record["directory"])
    require(set(record["source_sha256"])==set(guards.SOURCES),"board guard source closure")
    hashes(stage,record["source_sha256"]);hashes(stage,record["retained_sha256"])
    for p in record["source_sha256"]:
        require(local(root,p).read_bytes().replace(b"\r\n",b"\n")==local(stage,p).read_bytes().replace(b"\r\n",b"\n"),"board guard current source")
    require(record["negative_count"]==len(set(record["negatives_rejected"]))==47 and
        record["existing_final_sta_guard_tests"]==9 and record["redirect_protocol_checks"]==11,"board guard coverage")
    return dict(negative_count=47,existing_final_sta_guard_tests=9,redirect_protocol_checks=11)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root",type=Path,default=ROOT)
    ap.add_argument("--timing-only",action="store_true")
    ap.add_argument("--source-commit")
    ap.add_argument("--repository",type=Path)
    args=ap.parse_args();root=args.root;out=root/"build/cpu5_s19"
    profiles=["performance"] if args.timing_only else ["performance","validation"]
    result=dict(status="TIMING ONLY DIAGNOSTIC" if args.timing_only else "LOCAL VERIFIED",hardware_download_performed=False,
        formal_score_measured=False,pds=[],source_commit=args.source_commit)
    all_sources=set()
    for profile in profiles:
        for kind,bit in (("pds",False),("bitstream",True)):
            path=out/(kind+"_"+profile+".json")
            record=read(path);result["pds"].append(audit_pds(root,record,bit));all_sources.update(record["source_sha256"])
    if not args.timing_only:
        result["board_smoke"]=audit_smoke(root,read(out/"board_smoke.json"))
        result["control_groups"]=audit_controls(root,read(out/"control_regressions.json"))
        guards=read(out/"guards.json")
        result["guards"]=audit_guards(root,guards);all_sources.update(guards["source_sha256"])
        compatibility=read(root/"build/cpu5_s18_coremark/verification.json")
        import verify_cpu5_coremark as compat
        compat.validate_receipts(compatibility,root,True)
        audit=read(root/"build/cpu5_s18_coremark/audit.json")
        require(audit["status"]=="DIAGNOSTIC VERIFIED" and audit["configurations"]==4 and audit["record_sha256"]==sha(root/"build/cpu5_s18_coremark/verification.json"),"four-case independent RV32IM replay")
        result["compatibility"]={k:audit[k] for k in ("status","total_retired","total_window_cycles","record_sha256")}
        replay=compat.audit_complete(compatibility,root,True)
        require(replay["total_retired"]==audit["total_retired"] and replay["total_window_cycles"]==audit["total_window_cycles"],"fresh compatibility replay")
        result["compatibility"]["fresh_replay_performed"]=True
        all_sources.update(compatibility["source_sha256"])
        all_sources.update(smoke.SOURCES);all_sources.update(controls.SOURCES)
    all_sources.update(["tools/verify_cpu5_board_build.py","tb/cpu5_redirect_timing_tb.v"])
    if args.source_commit:
        require(re.fullmatch("[0-9a-f]{40}",args.source_commit) is not None,"source commit")
        repository=args.repository or root
        for name in sorted(all_sources):
            blob=subprocess.check_output(["git","--no-replace-objects","show",args.source_commit+":"+name],cwd=repository)
            require(blob==local(root,name).read_bytes().replace(b"\r\n",b"\n"),"source commit blob "+name)
        result["source_files_verified"]=len(all_sources)
        if not args.timing_only:result["status"]="COMMITTED SOURCES VERIFIED"
    build.write(out/"audit.json",result)
    print(json.dumps(result,indent=2))

if __name__=="__main__":main()

