# CPU5 S12 FENCE 冻结证据

基线 `ea03aba50e22ee9ca59c07abe3a7dd4f6f6905c3`，2026-10-24。阶段报告为 [CPU5 基础 FENCE](../../cpu5_fence_20261024.md)，边沿合同见 [合同](../../cpu5_fence_contract_20261024.md)。

- `verification.json`：本轮总验证，含四个新套件、兼容链路径、逐份依赖 SHA 与明确未验收范围。
- `source_identity.json`：所有测试依赖的原始/LF SHA 及基线提交。
- `selected_runs.json`：每个带 run_id 套件的最终完整批次；调试或失败批次不作为最终证据。
- `raw_evidence.zip`：旧完整兼容链和新程序/CSV/GPR/RAM/日志/波形、私有实际坏源、参数 guard、测试源码快照。排除编译缓存；私有程序输出仅保留一套规范副本。
- `archive_entries.json`：ZIP 中每个 entry 的原始 SHA，冻结与交付均逐项读取校验 CRC、条目集合和内容。
- `manifest.json`：本目录其余文件的原始 SHA；`.gitattributes` 保持冻结字节。

重新生成：`python -B tools/verify_cpu5_fence.py` 后 `python -B tools/freeze_cpu5_fence.py`。基础 FENCE 已验证；FENCE.I、Cache/AXI/完整 SoC、统计设备、CPU5 STA/P&R/板测及性能未在本轮验收。
