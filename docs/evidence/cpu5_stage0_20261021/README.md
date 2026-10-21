# CPU5 第一步证据索引

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
