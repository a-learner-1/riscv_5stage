# CPU5 RV32IM 五级流水线处理器

基于 Verilog 的 32 位 RISC-V 裸机处理器，在紫光同创 MES50HP（PGL50H-6IFBG484）开发板上运行。当前主线为 **IF → ID → EX → MEM → WB 五级流水线**，支持 RV32IM、数据前递、64 项 BTB、两路组相联 I/D Cache、UART、GPIO及最小机器态控制。

CPU5 已完成 50 MHz 实板 CoreMark 双种子测试，以及链表、矩阵和状态机的 ILA 采集。项目面向音频识别系统扩展：CPU 可承担控制与软件任务，后续与 CNN 协处理器配合。**CNN、MFCC、音频采集与完整推理链路目前仍属后续集成范围。**

仓库名 `riscv_3stage` 沿用早期工程；三级版本保留作历史对照。队友接入请使用下列 CPU5 入口。

## 从这里开始

| 你要做的事 | 入口 |
| --- | --- |
| CNN 队友第一次接手 | [CPU5 与 CNN 接入指南](docs/integration/cpu5_cnn_handoff.md) |
| 找代码、工具和验证资料 | [文档导航](docs/README.md) |
| 查看板级完整配置 | [cpu5_coremark_board_top.v](rtl/cpu5_coremark_board_top.v) |
| 扩展 D0 RAM 与 AXI4-Lite 外设 | [cpu5_d0_axi_lite_top.v](rtl/cpu5_d0_axi_lite_top.v) |
| 查看已完成的实板结果 | [板测与 ILA 结果](docs/cpu5_board_results_20261028.json)、[证据入口](docs/evidence/cpu5_board_20261028/README.md) |
| 下载既有 CoreMark 双种子位流 | [CPU5 下载包](docs/evidence/cpu5_board_20261026/cpu5_board_downloads.zip) |
| 导出源码、核对交付范围 | [源码交接说明](docs/cpu_handoff.md) |

## 当前配置与实测

| 项目 | CPU5 正式板级配置 |
| --- | --- |
| 指令集与执行 | RV32IM，ILP32，小端；单发射、顺序执行与退休 |
| 流水线提交 | MEM 为唯一架构退休点，WB 完成通用寄存器物理写回 |
| 工作频率 | 50 MHz，20 ns 时钟约束；已验证工作点 |
| 存储 | ROM 32 KiB；D0 同步 BRAM 16 KiB |
| Cache | I/D 各 2 KiB；两路、64 组、每行 16 字节 |
| D Cache 策略 | 写穿透、不写分配，无写缓冲 |
| 分支 | BTB64，EX 解析及重定向 |
| 外设 | UART 115200、8N1；GPIO；mtime/mtimecmp、MSIP；Stats |
| 统计 | schema4/profile2，64 位周期/退休计数，十类互斥周期 |
| 综合资源 | 10837 LUT、8870 寄存器、28 DRM18K 等价、4 APM |

| CoreMark 指标 | performance | validation |
| --- | ---: | ---: |
| 迭代次数 | 2000 | 2000 |
| 实际算法时间 / 秒 | 15.526302740 | 15.546583040 |
| 迭代每秒 | **128.813667587** | 128.645631960 |
| 每 MHz 迭代每秒 | **2.576273352** | 2.572912639 |
| CPI | 1.339822844 | 1.340521074 |
| 结果 | FORMAL PASS | FORMAL PASS |

正式性能取 performance；validation 用另一组种子核对正确性。原三级完整实现为 117.958048697 CoreMark，本版提升约 9.20%。两版存在预热方式和软件布局差异，该对照不单独衡量流水线级数的收益。50 MHz 也不表示已测得最高频率。

## 获取仓库

将工程放在英文路径，例如 `D:/FPGA/cpu5_cnn`。源码阅读与 CNN 接口开发可以先跳过约 1 GB 的历史 LFS 原始证据。在 **Git Bash** 执行：

```bash
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/a-learner-1/riscv_3stage.git cpu5_cnn
cd cpu5_cnn
git lfs install --local
git switch -c cnn-integration
```

只获取现有 CPU5 下载包和最新板测证据：

```bash
git lfs pull --include="docs/evidence/cpu5_board_20261028/raw_evidence.zip"
```

双种子下载包是普通 Git 文件，路径见上表；LFS 命令用于取得原始板测与 ILA 归档。若要运行引用旧提交的完整历史验收工具，再下载全部 LFS 数据并初始化本地兼容引用：

```bash
git lfs pull
python tools/setup_cpu5_git_baselines.py --install --report build/cpu5_git_baseline_setup.json
```

