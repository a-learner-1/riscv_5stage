# CPU5 机器 IRQ 冻结证据

2026-10-24。范围与结果见 [阶段报告](../../cpu5_irq_20261024.md)及 [合同](../../cpu5_irq_contract_20261024.md)。基线为 `baa2275d5a2ccb204f23b37414bc7a59f746ecaa`。此目录标记本轮局部验证，不声明完整 A01–A16、MMIO/SoC、STA、板测或性能通过。

- `verification.json`：总结果、兼容链、同源依赖与四套 IRQ 验收记录。
- `source_identity.json`：114 份实测依赖的原始字节 SHA 与规范 LF SHA；交付后 Git blob 按 LF 逐份核对。
- `raw_evidence.zip`：原始仿真日志/波形、逐周期与退休/M/D/I CSV、程序/RAM/GPR、坏证据副本、真实坏 RTL 和 compile/run 脚本；包含旧阶段本轮重跑的兼容证据及 tested_sources 快照。
- `selected_runs.json`：各有 run_id 的负测套件，仅保留最终完整批次，失败/局部探测不进入本轮验收归档。
- `archive_entries.json`：ZIP 内每个文件的原始字节 SHA；冻结工具检查 CRC、文件集合和逐 entry 摘要。
- `manifest.json`：除本清单自身以外的全部冻结文件摘要。

正常配置零 Error/Warning。37 项 RTL 功能变异和 5 项参数 guard 必须先零警告编译，再以指定语义 Fatal/非零退出拒绝；旧 IF 耗尽拒绝属于原兼容测试预期。模型或编译错误、警告、任意崩溃不能冒充功能负测成功。

标准复跑为 `python -B tools/verify_cpu5_irq.py`，随后 `python -B tools/freeze_cpu5_irq.py`。只在所有实测依赖原始 SHA 逐份相同且记录完整时允许复用；报告不依赖可再生 ModelSim 库或用户主工程的未提交文件。

归档 `.gitattributes` 固定原始字节，保留 Windows 行尾。不要用自动 EOL 转换重写冻结 JSON/日志后继续引用旧摘要。
