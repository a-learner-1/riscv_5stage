#!/usr/bin/env python3
"""Export identified CPU source; package creation is never validation evidence."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import stat
import subprocess
import sys
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOPS = {"rtl", "tb", "software", "programs", "benchmarks", "tools", "tests", "pds", "docs"}
EXTENSIONS = {".v", ".sv", ".vh", ".svh", ".c", ".h", ".s", ".ld", ".py", ".json",
              ".do", ".tcl", ".bat", ".md", ".txt", ".hex", ".mem", ".mif", ".fdc",
              ".sdc", ".cfg", ".inc"}
REQUIRED = (
    "README.md", "Makefile", ".gitignore", "export_cpu_package.bat",
    "tools/export_cpu_package.py", "docs/cpu_handoff.md", "software/start.S",
    "software/link.ld", "software/mmio.h", "pds/board_top.fdc",
    "benchmarks/coremark/LICENSE.md", "benchmarks/coremark/SOURCE.md",
    "rtl/cpu_top.v", "rtl/rv32m_unit.v", "rtl/soc_axi_lite_top.v", "rtl/dmem_axi_lite_bridge.v",
    "rtl/instr_mem.v", "rtl/if_stage.v", "rtl/decoder.v", "rtl/regfile.v",
    "rtl/alu.v", "rtl/data_mem.v", "rtl/data_bus_adapter.v", "rtl/instr_bus_adapter.v",
    "rtl/uart_tx.v", "rtl/uart_rx.v", "rtl/uart_rx_fifo.v", "rtl/uart_rx_mmio.v",
    "rtl/gpio_mmio.v", "rtl/machine_timer.v", "rtl/branch_predictor.v",
    "rtl/soc_instr_mem.v", "rtl/instr_cache.v", "rtl/data_cache.v",
)
SOURCE_OF_TRUTH = (
    "docs/cpu_handoff.md", "rtl/cpu_top.v", "rtl/soc_axi_lite_top.v",
    "software/link.ld", "tools/build_pds_board.py", "pds/board_top.fdc",
)
REGULAR_MODES = {"100644", "100755"}
ZIP_ROOT = "riscv_3stage/"
TIMEOUT_SECONDS = 15


class ExportError(Exception):
    """A friendly, non-validation export failure."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def text_value(data: bytes) -> str:
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ExportError("Git 路径或元数据不是 UTF-8；本工具拒绝不明确的名称。") from exc


def safe_name(name: str) -> str:
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or "\\" in name or ":" in name
            or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or any(part in {"", ".", ".."} for part in name.split("/"))):
        raise ExportError("Git 中存在不安全的相对路径，已拒绝导出。")
    return name


def selected_name(name: str) -> bool:
    safe_name(name)
    path = PurePosixPath(name)
    parts = path.parts
    lower = [part.lower() for part in parts]
    if any(part in {".git", "build", "work", "__pycache__", ".pytest_cache", ".mypy_cache",
                        ".ruff_cache", "node_modules", ".cache"}
           or part.endswith("_work") for part in lower):
        return False
    leaf = lower[-1]
    if (leaf == "modelsim.ini" or leaf == ".env" or leaf.startswith(".env.")
            or leaf.endswith(".bak") or ".bak." in leaf):
        return False
    if len(parts) == 1:
        return (leaf in {"readme.md", "makefile", ".gitignore", "export_cpu_package.bat"}
                or (leaf.startswith("license") and path.suffix.lower() in {"", ".md", ".txt"})
                or re.fullmatch(r"build_.+\.bat|run_.+\.(?:bat|do)", leaf) is not None)
    return parts[0] in TOPS and path.suffix.lower() in EXTENSIONS


def reparse(st: os.stat_result) -> bool:
    return stat.S_ISLNK(st.st_mode) or bool(getattr(st, "st_file_attributes", 0) & 0x400)


