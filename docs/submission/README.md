# 作品代码与验证说明

作品名称：**面向CNN推理的R-V结构设计**。当前仓库为作品的 CPU5 处理器子工程，交付 RV32IM 五级流水线、片内存储与外设、裸机程序、仿真工具、FPGA 构建入口及既有实板证据。

提交仓库链接：<https://github.com/a-learner-1/riscv_5stage>。

固定版本：[v1.0.0-cpu5](https://github.com/a-learner-1/riscv_5stage/releases/tag/v1.0.0-cpu5)。该版本整理代码导航与下载入口，处理器 RTL、固件及冻结证据沿用已有验证版本。

## 建议阅读顺序

1. 从[首页](../../README.md)了解五级结构、配置与正式实板结果。
2. 阅读[板级顶层](../../rtl/cpu5_coremark_board_top.v)，确认 CPU、存储、时钟、复位和接口配置。
3. 沿下表检查流水线、存储、机器控制及测量工具。
4. 对照[结果 JSON](../cpu5_board_results_20261028.json)与[原始证据入口](../evidence/cpu5_board_20261028/README.md)核对数据。
5. 若需要实际操作，按后文选择既有位流上板或从源码构建。

## 代码定位

| 功能 | 主要入口 |
| --- | --- |
| MES50HP 固定板级顶层 | [cpu5_coremark_board_top.v](../../rtl/cpu5_coremark_board_top.v) |
| CPU、ROM、AXI 路由与 Stats 组合 | [cpu5_stats_axi_lite_top.v](../../rtl/cpu5_stats_axi_lite_top.v) |
| 完整流水线执行与提交控制 | [cpu5_alu_pipeline.v](../../rtl/cpu5_alu_pipeline.v)、[cpu5_top.v](../../rtl/cpu5_top.v) |
| 级间包与冒险判断 | [cpu5_pipeline_types.vh](../../rtl/cpu5_pipeline_types.vh)、[cpu5_hazard.v](../../rtl/cpu5_hazard.v) |
| 分支与预测 | [cpu5_branch_unit.v](../../rtl/cpu5_branch_unit.v)、[branch_predictor.v](../../rtl/branch_predictor.v) |
| 访存授权、归属与数据后端 | [cpu5_ram_owner.v](../../rtl/cpu5_ram_owner.v)、[cpu5_ram_unit.v](../../rtl/cpu5_ram_unit.v)、[cpu5_d0_backend.v](../../rtl/cpu5_d0_backend.v) |
| I/D Cache | [instr_cache.v](../../rtl/instr_cache.v)、[data_cache.v](../../rtl/data_cache.v)、[cpu5_cache_adapter.v](../../rtl/cpu5_cache_adapter.v) |
| 乘除法及事务归属 | [rv32m_unit.v](../../rtl/rv32m_unit.v)、[cpu5_m_owner.v](../../rtl/cpu5_m_owner.v) |
| CSR、异常与中断 | [cpu5_csr_unit.v](../../rtl/cpu5_csr_unit.v)、[cpu5_irq_ctrl.v](../../rtl/cpu5_irq_ctrl.v) |
| 本地 MMIO 与机器设备 | [cpu5_mmio_router.v](../../rtl/cpu5_mmio_router.v)、[cpu5_machine_endpoint.v](../../rtl/cpu5_machine_endpoint.v) |
| AXI4-Lite 与可集成包装 | [dmem_axi_lite_bridge.v](../../rtl/dmem_axi_lite_bridge.v)、[cpu5_d0_axi_lite_top.v](../../rtl/cpu5_d0_axi_lite_top.v) |
| CPU5 启动、链接和移植 | [start.S](../../software/cpu5_coremark/start.S)、[link.ld](../../software/cpu5_coremark/link.ld)、[core_portme_cpu5.c](../../software/cpu5_coremark/core_portme_cpu5.c) |
| 固件与 FPGA 构建 | [build_cpu5_board_images.py](../../tools/build_cpu5_board_images.py)、[build_cpu5_pds.py](../../tools/build_cpu5_pds.py)、[build_cpu5_bitstream.py](../../tools/build_cpu5_bitstream.py) |
| CoreMark 仿真与独立核验 | [run_cpu5_coremark.py](../../tools/run_cpu5_coremark.py)、[verify_cpu5_coremark.py](../../tools/verify_cpu5_coremark.py) |

完整设计规则与阶段验收从[文档目录](../README.md)继续阅读。`cpu5_alu_pipeline` 的名称保留功能演进历史，当前配置含控制流、访存、机器态与乘除法，不限于 ALU 子集。

## 结果与证据对应

| 对象 | 已有记录 | 适用结论 |
| --- | --- | --- |
| 正式 CoreMark | performance / validation 各 2000 次，50 MHz，均超过 10 秒且 CRC 通过 | 当前 CPU 配置的实板正确性、计时与计分 |
| 正式 FPGA 实现 | 综合、布局布线、最终 STA 与对应双种子位流 | CPU 独立工程的资源与 50 MHz 时序 |
| CPU 功能 | 定向控制回归、四配置独立指令回放 | 对应配置、指令及异常边界的仿真验证 |
| ILA | 链表、矩阵、状态机各 1024 点，173 位探针、50 MHz | 采样窗口内的推进、驻留、退休及写回关系 |
| CNN 协同 | CPU AXI4-Lite 包装及接口指南 | 提供控制核心接口；完整音频/CNN 系统由其独立工程验收 |

正式成绩为 **128.813667587 CoreMark、2.576273352 CoreMark/MHz**。正式综合使用 **10837 LUT、8870 寄存器、28 DRM18K 等价与 4 APM**；50 MHz 最终 STA 的 Slow Setup WNS 为 **+0.021 ns**。这些数字不包含音频/CNN SoC，也不使用带 ILA 调试构建的资源。

MEM 为唯一架构退休点，WB 为物理 GPR 写回点。两类事件不能互相替代；CPI 使用完整计数窗口的周期数与退休数，ILA 局部事件数不用于计算整段 CoreMark CPI。

`COREMARK RESULT: FORMAL PASS` 是本项目移植层的有效运行标记，检查报告完整性、迭代、计时、CRC及正式运行时长；不代表形式化证明。

正式板顶把三个原始 IRQ 输入接为 0，内部定时器与 MSIP 设备仍保留。复杂异常及中断边界以对应仿真场景为依据，CoreMark 运行不代替专项中断实板验收。当前 Cache 行填充是逐字请求，独立 AXI4 读突发实验不是已集成的 CPU5 CNN DMA。

## 使用既有位流上板

1. 在[提交版本下载页](https://github.com/a-learner-1/riscv_5stage/releases/tag/v1.0.0-cpu5)取得 `CPU5_board_downloads.zip` 和 `SHA256SUMS.txt`。下载的是压缩包，不是 Git LFS 指针。
2. 先核对压缩包 SHA-256，再解包，按同包 `release_manifest.json` 核对 SBIT 身份。固定硬件为 MES50HP / PGL50H-6IFBG484，50 MHz。
3. 连接开发板供电、JTAG与 USB-UART；串口设置为 **115200、8N1、无流控**。
4. 通过 PDS 向 SRAM 下载 `CPU5_performance.sbit`，等待程序完成。KEY1 重启 CPU；REPROGRAM 重新装载 FPGA 配置。
5. 保存完整串口输出，检查配置、2000 次迭代、各 CRC、算法时间及最终判定。正式 performance 算法时间为 15.526302740 秒，结果为 128.813667587 CoreMark。
6. 下载 `CPU5_validation.sbit` 重复检查另一组种子。算法时间为 15.546583040 秒，结果为 128.645631960 CoreMark。

PowerShell 校验示例：

```powershell
Get-FileHash -Algorithm SHA256 .\CPU5_board_downloads.zip
Get-FileHash -Algorithm SHA256 .\CPU5_board_evidence.zip
```

两个压缩包的路径、字节数和校验值也保存在[附件清单](artifacts.json)。下载页附件与仓库中的原有归档逐字节相同；位流生成时的 `hardware_download_performed=false` 和 `formal_score_measured=false` 保持原记录，后续真实实板测试见[结果 JSON](../cpu5_board_results_20261028.json)，两者分别对应构建与运行阶段。

普通双种子下载包不含 ILA 插核位流。分析原始 ILA 材料请使用证据包；若重新下载 ILA 构建，SBIT 与 FIC 必须来自同一次插核实现。

## 从源码构建

工具版本：RISC-V GCC 15.2.0、ModelSim 10.6e、PDS 2022.2-SP6.4、Python 3.10+。Windows 工程放在英文路径，以下命令均从仓库根目录执行。`python` 指向实际 Python，`--cross` 和 `--pds` 按本机安装位置替换。

### 获取代码

在 Git Bash 中执行：

```bash
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/a-learner-1/riscv_5stage.git
cd riscv_5stage
git checkout v1.0.0-cpu5
git lfs install --local
```

该操作取得提交版本源码，先不下载约 1 GB 的历史 LFS 证据。最新板测证据可从提交版本下载页单独取得，或执行：

```bash
git lfs pull --include="docs/evidence/cpu5_board_20261028/raw_evidence.zip"
```

### 生成正式固件

GCC 工具在 PATH 时：

```bash
python tools/build_cpu5_board_images.py --profile performance --cross riscv-none-elf-
python tools/build_cpu5_board_images.py --profile validation --cross riscv-none-elf-
```

输出位于 `build/cpu5_s19/firmware/<profile>/`，包含 ELF、HEX、反汇编和构建身份。工具只生成固件，不执行或下载。若改动源文件或配置，应重新构建并使用配套镜像。

### FPGA 实现与位流

```bash
python tools/build_cpu5_pds.py --profile performance --stage timing --pds D:/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe
python tools/build_cpu5_bitstream.py --record build/cpu5_s19/pds_performance.json --pds D:/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe
```

validation 对应使用 `--profile validation` 和 `pds_validation.json`。每次运行的文件保存在 `build/cpu5_s19/runs/<run_id>/`，具体以生成的 JSON 为准；构建与位流脚本均不会下载硬件。引脚及时钟约束入口为 [pds/board_top.fdc](../../pds/board_top.fdc)。

重新实现后的资源、时序与位流身份可能变化，需检查同次最终 STA 并重新板测，不能直接沿用既有位流的实测身份。

### 仿真与历史证据复核

[CoreMark 仿真工具](../../tools/run_cpu5_coremark.py)支持 `--vsim`、`--cross`、`--storage`、`--cases` 等参数。其四配置功能仿真使用小 Cache、BTB16、一轮算法及仿真串口参数，与正式实板的 Cache/BTB64、2000 次运行分别记录。操作前阅读[计时与独立回放说明](../cpu5_coremark_hardening_20261026.md)，不要把一轮仿真作为正式性能成绩。

`run_cpu5_*.do` 对应不同开发阶段，有些是子集测试、有些检查冻结源码或使用本机路径。选择入口前对照对应阶段文档；根目录旧 `Makefile` 不作为当前 CPU5 正式板级构建命令。

若需运行依赖旧提交和完整原始归档的历史验收：

```bash
git lfs pull
python tools/setup_cpu5_git_baselines.py --install --report build/cpu5_git_baseline_setup.json
```

初始化只恢复本地历史引用兼容性，不重跑硬件验证，也不跳过冻结身份检查，详见[LFS 与历史基线说明](../cpu5_git_lfs_compat_20261026.md)。

## 交付范围与第三方内容

当前 CPU5 实现、公共外设、构建脚本和历史实验沿用原目录，避免破坏 include 路径、测试入口与冻结身份。评审按本页指定的五级顶层与工具进入；历史开发记录集中由[文档目录](../README.md)导航。

CNN 协同接口参见[CPU5 与 CNN 接入指南](../integration/cpu5_cnn_handoff.md)。本 CPU 仓库没有音频模型、权重、ES8311 采集与完整音频 SoC 顶层，不能代替完整作品系统代码包。

CoreMark 算法与许可保留在 [benchmarks/coremark/](../../benchmarks/coremark/)，来源见 [SOURCE.md](../../benchmarks/coremark/SOURCE.md)，使用条款见 [LICENSE.md](../../benchmarks/coremark/LICENSE.md)。
