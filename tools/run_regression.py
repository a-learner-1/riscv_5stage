"""Run declared ModelSim self-checks, or produce a strictly subprocess-free plan.

This runner never invokes a firmware builder, GCC, PDS, programmer or Git write.
Its source was delivered without executing, parsing or validating the new entry.
Only a later actual invocation can produce simulation evidence; no result is a
physical-board acceptance or a formal CoreMark score.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tools/regression_suites.json"
STATES = ("PASS", "FAIL", "BLOCKED", "NOT_RUN")
GUARDS = {"tools/coremark_axi_contract.py", "tools/machine_irq_contract.py", "tools/regression_preflight.py"}
SOURCE_DIRS = ("rtl", "tb", "software", "tools", "tests", "programs", "benchmarks")
SOURCE_SUFFIXES = {
    ".v", ".sv", ".vh", ".svh", ".c", ".h", ".s", ".ld", ".py", ".json",
    ".hex", ".bin", ".mem", ".mif", ".do", ".tcl", ".bat", ".cfg", ".inc",
}
DIAGNOSTIC = re.compile(r"^\s*(?:#\s*)?(?:\*\*\s*(?:Error|Fatal)\b|(?:Error|Fatal)\s*:)", re.IGNORECASE)
TB_FAILURE = re.compile(r"^(?:# )?FAIL(?:[:\s]|$)")


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def relative_path(value):
    """Accept only a normal repo-relative path resolving inside this checkout."""
    if not isinstance(value, str) or not value or "\x00" in value or "\n" in value or "\r" in value:
        raise ValueError("清单包含无效路径")
    portable = value.replace("\\", "/")
    if Path(portable).is_absolute() or PureWindowsPath(value).drive or ".." in portable.split("/"):
        raise ValueError("清单路径必须位于工程内部：" + value)
    path = (ROOT / portable).resolve()
    try:
        path.relative_to(ROOT)
    except ValueError as error:
        raise ValueError("清单路径越过工程边界：" + value) from error
    return path


def rel(path):
    return Path(path).resolve().relative_to(ROOT).as_posix()


def load_manifest():
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8-sig"))
    if not isinstance(manifest, dict):
        raise ValueError("回归清单必须为 JSON 对象")
    if manifest.get("schema_version") != 1:
        raise ValueError("只支持 regression_suites.json schema_version=1")
    cases, groups = manifest.get("cases"), manifest.get("groups")
    if not isinstance(cases, list) or not cases or not isinstance(groups, list) or not groups:
        raise ValueError("清单必须提供非空 cases/groups 数组")
    case_ids, group_ids = set(), set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("清单 case 必须为对象")
        case_id = case.get("id", "")
        if not isinstance(case_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", case_id) or case_id in case_ids:
            raise ValueError("清单 case id 无效或重复")
        case_ids.add(case_id)
        if not isinstance(case.get("title"), str) or not case["title"]:
            raise ValueError("case 缺少 title：" + case_id)
        script = relative_path(case.get("script"))
        if script.suffix.lower() != ".do":
            raise ValueError("只允许清单中的 .do 自检入口：" + case_id)
        timeout = case.get("timeout_seconds")
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not 0 < timeout <= 86400:
            raise ValueError("case timeout_seconds 必须处于 (0,86400]：" + case_id)
        for field in ("required_files", "required_markers", "preflight_commands", "build_hints"):
            if not isinstance(case.get(field), list):
                raise ValueError("case 字段必须为数组 " + field + "：" + case_id)
        for filename in case["required_files"]:
            relative_path(filename)
        if not case["required_markers"]:
            raise ValueError("case 必须提供独立完成证明：" + case_id)
        for marker in case["required_markers"]:
            if not isinstance(marker, str) or not marker.startswith("^") or not marker.endswith("$"):
                raise ValueError("完成证明必须为 ^...$ 行锚定正则：" + case_id)
            re.compile(marker, re.MULTILINE)
        for hint in case["build_hints"]:
            if not isinstance(hint, str):
                raise ValueError("build_hints 必须是说明文本：" + case_id)
        for guard in case["preflight_commands"]:
            if not isinstance(guard, dict) or not isinstance(guard.get("required_files"), list):
                raise ValueError("预检必须声明 required_files：" + case_id)
            argv = guard.get("argv")
            if not isinstance(argv, list) or len(argv) < 2 or not all(isinstance(part, str) and "\x00" not in part for part in argv):
                raise ValueError("预检必须提供 argv 字符串数组：" + case_id)
            # This allowlist contains only read-only image/source contracts.
            # Adding a new builder or arbitrary executable to the manifest is
            # insufficient to make this runner execute it.
            if argv[0].lower() not in ("python", "python3") or argv[1].replace("\\", "/") not in GUARDS:
                raise ValueError("预检只允许现有镜像契约，不允许构建命令：" + case_id)
            if argv[1].replace("\\", "/") == "tools/regression_preflight.py" and (
                    len(argv) != 4 or argv[2] != "--kind" or argv[3] not in ("icache", "dcache", "coremark-prepare")):
                raise ValueError("regression_preflight 只允许 icache/dcache/coremark-prepare 三种只读检查：" + case_id)
            relative_path(argv[1])
            for filename in guard["required_files"]:
                relative_path(filename)
            if not isinstance(guard.get("hint", ""), str):
                raise ValueError("预检 hint 必须是文本：" + case_id)
    for group in groups:
        if not isinstance(group, dict):
            raise ValueError("清单 group 必须为对象")
        group_id = group.get("id", "")
        if not isinstance(group_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", group_id) or group_id == "all" or group_id in group_ids:
            raise ValueError("清单 group id 无效或重复")
        group_ids.add(group_id)
        members = group.get("cases")
        if not isinstance(group.get("title"), str) or not isinstance(members, list) or not members:
            raise ValueError("分组必须提供 title 和非空 cases：" + group_id)
        if len(members) != len(set(members)) or any(member not in case_ids for member in members):
            raise ValueError("分组 case 引用无效或重复：" + group_id)
    if set(member for group in groups for member in group["cases"]) != case_ids:
        raise ValueError("每个 case 必须至少归属一个分组")
    return manifest


def print_listing(manifest):
    print("可选仿真分组（all 包含清单中的全部分组，包括可选板级仿真）：")
    by_id = {case["id"]: case for case in manifest["cases"]}
    for group in manifest["groups"]:
        print("  " + group["id"] + "：" + group["title"])
        for case_id in group["cases"]:
            case = by_id[case_id]
            print("    " + case_id + " -> " + case["script"] + "（" + str(case["timeout_seconds"]) + " 秒超时）")
    print("只列出入口，不调用模拟器、契约、Git 或构建工具。")


def selected_groups(values, manifest):
    known = [group["id"] for group in manifest["groups"]]
    requested = []
    for value in values:
        requested.extend(part.strip() for part in value.split(",") if part.strip())
    if not requested:
        raise ValueError("尚未选择分组；可使用 --group baseline 或 --plan")
    if "all" in requested:
        if any(part not in known and part != "all" for part in requested):
            raise ValueError("存在未知分组")
        return known
    unknown = [part for part in requested if part not in known]
    if unknown:
        raise ValueError("未知分组：" + ", ".join(unknown))
    return [part for part in known if part in requested]


def interactive_menu(manifest):
    if not sys.stdin.isatty():
        print("无参数时需要交互选择；当前没有交互终端。使用 --list、--plan 或 --group 指定操作。")
        return None
    groups = manifest["groups"]
    print("RV32I 仿真回归菜单：默认不运行任何测试。")
    for index, group in enumerate(groups, 1):
        print("  " + str(index) + ". " + group["title"] + " [" + group["id"] + "]")
    print("  A. 运行全部清单分组（包括板级仿真，可能缺前置镜像）")
    print("  P. 只生成全部分组计划，不启动子进程")
    print("  L. 只列出入口")
    print("  0 / 回车. 退出")
    while True:
        try:
            choice = input("选择编号，可逗号分隔：").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\n已退出，未运行。")
            return None
        if choice in ("", "0", "q", "exit"):
            return None
        if choice == "l":
            print_listing(manifest)
            continue
        if choice in ("a", "all"):
            return ["all"], False
        if choice in ("p", "plan"):
            return ["all"], True
        parts = [part.strip() for part in choice.split(",")]
        if all(part.isdigit() and 1 <= int(part) <= len(groups) for part in parts):
            return [groups[int(part)-1]["id"] for part in parts], False
        if all(part in [group["id"] for group in groups] for part in parts):
            return parts, False
        print("输入无效；选择分组编号、A、P、L 或 0。")


def executable_path(value):
    if not value:
        return None
    path = Path(value.strip().strip('"')).expanduser().resolve()
    if path.is_file() and path.name.lower() in ("vsim", "vsim.exe"):
        return path
    return None


def locate_vsim(explicit):
    # An explicit setting is authoritative; never silently replace a bad path.
    if explicit:
        path = executable_path(explicit)
        return path, "--vsim", "" if path else "--vsim 指定的 vsim 文件不存在或名称不正确"
    configured = os.environ.get("MODELSIM_VSIM")
    if configured:
        path = executable_path(configured)
        return path, "MODELSIM_VSIM", "" if path else "MODELSIM_VSIM 指定的 vsim 文件不存在或名称不正确"
    found = shutil.which("vsim") or shutil.which("vsim.exe")
    if found:
        path = executable_path(found)
        if path:
            return path, "PATH", ""
    # Search only existing conventional installation directories. Every returned
    # candidate must be an observed file; no installation/version is assumed.
    roots = []
    for value in (os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)"), os.environ.get("SystemDrive", "C:") + "/"):
        if value and Path(value).is_dir():
            roots.append(Path(value))
    candidates = set()
    patterns = (
        "[Mm]odeltech*/win64/vsim.exe", "[Mm]odeltech*/win32/vsim.exe",
        "[Mm]odel[Ss]im*/win64/vsim.exe", "[Mm]odel[Ss]im*/win32/vsim.exe",
        "[Mm]entor*/[Mm]odel[Ss]im*/win64/vsim.exe", "[Mm]entor*/[Mm]odel[Ss]im*/win32/vsim.exe",
        "intelFPGA*/*/modelsim*/win32*/vsim.exe", "intelFPGA*/*/modelsim*/win64*/vsim.exe",
        "[Aa]ltera/*/modelsim*/win32*/vsim.exe",
    )
    for directory in roots:
        for pattern in patterns:
            for candidate in directory.glob(pattern):
                path = executable_path(str(candidate))
                if path:
                    candidates.add(path)
    if len(candidates) == 1:
        return next(iter(candidates)), "observed_installation_file", ""
    if len(candidates) > 1:
        return None, "ambiguous", "发现多个 vsim；用 --vsim 指定所需版本：" + "; ".join(str(path) for path in sorted(candidates))
    return None, "not_found", "未找到 vsim。设置 MODELSIM_VSIM，或使用 --vsim \"安装目录/win64/vsim.exe\" 指定真实文件"


def hidden_process_options():
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = subprocess.SW_HIDE
        return {"startupinfo": startup, "creationflags": subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def terminate_owned_tree(process):
    """Terminate only the process tree rooted at this exact live Popen PID."""
    if process.poll() is not None:
        return "owned process already exited"
    if os.name == "nt":
        killer = shutil.which("taskkill")
        if killer:
            try:
                subprocess.run([killer, "/PID", str(process.pid), "/T", "/F"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               shell=False, timeout=15, **hidden_process_options())
            except (OSError, subprocess.TimeoutExpired):
                pass
        if process.poll() is None:
            process.kill()
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        return "owned process tree termination did not complete within 15 seconds"
    return "owned process tree terminated"


def run_process(argv, log_path, timeout):
    started = time.monotonic()
    result = {"argv": argv, "started_at": now(), "return_code": None, "timed_out": False,
              "interrupted": False, "spawn_error": None, "log_path": rel(log_path)}
    process = None
    with log_path.open("wb") as log:
        log.write(("RUNNER argv=" + json.dumps(argv, ensure_ascii=False) + "\n").encode("utf-8"))
        log.flush()
        try:
            process = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT, shell=False,
                                       **hidden_process_options())
            result["owned_pid"] = process.pid
            result["return_code"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
            result["termination"] = terminate_owned_tree(process)
            result["return_code"] = process.poll()
        except KeyboardInterrupt:
            result["interrupted"] = True
            if process is not None:
                result["termination"] = terminate_owned_tree(process)
                result["return_code"] = process.poll()
        except OSError as error:
            result["spawn_error"] = str(error)
        finally:
            if process is not None and process.poll() is None:
                result["termination"] = terminate_owned_tree(process)
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    result["completed_at"] = now()
    result["log_sha256"] = sha256(log_path)
    return result


def read_output(path):
    payload = path.read_bytes()
    try:
        return payload.decode("utf-8-sig")
    except UnicodeDecodeError:
        # ASCII diagnostic/completion lines survive the usual Windows encodings.
        return payload.decode("gb18030", errors="replace")


def git_identity():
    git = shutil.which("git")
    if not git:
        return {"status": "unavailable", "reason": "Git 不在 PATH；文件 SHA-256 仍记录"}
    values = {}
    commands = {
        "head": [git, "--no-optional-locks", "-C", str(ROOT), "rev-parse", "HEAD"],
        "tracked_dirty_porcelain": [git, "--no-optional-locks", "-C", str(ROOT), "status", "--porcelain=v1", "--untracked-files=no"],
    }
    for key, argv in commands.items():
        process = None
        try:
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, shell=False, **hidden_process_options())
            output, error = process.communicate(timeout=15)
            if process.returncode:
                return {"status": "unavailable", "reason": error.decode("utf-8", errors="replace").strip()[:500]}
            values[key] = output.decode("utf-8", errors="replace").strip()
        except (OSError, subprocess.TimeoutExpired) as error:
            if process is not None and process.poll() is None:
                terminate_owned_tree(process)
            return {"status": "unavailable", "reason": str(error)}
        except KeyboardInterrupt:
            if process is not None and process.poll() is None:
                terminate_owned_tree(process)
            raise
    return {"status": "available", "head": values["head"],
            "dirty": bool(values["tracked_dirty_porcelain"]),
            "tracked_dirty_porcelain": values["tracked_dirty_porcelain"],
            "untracked_source_policy": "relevant untracked source/image files are included in SHA-256 inventory"}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024*1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_inventory(cases):
    paths = {MANIFEST, Path(__file__).resolve()}
    for directory in SOURCE_DIRS:
        base = ROOT / directory
        if base.is_dir():
            for path in base.rglob("*"):
                if path.is_file() and path.suffix.lower() in SOURCE_SUFFIXES and "__pycache__" not in path.parts:
                    paths.add(relative_path(path.relative_to(ROOT).as_posix()))
    for pattern in ("*.do", "*.bat", "*.tcl"):
        paths.update(relative_path(path.name) for path in ROOT.glob(pattern) if path.is_file())
    if (ROOT / ".gitignore").is_file():
        paths.add(ROOT / ".gitignore")
    for case in cases:
        paths.add(relative_path(case["script"]))
        paths.update(relative_path(filename) for filename in case["required_files"])
        for guard in case["preflight_commands"]:
            paths.add(relative_path(guard["argv"][1]))
            paths.update(relative_path(filename) for filename in guard["required_files"])
    return sorted(paths, key=lambda path: rel(path))


def input_identity(cases, with_git):
    files, metadata, missing, errors = {}, {}, [], []
    try:
        paths = source_inventory(cases)
    except (OSError, ValueError) as error:
        paths = []
        errors.append(str(error))
    for path in paths:
        filename = rel(path)
        if not path.is_file():
            missing.append(filename)
            continue
        try:
            first_stat = path.stat()
            files[filename] = sha256(path)
            last_stat = path.stat()
            metadata[filename] = {"size": last_stat.st_size, "mtime_ns": last_stat.st_mtime_ns}
            if (first_stat.st_size, first_stat.st_mtime_ns) != (last_stat.st_size, last_stat.st_mtime_ns):
                errors.append(filename + ": input changed while hashing")
        except OSError as error:
            errors.append(filename + ": " + str(error))
    signature = hashlib.sha256(json.dumps({"files": files, "metadata": metadata, "missing": missing, "errors": errors},
                                         sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return {"captured_at": now(), "fingerprint_sha256": signature, "files_sha256": files, "files_stat": metadata,
            "missing_files": missing, "errors": errors,
            "git": git_identity() if with_git else {"status": "NOT_RUN", "reason": "计划模式不启动 Git 子进程"},
            "inventory_policy": "rtl/tb/software/tools/tests/programs/benchmarks inputs, root do/bat/tcl, explicit manifest artifacts; excludes generated simulation libraries/logs/INI"}


def identity_changes(before, after):
    names = set(before["files_sha256"]) | set(after["files_sha256"])
    changed = [name for name in sorted(names) if before["files_sha256"].get(name) != after["files_sha256"].get(name)
               or before["files_stat"].get(name) != after["files_stat"].get(name)]
    if before["missing_files"] != after["missing_files"]:
        changed.append("<input missing-file inventory>")
    if before["errors"] or after["errors"]:
        changed.append("<input identity read error>")
    old_git, new_git = before["git"], after["git"]
    if old_git.get("status") == new_git.get("status") == "available" and old_git["head"] != new_git["head"]:
        changed.append("<Git HEAD>")
    return changed


def atomic_text(path, text):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def save_identity(directory, case_id, phase, identity):
    path = directory / (case_id + ".inputs." + phase + ".json")
    atomic_text(path, json.dumps(identity, ensure_ascii=False, indent=2) + "\n")
    return {"path": rel(path), "fingerprint_sha256": identity["fingerprint_sha256"], "git": identity["git"]}


def required_files(case):
    names = {case["script"], *case["required_files"]}
    for guard in case["preflight_commands"]:
        names.add(guard["argv"][1])
        names.update(guard["required_files"])
    return sorted(names)


def missing_files(case):
    return [filename for filename in required_files(case) if not relative_path(filename).is_file()]


def tcl_word(value):
    # A Tcl double-quoted word is safe only after escaping substitution, quotes,
    # backslashes and line breaks. Braces are escaped too, so neither Windows
    # paths nor an unusual workspace name can turn into executable Tcl text.
    escapes = {"\\": "\\\\", '"': '\\"', "$": "\\$", "[": "\\[", "]": "\\]",
               "{": "\\{", "}": "\\}", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return '"' + "".join(escapes.get(char, char) for char in str(value)) + '"'


def run_case(case, record, simulator, directory, run_uuid, selected_cases):
    record["started_at"] = now()
    try:
        record["missing_files"] = missing_files(case)
    except (OSError, ValueError) as error:
        record.update(state="BLOCKED", reason="前置文件路径不可用：" + str(error))
        return False
    if record["missing_files"]:
        record.update(state="BLOCKED", reason="缺少源码或镜像前置文件；未自动构建")
        return False
    if not simulator:
        record.update(state="BLOCKED", reason="没有可用 vsim；未启动模拟器")
        return False
    before = input_identity(selected_cases, with_git=True)
    record["inputs_before"] = save_identity(directory, case["id"], "before", before)
    if before["errors"]:
        record.update(state="BLOCKED", reason="无法完整记录运行输入身份", source_errors=before["errors"])
        return False
    interrupted = False
    try:
        for index, guard in enumerate(case["preflight_commands"], 1):
            argv = [sys.executable, "-B", str(relative_path(guard["argv"][1])), *guard["argv"][2:]]
            result = run_process(argv, directory / (case["id"] + ".preflight-" + str(index) + ".log"),
                                 min(120, case["timeout_seconds"]))
            record["preflight_results"].append(result)
            if result["interrupted"]:
                record.update(state="NOT_RUN", reason="用户中断预检；未开始该项仿真")
                interrupted = True
                return True
            if result["spawn_error"] or result["timed_out"] or result["return_code"] != 0:
                record.update(state="BLOCKED", reason="现有镜像契约预检未通过；请查看预检日志和构建提示")
                return False
        token = "REGRESSION_COMPLETE_" + run_uuid + "_" + case["id"] + "_" + uuid.uuid4().hex
        wrapper = directory / (case["id"] + ".wrapper.do")
        wrapper_text = (
            "# Generated per-run completion wrapper; never reuse as prior evidence.\n"
            "onerror {quit -code 1 -f}\n"
            "if {[catch {source -encoding utf-8 " + tcl_word(relative_path(case["script"]).as_posix()) + "} regression_source_error]} {\n"
            "    puts stderr [format {RUNNER_SOURCE_ERROR: %s} $regression_source_error]\n"
            "    quit -code 1 -f\n"
            "}\n"
            "echo " + tcl_word(token) + "\n"
            "quit -code 0 -f\n"
        )
        atomic_text(wrapper, wrapper_text)
        record["wrapper_path"] = rel(wrapper)
        record["completion_token"] = token
        log_path = directory / (case["id"] + ".log")
        transcript_path = directory / (case["id"] + ".transcript.log")
        argv = [str(simulator), "-c", "-quiet", "-l", str(transcript_path), "-do",
                "source -encoding utf-8 " + tcl_word(wrapper.as_posix())]
        result = run_process(argv, log_path, case["timeout_seconds"])
        record["process"] = result
        record["stdout_log_path"] = rel(log_path)
        record["log_path"] = rel(transcript_path)
        record["evidence_log_path"] = rel(transcript_path)
        console_output = read_output(log_path)
        transcript_exists = transcript_path.is_file()
        output = read_output(transcript_path) if transcript_exists else ""
        record["evidence_log_sha256"] = sha256(transcript_path) if transcript_exists else None
        record["evidence_policy"] = "completion/positive proof from this unique -l transcript only; diagnostics also inspect this run's merged stdout/stderr"
        # Completion is an exact standalone line, rather than echoed command
        # text or a substring copied from a prior transcript.
        token_pattern = r"^(?:# )?" + re.escape(token) + r"\r?$"
        record["completion_token_count"] = len(re.findall(token_pattern, output, re.MULTILINE))
        record["missing_markers"] = [marker for marker in case["required_markers"] if not re.search(marker, output, re.MULTILINE)]
        record["diagnostic_lines"] = sorted(set(line for line in output.splitlines() + console_output.splitlines()
                                                if DIAGNOSTIC.match(line) or TB_FAILURE.match(line)))
        record["simulator_banner_lines"] = [line for line in console_output.splitlines()[:50]
                                             if re.search(r"ModelSim|Questa|vsim.*[Vv]ersion", line)][:8]
        if result["interrupted"]:
            record.update(state="NOT_RUN", reason="用户中断当前仿真；当前及后续未完成项均不算通过")
            interrupted = True
        elif result["spawn_error"]:
            record.update(state="BLOCKED", reason="无法启动已指定的 vsim：" + result["spawn_error"])
        elif result["timed_out"]:
            record.update(state="FAIL", reason="模拟器超时；已终止本次启动的进程树")
        elif result["return_code"] != 0:
            record.update(state="FAIL", reason="模拟器返回非零退出码")
        elif not transcript_exists:
            record.update(state="FAIL", reason="模拟器未生成本轮指定的独立 transcript，无法确认完整证据")
        elif record["completion_token_count"] != 1:
            record.update(state="FAIL", reason="缺少或重复本轮独有 wrapper 完成标记")
        elif record["diagnostic_lines"]:
            record.update(state="FAIL", reason="出现明确 ModelSim Error/Fatal 诊断或行首 TB FAIL")
        elif record["missing_markers"]:
            record.update(state="FAIL", reason="没有出现清单要求的全部独立完成证明")
        else:
            record.update(state="PASS", reason="本轮退出码、唯一完成标记、全部正向证明及诊断检查通过")
        return interrupted
    except KeyboardInterrupt:
        interrupted = True
        record.update(state="NOT_RUN", reason="用户中断当前项；没有完整完成证据")
        return True
    except (OSError, ValueError) as error:
        record.update(state="FAIL", reason="运行或证据保存异常：" + str(error))
        return False
    finally:
        try:
            after = input_identity(selected_cases, with_git=not interrupted)
            record["inputs_after"] = save_identity(directory, case["id"], "after", after)
            record["source_changes"] = identity_changes(before, after)
            if record["source_changes"] and record["state"] == "PASS":
                record.update(state="FAIL", reason="运行期间源码、镜像或 Git HEAD 改变，不能标记为当前版本通过")
        except (OSError, ValueError, KeyboardInterrupt) as error:
            if record["state"] == "PASS":
                record.update(state="FAIL", reason="无法完成运行后输入身份核对")
            record["identity_after_error"] = str(error)
        record["completed_at"] = now()


def aggregate(records, planned):
    if planned:
        return "NOT_RUN"
    selected = [record["state"] for record in records if record["selected"]]
    if "FAIL" in selected:
        return "FAIL"
    if "BLOCKED" in selected:
        return "BLOCKED"
    if not selected or "NOT_RUN" in selected:
        return "NOT_RUN"
    return "PASS"


def markdown_text(report):
    lines = ["# RV32I 仿真回归记录", "", "- 运行编号：`" + report["run_id"] + "`",
             "- 模式：" + ("计划，未运行任何子进程" if report["planned"] else "实际仿真"),
             "- 选择分组：`" + ", ".join(report["selected_groups"]) + "`",
             "- 所选项汇总：**" + report["selected_aggregate"] + "**", "",
             "PASS 仅表示本次所选 ModelSim 自检具备完整证据；不代表全工程验收、实物上板通过或正式 CoreMark 成绩。",
             "计划中的 NOT_RUN、缺文件、源码编写完成及既往日志均不能算新验证。", "",
             "| 测试项 | 选择 | 状态 | 说明 | 日志 |", "| --- | --- | --- | --- | --- |"]
    for record in report["cases"]:
        safe = lambda value: str(value).replace("|", "\\|").replace("\n", " ")
        log = record.get("log_path", "")
        lines.append("| " + safe(record["id"] + " / " + record["title"]) + " | " +
                     ("是" if record["selected"] else "否") + " | " + record["state"] + " | " +
                     safe(record["reason"]) + " | " + ("`" + safe(log) + "`" if log else "未启动") + " |")
    for record in report["cases"]:
        if not record["selected"]:
            continue
        details = []
        if record["missing_files"]:
            details += ["缺少前置文件："] + ["- `" + filename + "`" for filename in record["missing_files"]]
        if record.get("source_changes"):
            details += ["发生输入变化："] + ["- `" + filename + "`" for filename in record["source_changes"]]
        if record.get("missing_markers"):
            details += ["缺少正向证明（锚定正则）："] + ["- `" + marker + "`" for marker in record["missing_markers"]]
        if record.get("diagnostic_lines"):
            details += ["模拟器明确诊断："] + ["- " + line for line in record["diagnostic_lines"][:20]]
        if record["state"] != "PASS" and record["build_hints"]:
            details += ["操作提示（仅文本；本入口没有执行）："] + ["- `" + hint + "`" for hint in record["build_hints"]]
        if details:
            lines += ["", "## " + record["id"], "", *details]
    lines += ["", "输入身份、Git HEAD/已跟踪修改状态、SHA-256、预检结果和独有完成标记见同目录 summary.json 及 inputs.*.json。",
              "每项 .log 合并本轮 stdout/stderr；.transcript.log 是唯一正向证据来源。不会拼接两份日志计完成标记，不读取旧 transcript，不以裸 PASS/FAIL 子串判定。",
              "如果没有 Git，仍记录文件身份；modelsim.ini、工作库、日志及波形属于运行产物，不参与源码身份比较。", ""]
    return "\n".join(lines)


def write_report(report, directory):
    report["selected_aggregate"] = aggregate(report["cases"], report["planned"])
    atomic_text(directory / "summary.json", json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    atomic_text(directory / "summary.md", markdown_text(report))
    # latest.json is only a locator. A previous summary/log is never reused as
    # evidence, and every plan/run keeps its own unique directory permanently.
    locator = {"run_id": report["run_id"], "planned": report["planned"],
               "selected_aggregate": report["selected_aggregate"],
               "summary_json": rel(directory / "summary.json"), "summary_markdown": rel(directory / "summary.md")}
    atomic_text(directory.parent / "latest.json", json.dumps(locator, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description="按清单运行现有 ModelSim 自检；不会构建固件或下载板卡")
    parser.add_argument("--group", action="append", default=[], metavar="GROUP[,GROUP]",
                        help="可重复或逗号分组；all 包含全部清单分组")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="只列出分组，不启动子进程，不生成运行结果")
    mode.add_argument("--plan", action="store_true", help="默认计划all，只生成NOT_RUN/缺文件记录，不运行任何子进程")
    parser.add_argument("--vsim", metavar="VSIM_EXE", help="精确指定现有 vsim/vsim.exe 文件路径")
    args = parser.parse_args()
    try:
        manifest = load_manifest()
        if args.list:
            print_listing(manifest)
            return 0
        planned, choices = args.plan, args.group
        if not choices:
            if planned:
                choices = ["all"]
            else:
                selection = interactive_menu(manifest)
                if selection is None:
                    return 0
                choices, planned = selection
        groups = selected_groups(choices, manifest)
        members = set(member for group in manifest["groups"] if group["id"] in groups for member in group["cases"])
        selected = [case for case in manifest["cases"] if case["id"] in members]
        simulator, simulator_source, simulator_hint = locate_vsim(args.vsim)
        run_uuid = uuid.uuid4().hex
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ_") + run_uuid[:12]
        directory = relative_path("build/regression/" + run_id)
        directory.mkdir(parents=True, exist_ok=False)
        report = {"schema_version": 1, "run_id": run_id, "run_uuid": run_uuid, "started_at": now(),
                  "planned": planned, "repo_root": str(ROOT), "manifest": rel(MANIFEST),
                  "manifest_sha256": sha256(MANIFEST), "runner_sha256": sha256(Path(__file__).resolve()),
                  "selected_groups": groups, "cases": [], "interrupted": False,
                  "simulator": {"path": str(simulator) if simulator else None,
                                "discovery_source": simulator_source, "hint": simulator_hint,
                                "version_probe": "NOT_RUN; tool banner is captured only when a selected simulation actually runs"},
                  "boundary": {"firmware_build": False, "pds_build": False, "hardware_download": False,
                               "git_write": False, "physical_acceptance": False, "formal_coremark_score": False}}
        for case in manifest["cases"]:
            is_selected = case["id"] in members
            hints = list(case["build_hints"])
            hints.extend(guard["hint"] for guard in case["preflight_commands"] if guard.get("hint") and guard["hint"] not in hints)
            report["cases"].append({"id": case["id"], "title": case["title"], "script": case["script"],
                                     "selected": is_selected, "state": "NOT_RUN",
                                     "reason": "计划模式：未执行" if planned and is_selected else "尚未运行" if is_selected else "未选择该项",
                                     "missing_files": missing_files(case) if is_selected else [],
                                     "required_markers": case["required_markers"], "build_hints": hints,
                                     "timeout_seconds": case["timeout_seconds"], "preflight_results": []})
        # Planning is strictly read-only except for its own new report directory.
        # In particular with_git=False avoids every subprocess, even Git/version.
        # Keep an initial NOT_RUN report even if the user cancels while the
        # first file inventory/Git query is being collected.
        write_report(report, directory)
        try:
            before = input_identity(selected, with_git=not planned)
        except KeyboardInterrupt:
            report["interrupted"] = True
            report["completed_at"] = now()
            for record in report["cases"]:
                if record["selected"]:
                    record["reason"] = "用户在输入身份记录阶段中断，未启动测试"
            write_report(report, directory)
            print("已中断；所选项均未运行。报告：" + str(directory / "summary.md"))
            return 130
        report["run_inputs_before"] = save_identity(directory, "run", "before", before)
        write_report(report, directory)
        if planned:
            for record in report["cases"]:
                if record["selected"]:
                    print(record["id"] + "：NOT_RUN；缺少前置文件 " + str(len(record["missing_files"])) + " 个")
                    for filename in record["missing_files"]:
                        print("  缺少 " + filename)
                    for hint in record["build_hints"]:
                        print("  提示（未执行） " + hint)
            print("计划已保存，未启动任何子进程：" + str(directory / "summary.md"))
            report["completed_at"] = now()
            write_report(report, directory)
            return 0
        print("仅运行现有仿真入口；all 的范围以清单为准。缺镜像/契约过期只记录 BLOCKED，不自动构建。")
        if simulator_hint:
            print(simulator_hint)
        try:
            by_id = {case["id"]: case for case in selected}
            for record in report["cases"]:
                if not record["selected"]:
                    continue
                print("开始 " + record["id"] + "：" + record["title"], flush=True)
                interrupted = run_case(by_id[record["id"]], record, simulator, directory, run_uuid, selected)
                print(record["id"] + "：" + record["state"] + "；" + record["reason"], flush=True)
                write_report(report, directory)
                if interrupted:
                    report["interrupted"] = True
                    break
        except KeyboardInterrupt:
            report["interrupted"] = True
            for record in report["cases"]:
                if record["selected"] and record["state"] == "NOT_RUN" and "started_at" in record:
                    record["reason"] = "用户在输入准备或预检阶段中断该项；没有完成证据"
        finally:
            try:
                after = input_identity(selected, with_git=not report["interrupted"])
                report["run_inputs_after"] = save_identity(directory, "run", "after", after)
                report["run_source_changes"] = identity_changes(before, after)
                if report["run_source_changes"]:
                    for record in report["cases"]:
                        if record["selected"] and record["state"] == "PASS":
                            record.update(state="FAIL", reason="整轮期间输入或 Git HEAD 改变；此前完成记录不能算当前输入版本通过")
            except (OSError, ValueError, KeyboardInterrupt) as error:
                report["run_identity_after_error"] = str(error)
                for record in report["cases"]:
                    if record["selected"] and record["state"] == "PASS":
                        record.update(state="FAIL", reason="整轮运行后输入身份无法核对")
            if report["interrupted"]:
                for record in report["cases"]:
                    if record["selected"] and record["state"] == "NOT_RUN" and "started_at" not in record:
                        record["reason"] = "用户中断后未启动该项"
            report["completed_at"] = now()
            write_report(report, directory)
        print("所选项汇总：" + report["selected_aggregate"] + "；报告：" + str(directory / "summary.md"))
        if report["interrupted"]:
            return 130
        return 0 if report["selected_aggregate"] == "PASS" else 2 if report["selected_aggregate"] == "BLOCKED" else 1
    except (OSError, ValueError, KeyError, TypeError, re.error) as error:
        print("回归入口未能完成：" + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
