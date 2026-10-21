"""Record the simulator process exit, preserve the first observation, and hash inputs."""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

sys.stdout.reconfigure(encoding="utf-8")
ROOT = Path(__file__).resolve().parent
WORK = ROOT / "work"
DATA = WORK / "build/cpu5_stage0_measure"
FIRST = WORK / "build/cpu5_stage0_initial_observation"
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
def utc(): return datetime.now(timezone.utc).isoformat()
def require(value, message):
    if not value: raise ValueError(message)

if not FIRST.exists():
    shutil.copytree(DATA, FIRST)
source_files = ["tb/cpu5_baseline_raw_tb.v", "tools/analyze_cpu5_baseline_raw.py", "run_cpu5_baseline_raw.do"]
for profile in ("smoke", "smoke_validation"):
    report = json.loads((WORK / f"build/coremark/d0_m_cache_on_btb_{profile}/build_report.json").read_text())
    for name, digest in report["sources_sha256"].items():
        require(sha(WORK / name) == digest, "Firmware source hash mismatch: " + name)
    source_files += list(report["sources_sha256"])
sources_before = {name: sha(WORK/name) for name in sorted(set(source_files))}
record = {"started_at_utc": utc(), "source_sha256_before": sources_before,
    "command": [r"D:\modeltech64_10.6e\win64\vsim.exe", "-c", "-do", "do run_cpu5_baseline_raw.do"],
    "cwd": str(WORK), "initial_run_archive": str(FIRST),
    "initial_run_note": "Initial successful transcript and all observation files preserved. This run explicitly records OS process exit and deterministic trace identity."}
env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
log = ROOT / "modelsim_verified_process.log"
with log.open("wb") as out:
    process = subprocess.run(record["command"], cwd=WORK, env=env, stdout=out, stderr=subprocess.STDOUT)
record["simulator_returncode"] = process.returncode
record["simulator_stdout"] = {"file": str(log), "sha256": sha(log)}
require(process.returncode == 0, "ModelSim failed; see " + str(log))
transcript = (DATA / "modelsim_transcript.log").read_text(encoding="utf-8", errors="replace")
require("CPU5 BASELINE RAW DUAL SEED PASS" in transcript, "Missing dual-seed success marker")
require(not re.search(r"\*\* (?:Error|Fatal):|Errors: [1-9]", transcript), "Simulator diagnostics contain an error")
warnings = [line for line in transcript.splitlines() if "** Warning:" in line]
def known_optional_irq_warning(line):
    return ("rtl/soc_coremark_axi_top.v(66)" in line and
        (("vopt-2685" in line and "Too few port connections for 'u_core'" in line) or
         ("vopt-2718" in line and "irq_external" in line)))
# Cached optimized designs may not re-emit these diagnostics. Record both
# runs; zero repeated diagnostics does not prove the legacy warning is fixed.
require(len(warnings) in (0, 4) and all(known_optional_irq_warning(line) for line in warnings), "Unexpected warning set: " + repr(warnings))
record["warnings"] = warnings
initial_transcript = (FIRST/"modelsim_transcript.log").read_text(encoding="utf-8",errors="replace")
initial_warnings = [line for line in initial_transcript.splitlines() if "** Warning:" in line]
require(len(initial_warnings) == 4 and all(known_optional_irq_warning(line) for line in initial_warnings), "Unexpected initial warning set")
record["initial_warnings"] = initial_warnings
record["warning_scope"] = "Initial compilation emitted two inherited optional irq_external connection warnings per seed. Cached design reuse may emit none; the warning has not been fixed."
record["prior_harness_failure"] = {"path":str(ROOT/"verification_harness_initial_warning_check"),
    "reason":"Initial recording-harness warning expectation rejected zero repeated diagnostics on cached designs. Only the harness expectation was corrected; product RTL and legacy gates were unchanged."}
record["deterministic_trace_checks"] = {}
record["analysis"] = []
for profile in ("smoke", "smoke_validation"):
    for name in ("retirement_trace.csv", "window_endpoints.csv", "observer_metadata.csv"):
        require(sha(DATA/profile/name) == sha(FIRST/profile/name), "Observation differs on repeated deterministic run: " + profile + "/" + name)
        record["deterministic_trace_checks"][profile+"/"+name] = sha(DATA/profile/name)
    cmd = [sys.executable,"-X","utf8","-B","tools/analyze_cpu5_baseline_raw.py","--profile",profile.replace("_","-"),"--directory","build/cpu5_stage0_measure/"+profile]
    result = subprocess.run(cmd,cwd=WORK,env=env,capture_output=True,text=True,encoding="utf-8")
    record["analysis"].append({"argv":cmd,"returncode":result.returncode,"stdout":result.stdout,"stderr":result.stderr})
    require(result.returncode == 0, "Fresh trace analysis failed: " + result.stdout + result.stderr)
sources_after = {name: sha(WORK/name) for name in sources_before}
require(sources_before == sources_after, "Input sources changed during observation")
record.update(status="PASS", completed_at_utc=utc(), inputs_unchanged=True,
    changed_synthesizable_rtl=False, formal_score_measured=False, cpu5_implemented=False)
(ROOT/"observer_run_verification.json").write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding="utf-8")
print(json.dumps({"status":"PASS","simulator_returncode":process.returncode,"warnings":len(warnings),"deterministic_traces":6,"record":str(ROOT/"observer_run_verification.json")},ensure_ascii=False))
