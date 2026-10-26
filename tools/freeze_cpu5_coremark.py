"""Freeze CPU5 S18 only after full raw audit, negative tests and committed source identity.

Stores exact run-relative paths in a ZIP and verifies every entry. Historical
S17 evidence is left intact. No compile, download or board measurement occurs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

import run_cpu5_coremark as runner
import verify_cpu5_coremark as verifier
from cpu5_coremark_reference import check,read_json
from test_cpu5_coremark_harness import transformed

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/cpu5_s18_coremark"
EVIDENCE=ROOT/"docs/evidence/cpu5_coremark_s18_20261026"
SELF="tools/freeze_cpu5_coremark.py"
CONTRACT="docs/cpu5_coremark_hardening_20261026.md"


def sha(path):return runner.sha(path)
def write(path,value):runner.write(path,value)


def current_source(root,path,raw,snapshot,commit):
    check(sha(snapshot)==raw,"PHASE_SNAPSHOT_HASH",path)
    canonical=snapshot.read_bytes().replace(b"\r\n",b"\n")
    check((root/path).read_bytes().replace(b"\r\n",b"\n")==canonical,"PHASE_SOURCE_LF",path)
    blob=subprocess.check_output(["git","--no-replace-objects","show",commit+":"+path],cwd=root)
    check(blob==canonical,"PHASE_SOURCE_COMMIT",path)
    return dict(runtime_raw_sha256=raw,canonical_lf_sha256=hashlib.sha256(canonical).hexdigest())


def verify_frozen(folder):
    manifest=read_json(folder/"manifest.json")
    check(manifest["status"]=="FROZEN","FROZEN_STATUS")
    for name,expected in manifest["files"].items():check(sha(folder/name)==expected,"FROZEN_FILE_HASH",name)
    entries=read_json(folder/"archive_entries.json")
    check(len(entries)==manifest["archive_entries"],"FROZEN_ENTRY_COUNT")
    with zipfile.ZipFile(folder/"raw_evidence.zip") as archive:
        check(len(archive.namelist())==len(set(archive.namelist())) and set(archive.namelist())==set(entries),"FROZEN_ENTRY_SET")
        for name,expected in entries.items():
            h=hashlib.sha256()
            with archive.open(name) as stream:
                while chunk:=stream.read(1024*1024):h.update(chunk)
            check(h.hexdigest()==expected,"FROZEN_ENTRY_HASH",name)
    return dict(status="VERIFIED",archive_bytes=(folder/"raw_evidence.zip").stat().st_size,archive_entries=len(entries))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only",action="store_true")
    parser.add_argument("--evidence",type=Path,default=EVIDENCE)
    args=parser.parse_args();folder=args.evidence
    if args.verify_only:
        print(json.dumps(verify_frozen(folder),indent=2));return
    record=read_json(OUT/"verification.json");audit=read_json(OUT/"audit.json")
    check(not folder.exists(),"FROZEN_DIRECTORY_EXISTS")
    check(audit["status"]=="PASS" and audit["configurations"]==4 and record["status"]=="SIMULATED","FULL_AUDIT_REQUIRED")
    check(audit["record_sha256"]==sha(OUT/"verification.json") and audit["run_id"]==record["run_id"],"AUDIT_RECORD_BINDING")
    check(audit["negative_evidence"]["status"]=="PASS" and audit["negative_evidence"]["rejected"]==43
          and audit["negative_evidence"]["receipt_rejected"]==13 and audit["negative_evidence"]["semantic_rejected"]==30
          and audit["negative_evidence"]["good_inputs_unchanged"],"NEGATIVE_GATE")
    check(audit["source_identity"]["mode"]=="COMMITTED" and not audit["source_commit_required_for_delivery"],"SOURCE_COMMIT_REQUIRED")
    commit=audit["source_identity"]["source_commit"]
    check(subprocess.check_output(["git","--no-replace-objects","rev-parse","HEAD"],cwd=ROOT).decode().strip()==commit,"FREEZE_HEAD_CHANGED")
    verifier.validate_receipts(record,ROOT)
    probe=read_json(OUT/"probe_verification.json")
    fw_path=ROOT/"build/cpu5_s18_coremark_firmware_checks/verification.json";fw=read_json(fw_path)
    check(probe["status"]==fw["status"]=="PASS" and probe["sources_unchanged"] and fw["sources_unchanged"],"FIXTURE_GATE")
    check(len(probe["cases"])==4 and probe["harness_mechanical_wrapper_transform"] and
          probe["timer"]==dict(executions=12,responses=12,holds=23,carries=2,wraps=1),"PROBE_CLOSURE")
    check(fw["header_guard_cases"]==20 and fw["header_guard_rejected"]==15 and
          fw["native_backend"]["rejected_wrong_pairs"]==fw["native_backend"]["accepted_correct_pairs"]==4 and
          fw["native_backend"]["semantic_regression"]["status"]=="REJECTED","FIRMWARE_IDENTITY_GATE")
    check((ROOT/"tb/cpu5_coremark_harness.v").read_text(encoding="utf-8")==transformed(),"HARNESS_DERIVATION")
    audit_dir=ROOT/audit["audit_directory"];stage=ROOT/record["positive"]["directory"]
    files={}
    def include(path,expected=None):
        key=path.relative_to(ROOT).as_posix()
        check(path.is_file(),"FREEZE_INPUT_MISSING",key)
        actual=sha(path)
        if expected:check(actual==expected,"FREEZE_INPUT_HASH",key)
        if key in files:check(files[key]["sha256"]==actual,"FREEZE_DUPLICATE_DIVERGED",key)
        files[key]=dict(path=path,sha256=actual)
    identities={}
    for name,raw in record["source_sha256"].items():
        identities[name]=current_source(ROOT,name,raw,stage/name,commit);include(stage/name,raw)
    for name,raw in audit["audit_source_sha256"].items():
        identities[name]=current_source(ROOT,name,raw,audit_dir/"tested_sources"/name,commit)
    for name,raw in probe["source_sha256"].items():
        identities[name]=current_source(ROOT,name,raw,ROOT/probe["directory"]/name,commit)
        include(ROOT/probe["directory"]/name,raw)
    for name,raw in fw["source_sha256"].items():
        identities[name]=current_source(ROOT,name,raw,fw_path.parent/"tested_sources"/name,commit)
    for name in (SELF,CONTRACT,"README.md"):
        data=(ROOT/name).read_bytes();blob=subprocess.check_output(["git","--no-replace-objects","show",commit+":"+name],cwd=ROOT)
        check(data.replace(b"\r\n",b"\n")==blob,"FREEZER_SOURCE_COMMIT",name)
        identities[name]=dict(runtime_raw_sha256=hashlib.sha256(data).hexdigest(),canonical_lf_sha256=hashlib.sha256(blob).hexdigest())
    before_sources={p:sha(ROOT/p) for p in identities}
    for p,expected in record["raw_artifact_sha256"].items():include(ROOT/p,expected)
    for p,expected in record["firmware_artifact_sha256"].items():include(ROOT/p,expected)
    for p,expected in record["positive"]["retained_artifact_sha256"].items():include(stage/p,expected)
    for p,expected in probe["artifact_sha256"].items():include(ROOT/p,expected)
    for p,expected in fw["retained_artifact_sha256"].items():include(ROOT/p,expected)
    for path in audit_dir.rglob("*"):
        if path.is_file():include(path)
    for name in ("verification.json","audit.json","probe_verification.json"):include(OUT/name)
    include(fw_path);include((stage.parent)/"verification.json")
    for name in identities:include(ROOT/name)
    folder.mkdir(parents=True)
    (folder/".gitattributes").write_bytes(b"* -text\n")
    entries={name:row["sha256"] for name,row in sorted(files.items())}
    with zipfile.ZipFile(folder/"raw_evidence.zip","w",zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name,row in sorted(files.items()):archive.write(row["path"],name)
    check(before_sources=={p:sha(ROOT/p) for p in identities},"FREEZE_SOURCE_CHANGED")
    check(all(sha(row["path"])==row["sha256"] for row in files.values()),"FREEZE_INPUT_CHANGED")
    write(folder/"archive_entries.json",entries)
    write(folder/"verification.json",audit)
    write(folder/"selected_runs.json",dict(real_coremark_run_id=record["run_id"],probe_run_id=probe["run_id"],
        real_coremark_cases=4,quick_probes_used_as_coremark=False,source_commit=commit,
        reused_historical_s17_runs=[],fresh_four_configuration_simulation=True,
        metrics_claimed="NONE",formal_score=False,board_test=False))
    write(folder/"source_identity.json",dict(source_commit=commit,sources=identities,
        source_count=len(identities),all_phases_match_committed_lf=True,index_used=False))
    (folder/"README.md").write_text(
        "# CPU5 CoreMark S18 evidence (2026-10-26)\n\n"
        "Four fresh real RV32IM CoreMark smoke cases; performance seeds, one iteration. "
        "Raw edge/native/retire/Stats/timer traces and exact images are in raw_evidence.zip. "
        "The independent interpreter replays every retired instruction and rebuilds final RAM.\n\n"
        "43 receipt/semantic negative cases were rejected, including coherent metadata forgery. "
        "Short drain/timer probes are separate fixtures; the 8 backend init cases execute actual "
        "production C on Windows and do not claim RV32 wrong-image hardware execution. "
        "No formal CoreMark score, P&R/STA, bitstream or board performance is claimed.\n\n"
        "Replay: extract the ZIP at a clean checkout of source_commit, run "
        "tools/verify_cpu5_coremark.py with --source-commit set to that commit. "
        "The recorded runtime D: junction may be replaced by ordinary extracted build directories.\n",
        encoding="utf-8",newline="\n")
    names=[p.name for p in folder.iterdir() if p.is_file()]
    manifest=dict(status="FROZEN",source_commit=commit,real_run_id=record["run_id"],archive_entries=len(entries),
        archive_bytes=(folder/"raw_evidence.zip").stat().st_size,
        files={name:sha(folder/name) for name in sorted(names)},
        simulations_this_milestone=4,rtl_modified=False,formal_score=False,board_test=False)
    write(folder/"manifest.json",manifest)
    print(json.dumps(verify_frozen(folder),indent=2))


if __name__=="__main__":main()

