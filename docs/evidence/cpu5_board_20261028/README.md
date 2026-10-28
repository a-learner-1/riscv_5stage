# CPU5 实板与 ILA 证据入口

CPU5 已在 MES50HP 上完成 performance 和 validation 两组正式 CoreMark 运行。两组各 2000 次，均通过 CRC 和 `COREMARK RESULT: FORMAL PASS`；50 MHz ILA 调试构建完成时序闭合，并捕获链表、矩阵和状态机三类算法窗口。

| 文件 | 内容 |
| --- | --- |
| [结果汇总 JSON](../../cpu5_board_results_20261028.json) | 硬件配置、双种子数值、ILA 时序和窗口核对 |
| [raw_evidence.zip](raw_evidence.zip) | 原始串口截图、报告、三类采样及独立核对材料，共 60 个载荷文件 |
| [双种子下载包](../cpu5_board_20261026/cpu5_board_downloads.zip) | 正式 performance/validation SBIT、BIN和配套身份清单 |
| [构建冻结说明](../cpu5_board_20261026/README.md) | 下载前冻结的源码、PDS和回放记录 |

`raw_evidence.zip` 通过 Git LFS 保存，大小 19,806,021 字节，SHA-256：

```text
7d0ff2564dfffec6bcbe5fa10ab4b553203433eb2d96727b385ac690749e702c
```

在仓库根目录获取这份归档：

```bash
git lfs pull --include="docs/evidence/cpu5_board_20261028/raw_evidence.zip"
```

此前构建包中的 `hardware_download_performed=false`、`formal_score_measured=false` 表示构建器没有执行上板。该冻结包保持原样；本目录的后续板测记录补充真实运行结果。

正式 performance 为 **128.813667587 CoreMark / 2.576273352 CoreMark/MHz**，算法时间 15.526302740 秒。validation 为 128.645631960 迭代每秒，算法时间 15.546583040 秒；计分采用 performance。

三份 ILA 窗口均为 173 位数据、1024 个采样点，采样时钟 50 MHz，每点 20 ns。VCD 导出器的默认 100 ns 刻度按采样索引换算，不能当作板上实际时钟。窗口事件数用于局部时序核对，不代表完整运行 CPI；未采集的预测/重定向和后端握手不能据此推断原因。

新 CNN 系统从[接入指南](../../integration/cpu5_cnn_handoff.md)开始。现有证据属于独立 CPU5，不包含完整音频/CNN 系统验收。
