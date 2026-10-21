# RV32IM 双种子正式板测证据

2026-10-21，50 MHz，RV32IM，performance/validation 各自动校准 2,000 次，均 FORMAL PASS。代码提交为 347982c30c88095d4a6406bd26c535b7b9f468b5。

正式性能：117.958048697 CoreMark / 2.359160974 CoreMark/MHz。validation 只验证另一组种子，不参与平均。详见[执行记录](../../rv32m_execution_20261021.md)。

| 运行 | 原始分包串口日志 | 归一化日志 | 单次复核快照 |
|---|---|---|---|
| performance | [原文](performance_uart_original.txt) | [归一化](performance_uart_normalized.txt) | [JSON](performance_result.json) |
| validation | [原文](validation_uart_original.txt) | [归一化](validation_uart_normalized.txt) | [JSON](validation_result.json) |

[pair_result.json](pair_result.json) 是最终配对验收记录，configuration_pair_complete=true。单次 JSON 保留收取时的配对待完成状态，不回写历史快照。

本目录副本与本机 build/coremark_board_results/ 中原始档案字节一致。单次 JSON 中 uart_original_sha256 对应本目录同 profile 的原始日志；配对 JSON 的 profiles.*.record_sha256 分别对应 performance_result.json / validation_result.json。JSON 内绝对路径记录历史来源，其文件副本使用本目录相对路径访问。

SHA256_MANIFEST.json 覆盖本目录除其自身外全部文件。局部 .gitattributes 禁用文本换行转换，确保 Git 保存与检出时保留日志和 JSON 的原始字节。

下载由用户操作；代理只核对用户提供的 UART、固件报告和交付物，UART 文本本身不自证实际下载位流的 SHA。
