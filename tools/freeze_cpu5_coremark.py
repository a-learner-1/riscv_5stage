"""Freeze the CPU5 CoreMark artifacts into a self-describing evidence package.

The package contains only files this milestone produced. It re-verifies every
SHA it writes, records the source identity and the local Git commit, and never
modifies the measured artifacts.
"""
import argparse
import hashlib
import json
import platform
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import run_cpu5_coremark as runner

ROOT = Path(__file__).resolve().parents[1]
OUT = runner.OUT
EVIDENCE = ROOT / "docs/evidence/cpu5_coremark_20261025"
# Milestone baseline (S16 ten-class Stats delivery). The evidence package records
# this stable commit rather than the commit that will contain the package, so the
# manifest stays reproducible: a self-referential hash would change every amend.
BASELINE = "6a39363a70440be7b2a3a064ddedf1b6196cc904"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True,
                            encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError("git " + " ".join(arguments) + ": " + result.stderr.strip())
    return result.stdout.strip()


# Raw firmware artifacts that must travel with the evidence: the generated
# identity header, the linked ELF, the exact ROM/RAM payloads, the images the
# simulator loaded, the linker map and the disassembly.
FIRMWARE_ARTIFACTS = ("coremark_build_config.h", "program.elf", "program_text.bin",
                      "program_data.bin", "program.hex", "program_data.hex",
                      "program.map", "program.lst")


