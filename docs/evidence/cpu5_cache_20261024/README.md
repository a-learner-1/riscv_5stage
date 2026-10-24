# CPU5 S13 native Cache 冻结证据

基线 `40f92eb6b5da71898f824425a880e7b172c3b85a`，2026-10-24。见[阶段报告](../../cpu5_cache_20261024.md)与[接口合同](../../cpu5_cache_contract_20261024.md)。

- `verification.json`：本轮四个新套件、完整 CPU5 FENCE 兼容链路径、逐份测试依赖 SHA 与明确未验收范围。
- `source_identity.json`：192 份依赖的原始/LF SHA 和基线提交。
- `selected_runs.json`：带 run_id 套件的最终完整批次；调试/失败批次不作为最终证据。
- `raw_evidence.zip`：旧完整链和新刺激、程序、CSV、物理 GPR/RAM、日志、波形、私有实际坏源与编译快照。排除编译缓存；程序私有输出保留一套规范副本。
- `archive_entries.json`：ZIP 每个 entry 的原始 SHA；冻结和交付均逐项读取核对 CRC、条目集合和内容。
- `manifest.json`：本目录其余文件的原始 SHA；`.gitattributes` 保持冻结字节。

复跑 `python -B tools/verify_cpu5_cache.py`，再 `python -B tools/freeze_cpu5_cache.py`。Cache/native 接入已验证；AXI/D0/Stats/正式 SoC、FENCE.I、CPU5 STA/P&R/板测与性能未在本轮验收。
