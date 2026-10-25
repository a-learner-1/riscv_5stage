# CPU5 S14 AXI4-Lite 冻结证据

2026-10-25，基线 `88466d9764bd5c36265439720e28bebfd7c684c2`。见[阶段报告](../../cpu5_axi_20261025.md)和[接口合同](../../cpu5_axi_contract_20261024.md)。

- `verification.json`：四个新套件、完整旧CPU5兼容链路径、212份依赖SHA与明确未验收范围。
- `source_identity.json`：原始/LF SHA和基线提交。
- `selected_runs.json`：带run_id套件的最终完整批次，排除调试/失败批次。
- `raw_evidence.zip`：旧完整链、新独立协议/core组合/192程序、CSV、物理GPR/RAM、日志、12批程序波形、实际私有坏源/编译快照；包含磁盘故障与兼容恢复过程，排除编译缓存和程序输出重复副本。
- `archive_entries.json`：ZIP逐entry原始SHA；冻结和交付均检查CRC、条目集合及内容。
- `manifest.json`：本目录其余文件原始SHA；`.gitattributes`保留冻结字节。

复跑 `python -B tools/verify_cpu5_axi.py` 后 `python -B tools/freeze_cpu5_axi.py`。AXI4-Lite数据主接口已验证；native I、单outstanding和共享reset合同见报告。D0/Stats/正式SoC、AXI burst、FENCE.I、CPU5 STA/P&R/板测和性能未在本轮验收。
