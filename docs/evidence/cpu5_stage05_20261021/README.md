# CPU5 阶段 0.5 A′/B/C 长期证据

2026-10-21。主报告：[M、访存和路由测量](../../cpu5_stage05_20261021.md)。原三级性能成绩、RTL、六类 ABI 和正式位流未改变；这里没有 CPU5 实现结果。

- `m/`：双种子一迭代的窗口、逐 M owner、事件、固件 ROM/RAM/config、ELF gzip、构建输入；单元及实际 CPU 定向；ModelSim 初始与验收日志、退出码、84 项分析器正负自测和复跑原始 CSV 一致性。`verification.json` 中初次进程码为 null，初始旧端口警告四条；重复验收和定向进程退出 0。
- `memory/`：四个定向 fixture，三个边界的请求/响应 CSV、实际 ROM 与退休/I-fetch CSV、逐对 latency/II、独立模型和六项污染拒绝检查。`README.md` 详列可比较的类别和边界。原生错误端点不代表真实 AXI 传输。
- `timing/`：原最终报告的字节无损 gzip、manifest、24 条逐弧路径 JSON、来源／签核复核和说明。只读提取，未运行新 STA/P&R。
- `abi/contract_check.json`：40 个周期寄存字的静态布局、12 个坏合同拒绝、真实旧 C guard 的五项预处理。CPU5 Stats5/固件/十类计数仍未实现。
- `independent_integration_check.json`：根任务直接从原 CSV 复算 MUL 算术、边沿、差额、访存计数/II、最终 34 份代码/输入身份及 RTR 解压字节校验。
- `protected_files_check.json`：668 份原有文件的前后字节哈希核对结论；逐文件现场快照保留本机归档。
- `sha256_manifest.json`：本目录文件的原始字节哈希；gzip 条目另记解压 SHA。M 汇总/验证文件中的 raw SHA 指**解压后的** CSV，不是 gzip 容器。

本轮严格使用一迭代 smoke / smoke-validation；CoreMark 的不足 10 秒提示不构成正式成绩。这些仿真的成功依据为保留的 workload CRC、tohost、mtime、旧六类账本及新 owner/数据门，而非以短程结果冒充正式跑分。

可复跑代码位于工程 `tb/`、`tools/` 和 `run_cpu5_*.do`，命令见主报告。重跑会在 build 目录生成独立证据；分析已归档的 trace 时，可把相应 CSV 解压到原 build 子目录，恢复对应构建报告后使用同一 analyzer。不要原位覆盖本目录中的冻结证据。

完整源提交归档、原始 CSV/WLF、构建物和逐文件保护快照保留在本机 `build/verification/cpu5_stage05_20261021/`；原隔离目录 `cpu5_s05/work_m`、`work_mem` 亦保留。完整 PDS route 位于既有 RV32IM release/build 归档，SHA 已由本轮只读解析器核对。
