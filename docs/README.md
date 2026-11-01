# 文档导航

当前主线为 CPU5 五级流水线。作品评审请先看[仓库首页](../README.md)和[作品代码与验证说明](submission/README.md)；开发接手再看[CNN 接入指南](integration/cpu5_cnn_handoff.md)。下列阶段文档保留冻结时的事实与验证范围；当前实板状态以最新结果记录为准。

## 作品提交入口

| 文档 | 内容 |
| --- | --- |
| [作品代码与验证说明](submission/README.md) | 评审阅读顺序、五级代码定位、上板步骤与构建方式 |
| [固定版本与下载](https://github.com/a-learner-1/riscv_5stage/releases/tag/v1.0.0-cpu5) | 对应提交的源码、双种子上板包、实板与 ILA 证据 |
| [附件校验清单](submission/artifacts.json) | 下载附件与原冻结归档的路径、字节数及 SHA-256 |

## 交接与实板结果

| 文档 | 内容 |
| --- | --- |
| [CPU5 与 CNN 接入指南](integration/cpu5_cnn_handoff.md) | 集成包装、AXI、地址、Cache、IRQ、分工与联调顺序 |
| [源码交接](cpu_handoff.md) | 获取工程、导出源码、交付文件与复现边界 |
| [当前板测结果 JSON](cpu5_board_results_20261028.json) | performance/validation、50 MHz ILA及三算法采样数据 |
| [当前板测证据入口](evidence/cpu5_board_20261028/README.md) | 原始串口、截图、VCD和报告归档 |
| [CPU5 板级构建说明](cpu5_pds_board_20261026.md) | 固定板级配置、构建命令和冻结实现 |
| [构建冻结证据](evidence/cpu5_board_20261026/README.md) | 同次源码、下载包、时序与审计清单；保存构建时状态 |
| [LFS 与历史基线兼容](cpu5_git_lfs_compat_20261026.md) | 历史大归档和旧提交引用的本地恢复 |

## CPU5 实现与接口

| 主题 | 说明与合同 |
| --- | --- |
| 整体设计 | [设计合同](cpu5_design_contract_20261021.md) |
| 译码与 ALU | [ALU](cpu5_alu_20261021.md) |
| 前递与相关性 | [Forward](cpu5_forward_20261021.md) |
| 分支控制 | [Branch](cpu5_branch_20261022.md) |
| 数据事务与所有权 | [RAM](cpu5_ram_20261022.md) |
| 异常与 CSR | [Trap](cpu5_trap_20261023.md)、[CSR](cpu5_csr_20261023.md) |
| 乘除法 | [RV32M](cpu5_m_20261023.md) |
| 本地 MMIO及机器设备 | [MMIO](cpu5_mmio_20261024.md)、[Machine](cpu5_machine_20261024.md) |
| 中断与屏障 | [IRQ](cpu5_irq_20261024.md)、[FENCE](cpu5_fence_20261024.md) |
| Cache | [实现](cpu5_cache_20261024.md)、[接口合同](cpu5_cache_contract_20261024.md) |
| AXI4-Lite | [实现](cpu5_axi_20261025.md)、[桥接合同](cpu5_axi_contract_20261024.md) |
| D0 同步 BRAM | [实现](cpu5_d0_20261025.md)、[接口合同](cpu5_d0_contract_20261025.md) |
| 十类周期统计 | [Stats](cpu5_stats_20261025.md)、[统计合同](cpu5_stats_contract_20261025.md) |
| CoreMark | [平台移植](cpu5_coremark_20261025.md)、[计时与独立回放审计](cpu5_coremark_hardening_20261026.md) |

## 三级基线与独立实验

| 文档 | 阅读用途 |
| --- | --- |
| [原首页存档](history/README_legacy_cpu3.md) | 三级工程的功能表、各演示入口与历史成绩 |
| [原交接说明存档](history/cpu_handoff_legacy_cpu3.md) | 三级接口交接背景 |
| [开发历史](development_history.md) | 功能演进记录 |
| [RV32M 三级实测](rv32m_execution_20261021.md) | 117.958048697 CoreMark 对照的配置与证据 |
| [AXI4 读突发独立实验](axi4_read_burst_step5_20261020.md) | 旧系统的读突发参考；尚未组成 CPU5 CNN DMA |
| [统一回归说明](regression.md) | 既有三级和公共模块回归分组 |
| [I Cache](icache.md)、[D Cache](dcache.md)、[BTB](btb.md) | 公共模块背景与专用演示 |

文件名中的阶段和日期用于证据定位。冻结 JSON 中 `hardware_download_performed=false` 等字段表示生成工具当时的操作范围；后续真实板测另行记录，不回写旧冻结身份。
