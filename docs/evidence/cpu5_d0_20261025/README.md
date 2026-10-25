# CPU5 S15 D0 冻结证据

2026-10-25；基线 `aad84b44eae382cf243a4929a3114c5db6980198`。新后端/控制/384 程序配置实测通过；21 个语义变异与 2 个参数 guard 预期拒绝。全部 235 份依赖见 source_identity.json。

`verification.json` 汇总本阶段结果；`raw_evidence.zip` 包含新运行的私有源快照、清洁编译日志、原始 CSV/HEX/JSON、WLF、坏 RTL/坏证据与选中 run。`archive_entries.json` 列逐条 SHA256；`manifest.json` 列所有冻结文件 SHA256；`selected_runs.json` 排除先前诊断/失败 run。ZIP 完整逐条 SHA/CRC 已复核。

该新 ZIP 不复制历史 S14 大归档。显式依赖固定提交下的 [S14 manifest](../cpu5_axi_20261025/manifest.json) 和 [S14 原始 ZIP](../cpu5_axi_20261025/raw_evidence.zip)，共 17365 条；依赖的 manifest/ZIP SHA 在本目录 manifest.baseline_dependency 和 raw 内 build/cpu5_s15_reference/verification.json 中记录。212 份历史源码规范 LF 一致，原 ZIP 每条 SHA/CRC 与 1168 个源/日志/波形引用重新核验；历史仿真本阶段未重跑。

状态为局部功能验证；没有 CPU5 CoreMark、STA/P&R、资源/Fmax 或板测结果。详细范围及复现入口见 [阶段报告](../../cpu5_d0_20261025.md)。不要将新程序退休尾指令或复位撤销的 WB 记为账本丢失；各自有独立显式计数。
