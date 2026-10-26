"""Exercise baseline setup in a repository containing only published history.

This test builds a standalone pack (no alternates, no original commits), hydrates
the LFS working files, checks the proof, and exercises the historical Git reads.
It also requires designated rejection reasons for corrupted proofs and payloads.
"""
import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import setup_cpu5_git_baselines as bridge


def run(source, proof, destination):
    source_files={"tools/"+name:Path(__file__).parent/name for name in
                  ("setup_cpu5_git_baselines.py","test_cpu5_git_baselines.py")}
    measured_sources={name:hashlib.sha256(path.read_bytes()).hexdigest() for name,path in source_files.items()}
    destination.mkdir(parents=True, exist_ok=False)
    repository = destination / "fresh_clone"; repository.mkdir()
    bridge.git(repository, "init", "-q")
    pack = destination / "published.pack"
    source_head = bridge.git(source,"rev-parse","HEAD").decode().strip()
    with pack.open("wb") as output:
        process = subprocess.run(["git", "--no-replace-objects", "pack-objects", "--stdout", "--revs"],
                                 cwd=source, input=(source_head + "\n").encode(), stdout=output,
                                 stderr=subprocess.PIPE, env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"))
    bridge.require(process.returncode == 0, "pack export failed")
    with pack.open("rb") as stream:
        subprocess.run(["git", "index-pack", "--stdin"], cwd=repository, stdin=stream,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    bridge.git(repository, "update-ref", "refs/heads/main", source_head)
    bridge.git(repository, "symbolic-ref", "HEAD", "refs/heads/main")
    bridge.git(repository, "read-tree", "HEAD")
    bridge.require(not (repository / ".git/objects/info/alternates").exists(), "shared object database")
    for row in proof["commits"]:
        check = subprocess.run(["git", "--no-replace-objects", "cat-file", "-e", row["old"]],
                               cwd=repository, capture_output=True)
        bridge.require(check.returncode != 0, "original commit leaked into clone")
    objects = bridge.Objects(repository)
    try:
        listing = bridge.git(repository, "ls-tree", "-r", "-z", "HEAD")
        for item in listing.rstrip(b"\0").split(b"\0"):
            header, name = item.split(b"\t", 1); mode, kind, oid = header.decode().split()
            bridge.require(kind == "blob" and mode in ("100644", "100755"), "unexpected checkout mode")
            target = repository / name.decode("utf-8"); target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(objects.get(oid, "blob"))
    finally:
        objects.close()
    # Files are copied, not linked: corruption specimens cannot alter the source.
    gitdir = Path(bridge.git(source,"rev-parse","--absolute-git-dir").decode().strip())
    for path in repository.glob("docs/evidence/*/raw_evidence.zip"):
        pointer=path.read_bytes(); oid=pointer.splitlines()[1].split(b":")[1].decode()
        payload=gitdir/"lfs/objects"/oid[:2]/oid[2:4]/oid
        shutil.copyfile(payload,path)
    before = bridge.verify(repository, proof)
    bridge.require(not before["unhydrated_lfs_paths"],"test hydration failed")
    created = bridge.install(repository, proof)
    bridge.require(created == 19 and bridge.install(repository, proof) == 0, "install idempotence")
    lookups = 0
    for row in proof["commits"]:
        for prefix in ("rtl", "tb", "software", "tools"):
            alias = subprocess.check_output(["git", "ls-tree", "-r", row["old"], "--", prefix], cwd=repository)
            actual = bridge.git(repository, "ls-tree", "-r", row["new"], "--", prefix)
            bridge.require(alias == actual, "historical source lookup: " + prefix)
            lookups += 1
    sys.path.insert(0, str(repository / "tools"))
    import cpu5_stats_baseline as old_stats
    old_stats.ROOT = repository
    archive_entries = 0
    for path in ("docs/evidence/cpu5_d0_20261025", "docs/evidence/cpu5_axi_20261025"):
        _, entries = old_stats.audit_archive(repository / path)
        archive_entries += len(entries)
    # The frozen dependency chain is exercised without pretending to re-run RTL.
    rejected = []

    def reject(name, specimen, reason):
        try:
            bridge.verify(repository, specimen)
        except (ValueError, subprocess.CalledProcessError) as error:
            bridge.require(reason in str(error), name + " failed for an unexpected reason: " + str(error))
            rejected.append({"name": name, "reason": str(error)})
        else:
            raise ValueError("negative evidence accepted: " + name)

    bad = copy.deepcopy(proof); bad["commits"].pop(0)
    reject("missing_commit", bad, "exactly 19")
    bad = copy.deepcopy(proof); bad["commits"][0]["old_commit"] = base64.b64encode(b"corrupt").decode()
    reject("corrupt_original_commit", bad, "proof object hash")
    bad = copy.deepcopy(proof); bad["commits"][0]["new"] = bad["commits"][1]["new"]
    reject("duplicate_mapping", bad, "duplicate commit mapping")
    bad = copy.deepcopy(proof); bad["commits"][0]["new"] = bridge.COMMON
    reject("wrong_new_parent", bad, "commit parent chain")
    bad = copy.deepcopy(proof); key = next(iter(bad["old_trees"]))
    bad["old_trees"][key] = base64.b64encode(b"corrupt").decode()
    reject("corrupt_original_tree", bad, "proof object hash")
    bad = copy.deepcopy(proof); bad["old_trees"].pop(key)
    reject("missing_tree_proof", bad, "missing proof tree")
    bad = copy.deepcopy(proof); extra = b"unused proof"; oid = bridge.object_id("tree", extra)
    bad["old_trees"][oid] = base64.b64encode(extra).decode()
    reject("unused_tree_proof", bad, "unused proof objects")
    # Corrupt a real, small LFS working file in the independent clone.
    small = min(before["lfs_payloads"], key=lambda item: item["bytes"])
    path = repository / small["path"]; raw = path.read_bytes()
    path.write_bytes(b"bad payload\n")
    try:
        reject("corrupt_lfs_payload", proof, "LFS payload differs from original Git blob")
    finally:
        path.write_bytes(raw)
    try:
        bridge.unique([("same", 1), ("same", 2)])
    except ValueError as error:
        bridge.require("duplicate JSON key" in str(error), "JSON duplicate rejection")
        rejected.append({"name": "duplicate_json_key", "reason": str(error)})
    else:
        raise ValueError("duplicate JSON accepted")
    # A valid pointer in the working tree must not be mistaken for an expanded ZIP.
    saved_proof=destination/"proof.json"
    saved_proof.write_text(json.dumps(proof),encoding="utf-8")
    row=next(item for item in before["lfs_payloads"] if item["path"] == small["path"])
    path.write_bytes(bridge.git(repository,"cat-file","blob",row["pointer_blob"]))
    # The audit can use the copied payload cache; installation must still refuse.
    cache=repository/".git/lfs/objects"/row["sha256"][:2]/row["sha256"][2:4]/row["sha256"]
    cache.parent.mkdir(parents=True,exist_ok=True);cache.write_bytes(raw)
    refs_before=bridge.git(repository,"for-each-ref","refs/replace")
    try:
        process=subprocess.run([sys.executable,str(Path(bridge.__file__).resolve()),"--root",str(repository),
                                "--proof",str(saved_proof),"--install"],capture_output=True)
        bridge.require(process.returncode != 0 and b"LFS working files are pointers" in process.stderr,
                       "unexpanded pointer installation was accepted")
        bridge.require(bridge.git(repository,"for-each-ref","refs/replace") == refs_before,"pointer failure changed refs")
        rejected.append({"name":"unexpanded_pointer_install","reason":"LFS working files are pointers"})
    finally:
        path.write_bytes(raw)
    ref = "refs/replace/" + proof["commits"][0]["old"]
    expected = proof["commits"][0]["new"]
    bridge.git(repository, "update-ref", ref, bridge.COMMON, expected)
    refs_before = bridge.git(repository, "for-each-ref", "refs/replace")
    try:
        bridge.install(repository, proof)
    except ValueError as error:
        bridge.require("conflicting baseline alias" in str(error), "conflict rejection")
        bridge.require(bridge.git(repository, "for-each-ref", "refs/replace") == refs_before,
                       "partial ref mutation on conflict")
        rejected.append({"name": "conflicting_alias_atomic", "reason": str(error)})
    else:
        raise ValueError("conflicting alias accepted")
    bridge.git(repository, "update-ref", ref, expected, bridge.COMMON)
    after = bridge.verify(repository, proof)
    bridge.require(before == after, "positive evidence changed during negative tests")
    bridge.git(repository,"fsck","--full","--strict","--no-reflogs")
    bridge.require(measured_sources == {name:hashlib.sha256(path.read_bytes()).hexdigest()
                                        for name,path in source_files.items()},"test sources changed during run")
    bridge.require(bridge.git(source,"rev-parse","HEAD").decode().strip() == source_head,
                   "source commit changed during run")
    result = dict(status="PASS", original_commits_absent=19, object_alternates=False,
                  aliases_created=created, second_install_created=0, historical_source_tree_lookups=lookups,
                  historical_archive_entries_checked=archive_entries,
                  negative_tests=rejected, negative_rejected=len(rejected),
                  lfs_payloads_verified=len(before["lfs_payloads"]), lfs_bytes=before["lfs_bytes"],
                  simulation_rerun=False, repository=str(repository), source_commit=source_head,
                  source_sha256=measured_sources,
                  sources_unchanged=True,
                  proof_canonical_sha256=hashlib.sha256(json.dumps(proof,sort_keys=True).encode()).hexdigest())
    (destination / "verification.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=bridge.ROOT)
    parser.add_argument("--proof", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args=parser.parse_args()
    result=run(args.source.resolve(),bridge.read_json(args.proof or args.source/bridge.PROOF),args.output.resolve())
    print(json.dumps(result,indent=2))


if __name__ == "__main__": main()