def selected_files():
    """Every artifact this package copies, in a deterministic order."""
    files = [OUT / "verification.json", OUT / "audit.json"]
    for number in range(len(runner.CASES)):
        files += [OUT / "cases" / f"case{number}" / "console.txt",
                  OUT / "cases" / f"case{number}" / "summary.json",
                  runner.FIRMWARE_OUT / f"case{number}" / "build.json"]
        files += [runner.FIRMWARE_OUT / f"case{number}" / name for name in FIRMWARE_ARTIFACTS]
    files.append(runner.FIRMWARE_OUT / "firmware_manifest.json")
    return [path for path in files if path.is_file()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", action="store_true", default=True)
    arguments = parser.parse_args()
    verification = json.loads((OUT / "verification.json").read_text(encoding="utf-8"))
    audit = json.loads((OUT / "audit.json").read_text(encoding="utf-8"))
    assert verification["status"] == "PASS" and audit["status"] == "PASS"
    assert audit["mutation_rejected"] == audit["mutation_total"]
    if EVIDENCE.exists():
        raise RuntimeError("evidence directory already exists: " + str(EVIDENCE))
    EVIDENCE.mkdir(parents=True)
    stage = verification["positive"]["directory"]
    entries = []
    for source in selected_files():
        relative = source.relative_to(ROOT).as_posix()
        target = EVIDENCE / source.relative_to(OUT if OUT in source.parents else runner.FIRMWARE_OUT)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        if sha(target) != sha(source):
            raise RuntimeError("copy diverged: " + relative)
        entries.append({"evidence_path": target.relative_to(ROOT).as_posix(),
                        "source_path": relative, "bytes": target.stat().st_size,
                        "sha256": sha(target)})
    logs = {"compile": ROOT / stage / "compile_console.log",
            "simulate": ROOT / stage / "simulate_console.log"}
    for name in ("compile.do", "simulate.do"):
        script = ROOT / stage / name
        if script.is_file():
            target = EVIDENCE / "logs" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(script.read_bytes())
            if sha(target) != sha(script):
                raise RuntimeError("script copy diverged: " + name)
            entries.append({"evidence_path": target.relative_to(ROOT).as_posix(),
                            "source_path": script.relative_to(ROOT).as_posix(),
                            "bytes": target.stat().st_size, "sha256": sha(target)})
    for name, log in logs.items():
        if log.is_file():
            target = EVIDENCE / "logs" / (name + "_console.log")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(log.read_bytes())
            if sha(target) != sha(log):
                raise RuntimeError("log copy diverged: " + name)
            entries.append({"evidence_path": target.relative_to(ROOT).as_posix(),
                            "source_path": log.relative_to(ROOT).as_posix(),
                            "bytes": target.stat().st_size, "sha256": sha(target)})
    selected = {"run_id": verification["run_id"], "stage_directory": stage,
                "cases": [{"case": case["case"], "d0": case["d0"], "cache": case["cache"],
                           "window_cycles": case["window_cycles"],
                           "window_retired": case["window_retired"],
                           "raw_ticks": case["raw_ticks"],
                           "window_tick_gap": case["window_tick_gap"]}
                          for case in verification["cases"]],
                "all_cases_rerun_this_milestone": True,
                "reused_historical_runs": [],
                "not_run": ["formal 10-second CoreMark score", "CPU5 P&R/STA",
                            "LUT/APM/Fmax", "bitstream", "board performance test",
                            "full A01-A16 sign-off"]}
    identity = {"source_sha256": verification["source_sha256"],
                "sources_unchanged": verification["sources_unchanged"],
                "firmware_sources_sha256": verification["firmware"][0]["sources_sha256"],
                "baseline_commit": BASELINE,
                "git_head_at_freeze": git("rev-parse", "HEAD"),
                "git_branch": git("rev-parse", "--abbrev-ref", "HEAD"),
                "git_status_short_count": len(git("status", "--porcelain").splitlines()),
                "tested_compiler": verification["firmware"][0]["compiler"],
                "python": platform.python_version(), "platform": platform.platform(),
                "simulator": str(runner.DEFAULT_VSIM), "vsim_version": "Questa/ModelSim 10.6e",
                "frozen_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    (EVIDENCE / "selected_runs.json").write_text(json.dumps(selected, indent=2) + "\n",
                                               encoding="utf-8", newline="\n")
    # Evidence README and identity are written before the manifest so that the
    # manifest enumerates every file in the package, including this attribute
    # file that pins CRLF/LF handling.
    (EVIDENCE / "source_identity.json").write_text(json.dumps(identity, indent=2) + "\n",
                                                 encoding="utf-8", newline="\n")
    (EVIDENCE / "README.md").write_text(
        "# CPU5 CoreMark 功能接入证据（2026-10-25）\n\n"
        "本目录只包含本阶段实际生成的工件与校验和。范围、结论与未运行项见\n"
        "[阶段报告](../../cpu5_coremark_20261025.md)与[范围合同]"
        "(../../cpu5_coremark_contract_20261025.md)。\n\n"
        f"- 运行：`{verification['run_id']}`（{len(verification['cases'])} 个配置，"
        "本阶段新跑）\n"
        "- 审计：`audit.json` 记录控制台自洽性、独立快照交叉核对与"
        f"{audit['mutation_total']} 项负证据拒绝\n"
        "- 复跑：`python -B tools/run_cpu5_coremark.py`；"
        "`python -B tools/verify_cpu5_coremark.py`；"
        "`python -B tools/freeze_cpu5_coremark.py`\n"
        "- 本包不解压、不改写原始工件；`manifest.json` 列出每个文件的 SHA256。\n",
        encoding="utf-8", newline="\n")
    # Keep every recorded byte exactly as measured: no EOL normalization.
    (EVIDENCE / ".gitattributes").write_text("* -text\n", encoding="ascii", newline="\n")
    for name in ("README.md", "selected_runs.json", "source_identity.json", ".gitattributes"):
        entries.append({"evidence_path": (EVIDENCE / name).relative_to(ROOT).as_posix(),
                        "source_path": None, "bytes": (EVIDENCE / name).stat().st_size,
                        "sha256": sha(EVIDENCE / name)})
    archive = EVIDENCE / "raw_evidence.zip"
    if arguments.archive:
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for entry in sorted(entries, key=lambda item: item["evidence_path"]):
                bundle.write(ROOT / entry["evidence_path"],
                             entry["evidence_path"].split("cpu5_coremark_20261025/", 1)[1])
        with zipfile.ZipFile(archive) as bundle:
            bad = bundle.testzip()
            if bad is not None:
                raise RuntimeError("raw archive entry corrupt: " + bad)
            for name in bundle.namelist():
                if bundle.read(name) != (ROOT / "docs/evidence/cpu5_coremark_20261025" / name).read_bytes():
                    raise RuntimeError("raw archive entry diverges: " + name)
        entries.append({"evidence_path": archive.relative_to(ROOT).as_posix(),
                        "source_path": None, "bytes": archive.stat().st_size,
                        "sha256": sha(archive)})
    manifest = {"status": "FROZEN", "evidence": EVIDENCE.relative_to(ROOT).as_posix(),
                "run_id": verification["run_id"],
                "verification_status": verification["status"],
                "audit_mutations_rejected": audit["mutation_rejected"],
                "files": entries, "baseline_commit": identity["baseline_commit"],
                "git_head_at_freeze": identity["git_head_at_freeze"],
                "frozen_utc": identity["frozen_utc"],
                "pushed": False, "downloaded": False, "performance_claim": "NONE"}
    (EVIDENCE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n",
                                           encoding="utf-8", newline="\n")
    for entry in entries:
        if sha(ROOT / entry["evidence_path"]) != entry["sha256"]:
            raise RuntimeError("evidence file changed during freeze: " + entry["evidence_path"])
    print(json.dumps({"status": "FROZEN", "files": len(entries),
                      "archive_bytes": archive.stat().st_size if archive.exists() else 0,
                      "evidence": manifest["evidence"]}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
