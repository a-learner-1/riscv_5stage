"""CPU5 stage-0 read-only CPU3 baseline audit; writes only its output folder.

No Git ref/index updates, firmware rebuild, simulator, PDS, hardware, or network
commands are performed.  Ignored artifacts are audited only when referenced by
the existing release/firmware/evidence manifests; no waveform is copied.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from decimal import Decimal, localcontext
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import traceback

sys.dont_write_bytecode = True
MAIN = Path(r"D:\FPGA\riscv_3stage")
OUT = Path(__file__).resolve().parent
SPEC = Path(r"C:\Users\23123\Downloads\cpu5_arch_spec_v0_3.md")
M1 = Path(r"C:\Users\23123\.codex\visualizations\2026\10\19\01a151db-bb68-7633-bd17-5c52d2aa2890\m1")
EXPECTED_DIRTY = {"docs/regression.md", "tb/coremark_axi_tb.v", "tools/regression_suites.json"}
ROLES = {"m_work_start": "75c43aa", "accepted_rv32im_source": "347982c",
         "board_evidence": "ab8e3f6", "current_head": "1b7cb12"}
ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0",
           PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
CHECKS = []
COMMANDS = []
HASH_CACHE = {}


def now():
    return datetime.now(timezone.utc).isoformat()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest(path):
    p = Path(path)
    stat = p.stat()
    key = (str(p.resolve()), stat.st_size, stat.st_mtime_ns)
    if key not in HASH_CACHE:
        h = hashlib.sha256()
        with p.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        HASH_CACHE[key] = h.hexdigest()
    return HASH_CACHE[key]


def canonical(data):
    return data.replace(b"\r\n", b"\n")


def check(label, condition, details=None):
    item = {"check": label, "status": "PASS" if condition else "FAIL"}
    if details is not None:
        item["details"] = details
    CHECKS.append(item)
    if not condition:
        raise AssertionError(label + (": " + str(details) if details is not None else ""))


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def file_identity(path, expected=None):
    p = Path(path)
    item = {"path": str(p), "exists": p.is_file()}
    if not p.is_file():
        item["status"] = "UNAVAILABLE"
        return item
    item.update(bytes=p.stat().st_size, sha256=digest(p), status="PASS")
    if expected is not None:
        item["expected_sha256"] = expected
        check("file SHA256: " + str(p), item["sha256"] == expected)
    return item


def required_file(path, expected=None):
    obj = file_identity(path, expected)
    check("required file available: " + str(path), obj["exists"])
    return obj


def git(*args, allow_one=False):
    cmd = ["git", "-C", str(MAIN), *args]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
    COMMANDS.append({"argv": cmd, "returncode": p.returncode,
                     "stdout_sha256": sha(p.stdout),
                     "stderr": p.stderr.decode("utf-8", errors="replace")})
    if p.returncode and not (allow_one and p.returncode == 1):
        raise RuntimeError("Git failed: " + repr(cmd) + "\n" + p.stderr.decode("utf-8", errors="replace"))
    return p


def z_names(data):
    return [s.decode("utf-8") for s in data.split(b"\0") if s]


def snapshot():
    dirty_names = sorted(set(z_names(git("diff", "--name-only", "-z").stdout) +
                             z_names(git("diff", "--cached", "--name-only", "-z").stdout)))
    untracked = sorted(z_names(git("ls-files", "--others", "--exclude-standard", "-z").stdout))
    def records(names):
        return {name: {"sha256": digest(MAIN / name), "bytes": (MAIN / name).stat().st_size}
                for name in names}
    return {"captured_at": now(), "head": git("rev-parse", "HEAD").stdout.decode().strip(),
            "status_porcelain": git("status", "--porcelain=v1", "--untracked-files=all").stdout.decode("utf-8"),
            "dirty_tracked": records(dirty_names), "untracked": records(untracked),
            "untracked_count": len(untracked),
            "git_refs_sha256": sha(git("show-ref").stdout),
            "inventory_policy": "All Git-visible non-ignored untracked files from git ls-files --others --exclude-standard; ignored build products audited separately by explicit manifest references."}


def elf_identity(path):
    data = Path(path).read_bytes()
    check("ELF32 little-endian: " + str(path), data[:6] == b"\x7fELF\x01\x01")
    e = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    phoff, shoff, phentsize, phnum, shentsize, shnum, shstrndx = e[5], e[6], e[9], e[10], e[11], e[12], e[13]
    sections_raw = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shentsize) for i in range(shnum)]
    shstr = sections_raw[shstrndx]
    names = data[shstr[4]:shstr[4] + shstr[5]]
    sections = {}
    for s in sections_raw:
        name = names[s[0]:].split(b"\0", 1)[0].decode("ascii", errors="replace")
        content = b"" if s[1] == 8 else data[s[4]:s[4] + s[5]]
        sections[name] = {"type": s[1], "flags": s[2], "addr": s[3], "size": s[5],
                          "align": s[8], "bytes_sha256": sha(content)}
    loads = []
    for i in range(phnum):
        p = struct.unpack_from("<IIIIIIII", data, phoff + i * phentsize)
        if p[0] == 1:
            loads.append({"vaddr": p[2], "paddr": p[3], "filesz": p[4], "memsz": p[5],
                          "flags": p[6], "align": p[7],
                          "file_bytes_sha256": sha(data[p[1]:p[1] + p[4]])})
    return {"path": str(path), "sha256": sha(data), "entry": e[4],
            "allocated_sections": {k: v for k, v in sections.items() if v["flags"] & 2},
            "all_sections": sections, "PT_LOAD": loads}


def audit_uart(profile, evidence, firmware_report):
    record_path = evidence / (profile + "_result.json")
    record = load_json(record_path)
    raw_path = evidence / (profile + "_uart_original.txt")
    raw = raw_path.read_bytes()
    norm, count = re.subn(r"(?:\r?\n)?\[\d\d:\d\d:\d\d\.\d{3}\]收←◆", "", raw.decode("utf-8").replace("\r\n", "\n"))
    # The archived normalized text was written on Windows with CRLF. Its
    # immutable byte SHA is checked separately; normalization removes packet
    # prefixes and compares textual content after LF canonicalization.
    check(profile + " normalized UART content (LF canonical)", norm.encode() == canonical((evidence / (profile + "_uart_normalized.txt")).read_bytes()))
    pairs = re.findall(r"(?m)^COREMARK ([A-Za-z0-9_]+)=([^\r\n]*)", norm)
    fields = dict(pairs)
    check(profile + " unique metadata fields", len(fields) == len(pairs) == 63)
    check(profile + " raw/record/field closure", sha(raw) == record["uart_original_sha256"] and fields == record["fields"])
    check(profile + " SSCOM prefix count", count == record["sscom_packet_prefixes_removed"])
    expected = {"platform": "d0-m-cache-on-btb", "isa": "rv32im", "data_backend": "bram",
                "profile": profile, "run": profile, "mode": "formal", "cache_enable": "3",
                "branch_pred_enable": "1", "btb_entries": "64", "btb_config": "4194305",
                "cpu_hz": "50000000", "uart_baud": "115200", "iterations_requested": "0", "iterations": "2000",
                "counter_valid": "1", "cycle_profile_valid": "1", "cycle_profile_schema": "1"}
    crcs = ("e9f5", "e714", "1fd7", "8e3a") if profile == "performance" else ("18f2", "e3c1", "0747", "8d84")
    expected.update(zip(("seedcrc", "crclist", "crcmatrix", "crcstate"), ("0x" + c for c in crcs)))
    expected.update(seed1="0x0000" if profile == "performance" else "0x3415",
                    seed2="0x0000" if profile == "performance" else "0x3415", seed3="0x0066")
    check(profile + " configuration/CRC", all(fields.get(k) == v for k, v in expected.items()))
    check(profile + " formal UART markers", "Correct operation validated." in norm and "COREMARK RESULT: FORMAL PASS" in norm and not re.search("Errors detected|ERROR!", norm))
    check(profile + " firmware flags/compiler/memory", fields["flags"] == " ".join(firmware_report["compiler_flags"] + firmware_report["linker_flags"] + firmware_report["linked_libraries"]) and fields["compiler"] == firmware_report["compiler"] and fields["memory"] == firmware_report["memory_location"])
    n = lambda k: int(fields[k])
    with localcontext() as ctx:
        ctx.prec = 60
        seconds = Decimal(n("raw_ticks")) / n("cpu_hz")
        rate = Decimal(n("iterations")) * n("cpu_hz") / n("raw_ticks")
        pm = rate / 50
        cpi = Decimal(n("counter_cycles")) / n("counter_retired")
        for k, val in [("seconds", seconds), ("iterations_per_second", rate), ("coremark_per_mhz", pm), ("counter_cpi", cpi)]:
            check(profile + " Decimal " + k, abs(Decimal(fields[k]) - val) <= Decimal("0.0000000005"))
        check(profile + " duration >=10s", seconds >= 10)
        computed = {"seconds": str(seconds), "coremark": str(rate), "coremark_per_mhz": str(pm), "cpi": str(cpi),
                    "ticks_per_iteration": str(Decimal(n("raw_ticks")) / n("iterations")),
                    "boundary_overhead_cycles": n("counter_cycles") - n("raw_ticks"),
                    "work_other_minus_retired": n("cycle_work_other") - n("counter_retired")}
    classes = ("work_other", "ifetch_wait", "data_read_wait", "data_write_wait", "local_mmio_wait", "redirect_wait")
    check(profile + " exclusive cycle ledger", sum(n("cycle_" + k) for k in classes) == n("counter_cycles") == n("cycle_profile_sum"))
    check(profile + " I-cache ledger", n("icache_hit") + n("icache_miss") == n("icache_access"))
    residual = n("icache_refill_words") - 4 * n("icache_miss")
    check(profile + " I-cache window refill residual", residual == (0 if profile == "performance" else 3))
    check(profile + " D-cache ledger", sum(n("dcache_" + k) for k in ("hit", "miss", "write", "bypass")) == n("dcache_access"))
    check(profile + " D-cache refill", n("dcache_refill_words") == 4 * n("dcache_miss"))
    check(profile + " STORE two cycles", n("cycle_data_write_wait") == 2 * n("dcache_write"))
    check(profile + " zero cache/target errors", all(n(k) == 0 for k in ("icache_errors", "dcache_errors", "bp_target_error")))
    return {"record": required_file(record_path), "raw_uart": required_file(raw_path),
            "normalized_uart": required_file(evidence / (profile + "_uart_normalized.txt")),
            "prefixes_removed": count, "fields": fields, "computed": computed,
            "icache_refill_minus_four_misses": residual,
            "binding_limit": "User-operated downloads. UART configuration is consistent with the archived expected SBIT; UART does not self-attest the programmed SBIT SHA."}


def audit():
    result = {"schema": 1, "audit_kind": "CPU5-v0.3-stage0 CPU3 baseline verification and freeze proposal",
              "started_at": now(), "main_workspace": str(MAIN), "output_directory": str(OUT),
              "scope": "Read-only verification of existing evidence; no source edits, Git ref/index writes, rebuilds, simulations, PDS, hardware access, or network.",
              "specification": required_file(SPEC), "audit_script": file_identity(__file__), "checks": CHECKS}
    result["workspace_before"] = snapshot()
    before = result["workspace_before"]
    check("expected three user dirty tracked files", set(before["dirty_tracked"]) == EXPECTED_DIRTY, sorted(before["dirty_tracked"]))
    result["git_commits"] = {}
    for role, short in ROLES.items():
        objtype = git("cat-file", "-t", short).stdout.decode().strip()
        full = git("rev-parse", short + "^{commit}").stdout.decode().strip()
        fuller = git("show", "-s", "--format=fuller", full).stdout.decode("utf-8")
        check(role + " is 40-hex commit", objtype == "commit" and bool(re.fullmatch("[0-9a-f]{40}", full)))
        result["git_commits"][role] = {"short": short, "full": full, "type": objtype, "git_show_fuller": fuller}
    fulls = {k: v["full"] for k, v in result["git_commits"].items()}
    check("HEAD matches supplied current baseline", before["head"] == fulls["current_head"])
    result["ancestor_checks"] = []
    roles = list(ROLES)
    for a, b in zip(roles, roles[1:]):
        ok = git("merge-base", "--is-ancestor", fulls[a], fulls[b], allow_one=True).returncode == 0
        check(a + " ancestor of " + b, ok)
        result["ancestor_checks"].append({"ancestor": fulls[a], "descendant": fulls[b], "status": "PASS"})
    hw_diff = git("diff", "--name-status", fulls["accepted_rv32im_source"], fulls["current_head"], "--", "rtl", "pds").stdout.decode("utf-8")
    check("hardware/constraints unchanged between accepted M commit and HEAD", not hw_diff.strip(), hw_diff)
    result["hardware_commit_diff"] = hw_diff
    relroot = MAIN / "build/board_release_rv32m_20261020"
    relpath = relroot / "release_manifest.json"
    release = load_json(relpath)
    delivery_path = MAIN / "build/verification/rv32m_20261021/delivery_identity.json"
    delivery = load_json(delivery_path)
    result["release_manifest"] = required_file(relpath)
    result["delivery_identity"] = required_file(delivery_path)
    check("delivery source-identity report historically PASS", delivery["status"] == "PASS")
    check("delivery binds release manifest", delivery["release_manifest_sha256"] == digest(relpath))
    check("release RV32IM O2 50MHz 115200", release["isa"] == "rv32im" and release["clock_hz"] == 50000000 and release["uart_baud"] == 115200 and release["compiler_optimization"] == "O2")
    result["historical_build_state"] = {"hardware_programmed": release["hardware_programmed"], "formal_score_measured": release["formal_score_measured"], "note": "Preserved build-time snapshot; later user UART evidence is audited separately below."}
    result["delivery_source_recheck"] = {}
    for name, saved in delivery["source_identity"].items():
        current = MAIN / name
        item = {"saved": saved, "current": required_file(current)}
        data = current.read_bytes()
        if saved.get("generated_configuration"):
            check("generated config still byte-identical: " + name, digest(current) == saved["sha256"])
        else:
            blob = git("show", fulls["accepted_rv32im_source"] + ":" + name).stdout
            item.update(commit_blob_sha256=sha(blob), current_canonical_lf_sha256=sha(canonical(data)),
                        raw_commit_equals_current=blob == data)
            check("delivery canonical source identity: " + name, sha(canonical(data)) == saved["canonical_lf_sha256"] == sha(canonical(blob)))
            check("delivery raw worktree identity retained: " + name, digest(current) == saved["main_worktree_sha256"])
        result["delivery_source_recheck"][name] = item
    result["profiles"] = {}
    firmware_reports = {}
    for profile, rp in release["profiles"].items():
        pdspath = Path(rp["build_manifest"])
        pdsdir = pdspath.parent
        original_root = pdspath.parents[2]
        pds = load_json(pdspath)
        cur_report_path = MAIN / "build/coremark" / ("d0_m_cache_on_btb_" + profile) / "build_report.json"
        old_report_path = Path(delivery["profiles"][profile]["immutable_original_firmware_report"])
        curreport, oldreport = load_json(cur_report_path), load_json(old_report_path)
        firmware_reports[profile] = curreport
        info = {"released_sbit": required_file(relroot / rp["file"], rp["sha256"]),
                "original_pds_manifest": required_file(pdspath, rp["build_manifest_sha256"]),
                "mirrored_pds_manifest": required_file(Path(delivery["profiles"][profile]["mirrored_pds_manifest"]), rp["build_manifest_sha256"]),
                "original_firmware_report": required_file(old_report_path),
                "original_build_firmware_report": {}, "current_firmware_report": required_file(cur_report_path),
                "original_build_root": str(original_root), "sources": {}, "implementation_artifacts": {},
                "original_images": {}, "current_images": {}, "source_rebuild_differences": []}
        check(profile + " SBIT size", (relroot / rp["file"]).stat().st_size == rp["bytes"] == 2101696)
        check(profile + " hardware variant", pds["variant"] == "coremark_d0_m_btb" and pds["march"] == "rv32im" and pds["enable_m"] == 1 and pds["enable_d0_bram"] == 1)
        info["route"] = required_file(pdsdir / "place_route/board_top_pnr.adf", rp["route_sha256"])
        info["final_rtr"] = required_file(pdsdir / "report_timing/board_top.rtr", rp["final_sta_report_sha256"])
        check(profile + " route binding", pds["final_sta_route_sha256"] == rp["route_sha256"])
        check(profile + " STA binding", pds["final_sta_report_sha256"] == rp["final_sta_report_sha256"])
        for field in ("router_slacks_ns", "final_slacks_ns", "pulse_slacks_ns"):
            check(profile + " positive " + field, all(Decimal(v) > 0 for v in rp[field]))
        info["timing"] = {k: rp[k] for k in ("router_slacks_ns", "final_slacks_ns", "pulse_slacks_ns", "resources")}
        for name, expected in pds["sources"].items():
            original = original_root / name
            current = MAIN / name
            build_data, current_data = original.read_bytes(), current.read_bytes()
            blob = git("show", fulls["accepted_rv32im_source"] + ":" + name).stdout
            info["sources"][name] = {"original": required_file(original, expected), "current": file_identity(current),
                                     "commit_blob_sha256": sha(blob), "canonical_lf_sha256": sha(canonical(build_data)),
                                     "raw_build_equals_current": build_data == current_data,
                                     "raw_build_equals_commit": build_data == blob,
                                     "canonical_equal_build_current_commit": canonical(build_data) == canonical(current_data) == canonical(blob)}
            check(profile + " canonical hardware source: " + name, info["sources"][name]["canonical_equal_build_current_commit"])
        for name, expected in pds["implementation_artifacts_sha256"].items():
            info["implementation_artifacts"][name] = required_file(pdsdir / name, expected)
        for name, expected in pds["bitstreams"].items():
            info["implementation_artifacts"][name] = required_file(pdsdir / name, expected)
        for name, expected in pds["firmware_build_report"].items():
            info["original_build_firmware_report"][name] = required_file(original_root / name, expected)
            check(profile + " archived pre-rebuild report preserved", digest(old_report_path) == expected)
        for name, expected in oldreport["images_sha256"].items():
            info["original_images"][name] = required_file(original_root / name, expected)
            info["current_images"][name] = required_file(MAIN / name, expected)
            check(profile + " current image metadata exact: " + name, curreport["images_sha256"][name] == expected)
        for name, expected in oldreport["sources_sha256"].items():
            check(profile + " original firmware source: " + name, digest(original_root / name) == expected)
            check(profile + " rebuilt firmware current source: " + name, digest(MAIN / name) == curreport["sources_sha256"][name])
            original_data, current_data = (original_root / name).read_bytes(), (MAIN / name).read_bytes()
            check(profile + " source differs at most CRLF/LF: " + name, canonical(original_data) == canonical(current_data))
            if original_data != current_data:
                info["source_rebuild_differences"].append({"path": name, "original_sha256": sha(original_data), "current_sha256": sha(current_data), "canonical_lf_sha256": sha(canonical(original_data)), "difference": "CRLF/LF only"})
        name = "d0_m_cache_on_btb_" + profile
        oldelf = elf_identity(original_root / "build/coremark" / name / "coremark.elf")
        newelf = elf_identity(MAIN / "build/coremark" / name / "coremark.elf")
        check(profile + " original ELF SHA", oldelf["sha256"] == oldreport["elf_sha256"])
        check(profile + " rebuilt ELF SHA", newelf["sha256"] == curreport["elf_sha256"])
        check(profile + " allocated ELF sections identical", oldelf["allocated_sections"] == newelf["allocated_sections"])
        check(profile + " PT_LOAD byte/addresses identical", oldelf["PT_LOAD"] == newelf["PT_LOAD"])
        names = set(oldelf["all_sections"]) | set(newelf["all_sections"])
        diffs = [n for n in sorted(names) if oldelf["all_sections"].get(n) != newelf["all_sections"].get(n)]
        check(profile + " only nonloaded .strtab differs", set(diffs) <= {".strtab"})
        info["elf_comparison"] = {"original": oldelf, "rebuilt": newelf, "differing_sections": diffs,
                                  "note": "Do not claim full ELF raw-byte identity; a nonloaded .strtab temporary object name may differ."}
        info["build_metadata_differing_keys"] = [k for k in sorted(set(oldreport) | set(curreport)) if oldreport.get(k) != curreport.get(k)]
        result["profiles"][profile] = info
    result["firmware_contract_checks"] = []
    sys.path.insert(0, str(MAIN / "tools"))
    from coremark_axi_contract import validate_coremark_axi_firmware
    for profile in ("performance", "validation"):
        validate_coremark_axi_firmware("coremark_d0_m_cache_on_btb_" + profile, "on", root=MAIN,
                                      btb_mode="on", backend="bram", isa="rv32im")
        result["firmware_contract_checks"].append({"profile": profile, "status": "PASS", "rebuild_performed": False})
    evidence = MAIN / "docs/evidence/rv32m_board_20261021"
    evidence_manifest = load_json(evidence / "SHA256_MANIFEST.json")
    result["board_evidence"] = {"manifest": required_file(evidence / "SHA256_MANIFEST.json"), "files": {}}
    for name, expected in evidence_manifest.items():
        result["board_evidence"]["files"][name] = required_file(evidence / name, expected)
        blob = git("show", fulls["board_evidence"] + ":docs/evidence/rv32m_board_20261021/" + name).stdout
        check("evidence commit raw-byte match: " + name, sha(blob) == expected)
    check("evidence manifest inventory complete", {p.name for p in evidence.iterdir() if p.is_file()} == set(evidence_manifest) | {"SHA256_MANIFEST.json"})
    check("evidence directory disables EOL conversion", "* -text" in (evidence / ".gitattributes").read_text(encoding="utf-8"))
    pair = load_json(evidence / "pair_result.json")
    check("formal pair complete", pair["status"] == "FORMAL_PAIR_PASS" and pair["configuration_pair_complete"] is True)
    check("pair source commit", pair["source_commit"] == fulls["accepted_rv32im_source"])
    check("pair release manifest binding", pair["release_manifest_sha256"] == digest(relpath))
    check("performance only advertised", pair["advertised_score_source"] == "performance" and pair["score_uses_performance_only"] is True)
    result["board_evidence"]["pair_result"] = pair
    result["board_evidence"]["runs"] = {}
    for profile in ("performance", "validation"):
        check(profile + " pair -> single record hash", digest(evidence / (profile + "_result.json")) == pair["profiles"][profile]["record_sha256"])
        run = audit_uart(profile, evidence, firmware_reports[profile])
        check(profile + " pair fields identical", run["fields"] == pair["profiles"][profile]["fields"])
        result["board_evidence"]["runs"][profile] = run
    check("pair hardware sources match original PDS", pair["same_hardware_source_hashes"] == {k: v["original"]["sha256"] for k, v in result["profiles"]["performance"]["sources"].items()})
    common = set(firmware_reports["performance"]["sources_sha256"]) & set(firmware_reports["validation"]["sources_sha256"])
    common = {n for n in common if not n.startswith("build/")}
    check("48 shared firmware source hashes", len(common) == pair["same_firmware_source_paths"] == 48 and all(firmware_reports["performance"]["sources_sha256"][n] == firmware_reports["validation"]["sources_sha256"][n] for n in common))
    result["historical_identity_records"] = {name: required_file(MAIN / "build/verification/rv32m_20261021" / name) for name in ("main_firmware_identity.json", "commit_identity.json", "main_firmware_rebuild.log", "main_firmware_rebuild_final.log", "main_firmware_guards_final.log")}
    tag = "cpu3-rv32im-board-20261021"
    tag_current = git("tag", "--list", tag).stdout.decode().strip()
    result["freeze_tag_proposal"] = {"name": tag, "target_commit": fulls["accepted_rv32im_source"],
                                     "evidence_commit": fulls["board_evidence"], "created_by_this_audit": False,
                                     "status": "NOT CREATED" if not tag_current else "ALREADY EXISTS; independently inspect before acting",
                                     "note": "Root agent may create the tag only after accepting this audit. No tag/ref command that writes was executed."}
    result["not_run"] = ["Fresh ModelSim/lint/regression", "Fresh PDS/synthesis/place-route/STA", "Hardware download/UART access", "CPU5 development", "Freeze tag creation"]
    result["workspace_after"] = snapshot()
    after = result["workspace_after"]
    for key in ("head", "status_porcelain", "dirty_tracked", "untracked", "git_refs_sha256"):
        check("read-only workspace preserved: " + key, before[key] == after[key])
    result["git_commands"] = COMMANDS
    result["completed_at"] = now()
    result["status"] = "PASS"
    result["pass_scope"] = "Existing CPU3 source/release/firmware/board-evidence identity and numeric checks only. NOT a fresh performance, timing, or CPU5 verification result. Tag is proposed, not created."
    return result


def write_summary(result):
    good = sum(c["status"] == "PASS" for c in CHECKS)
    bad = sum(c["status"] == "FAIL" for c in CHECKS)
    before = result.get("workspace_before", {})
    lines = ["# CPU5 阶段 0：三级 RV32IM 基线只读冻结审计", "",
             "审计状态：**" + result["status"] + "**。此结论只覆盖既有来源、归档与板测数据身份，不代表重跑仿真、PDS 或 CPU5 验证。", "",
             f"检查：{good} PASS / {bad} FAIL。未修改主工程、索引、Git refs 或原产物。", "",
             "## Git 角色", "", "| 角色 | 完整 commit |", "|---|---|"]
    for role, info in result.get("git_commits", {}).items():
        lines.append(f"| {role} | `{info['full']}` |")
    if "freeze_tag_proposal" in result:
        t = result["freeze_tag_proposal"]
        lines += ["", f"拟冻结 tag：`{t['name']}` → `{t['target_commit']}`。**本审计未创建 tag**。板测证据另绑定其证据 commit。"]
    lines += ["", "## 保护现场", "", f"事前记录 {len(before.get('dirty_tracked', {}))} 个用户已跟踪修改及 {before.get('untracked_count', 'UNAVAILABLE')} 个 Git 可见非 ignored 未跟踪文件，逐文件大小/SHA-256 见 JSON。审计末尾再次核对，未改变。", "",
              "Ignored build 文件不混入用户未跟踪源码清单；仅核验发布清单显式引用的原产物，不复制大波形。", "",
              "## 交付身份", "", "两份正式 SBIT 各 2,101,696 字节；发布 manifest、delivery identity、原始 PDS manifest、route/RTR、实现产物与原始 firmware report 均按原 SHA 核对。", "",
              "当前正式 ROM/RAM/config 三件套与位流输入逐字节一致。原始源码、Git blob、当前工作区的 raw SHA 分别保留，CRLF/LF 仅以归一化方式证明等价，**不宣称 raw 字节一致**。原 ELF 与重建 ELF 的已分配节和 PT_LOAD 内容/地址一致；非加载 .strtab 差异单独记录。", "",
              "只读运行两份正式固件 contract 检查；没有重建固件。", "",
              "## 正式板测证据", "", "docs/evidence/rv32m_board_20261021 的全文件清单、证据 commit、pair→single→raw/normalized UART 哈希闭合。两组 metadata、flags、CRC、时长、六分类与 Cache 账本重新核算；performance 独立计分，不平均 validation。", "",
              "performance：117.958048697 CoreMark / 2.359160974 CoreMark/MHz；2000 次，16.955180440 秒。", "",
              "validation：117.763402970 次/秒，16.983204880 秒；I-cache refill 比 4×miss 多 3 字，保留为跨窗口边界差。两次 work_other−retired 均为 56,376,000，不能直接认定为纯 MUL 等待。", "",
              "用户自行下载；UART 文本不能自证实际下载 SBIT SHA。发布 manifest 中硬件/正式成绩未运行字段保留为构建时快照，后续配对板测证据单独提供。", "",
              "## NOT RUN", ""]
    lines += ["- " + n for n in result.get("not_run", ["审计在完成前失败，见 JSON exception/FAIL 检查"])]
    if result.get("exception"):
        lines += ["", "审计未完成：", "", "```text", result["exception"], "```"]
    lines += ["", "完整路径、字节哈希、Git fuller 输出、差异及检查明细见 [baseline_freeze.json](baseline_freeze.json)，复核脚本见 [audit_baseline.py](audit_baseline.py)。", ""]
    (OUT / "summary.md").write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-preserved", action="store_true", help="Compare current dirty/untracked/HEAD/refs with the saved before snapshot; write only preservation_check.json")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.verify_preserved:
        old = load_json(OUT / "baseline_freeze.json")["workspace_before"]
        current = snapshot()
        differences = [k for k in ("head", "status_porcelain", "dirty_tracked", "untracked", "git_refs_sha256") if old[k] != current[k]]
        answer = {"checked_at": now(), "status": "PASS" if not differences else "FAIL", "differences": differences, "current": current,
                  "note": "A root-created freeze tag legitimately changes git_refs_sha256; compare dirty/untracked separately when that is the sole difference."}
        (OUT / "preservation_check.json").write_text(json.dumps(answer, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"status": answer["status"], "differences": differences}))
        return int(bool(differences))
    try:
        result = audit()
    except Exception:
        result = {"status": "FAIL", "completed_at": now(), "exception": traceback.format_exc(), "checks": CHECKS, "git_commands": COMMANDS}
    (OUT / "baseline_freeze.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_summary(result)
    print(json.dumps({"status": result["status"], "checks": len(CHECKS), "failed": [c["check"] for c in CHECKS if c["status"] == "FAIL"], "output": str(OUT)}, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
