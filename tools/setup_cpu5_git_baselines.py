"""Verify the CPU5 LFS migration and optionally install local baseline aliases.

The aliases are Git replacement refs, not recreated original commits. They let
historical tools read unchanged source/manifest blobs using their recorded IDs.
ZIP blobs are LFS pointers in the replacement trees. No ref is pushed by this
tool; a fresh clone must run this setup explicitly.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PROOF = "docs/cpu5_lfs_migration_20261026.json"
OLD_HEAD = "a8bcedf971b172436d9a14adb6d59df5c19c8d9c"
NEW_HEAD = "4299b9ec38520ac480b70250d23bfe2f3be8fad5"
COMMON = "1b7cb1251f5ff589ab1a6be8537b3362cc3f3a73"
RULE = b"docs/evidence/**/raw_evidence.zip filter=lfs diff=lfs merge=lfs -text\n"
OID = re.compile(r"[0-9a-f]{40}\Z")
ZIP_PATH = re.compile(r"docs/evidence/[^/]+/raw_evidence\.zip\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def git(root, *arguments, data=None):
    env = dict(os.environ, GIT_NO_REPLACE_OBJECTS="1")
    return subprocess.check_output(["git", "--no-replace-objects", *arguments],
                                   cwd=root, input=data, env=env)


def object_id(kind, data):
    return hashlib.sha1(kind.encode() + b" " + str(len(data)).encode() + b"\0" + data).hexdigest()


def decode(encoded, kind, oid):
    require(OID.fullmatch(oid), "invalid object ID")
    data = base64.b64decode(encoded, validate=True)
    require(object_id(kind, data) == oid, "proof object hash: " + oid)
    return data


class Objects:
    """Read real objects even if the checkout already has replacement refs."""
    def __init__(self, root):
        self.process = subprocess.Popen(["git", "--no-replace-objects", "cat-file", "--batch"],
                                        cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE,
                                        env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"))
        self.cache = {}

    def get(self, oid, kind):
        require(OID.fullmatch(oid), "invalid requested object")
        if oid not in self.cache:
            self.process.stdin.write((oid + "\n").encode()); self.process.stdin.flush()
            header = self.process.stdout.readline().decode().strip().split()
            require(len(header) == 3 and header[0] == oid, "missing real Git object: " + oid)
            data = self.process.stdout.read(int(header[2]))
            require(self.process.stdout.read(1) == b"\n", "truncated Git object")
            require(object_id(header[1], data) == oid, "Git object hash mismatch")
            self.cache[oid] = (header[1], data)
        actual_kind, data = self.cache[oid]
        require(actual_kind == kind, "unexpected Git object type")
        return data

    def close(self):
        self.process.stdin.close(); self.process.stdout.close()
        self.process.wait(timeout=10); self.process.stderr.close()


def tree(data):
    entries = {}; cursor = 0
    while cursor < len(data):
        end = data.index(b"\0", cursor)
        mode, name = data[cursor:end].split(b" ", 1)
        require(name not in entries and name not in (b".", b"..") and b"/" not in name,
                "invalid tree name")
        oid = data[end + 1:end + 21]
        require(len(oid) == 20, "truncated tree entry")
        entries[name] = (mode, oid.hex()); cursor = end + 21
    return entries


def commit(data):
    headers, message = data.split(b"\n\n", 1)
    lines = headers.split(b"\n")
    require(lines[0].startswith(b"tree "), "commit tree header")
    parents = [line[7:].decode() for line in lines if line.startswith(b"parent ")]
    require(len(parents) == 1, "migration must be a linear commit chain")
    other = b"\n".join(line for line in lines if not line.startswith((b"tree ", b"parent ")))
    return lines[0][5:].decode(), parents[0], other, message


def verify(root, proof, cache_root=None):
    require(proof.get("schema") == 1 and len(proof.get("commits", [])) == 19,
            "expected exactly 19 migrated commits")
    rows = proof["commits"]
    require(rows[-1]["old"] == OLD_HEAD and rows[-1]["new"] == NEW_HEAD, "migration endpoints")
    require(len({r["old"] for r in rows}) == len(rows)
            and len({r["new"] for r in rows}) == len(rows), "duplicate commit mapping")
    require(git(root, "merge-base", "--is-ancestor", NEW_HEAD, "HEAD") == b"",
            "checkout is not descended from the published LFS history")
    objects = Objects(root)
    checked_trees = set(); used_trees = set(); used_blobs = set()
    checked_zip = {}; attribute_changes = set(); changed_paths = set(); unhydrated = set()
    unchanged_subtrees = set(); old_parent = new_parent = COMMON
    gitdir = Path(git(root, "rev-parse", "--absolute-git-dir").decode().strip())
    lfs_root = Path(cache_root) if cache_root else gitdir / "lfs/objects"

    def old_object(oid, kind):
        field = "old_trees" if kind == "tree" else "old_attribute_blobs"
        require(oid in proof[field], "missing proof " + kind + ": " + oid)
        (used_trees if kind == "tree" else used_blobs).add(oid)
        return decode(proof[field][oid], kind, oid)

    def walk(old, new, prefix=""):
        if old == new:
            unchanged_subtrees.add(old); return
        if (old, new, prefix) in checked_trees:
            return
        checked_trees.add((old, new, prefix))
        before = tree(old_object(old, "tree")); after = tree(objects.get(new, "tree"))
        for name in sorted(set(before) | set(after)):
            left, right = before.get(name), after.get(name)
            if left == right:
                if left[0] == b"40000": unchanged_subtrees.add(left[1])
                continue
            path = prefix + name.decode("utf-8")
            if left and right and left[0] == right[0] == b"40000":
                walk(left[1], right[1], path + "/"); continue
            changed_paths.add(path)
            if path == ".gitattributes":
                require(right and right[0] == b"100644" and
                        (left is None or left[0] == b"100644"), "attributes mode")
                previous = old_object(left[1], "blob") if left else b""
                require(objects.get(right[1], "blob") == previous + RULE, "unexpected attributes edit")
                attribute_changes.add((left[1] if left else None, right[1])); continue
            require(ZIP_PATH.fullmatch(path) and left and right
                    and left[0] == right[0] == b"100644", "unexpected migration edit: " + path)
            key = (left[1], right[1])
            if key in checked_zip: continue
            pointer = objects.get(right[1], "blob")
            match = re.fullmatch(rb"version https://git-lfs.github.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize ([1-9][0-9]*)\n", pointer)
            require(match, "invalid LFS pointer: " + path)
            sha256 = match[1].decode(); size = int(match[2])
            cache = lfs_root / sha256[:2] / sha256[2:4] / sha256
            candidate = cache if cache.is_file() else root / path
            require(candidate.is_file(), "LFS payload missing; run git lfs pull: " + path)
            raw_hash = hashlib.sha256(); blob_hash = hashlib.sha1(f"blob {size}\0".encode()); count = 0
            with candidate.open("rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    raw_hash.update(chunk); blob_hash.update(chunk); count += len(chunk)
            require(count == size and raw_hash.hexdigest() == sha256 and blob_hash.hexdigest() == left[1],
                    "LFS payload differs from original Git blob: " + path)
            working = root / path
            if working.is_file() and working.stat().st_size == len(pointer) and working.read_bytes() == pointer:
                unhydrated.add(path)
            elif working != candidate:
                working_hash = hashlib.sha256()
                require(working.is_file() and working.stat().st_size == size, "working LFS size: " + path)
                with working.open("rb") as stream:
                    while chunk := stream.read(1024 * 1024): working_hash.update(chunk)
                require(working_hash.hexdigest() == sha256, "working LFS content: " + path)
            checked_zip[key] = {"path": path, "bytes": size, "sha256": sha256,
                                "original_git_blob": left[1], "pointer_blob": right[1]}

    try:
        for row in rows:
            old_data = decode(row["old_commit"], "commit", row["old"])
            old_tree, parent, metadata, message = commit(old_data)
            new_data = objects.get(row["new"], "commit")
            new_tree, mapped_parent, mapped_metadata, mapped_message = commit(new_data)
            require(parent == old_parent and mapped_parent == new_parent, "commit parent chain")
            require(metadata == mapped_metadata and message == mapped_message, "commit metadata/message changed")
            walk(old_tree, new_tree)
            old_parent, new_parent = row["old"], row["new"]
        require(used_trees == set(proof["old_trees"]) and used_blobs == set(proof["old_attribute_blobs"]),
                "unused proof objects")
        require(len(checked_zip) == 11 and len(attribute_changes) == 1, "unexpected migration scope")
    finally:
        objects.close()
    return {"status": "PASS", "migration_commits": len(rows), "common_parent": COMMON,
            "old_head": OLD_HEAD, "published_lfs_head": NEW_HEAD,
            "changed_tree_pairs": len(checked_trees), "unchanged_subtrees": len(unchanged_subtrees),
            "changed_paths": sorted(changed_paths), "lfs_payloads": list(checked_zip.values()),
            "lfs_bytes": sum(r["bytes"] for r in checked_zip.values()),
            "unhydrated_lfs_paths": sorted(unhydrated),
            "source_and_manifest_blobs_unchanged": True,
            "simulation_rerun": False}


def install(root, proof):
    """Atomically create the aliases; reject an existing conflicting alias."""
    commands = ["start"]
    created = 0
    for row in proof["commits"]:
        ref = "refs/replace/" + row["old"]
        found = subprocess.run(["git", "--no-replace-objects", "rev-parse", "--verify", "--quiet", ref],
                               cwd=root, capture_output=True)
        if found.returncode == 0:
            require(found.stdout.decode().strip() == row["new"], "conflicting baseline alias: " + ref)
            commands.append("verify " + ref + " " + row["new"])
        else:
            require(found.returncode == 1,
                    "could not inspect replacement ref")
            commands.append("create " + ref + " " + row["new"]); created += 1
    commands += ["prepare", "commit"]
    git(root, "update-ref", "--stdin", data=("\n".join(commands) + "\n").encode())
    for row in proof["commits"]:
        actual = subprocess.check_output(["git", "cat-file", "-p", row["old"]], cwd=root,
                                         env={k:v for k,v in os.environ.items() if k != "GIT_NO_REPLACE_OBJECTS"})
        require(object_id("commit", actual) == row["new"], "replacement lookup failed")
    return created


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--proof", type=Path)
    parser.add_argument("--install", action="store_true", help="install 19 local Git replacement refs")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = args.root.resolve(); path = args.proof or root / PROOF
    before = path.read_bytes(); proof = read_json(path)
    report = verify(root, proof)
    require(path.read_bytes() == before, "migration proof changed during audit")
    report["proof_sha256"] = hashlib.sha256(before).hexdigest()
    require(not args.install or not report["unhydrated_lfs_paths"],
            "LFS working files are pointers; run git lfs checkout (or git lfs pull) before --install")
    report["aliases_created"] = install(root, proof) if args.install else 0
    report["aliases_installed"] = args.install
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("CPU5 baseline setup FAILED: " + str(error), file=sys.stderr)
        sys.exit(1)
