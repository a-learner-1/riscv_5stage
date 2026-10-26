# CPU5 板级构建冻结证据（2026-10-26）

源码提交：`18c8e61fd5d024d41e96792f222c2de8f28fdc95`。

`cpu5_board_downloads.zip` 是供 MES50HP 上板使用的双种子下载包，内含 `CPU5_performance.sbit`、`CPU5_validation.sbit`、同次生成的 BIN、SHA-256 清单及操作说明。它们均为 RV32IM／D0／各 2 KiB Cache／BTB64／50 MHz／115200，2000 迭代。已生成并通过最终 STA，尚未下载、没有 CPU5 正式成绩。

`raw_evidence.zip` 包含选定的两次 PDS 时序、两次位流生成、板级真实串口速率短程、六组控制回归、47 个错误输入拒绝、11 项新取指检查和四配置 CoreMark 原始证据。`archive_entries.json` 逐文件记录字节数及 SHA-256。失败的调试运行保留在工作存储中，不纳入本冻结包。

`source_package.zip` 保存对应提交的规范 LF 源码及工具依赖；`source_identity.json` 记录 Git blob 内容哈希。`manifest.json` 保存两个包的完整身份，`selected_runs.json` 标明实际选定的 run id。运行期独立核验结果在 `verification.json`；另外在普通新目录解包后重新核对提交、路由、时序、UART、RAM 和 2,409,425 条指令回放，结果在 `frozen_replay.json` 与对应控制台文件。离线复核不需要原来的目录 junction。

解包到同一个新目录后运行：

```powershell
python tools/verify_cpu5_board_build.py
```

若本机可访问对应 Git 提交，可加 `--source-commit 18c8e61fd5d024d41e96792f222c2de8f28fdc95 --repository <仓库绝对路径>`，逐文件核对规范 LF Git blob。此命令只审查和回放原始证据，不调用 PDS、不下载板卡。

短程串口结果仅证明功能与配置一致；正式 performance／validation 镜像的 FPGA 执行结果仍待取得。原三级 CPU 的板测成绩与下载文件不属于本包。
