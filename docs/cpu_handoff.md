# CPU5 源码交接

当前交接对象是 RV32IM 五级 CPU5。CNN 队友先阅读[仓库首页](../README.md)，再按[接入指南](integration/cpu5_cnn_handoff.md)选择完整功能参数、总线和地址映射。原三级交接内容保存在[历史说明](history/cpu_handoff_legacy_cpu3.md)。

## 推荐直接使用 Git 仓库

仓库地址：`https://github.com/a-learner-1/riscv_5stage.git`。接收方需要具备仓库访问权限。使用英文路径，先取得源码，按需要再拉取 LFS 原始证据：

```bash
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/a-learner-1/riscv_5stage.git cpu5_cnn
cd cpu5_cnn
git lfs install --local
git switch -c cnn-integration
```

CPU5 当前板测汇总在[结果 JSON](cpu5_board_results_20261028.json)。原始证据、既有双种子下载包及配套清单见[证据入口](evidence/cpu5_board_20261028/README.md)。

## 导出源码 ZIP

已有 `export_cpu_package.bat` / `tools/export_cpu_package.py` 是多版本源码导出工具，包含 CPU5 和保留的三级工程。它仍保留旧版 `source_of_truth_paths` 元数据；选择 CPU5 时以本说明、接入指南及实际板顶为准。

从仓库根目录在 Git Bash 执行：

```bash
# 先检查选取范围、工作区状态和阻塞条件
cmd.exe //c export_cpu_package.bat --plan

# 工作区与暂存区干净且交接文件已提交后，导出 HEAD 源码
cmd.exe //c export_cpu_package.bat --export
```

如果明确需要打包未提交的工作区版本，使用 `--export --include-uncommitted`，并先核对 `git status`；该模式可能纳入符合规则的未跟踪文档。收到的源码不等同于 HEAD，具体以清单为准。

每次输出独立目录 `build/handoff/<run_id>/`，包含 `cpu_source.zip`、`.sha256`、`handoff_manifest.json`、`HANDOFF.md` 与 `package_report.json`。这些文件应作为同一组发送。ZIP 不含 `.git` 历史、构建报告、FPGA 位流或原始波形，也不代替 LFS 证据归档。

源码 ZIP 内的旧 HEX 只是保留的初始化文件。需要运行带身份检查的仿真或板级构建时，应先按对应说明生成匹配镜像和报告；完整历史复核建议使用 Git clone 与 LFS 初始化。

## CPU5 接手时核对

| 内容 | 当前入口或约束 |
| --- | --- |
| 已验证固定板顶 | `rtl/cpu5_coremark_board_top.v` |
| 新 CNN 系统集成包装 | `rtl/cpu5_d0_axi_lite_top.v`；完整参数参考 `cpu5_stats_axi_lite_top.v` |
| 固件布局 | `software/cpu5_coremark/link.ld`，ROM 32 KiB / RAM 16 KiB |
| 外部总线 | 32 位 AXI4-Lite，单笔在途；native 指令 ROM 单独相接 |
| Stats 地址 | `0x30000000–0x300001FF`，CNN 另行分配窗口 |
| 时钟与复位 | 50 MHz；协议参与者协调复位，异频模块需明确 CDC |
| 数据共享 | D0 当前无 CNN 端口；无 DMA Cache 一致性/失效接口 |
| 运行与性能 | 已有双种子 CoreMark 与三类 ILA；CNN 系统需重新联调 |

建议队友先交付寄存器表、顶层端口和一组最小输入/期望输出，随后共同完成 ID 读、数据窗口读写、轮询启动和结果核对。具体参数与分工见[接入指南](integration/cpu5_cnn_handoff.md)。

## 仓库内的文件放置

CPU RTL、固件、仿真和构建工具沿用既有目录。新增 CNN 内容建议放 `rtl/cnn/`、`software/cnn/` 及 `docs/integration/`；分别建立系统顶层、构建入口和验证记录。现有板级性能基线及冻结证据保留原身份。

本机工作目录为 `D:/FPGA/riscv_3stage_github_lfs`；早期 `D:/FPGA/riscv_3stage` 留有未提交实验。交接采用当前仓库和选定提交，具体文件身份见导出清单。
