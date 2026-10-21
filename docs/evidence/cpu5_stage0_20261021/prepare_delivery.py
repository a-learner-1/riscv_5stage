"""Build a reviewable CPU5 first-step delivery; do not mutate the main checkout."""
from pathlib import Path
from collections import Counter, defaultdict
import csv
import gzip
import hashlib
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
MAIN = Path(r"D:\FPGA\riscv_3stage")
WORK = ROOT / "work"
DATA = WORK / "build/cpu5_stage0_measure"
STAGE = ROOT / "delivery_files"
REL = "docs/evidence/cpu5_stage0_20261021"
OUT = STAGE / REL
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
read = lambda path: json.loads(path.read_text(encoding="utf-8"))
def require(value, message):
    if not value: raise ValueError(message)
def git(*args): return subprocess.check_output(["git","-C",str(MAIN),*args])
def copy(source, destination):
    destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,destination)
def write_json(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8",newline="\n")

freeze = read(ROOT/"freeze/baseline_freeze.json")
run = read(ROOT/"observer_run_verification.json")
inventory = read(ROOT/"audit/profiler_inventory.json")
require(freeze["status"] == run["status"] == "PASS", "Unverified inputs")
require(run["simulator_returncode"] == 0, "Simulator failure")
require(inventory["audited_files_unchanged_at_end"], "Profiler inputs changed")
before = freeze["workspace_before"]
require(git("rev-parse","HEAD").decode().strip() == before["head"], "Main HEAD changed")
for kind in ("dirty_tracked","untracked"):
    for name, identity in before[kind].items():
        require(sha(MAIN/name) == identity["sha256"], "Original main file changed: "+name)
require(git("status","--porcelain=v1","--untracked-files=all").decode("utf-8") == before["status_porcelain"], "Main file inventory changed")
tag = "cpu3-rv32im-board-20261021"
tag_commit = git("rev-parse",tag+"^{commit}").decode().strip()
require(tag_commit == freeze["git_commits"]["accepted_rv32im_source"]["full"], "Wrong tag target")
require(git("cat-file","-t",tag).decode().strip() == "tag", "Tag is not annotated")
require(not STAGE.exists(), "Refuse overwriting delivery staging")
OUT.mkdir(parents=True)
(OUT/".gitattributes").write_bytes(b"# Immutable imported evidence: preserve bytes and received spacing.\n* -text -whitespace\n")
for source, name in [
    (ROOT/"freeze/baseline_freeze.json","baseline_freeze.json"),
    (ROOT/"freeze/summary.md","baseline_audit_summary.md"),
    (ROOT/"freeze/audit_baseline.py","audit_baseline.py"),
    (ROOT/"audit/profiler_inventory.json","profiler_inventory.json"),
    (ROOT/"audit/profiler_signal_map.md","profiler_signal_map.md"),
    (ROOT/"audit/audit_profiler_inventory.py","audit_profiler_inventory.py"),
    (ROOT/"observer_run_verification.json","observer_run_verification.json"),
    (ROOT/"verify_observer_run.py","verify_observer_run.py"),
    (ROOT/"cpu5_arch_spec_v0_3.md","cpu5_arch_spec_v0_3.md"),
    (DATA/"modelsim_transcript.log","modelsim_transcript.log"),
    (WORK/"build/cpu5_stage0_initial_observation/modelsim_transcript.log","initial_compilation_transcript.log"),
    (ROOT/"verification_harness_initial_warning_check/diagnosis.json","harness_warning_check_diagnosis.json"),
    (Path(__file__),"prepare_delivery.py"),
]: copy(source,OUT/name)
selftest_command=[sys.executable,"-X","utf8","-B","tools/analyze_cpu5_baseline_raw.py","--self-test"]
selftest=subprocess.run(selftest_command,cwd=WORK,capture_output=True,text=True,encoding="utf-8")
require(selftest.returncode==0,"Analyzer self-tests failed")
write_json(OUT/"analyzer_self_tests.json",{"argv":selftest_command,"returncode":selftest.returncode,"stdout":selftest.stdout,"stderr":selftest.stderr})
tag_info = {"name":tag,"object_sha":git("rev-parse",tag).decode().strip(),"target_commit":tag_commit,
    "evidence_commit":freeze["git_commits"]["board_evidence"]["full"],
    "tag_object":git("cat-file","-p",tag).decode("utf-8"),"created_locally":True,"pushed":False,
    "baseline_audit_sha256":sha(ROOT/"freeze/baseline_freeze.json")}
write_json(OUT/"freeze_tag.json",tag_info)

# A second oracle uses actual WB enable/rd as producer facts, rather than the
# analyzer's static writes_rd decoder. Both consume the same passive trace.
independent = {"method":"Closest-writer oracle driven by observed wb_we/wb_rd, independent of static producer-write decoder", "profiles":{}}
summaries = {}
for profile in ("smoke","smoke_validation"):
    folder=DATA/profile; summary=read(folder/"summary.json"); summaries[profile]=summary
    start,stop=summary["selected_window"]["start_edge"],summary["selected_window"]["stop_edge"]
    counts=Counter(); writers={}; latest_seq=0
    with (folder/"retirement_trace.csv").open(newline="") as stream:
        for r in csv.DictReader(stream):
            seq=int(r["seq"]); word=int(r["instr"],16); op=word&127; edge=int(r["retire_edge"])
            require(seq==latest_seq+1,"Non-contiguous retirement sequence"); latest_seq=seq
            if start<=edge<stop:
                counts["retired"]+=1
                if op in (0x63,0x67):
                    counts["branch_total"]+=1
                    src={(word>>15)&31}
                    if op==0x63:src.add((word>>20)&31)
                    distances=[seq-writers[s] for s in src if s and s in writers]
                    counts["distance1_raw"]+=1 in distances
                    counts["distance2_raw"]+=2 in distances
                    counts["distance3plus_raw"]+=any(d>=3 for d in distances)
                    counts["redirect_events"]+=int(r["normal_redirect"])
                    counts["both_distance1_and_distance2"]+=(1 in distances and 2 in distances)
            if int(r["wb_we"]):
                rd=int(r["wb_rd"]);require(rd!=0,"Write to x0")
                writers[rd]=seq
    require(counts["retired"]==summary["selected_window"]["frozen_retired"],"Independent retirement count differs")
    for key in ("branch_total","distance1_raw","distance2_raw","distance3plus_raw","redirect_events"):
        require(counts[key]==summary["groups"]["all"].get(key,0),"Independent RAW differs: "+profile+"/"+key)
    independent["profiles"][profile]={"status":"PASS","counts":dict(counts),"trace_sha256":sha(folder/"retirement_trace.csv")}
    for name in ("summary.json","branch_raw_trace.csv","window_endpoints.csv","observer_metadata.csv"):
        copy(folder/name,OUT/profile/name)
    for name in ("retirement_trace.csv","branch_source_dependencies.csv"):
        dest=OUT/profile/(name+".gz")
        dest.write_bytes(gzip.compress((folder/name).read_bytes(),compresslevel=9,mtime=0))
        require(hashlib.sha256(gzip.decompress(dest.read_bytes())).hexdigest()==sha(folder/name),"Gzip archive mismatch")
    firmware_dir=WORK/f"build/coremark/d0_m_cache_on_btb_{profile}"
    copy(firmware_dir/"build_report.json",OUT/profile/"build_report.json")
    (OUT/profile/"coremark.elf.gz").write_bytes(gzip.compress((firmware_dir/"coremark.elf").read_bytes(),compresslevel=9,mtime=0))
    stem="coremark_d0_m_cache_on_btb_"+profile
    for suffix in (".hex","_data.hex","_config.vh"):
        copy(WORK/"programs"/(stem+suffix),OUT/profile/(stem+suffix))
independent["status"]="PASS"
write_json(OUT/"independent_trace_audit.json",independent)

new_sources = ["tb/cpu5_baseline_raw_tb.v","tools/analyze_cpu5_baseline_raw.py","run_cpu5_baseline_raw.do"]
for name in new_sources:
    require(sha(WORK/name)==run["source_sha256_before"][name],"Observation source changed after run: "+name)
    require(not (MAIN/name).exists(),"Main destination exists: "+name)
    copy(WORK/name,STAGE/name)

# The untracked profiler is audited, not used by the D observer or staged as
# product code. Preserve a local snapshot without taking ownership of it.
local_snapshot=ROOT/"legacy_untracked_profiler_snapshot"
local_snapshot.mkdir(exist_ok=False)
for name in ("run_coremark_axi_write_profile.do","tb/coremark_axi_write_profile_tb.v","tools/analyze_coremark_axi_write_profile.py","docs/coremark_axi_write_profile.md"):
    copy(MAIN/name,local_snapshot/name)
write_json(local_snapshot/"SHA256_MANIFEST.json",{str(f.relative_to(local_snapshot)):sha(f) for f in local_snapshot.rglob("*") if f.is_file()})

states={"baseline_identity_and_local_tag":"PASS","dynamic_branch_raw_D":"PASS","profiler_inventory_and_semantic_mapping_E":"PASS",
    "baseline_six_class_audit_A":"PASS (historical formal UART rechecked; fresh short runs also close)",
    "independent_MUL_DIV_breakdown_A_prime":"NOT RUN","memory_latency_and_II_B":"NOT RUN","routed_top3_export_C":"NOT RUN",
    "CPU5_design_freeze":"NOT ASSERTED","CPU5_RTL":"NOT IMPLEMENTED","CPU5_hazard_cycles":"NOT RUN",
    "CPU5_A01_A16":"NOT IMPLEMENTED / NOT RUN","fresh_PDS_or_STA":"NOT RUN","PLL_and_ILA":"NOT RUN","hardware_access":"NOT RUN"}
result={"date":"2026-10-21","scope":"cpu5_arch_spec_v0_3.md section 10.0: verified CPU3 baseline, dynamic RAW D and profiler E only",
    "status":"FIRST_STEP_PASS","states":states,"freeze_tag":tag_info,"new_observation_sources":{n:sha(WORK/n) for n in new_sources},
    "profiles":{p:{"groups":s["groups"],"window":s["selected_window"],"reconciliation":s["reconciliation"],"firmware_sha256":s["firmware_sha256"]} for p,s in summaries.items()},
    "preservation":{"original_tracked_dirty":before["dirty_tracked"],"original_untracked_count":before["untracked_count"],"all_original_files_unchanged_before_delivery":True},
    "next":"Complete section 0.5 A-prime/B/C and freeze design contracts before CPU5 RTL skeleton. Retain switchable ID/EX branch resolution; RAW distance is not measured CPU5 stall or speedup."}
write_json(OUT/"step_result.json",result)

report=["# CPU5 v0.3 第一步：三级基线冻结、动态 RAW 与 profiler 审计", "", "日期：2026-10-21。规格：[cpu5_arch_spec_v0_3.md](evidence/cpu5_stage0_20261021/cpu5_arch_spec_v0_3.md)。", "",
    "本次完成 §10.0：原 Git/三级 RV32IM 交付核验、§8.5 动态分支依赖距离 D、§8.6 profiler 清点与语义映射 E。没有开发 CPU5 可综合 RTL，也不宣称阶段 0.5 全部完成或 SPEC FROZEN。", "",
    "## 基线与现场保护", "", f"- 已验收 M 源码：`{tag_commit}`；证据：`{tag_info['evidence_commit']}`。`75c43aa` 仅为 M 工作起点。",
    f"- 本地 annotated tag：`{tag}` → `{tag_commit}`；尚未推送。",
    "- 既有位流、原始/重建固件、源码、route/RTR、正式 UART 和 Git 角色共 **845 项检查 PASS**。本轮没有重新 P&R；正式成绩仍为 117.958048697 CoreMark / 2.359160974 CoreMark/MHz。",
    "- 原 3 个已跟踪修改和 182 个 Git 可见未跟踪文件逐个保存 SHA 并核对；未覆盖原 RTL、镜像、位流或用户改动。源码 CRLF/LF 等价与原始字节哈希分别记录，ELF 非加载 .strtab 差异保留。", "",
    "## D：真实短程动态依赖测量", "", "独立目录由提交 `1b7cb12` 导出，与已验收 M 提交的 RTL/约束相同。重新构建 RV32IM、D0、双 Cache、BTB64、O2 的 smoke 和 smoke-validation，各一迭代、50 MHz；仿真 UART 为 5 MHz。原 workload 的 CRC、tohost、mtime、六类周期及 I/D/BP 冻结门全部保留。", "",
    "| 项目 | smoke | smoke-validation |", "|---|---:|---:|"]
for label,key in [("窗口周期","frozen_cycles"),("窗口退休指令","frozen_retired"),("原 BP resolved（条件分支＋JAL）","frozen_resolved"),("原全部 mismatch","frozen_mismatch")]:
    report.append(f"| {label} | {summaries['smoke']['selected_window'][key]:,} | {summaries['smoke_validation']['selected_window'][key]:,} |")
for label,key in [("B_dyn（条件分支＋JALR）","branch_total"),("distance1_raw","distance1_raw"),("distance2_raw","distance2_raw"),("distance3plus_raw","distance3plus_raw"),("同集合 R（条件分支＋JALR）","redirect_events")]:
    report.append(f"| {label} | {summaries['smoke']['groups']['all'][key]:,} | {summaries['smoke_validation']['groups']['all'][key]:,} |")
for label,key in [("相邻 RAW / B_dyn","distance1_raw"),("同集合 R / B_dyn","redirect_events")]:
    vals=[s["groups"]["all"][key]/s["groups"]["all"]["branch_total"]*100 for s in summaries.values()]
    report.append(f"| {label} | {vals[0]:.2f}% | {vals[1]:.2f}% |")
report += ["", "每个源寄存器使用最近的真实动态写者，x0/未写 rd/未使用源被排除，双源相同寄存器去重。distance 各桶按分支去重，但不同源可使同一分支同时命中 D1/D2/D3+；CSV 另有 nearest_* 互斥最小距离分区。存在跨最终 START 的前驱，历史不清零。独立使用真实 wb_we/wb_rd 重算，与静态译码分析器完全一致。", "",
    "原 BPresolved 包含 JAL、排除 JALR，不能当成 B_dyn。全部 mismatch 分解为 conditional/JALR/JAL/other；JAL 的 449/446 次单列。retire_valid/WB 为上一完成边沿的寄存观测，BPresolve 为执行边沿事件，两套 [START,STOP) 分别核对；本次两个种子的边界调整均为 0。", "",
    "**结论限制：** 本次只测到三级的一迭代动态依赖分布。相邻 RAW 明显多于同集合重定向，只在规格的简化模型下支持继续评估 EX 解析；不能据此认定 ID 实际会多停这些拍。CPU5 尚不存在，因此实际 ready/stall、ID/EX A/B 时序与 CPI 均 NOT RUN，不冻结分支解析默认值。", "",
    "## 仿真与分析验证", "", "- ModelSim 10.6e 记录运行退出码 0；双种子原 workload 与 observer 均 PASS。六份退休/端点/窗口原始 CSV 与首次观察逐字节相同。",
    "- 新分析器 16 个手工构造的用例 PASS：覆盖覆盖写、源去重、x0、CSR/M/LOAD 分类、跨窗口历史及排他边界；另有实际 WB 事实驱动的独立全 trace 复算。",
    "- 首次编译保留每种子 2 条既有 irq_external 未连接警告。缓存优化设计复用时工具可不重发告警，不能据此声称消除。记录器曾错误要求重复运行仍必须有 4 条警告，已仅修正记录器预期；初始失败原因及完整日志保留，本轮未改产品或旧验证门。", "",
    "## E：观测设施迁移", "", "详见[清点与信号映射](evidence/cpu5_stage0_20261021/profiler_signal_map.md)及[机器清单](evidence/cpu5_stage0_20261021/profiler_inventory.json)。记录了实际层次、来源与 SHA、指令/事务 owner、pre/post-NBA、窗口和 CSV 字段。", "",
    "- D1 TB/analyzer 仍固定 raw START=2；D0 与真实 CoreMark 写画像使用通用最后 START。没有改写历史实现。",
    "- 独立十场景 AXI 写平台的加总检查在 TB 内，未发现独立 Python analyzer；真实 CoreMark 写通路的 runner/TB/analyzer/docs 四份文件存在但未跟踪，已额外在本机归档原样快照，不并入本次产品提交。",
    "- mem_start_x 是旧 EX 发起条件，不等于 req_fire；禁止与 CPU5 不同年龄的 is_store_x 拼接。MEM 退休与 WB 写回、物理 RAM WE、BP 训练及 Stats AR 副作用分别映射。",
    "- CPU5 拟探针、十类 ABI、12 条未来观测合同测试均为规划；CPU5 A01–A16 当前 NOT IMPLEMENTED / NOT RUN。", "",
    "## 复跑", "", "在匹配工具链的工程根目录执行：", "", "```powershell",
    "python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile smoke",
    "python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile smoke-validation",
    "# ModelSim：do run_cpu5_baseline_raw.do（脚本完成后退出仿真器，退出码 0）",
    "python -B tools/analyze_cpu5_baseline_raw.py --self-test",
    "python -B tools/analyze_cpu5_baseline_raw.py --profile smoke --directory build/cpu5_stage0_measure/smoke",
    "python -B tools/analyze_cpu5_baseline_raw.py --profile smoke-validation --directory build/cpu5_stage0_measure/smoke_validation",
    "```", "", "初始观察、记录器失败日志、全部 WLF、固件 ELF 和源代码副本保存在本机 `build/verification/cpu5_stage0_20261021/`；可随仓库读取的 CSV 汇总、gzip 原始 trace、输入镜像、报告与 SHA 清单位于[长期证据目录](evidence/cpu5_stage0_20261021/README.md)。", "",
    "## 下一步边界", "", "继续完成阶段 0.5 的 A′（MUL/DIV 独立事件与等待）、B（全链 latency/II）、C（最终路由 Top-3），明确 owner/IRQ/接口及预期断言合同后再设计冻结。PLL、ILA、CPU5 骨架及新硬件成绩均不包含在本次完成范围。", ""]
report_path=STAGE/"docs/cpu5_stage0_20261021.md"
report_path.write_text("\n".join(report),encoding="utf-8",newline="\n")
(OUT/"README.md").write_text("""# CPU5 第一步证据索引

本目录只证明三级 RV32IM 基线核验、动态 RAW 距离 D 与 profiler 映射 E。详见[执行报告](../../cpu5_stage0_20261021.md)。CPU5 RTL/真实气泡/STA/硬件均未运行。

- `baseline_freeze.json`：845 项既有来源与交付物检查；其 tag proposal 是审计时历史状态。
- `freeze_tag.json`：后续实际创建的本地 annotated tag 及完整目标 SHA。
- `profiler_inventory.json` / `profiler_signal_map.md`：当前工作区真实文件、哈希、层次与观测语义。
- `smoke/`、`smoke_validation/`：逐分支汇总、窗口和构建报告、完整程序三件套，以及 gzip 压缩的原始退休 trace、逐源最近 writer、ELF。`summary.json.output_sha256` 对压缩文件记录的是解压后原文 SHA；本目录总清单记录压缩后 SHA。
- `observer_run_verification.json`：进程退出码、输入哈希、原始 CSV 的确定性复核；历史工作目录绝对路径保留为来源。
- `initial_compilation_transcript.log`：原有 IRQ 连接警告；缓存复用可不再发出该警告。
- `harness_warning_check_diagnosis.json`：记录器初次告警数量预期失败的原因。完整失败脚本/日志保存在本机 ignored 归档中。
- `independent_trace_audit.json`：实际 WB 事实驱动的独立最近写者复算。
- `step_result.json`：分项 PASS/NOT RUN/NOT IMPLEMENTED，不能替代 CPU5 设计或实现签核。
- `cpu5_arch_spec_v0_3.md`：用户提供规格的原始字节副本；未修改其内容。

总 SHA256_MANIFEST.json 覆盖除其自身外全部证据文件；本目录局部 .gitattributes 保留原始换行和空白。模型 WLF 和完整本机路径产物不纳入 Git。两个种子各一迭代，短时 CoreMark 提示属于 smoke 预期，不是正式分数。
""",encoding="utf-8",newline="\n")
write_json(OUT/"SHA256_MANIFEST.json",{f.relative_to(OUT).as_posix():sha(f) for f in sorted(OUT.rglob("*")) if f.is_file()})
delivery={f.relative_to(STAGE).as_posix():sha(f) for f in sorted(STAGE.rglob("*")) if f.is_file()}
write_json(ROOT/"delivery_manifest.json",delivery)
print(json.dumps({"status":"PREPARED","files":len(delivery),"bytes":sum(f.stat().st_size for f in STAGE.rglob("*") if f.is_file()),"stage":str(STAGE),"independent":"PASS"},ensure_ascii=False))
