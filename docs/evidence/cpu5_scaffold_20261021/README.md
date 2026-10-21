# CPU5 首轮设计／骨架证据（2026-10-21）

主报告：[cpu5_scaffold_20261021.md](../../cpu5_scaffold_20261021.md)。设计合同仅 SPEC FROZEN；下面是 IF、hazard 和 metadata scaffold 的局部实测，完整 CPU5 ISA、A01–A16、STA、板测均未实现／未运行。

- `if/`：七门 CSV、公开端口逐边沿事件、独立457项账本分析、正例日志、序号耗尽预期 fatal、最终 OS 退出码。`initial_testbench_failure/` 保留初次 G4 驱动时序错误的失败证据；没有放宽检查门。
- `hazard/`：原版442,418向量和1,769,672逐源比较；六项突变的实际坏 RTL 与失败日志。正常版0错误/警告，突变退出1是预期拒绝。
- `scaffold/`：原版 metadata pipeline / top 两模式日志、公开包队列 trace、独立29=21+5+3账本、三项 must-fail 突变各自的原始坏 RTL/DO/trace/日志。取指故障停在 MEM，架构退休等端口固定零。
- `contract/`：15个 IRQ 纯设计参考案例与16个完整断言状态的静态核对；没有 IRQ 硬件测试。可用该目录的 checker 指定 `--contract docs/cpu5_design_contract_20261021.json --output <临时输出>` 复核。
- `integration_check.json`：各被测源码 SHA 与本次交付匹配，三个隔离副本原 Git archive 文件逐字节未改。
- `protected_files_check.json`：766份原主工程文件（含位流和原用户修改/未跟踪文件）前后保护结论。逐文件快照在本机归档。
- `sha256_manifest.json`：本目录原始字节 SHA；`.wlf.gz` 另外记解压 SHA。分析器结果内的 WLF SHA 指解压后的原文件。

`new_sources` 同时记录被测工作副本的原始 `sha256` 与文本 LF 归一后的 `canonical_lf_sha256`。Git 对证据目录外的源码/JSON执行行尾标准化；比较 Git blob 时使用后者，不能把 CRLF/LF 差异误报为逻辑源码变化。本目录证据通过 `-text` 保留原始字节。

序号耗尽仿真特意产生1条 Fatal；hazard六项、scaffold三项负测也特意失败。其作用是验证检查器能拒绝错误，不能把它们和原版正例错误混算。IF 门5只证明测试提供的“已获 MEM 授权”事件的去重/训练，真实 MEM 退休与错误路径训练约束留待提交控制器实现。

所有 `.v/.vh` 新骨架由 `vlog -sv` 编译；未接入原 PDS/板顶。原 `cpu_top.v/if_stage.v`、固件、约束、正式位流不变。完整源 ZIP、WLF、原始过程文件及审计脚本保存本机 `build/verification/cpu5_scaffold_20261021/`；隔离副本 `cpu5_s1/work*` 亦保留。