def check_root() -> None:
    # Examine the path itself and ancestors before using any repository file.
    for component in (ROOT, *ROOT.parents):
        if reparse(component.lstat()):
            raise ExportError("工程路径包含符号链接或重解析点，已拒绝导出。")


def local_file(name: str) -> Path | None:
    """None means absent/nonregular/reparse; never follow directory links."""
    safe_name(name)
    current = ROOT
    for number, part in enumerate(PurePosixPath(name).parts):
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            return None
        if reparse(info):
            return None
        last = number == len(PurePosixPath(name).parts) - 1
        if (last and not stat.S_ISREG(info.st_mode)) or (not last and not stat.S_ISDIR(info.st_mode)):
            return None
    return current


def stable_read(name: str) -> tuple[bytes, dict[str, object]]:
    path = local_file(name)
    if path is None:
        raise ExportError(f"源码不存在、不是普通文件或包含链接：{name}")
    before = path.lstat()
    content = path.read_bytes()
    after_path = local_file(name)
    if after_path is None:
        raise ExportError(f"读取过程中源码路径发生变化：{name}")
    after = after_path.lstat()
    identity_before = (before.st_size, before.st_mtime_ns, before.st_ctime_ns, before.st_dev, before.st_ino)
    identity_after = (after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_dev, after.st_ino)
    if identity_before != identity_after or len(content) != after.st_size:
        raise ExportError(f"读取过程中源码发生变化：{name}")
    return content, {"size": len(content), "mtime_ns": after.st_mtime_ns,
                     "ctime_ns": after.st_ctime_ns, "sha256": digest(content)}


def stop_owned(process: subprocess.Popen[bytes]) -> None:
    """Only terminate the process tree created by this invocation."""
    if process.poll() is not None:
        return
    if os.name == "nt":
        try:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           shell=False, timeout=TIMEOUT_SECONDS,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
    if process.poll() is None:
        try:
            process.kill()  # Fallback is limited to the exact still-owned Popen PID.
        except OSError:
            pass
    try:
        process.wait(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=TIMEOUT_SECONDS)


