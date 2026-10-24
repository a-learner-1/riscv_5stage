# CPU5 机器 timer/MSIP 设备冻结证据

2026-10-24。基线 `d74836b60f5d313cff408956e373b0a7aa79cc1a`。实现范围见 [阶段报告](../../cpu5_machine_20261024.md)与 [合同](../../cpu5_machine_contract_20261024.md)。此处仅声明本阶段局部验证，不声明完整 A01–A16、FENCE、Stats/Cache/SoC、STA、板测或性能通过。

- `verification.json`：总验收、五套新测试、完整旧兼容链与同源依赖。
- `source_identity.json`：158 份实测依赖原始 SHA / 规范 LF SHA；交付 Git blob 逐项核对。
- `raw_evidence.zip`：原始独立 timer/MSIP 模型、路由/top/真实 IF 程序日志波形、逐周期与退休/WB/接受/D/IF/设备 CSV、程序/RAM/GPR、实际坏源与编译运行脚本、坏证据副本，旧阶段本轮同源重跑证据及 tested_sources 快照。
- `selected_runs.json`：各 run_id 套件仅选最终完整批次，含控制正例与控制负例各自批次。
- `archive_entries.json`：ZIP 每个文件的原始 SHA，冻结时核对 CRC、完整文件集合与逐 entry 摘要。
- `manifest.json`：除本清单自身以外的全部冻结文件 SHA。

40 项真实 RTL 功能变异和 5 项参数 guard 都先独立零警告编译，再按指定语义 Fatal/非零退出拒绝。部分坏样本修改私有旧 timer 副本以验证比较/计数器模型；实际旧 `machine_timer.v` 未改。reset 取消/丢弃单列，不冒充普通事务响应完成。

标准复跑 `python -B tools/verify_cpu5_machine.py`，随后 `python -B tools/freeze_cpu5_machine.py`。复用仅在完整 PASS 且逐份原始 SHA 相同时允许。原始证据受 `.gitattributes` 保护，保留 Windows 行尾；重写任何文件后须重建相应摘要，不能沿用旧值。
