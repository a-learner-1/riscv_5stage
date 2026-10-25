# CPU5 S16 十类 Stats 冻结证据

2026-10-25；基线 `102806a554a9ebee497289d4830e59d22bccbdef`。状态：PARTIAL VERIFIED: CPU5 ten-class cycle Stats schema4/profile2。

`verification.json` 保存分类/端点/程序/真实C系统/原控制兼容/新旧ABI套件结果；`selected_runs.json` 指定本次有效私有run。`raw_evidence.zip` 仅保存本阶段新运行的源快照、编译/构建命令与日志、原始CSV/HEX/JSON、ELF/bin/反汇编、WLF、坏RTL/坏数据和全部 272 份 tested_sources。未包含早期诊断/失败run或compiled work库。

`source_identity.json` 同时记录原始字节SHA与规范LF SHA；`archive_entries.json` 记录ZIP逐条SHA；`manifest.json` 记录本目录冻结文件SHA。ZIP逐条SHA和CRC已复核。

显式依赖 [S15 manifest](../cpu5_d0_20261025/manifest.json) 及其中记录的 [S14 manifest](../cpu5_axi_20261025/manifest.json)。新ZIP不重复打包旧raw大归档；固定提交、旧manifest/ZIP SHA、旧条目数以及纯观察变更inverse证明在 manifest.baseline_dependency、verification.reference 与 raw 的 build/cpu5_s16_reference/ 中记录。历史全链不冒称本阶段重跑。

复位、注册事件和snapshot_next的逐边沿来源分开保存。384程序由独立AXI读主机触发Stats窗口，真实C系统由CPU实际发起读；二者范围分开。DIV非零和M窗口边界由专门套件证明，原232退休程序不含DIV。

没有完整CoreMark、CPU5 STA/P&R、资源/Fmax或上板结果。详细结果与复现入口见[阶段报告](../../cpu5_stats_20261025.md)。
