# CPU5 最小 MMIO 冻结证据

2026-10-24。基线 `fb5d1a48776b87976b1bdcbe0c98a301d757b753`。范围和实际结果见 [阶段报告](../../cpu5_mmio_20261024.md)及 [合同](../../cpu5_mmio_contract_20261024.md)。此处为局部实现验证，不声明完整 A01–A16、计时器/软件中断设备、Stats/SoC、STA、板测或性能通过。

- `verification.json`：总验收、五套新测试、完整旧兼容链及同源记录。
- `source_identity.json`：138 份实测依赖原始 SHA/规范 LF SHA；交付 Git blob 逐项按 LF 校验。
- `raw_evidence.zip`：原始端点/路由/控制/程序日志与波形，退休/WB/接受/首次请求/响应/路由/设备/IF/逐周期 CSV，程序/RAM/GPR、坏证据副本、实际坏 RTL、编译运行脚本，前阶段本轮同源重跑证据及 tested_sources 快照。
- `selected_runs.json`：所有 run_id 套件只保留最终完整批次；失败探测/局部运行不进入本轮验收归档。
- `archive_entries.json`：每个 ZIP 文件的原始字节 SHA；冻结时核对 CRC、文件集合及逐 entry 摘要。
- `manifest.json`：除本清单自身之外的全部冻结文件 SHA。

正常配置零 Error/Warning；39 项真实 RTL 功能变异与 6 项参数 guard 均先零警告编译，再以指定语义 Fatal/非零退出拒绝，其他错误不能冒充负测成功。复位取消按独立分类账本记录，不能以普通无复位请求/响应相等条件覆盖取消。

标准复跑 `python -B tools/verify_cpu5_mmio.py` 后执行 `python -B tools/freeze_cpu5_mmio.py`。复用仅允许所有实测依赖原始 SHA 逐项相同且记录完整。归档字节受 `.gitattributes` 保护，保留 Windows 行尾；重写文件后必须重新生成对应摘要，不能沿用旧值。