各阶段冻结证据与工具的使用范围见 [LFS 与历史基线说明](docs/cpu5_git_lfs_compat_20261026.md)。源码 ZIP 不含 Git 历史，执行上述 Git 初始化时需使用 clone 的仓库。

## 构建与上板入口

已使用的工具版本为 RISC-V GCC 15.2.0、ModelSim 10.6e、PDS 2022.2-SP6.4。以下命令从仓库根目录执行；`python` 需为 Python 3.9 或以上，`--cross` 是本机 GCC 工具名前缀。

```bash
# 编译两组正式固件；工具链在 PATH 时可使用此前缀
python tools/build_cpu5_board_images.py --profile performance --cross riscv-none-elf-
python tools/build_cpu5_board_images.py --profile validation --cross riscv-none-elf-

# 以 performance 为例，完成 P&R 和时序检查，再生成位流
python tools/build_cpu5_pds.py --profile performance --stage timing --pds D:/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe
python tools/build_cpu5_bitstream.py --record build/cpu5_s19/pds_performance.json --pds D:/pango/PDS_2022.2-SP6.4/bin/pds_shell.exe
```

`--pds` 替换为实际安装路径。validation 使用相应的 `--profile validation` 与 `pds_validation.json`。固件在 `build/cpu5_s19/firmware/<profile>/`；每次实现与生成文件在 `build/cpu5_s19/runs/<run_id>/`，实际路径以 JSON 记录为准。脚本只构建，JTAG 下载由用户操作。

使用既有下载包时，核对同包的 `release_manifest.json`，打开串口 115200、8N1、无流控，再通过 PDS 下载对应 `.sbit`。KEY1 重启 CPU；REPROGRAM 会重装 FPGA 配置。ILA `.sbit` 与 `.fic` 必须来自同一次插核构建。

CPU5 的编译清单采用 SystemVerilog 模式及仓库根目录 include 路径，示例为 `vlog -sv +incdir+.`。`run_cpu5_*.do` 是各阶段的定向入口；部分入口固定本机 Python 路径或检查历史基线。完整 CoreMark 仿真可由 `tools/run_cpu5_coremark.py` 配置 `--vsim`、`--cross`、`--storage`；操作前阅读[对应说明](docs/cpu5_coremark_hardening_20261026.md)。根目录旧 `Makefile` 和不带 `cpu5` 的板级脚本主要服务三级工程。

## CNN 接入先确认这几项

- 使用 `cpu5_d0_axi_lite_top` 的 `m_axi_*` 接口，在新系统顶层组合路由、Stats 和 CNN 从设备；正式 CoreMark 板顶用于保留性能基线。
- 当前数据控制接口为 **32 位 AXI4-Lite、单笔在途**。独立 AXI4 读突发演示属于旧系统实验，不是已接入 CPU5 的 CNN DMA。
- 正式配置的 `0x30000000–0x300001FF` 为 Stats；CNN 控制窗口与缓冲区地址需单独约定。
- D0 RAM 是 CPU 私有 16 KiB 工作存储，当前没有 CNN 访问端口或 DMA 一致性机制。共享缓冲区需明确实际存储、访问路径和 Cache 策略。
- 正式板顶把外部原始 IRQ 接为 0。首次联调可用状态轮询，接中断时需在新顶层引出并接入 `irq_external`。

信号分组、参数、寄存器约定和联调顺序均在[接入指南](docs/integration/cpu5_cnn_handoff.md)。项目目标中的 MFCC、INT8 CNN、脉动阵列和时钟门控需要在各自实现与联调后再记录结果。CoreMark 衡量 CPU；CNN 加速比应使用同一模型、输入和精度口径比较软件推理与硬件推理。

## 目录地图

```text
rtl/                    CPU5、保留的三级实现、Cache、总线与外设
software/cpu5_coremark/  CPU5 启动、链接和 CoreMark 平台移植
software/               公共 MMIO 头文件及各类裸机示例
benchmarks/coremark/    CoreMark 算法及许可证
tb/                     模块、CPU、SoC 与板级 testbench
tools/                  固件生成、仿真、构建、验收和导出工具
pds/                    板卡引脚及时钟约束
programs/               已保留的文本初始化镜像
docs/integration/       队友接入指南
docs/evidence/          冻结证据与 LFS 原始归档
docs/history/           旧首页与旧交接说明
build/                  本机构建产物，不提交
```

根目录 `.do`、`.bat` 保留原位置，使现有脚本和冻结文件身份保持可用。后续 CNN 模块可放在 `rtl/cnn/`、驱动放在 `software/cnn/`，并新增独立系统顶层与构建入口；这些目录目前是建议布局。历史版本和详细说明从[文档导航](docs/README.md)进入。
