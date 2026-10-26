# CPU5 CoreMark 功能接入证据（2026-10-25）

本目录只包含本阶段实际生成的工件与校验和。范围、结论与未运行项见
[阶段报告](../../cpu5_coremark_20261025.md)与[范围合同](../../cpu5_coremark_contract_20261025.md)。

- 运行：`20261026T033442697661Z_0dfe0c9a`（4 个配置，本阶段新跑）
- 审计：`audit.json` 记录控制台自洽性、独立快照交叉核对与22 项负证据拒绝
- 复跑：`python -B tools/run_cpu5_coremark.py`；`python -B tools/verify_cpu5_coremark.py`；`python -B tools/freeze_cpu5_coremark.py`
- 本包不解压、不改写原始工件；`manifest.json` 列出每个文件的 SHA256。