class Git:
    def __init__(self) -> None:
        self.options = ["--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false"]
        # Status can consult clean filters. Disable configured drivers without reading,
        # recording or executing their command values; cat-file uses raw blobs.
        code, names = self.run(["config", "--name-only", "--get-regexp",
                                r"^filter\..*\.(clean|smudge|process|required)$"], allowed=(0, 1))
        if code == 0:
            drivers = set()
            for key in text_value(names).splitlines():
                if key.startswith("filter.") and "." in key[7:]:
                    drivers.add(key[7:].rsplit(".", 1)[0])
            for driver in sorted(drivers):
                if any(ord(char) < 32 for char in driver):
                    raise ExportError("Git filter 配置名称无效。")
                for kind in ("clean", "smudge", "process"):
                    self.options.extend(["-c", f"filter.{driver}.{kind}="])
                self.options.extend(["-c", f"filter.{driver}.required=false"])
        _, worktree = self.run(["rev-parse", "--is-inside-work-tree"])
        _, top = self.run(["rev-parse", "--show-toplevel"])
        if text_value(worktree).strip() != "true" or Path(text_value(top).strip()).resolve() != ROOT:
            raise ExportError("导出入口必须位于 CPU 工程 Git 根目录，不能借用上级仓库。")

    def run(self, arguments: list[str], input_bytes: bytes | None = None,
            allowed: tuple[int, ...] = (0,)) -> tuple[int, bytes]:
        environment = os.environ.copy()
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"  # Missing local blobs must fail, never fetch.
        kwargs: dict[str, object] = {"cwd": ROOT, "shell": False, "env": environment,
                                    "stdin": subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
                                    "stdout": subprocess.PIPE, "stderr": subprocess.PIPE}
        if os.name == "nt":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = subprocess.SW_HIDE
            kwargs["startupinfo"] = startup
            kwargs["creationflags"] = (getattr(subprocess, "CREATE_NO_WINDOW", 0)
                                        | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
        else:
            kwargs["start_new_session"] = True
        try:
            process = subprocess.Popen(["git", *self.options, "-C", str(ROOT), *arguments], **kwargs)
        except OSError as exc:
            raise ExportError("找不到可用 Git；不能确定源码版本。请安装 Git 并在工程中提交代码。") from exc
        try:
            output, _ = process.communicate(input=input_bytes, timeout=TIMEOUT_SECONDS)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
            try:
                stop_owned(process)
            except (OSError, subprocess.TimeoutExpired):
                pass
            if isinstance(exc, KeyboardInterrupt):
                raise
            raise ExportError("Git 只读查询超时；没有完成交接包。") from exc
        if process.returncode not in allowed:
            # stderr can contain local usernames/absolute paths: do not put it in reports.
            raise ExportError("Git 只读查询失败；请确认工程为可读取的 Git 仓库。")
        return process.returncode, output

    def snapshot(self) -> dict[str, object]:
        head_code, head_raw = self.run(["rev-parse", "--verify", "HEAD"], allowed=(0, 128))
        head = text_value(head_raw).strip() if head_code == 0 else None
        if head is not None and re.fullmatch(r"[0-9a-f]{40,64}", head) is None:
            raise ExportError("Git HEAD 标识无效。")
        branch_code, branch_raw = self.run(["symbolic-ref", "--quiet", "--short", "HEAD"], allowed=(0, 1, 128))
        branch = text_value(branch_raw).strip() if branch_code == 0 else None
        _, index_raw = self.run(["ls-files", "--stage", "-z"])
        index: dict[str, dict[str, str]] = {}
        conflicted = False
        for record in index_raw.split(b"\0"):
            if not record:
                continue
            header, name_raw = record.split(b"\t", 1)
            mode, oid, stage = text_value(header).split(" ")
            name = safe_name(text_value(name_raw))
            if stage != "0":
                conflicted = True
            index[name] = {"mode": mode, "oid": oid, "stage": stage}
        _, others_raw = self.run(["ls-files", "--others", "--exclude-standard", "-z"])
        others = sorted({safe_name(text_value(name)) for name in others_raw.split(b"\0") if name})
        _, status_raw = self.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        records = status_raw.split(b"\0")
        porcelain: list[dict[str, str]] = []
        position = 0
        while position < len(records):
            record = records[position]
            position += 1
            if not record:
                continue
            if len(record) < 4 or record[2:3] != b" ":
                raise ExportError("无法读取 Git porcelain 状态。")
            xy = text_value(record[:2])
            item = {"status": xy, "path": safe_name(text_value(record[3:]))}
            if "R" in xy or "C" in xy:
                if position >= len(records) or not records[position]:
                    raise ExportError("Git 重命名状态不完整。")
                item["from"] = safe_name(text_value(records[position]))
                position += 1
            # Generated output and unrelated ignored/untracked files are not package inputs.
            if xy != "??" or selected_name(item["path"]):
                porcelain.append(item)
        tree: dict[str, dict[str, str]] = {}
        if head is not None:
            _, tree_raw = self.run(["ls-tree", "-r", "-z", "--full-tree", head])
            for record in tree_raw.split(b"\0"):
                if record:
                    header, name_raw = record.split(b"\t", 1)
                    mode, kind, oid = text_value(header).split(" ")
                    tree[safe_name(text_value(name_raw))] = {"mode": mode, "kind": kind, "oid": oid}
        return {"head": head, "branch": branch, "index_sha256": digest(index_raw), "index": index,
                "others": others, "porcelain": porcelain, "tree": tree, "conflicted": conflicted}

    def blobs(self, entries: dict[str, dict[str, str]]) -> dict[str, bytes]:
        objects = sorted({entry["oid"] for entry in entries.values()})
        if any(re.fullmatch(r"[0-9a-f]{40,64}", oid) is None for oid in objects):
            raise ExportError("Git blob 标识无效。")
        _, output = self.run(["cat-file", "--batch"], ("\n".join(objects) + "\n").encode("ascii"))
        position = 0
        content: dict[str, bytes] = {}
        for oid in objects:
            end = output.find(b"\n", position)
            if end < 0:
                raise ExportError("Git blob 响应不完整。")
            fields = output[position:end].split(b" ")
            if len(fields) != 3 or fields[0] != oid.encode("ascii") or fields[1] != b"blob":
                raise ExportError("Git blob 类型或身份不匹配。")
            try:
                size = int(fields[2])
            except ValueError as exc:
                raise ExportError("Git blob 长度无效。") from exc
            position = end + 1
            if size < 0 or position + size >= len(output) or output[position + size:position + size + 1] != b"\n":
                raise ExportError("Git blob 内容长度不匹配。")
            content[oid] = output[position:position + size]
            position += size + 1
        if position != len(output):
            raise ExportError("Git blob 响应包含额外数据。")
        return {name: content[entry["oid"]] for name, entry in entries.items()}


def choose_sources(snapshot: dict[str, object], current: bool) -> tuple[dict[str, dict[str, str]], list[str], Counter]:
    entries = snapshot["index"] if current else snapshot["tree"]
    candidates = dict(entries)
    if current:
        for name in snapshot["others"]:
            candidates[name] = {"mode": "100644", "stage": "0", "oid": ""}
    selected: dict[str, dict[str, str]] = {}
    unavailable: list[str] = []
    excluded = Counter()
    folded: dict[str, str] = {}
    for name, entry in sorted(candidates.items()):
        if not selected_name(name):
            excluded["outside_source_allowlist"] += 1
            continue
        if entry["mode"] not in REGULAR_MODES or entry.get("stage", "0") != "0":
            excluded["nonregular_git_mode_or_conflict"] += 1
            continue
        if local_file(name) is None:
            unavailable.append(name)
            excluded["absent_nonregular_or_reparse_worktree"] += 1
            continue
        if name.casefold() in folded:
            raise ExportError("源码名称在 Windows 下冲突，已拒绝导出。")
        folded[name.casefold()] = name
        selected[name] = entry
    return selected, unavailable, excluded


def blockers(snapshot: dict[str, object], sources: dict[str, dict[str, str]],
             unavailable: list[str], current: bool) -> list[str]:
    messages = []
    if snapshot["conflicted"]:
        messages.append("Git index 有合并冲突，请先解决并提交。")
    if not current:
        if snapshot["head"] is None:
            messages.append("尚无 Git HEAD 提交；先提交，或明确使用 --include-uncommitted。")
        if any(item["status"] != "??" for item in snapshot["porcelain"]):
            messages.append("tracked 工作区/index 有改动；先提交，或明确使用 --include-uncommitted。")
        new_sources = [name for name in snapshot["others"] if selected_name(name) and local_file(name) is not None]
        if new_sources:
            messages.append("存在未提交的候选源码：" + ", ".join(new_sources)
                            + "；先提交，或明确使用 --include-uncommitted。")
        if unavailable:
            messages.append("HEAD 候选源码在工作区缺失或为链接：" + ", ".join(unavailable))
    missing = [name for name in REQUIRED if name not in sources]
    if missing:
        messages.append("本来源缺少必需文件：" + ", ".join(missing)
                        + "。新交接工具/文档需先提交，或使用 --include-uncommitted。")
    if not sources:
        messages.append("没有可导出的白名单源码。")
    return messages


def source_identity(sources: dict[str, dict[str, str]], snapshot: dict[str, object],
                    observations: dict[str, dict[str, object]]) -> dict[str, object]:
    return {"head": snapshot["head"], "branch": snapshot["branch"],
            "index_sha256": snapshot["index_sha256"], "porcelain": snapshot["porcelain"],
            "selected_untracked": sorted(name for name in snapshot["others"] if selected_name(name)),
            "selected_entries": sources, "working_files": observations}


def exclusive_write(path: Path, data: bytes) -> None:
    with path.open("xb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def output_directory(run_id: str) -> Path:
    parent = ROOT
    for part in ("build", "handoff"):
        parent = parent / part
        if parent.exists():
            info = parent.lstat()
            if reparse(info) or not stat.S_ISDIR(info.st_mode):
                raise ExportError("输出目录包含链接或不是普通目录，已拒绝写入。")
        else:
            parent.mkdir()
    destination = parent / run_id
    destination.mkdir(exist_ok=False)
    return destination


def publish_without_overwrite(partial: Path, final: Path) -> None:
    if os.name == "nt":
        # Windows rename refuses an existing destination. Do not use os.replace.
        os.rename(partial, final)
    else:
        # link provides no-overwrite publication on systems where rename replaces.
        os.link(partial, final)
        partial.unlink()


def package(git: Git, initial: dict[str, object], sources: dict[str, dict[str, str]],
            unavailable: list[str], excluded: Counter, current: bool) -> Path:
    raw: dict[str, bytes] = {}
    observed: dict[str, dict[str, object]] = {}
    for name in sources:
        raw[name], observed[name] = stable_read(name)
    contents = raw if current else git.blobs(sources)
    if any(b"\0" in content for content in contents.values()):
        raise ExportError("白名单文本文件含 NUL 字节；拒绝将二进制伪装为源码导出。")
    records = []
    for name in sources:
        record = {"path": name, "size": len(contents[name]), "sha256": digest(contents[name]),
                  "git_tracked": name in initial["index"] if current else True}
        if not current:
            record["git_blob_oid"] = sources[name]["oid"]
        records.append(record)
    source_hash = digest(json_bytes(records))
    instant = datetime.now(timezone.utc)
    run_id = instant.strftime("%Y%m%dT%H%M%SZ") + "_" + uuid.uuid4().hex[:12]
    manifest = {
        "schema_version": 1, "package_kind": "cpu-source-handoff", "run_id": run_id,
        "created_utc": instant.isoformat(), "source_mode": "working-tree" if current else "git-head",
        "validation_status": "NOT_RUN", "source_list_sha256": source_hash, "source_count": len(records),
        "hash_meaning": "身份与传输完整性标识；不代表编译、仿真、时序、上板或成绩验证。",
        "git": {"head": initial["head"], "head_available": initial["head"] is not None,
                "head_role": "baseline_only" if current else "source_commit",
                "branch": initial["branch"], "branch_available": initial["branch"] is not None,
                "tracked_or_index_dirty": any(item["status"] != "??" for item in initial["porcelain"]),
                "dirty_porcelain": initial["porcelain"], "index_listing_sha256": initial["index_sha256"],
                "uncommitted_selected_files": sorted(
                    {name for name in sources if name not in initial["index"]}
                    | {item["path"] for item in initial["porcelain"] if item["path"] in sources})},
        "source_of_truth_paths": list(SOURCE_OF_TRUTH), "files": records,
        "excluded_reason_counts": dict(excluded), "unavailable_working_source_paths": unavailable,
        "build_reports_included": False,
        "guard_note": "build/、工作库与构建报告未打包；镜像/源码不匹配或报告缺失时守卫会 BLOCKED。",
        "scope": {"build_run": False, "simulation_run": False, "pds_run": False,
                  "physical_board_verified": False, "coremark_score_verified": False},
    }
    manifest_data = json_bytes(manifest)
    head_label = initial["head"] or "不可用（当前工作区来源，没有提交基线）"
    mode_label = "当前工作区原始字节；HEAD 仅作基线，允许包含未提交内容" if current else "已提交 HEAD 的原始 Git blob"
    handoff_data = (f"# CPU 源码交接包\n\n详细操作、配置表与联调边界见 [docs/cpu_handoff.md](docs/cpu_handoff.md)。\n\n"
                    f"- 来源：{mode_label}\n- Git HEAD：`{head_label}`\n"
                    f"- 源码列表 SHA-256：`{source_hash}`\n- 验证状态：**NOT_RUN**\n\n"
                    "哈希只标识包内源码，不证明功能正确或成绩有效。导出工具没有解析、证实 RTL 参数。\n\n"
                    "本包不包含 build/ 构建报告、ModelSim 工作库或 FPGA 位流；即使含已提交的 HEX，"
                    "仍须按文档准备相符镜像和报告。缺报告或源码哈希不符会使守卫 BLOCKED。\n"
                    "不要将打包成功当作编译、仿真、时序、实物或 CoreMark 验收通过。\n").encode("utf-8")
    before_identity = source_identity(sources, initial, observed)
    destination = output_directory(run_id)
    partial = destination / "cpu_source.zip.partial"
    final = destination / "cpu_source.zip"
    try:
        members = {ZIP_ROOT + name: content for name, content in contents.items()}
        members[ZIP_ROOT + "HANDOFF.md"] = handoff_data
        members[ZIP_ROOT + "handoff_manifest.json"] = manifest_data
        stamp = instant.timetuple()[:6]
        with partial.open("xb") as output:
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, content in members.items():
                    info = zipfile.ZipInfo(name, date_time=stamp)
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.create_system = 3
                    info.external_attr = (stat.S_IFREG | 0o644) << 16
                    archive.writestr(info, content)
            output.flush()
            os.fsync(output.fileno())
        # This checks ZIP transfer integrity only, never CPU functionality.
        with zipfile.ZipFile(partial, "r") as archive:
            if archive.namelist() != list(members):
                raise ExportError("交接 ZIP 成员列表不一致。")
            for name, expected in members.items():
                if archive.read(name) != expected:
                    raise ExportError("交接 ZIP 内容回读不一致。")
        after_observed = {name: stable_read(name)[1] for name in sources}
        after = git.snapshot()
        after_sources, after_unavailable, _ = choose_sources(after, current)
        if (before_identity != source_identity(after_sources, after, after_observed)
                or unavailable != after_unavailable):
            raise ExportError("打包过程中 HEAD、index、源码集合、状态或文件发生变化；请重试。")
        final_blockers = blockers(after, after_sources, after_unavailable, current)
        if final_blockers:
            raise ExportError("打包结束时来源不再满足前置条件。")
        zip_sha = digest(partial.read_bytes())
        # Copies use exactly the same bytes as the members, with no hash cycle.
        exclusive_write(destination / "handoff_manifest.json", manifest_data)
        exclusive_write(destination / "HANDOFF.md", handoff_data)
        exclusive_write(destination / "cpu_source.zip.sha256", (zip_sha + "  cpu_source.zip\n").encode("ascii"))
        publish_without_overwrite(partial, final)
        report = {"schema_version": 1, "run_id": run_id, "package_generation": "COMPLETE",
                  "validation_status": "NOT_RUN", "zip_filename": final.name, "zip_sha256": zip_sha,
                  "zip_member_count": len(members), "source_count": len(records),
                  "source_mode": manifest["source_mode"], "source_list_sha256": source_hash,
                  "note": "只完成源码包装与完整性回读；未运行编译、仿真、PDS、上板或性能验收。"}
        report_partial = destination / "package_report.json.partial"
        exclusive_write(report_partial, json_bytes(report))
        publish_without_overwrite(report_partial, destination / "package_report.json")
        return destination
    except BaseException:
        # Do not remove or overwrite any user file; an incomplete run stays identifiable.
        try:
            exclusive_write(destination / "NOT_COMPLETE.txt",
                            "交接包生成未完成。没有验证通过的结论，请勿将此目录作为成功交付。\n".encode("utf-8"))
        except OSError:
            pass
        raise


def show_plan(snapshot: dict[str, object], sources: dict[str, dict[str, str]],
              unavailable: list[str], excluded: Counter, current: bool, issues: list[str]) -> None:
    print("CPU 源码交接计划（NOT_RUN；只读取，不写 ZIP、不构建、不验证）")
    print("来源：" + ("当前工作区；HEAD 仅作基线" if current else "已提交 HEAD 的原始 Git blob"))
    print("HEAD：" + str(snapshot["head"] or "不可用"))
    print("分支：" + str(snapshot["branch"] or "不可用或 detached HEAD"))
    print(f"可选普通源码 {len(sources)} 项；按原因排除 {sum(excluded.values())} 项。")
    for name in sources:
        print("  " + name)
    if unavailable:
        print("缺失/非普通文件/链接候选：" + ", ".join(unavailable))
    if issues:
        print("导出前置条件尚未满足：")
        for issue in issues:
            print("  - " + issue)
    else:
        print("上述只读前置查询未发现阻塞；真正导出还会读取源码并检查打包前后身份。")
    print("输出固定为 build/handoff/<UTC+UUID>/cpu_source.zip；本计划没有生成产物。")


def main() -> int:
    parser = argparse.ArgumentParser(description="CPU 源码交接导出；打包成功不代表验证通过。")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--export", action="store_true", help="导出源码 ZIP，不编译或验证")
    mode.add_argument("--plan", action="store_true", help="只读列出来源、候选和阻塞，不生成 ZIP")
    parser.add_argument("--include-uncommitted", action="store_true",
                        help="明确选择当前工作区原始源码；HEAD 仅作为基线")
    args = parser.parse_args()
    if not args.export and not args.plan:
        if not sys.stdin.isatty():
            print("请指定 --export 或 --plan；未指定时不会自动导出。")
            return 0
        print("CPU 源码交接：1 导出源码包；2 只列计划；0 或回车退出")
        try:
            answer = input("请选择：").strip()
        except EOFError:
            return 0
        except KeyboardInterrupt:
            print("\n已取消；没有生成产物或验证结论。")
            return 130
        if answer in {"", "0"}:
            return 0
        if answer not in {"1", "2"}:
            print("未选择有效操作；没有生成产物。")
            return 2
        args.export = answer == "1"
        args.plan = answer == "2"
    try:
        check_root()
        git = Git()
        snapshot = git.snapshot()
        sources, unavailable, excluded = choose_sources(snapshot, args.include_uncommitted)
        issues = blockers(snapshot, sources, unavailable, args.include_uncommitted)
        if args.plan:
            show_plan(snapshot, sources, unavailable, excluded, args.include_uncommitted, issues)
            return 0  # Plan output is not a packaging result or validation verdict.
        if issues:
            print("拒绝导出：")
            for issue in issues:
                print("  - " + issue)
            return 2
        destination = package(git, snapshot, sources, unavailable, excluded, args.include_uncommitted)
        print("源码包生成完成：" + destination.relative_to(ROOT).as_posix() + "/cpu_source.zip")
        print("SHA-256 和交接清单已保存。验证状态 NOT_RUN；没有执行编译、仿真、PDS 或上板验证。")
        return 0
    except KeyboardInterrupt:
        print("已取消；没有新的验证结论。若已创建输出目录，请查看 NOT_COMPLETE.txt。")
        return 130
    except (ExportError, OSError, ValueError, zipfile.BadZipFile) as exc:
        # Internal OS errors may contain local identity: only domain errors are printed verbatim.
        message = str(exc) if isinstance(exc, ExportError) else "文件/Git 数据处理失败；交接包未完成。"
        print("导出未完成：" + message)
        print("未运行验证；没有成功报告的目录不可作为完成交付。")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
