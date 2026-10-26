# RV32I / RV32IM 三级流水线 CPU

自研的 32 位 RISC-V 裸机处理器，采用 **IF → EX → WB** 三级流水线，支持可选的完整 RV32M 乘除法扩展。使用 Verilog 实现 CPU、两路 I/D Cache、存储接口和基础外设，在紫光同创 MES50HP 开发板上验证。工程提供 GCC 固件构建、ModelSim 自动自检和 PDS 独立板级构建入口，可作为后续 CNN 加速器的控制处理器。

**更新时间：2026-10-21。** RV32IM＋D0 同步 BRAM＋双 Cache＋64 项 BTB 的 performance／validation 均已上板 `FORMAL PASS`，完成双种子正式验收。50 MHz、GCC 15.2.0、O2 下，正式性能为 **117.958048697 CoreMark／2.359160974 CoreMark/MHz**，相对上一版 D0/RV32I 的 55.333377791 CoreMark 提升 **113.18%（2.132 倍）**。validation 用于验证另一组种子，不参与性能分数平均。完整实现、回归、资源、时序及板测证据见 [RV32M 交付记录](docs/rv32m_execution_20261021.md)和[双种子原始证据](docs/evidence/rv32m_board_20261021/README.md)。

## CPU5 五级流水线：下载后初始化

CPU5 的历史验收证据归档现由 Git LFS 保存。新 clone 请先执行 `git lfs pull`，再执行 `python tools/setup_cpu5_git_baselines.py --install`，以恢复归档并建立旧提交编号的本地兼容引用。详细步骤、迁移完整性证明和验证范围见 [CPU5 LFS 与历史基线说明](docs/cpu5_git_lfs_compat_20261026.md)。这一步不代表重新完成 CPU5 功能或上板验收。

## 功能与验证状态

| 功能 | 当前实现 | 验证状态 |
| --- | --- | --- |
| RV32I 整数指令 | 37 种常用整数指令；开启异常模式后支持 FENCE、ECALL、EBREAK | 指令、裸机 C 和 CoreMark 验证通过 |
| RV32M 乘除法扩展 | `ENABLE_M=1` 启用全部 8 条乘除法指令；4 个 APM 实现乘法，共享迭代除法／余数单元 | 11,904 个独立算术向量、7 个 CPU 场景、双种子正式上板通过，见[记录](docs/rv32m_execution_20261021.md) |
| 三级流水线 | WB → EX 前递、访存等待、六种分支、JAL/JALR、跳转冲刷 | RTL 回归和板级程序通过 |
| 取指／数据握手 | 单笔在途、请求背压、响应等待、错误响应；跳转后丢弃旧取指响应 | 可变延迟、复位和错误路径自检通过 |
| 片上 ROM／RAM | 默认 32 KiB ROM、16 KiB RAM；D0 在 D-Cache 后将 RAM 接至同步 BRAM，保留非 RAM AXI4-Lite 区域 | 定向、精确异常、回归、PDS 与正式上板通过；D0 STORE 为两拍 |
| UART TX／RX | 115200、8N1；RX 默认 16 字节 FIFO，软件轮询回显 | `Hello RISC-V`、`CPU123` 回显实物验证通过 |
| GPIO | 8 位输入／输出／输出使能，SET／CLEAR／TOGGLE，按键输入同步 | LED、按键和 KEY1 复位实物验证通过 |
| AXI4-Lite | 32 位数据主桥、AXI RAM、1 主 2 从地址分发、演示控制设备 | 协议自检、CPU 集成和 `AXI CTRL PASS` 实物验证通过 |
| AXI4 四拍 INCR 读突发 | 独立 CPU 命令 CSR → 读主机 → 锁存目标的路由器 → 两个 BRAM buffer；错误完整排空至 RLAST | 协议、真实 CPU/C、独立 P&R 通过；演示版上板及真实 CNN 联调待完成，见[记录](docs/axi4_read_burst_step5_20261020.md) |
| 最小 M 模式同步异常 | 6 种 Zicsr、MRET、必要 CSR；非法指令、ECALL／EBREAK、取指／访存错误 | `TRAP BOARD PASS` 实物验证通过 |
| 机器定时器中断 | 64 位 mtime／mtimecmp、MTIE／MTIP、屏蔽与挂起、中断返回 | `TIMER IRQ PASS` 实物验证通过，见[验证记录](docs/timer_irq_board.md) |
| 机器外部／软件中断 | 单路电平外部输入、MSIP 本地寄存器、三源使能／挂起及优先级，默认关闭 | 定向自检和三源固件板顶 RTL 已通过；专用实物验收待完成，见[说明](docs/machine_irq.md) |
| 两路指令 Cache | 2 KiB、64 组、16 字节行、LRU，可选择启用 | RTL、50 MHz 时序、综合网表及 2026-10-04 实物验证通过，见[验证记录](docs/icache_verification_20261003.md) |
| 内部 RAM CoreMark 基线 | performance／validation 独立正式模式，64 位计时和 CRC 检查 | 两次均 `FORMAL PASS`；历史无 Cache 性能为 **52.574739 CoreMark** |
| AXI SoC 的 CoreMark 对照 | 历史 AXI 无 Cache／双 Cache／双 Cache＋BTB，均为 RV32I | 三配置六项正式运行全部配对通过；performance 为 38.108122／46.049672／49.603719 CoreMark，见[历史测量](docs/coremark_axi_results_20261015.md) |
| D0/RV32IM CoreMark | 同步 BRAM、双 Cache、64 项 23 bit BTB、RV32IM、50 MHz、O2 | performance **117.958048697 CoreMark**，validation 也正式通过；计时、CRC、周期和 Cache 账本闭合 |
| 两路数据 Cache | 2 KiB、两路、64 组、16 字节行、LRU；写穿透、写缺失不分配；RAM 之外旁路 | RTL、真实 CPU 错误恢复、PDS、综合网表及 CoreMark 实板通过；专用 `DCACHE PASS` 演示的实物验收另行确认 |
| 动态分支预测／BTB | 64 项、两位方向语义；默认 32 KiB ROM 下每项压缩为 23 bit，查询／训练带 ROM 高位和对齐守卫 | 单元、CPU、等价性、边界、PDS 及 CoreMark 双种子实板通过；未扩容，见[瘦身记录](docs/btb_step4_20261020.md) |
| 更完整的异常／中断 | 最小 M 模式同步异常；定时器及新增外部／软件中断代码 | 三类中断 RTL 已通过；PLIC、向量入口、嵌套中断与 S/U 模式尚未实现 |
| CNN／DDR／DMA | 已有 AXI4-Lite 控制基础和独立 AXI4 读突发演示 | 真实 CNN 联调、DDR／DMA 和 ILA 仍待完成；独立读突发演示不代表加速器已接入 |
| 统一回归入口 | 双击菜单、分组 ModelSim 自检、前置镜像检查及 JSON／中文 Markdown 汇总 | 已提交基线清单 12 项全部 PASS；M 专项另验。额外工作区画像分组独立记录，见[说明](docs/regression.md)和[M 验证范围](docs/rv32m_execution_20261021.md) |
| CPU 源码交接工具 | 已提交源码／显式工作区导出、版本和文件哈希清单、中文交接说明 | 工具代码准备，尚未运行或生成交接包，见[交接说明](docs/cpu_handoff.md) |

上述板级结果来自用户提供的串口记录、截图和现象确认，具体资源、时序与镜像哈希按各版本验证记录区分。构建脚本不会自动下载 FPGA；生成 manifest 中的 `hardware_verified=false` 表示构建器自身未执行实物验收。

## 硬件与默认配置

| 项目 | 配置 |
| --- | --- |
| 开发板／FPGA | MES50HP／PGL50H-6IFBG484 |
| 板级 CPU 时钟 | 50 MHz，板载晶振；当前板级入口不使用 PLL |
| 指令集 | 通用配置 RV32I；`coremark_d0_m_btb` 显式启用 RV32IM，均使用 ilp32 ABI |
| 数据宽度／字节序 | 32 位／小端；寄存器 x0 固定为 0 |
| ROM | 32 KiB，8192 × 32 位，`0x00000000`–`0x00007FFF` |
| RAM | 16 KiB，4096 × 32 位，`0x00010000`–`0x00013FFF` |
| UART | 板载 USB-UART，115200、8 数据位、1 停止位、无校验、无流控 |
| CPU 复位 | KEY1；异步置复位，同步延迟释放约 1 ms |
| 引脚约束 | [pds/board_top.fdc](pds/board_top.fdc)，含 50 MHz 时钟和 UART／LED／按键引脚 |

ROM 与 RAM 均为 FPGA 内的片上存储，不是板载 DDR。不同仿真脚本可能使用更快的模拟 UART 或不同测试时钟，应以对应脚本为准。

主要开关：

| 参数 | 默认行为与用途 |
| --- | --- |
| `ENABLE_M=0` | 默认关闭乘除法扩展；`coremark_d0_m_btb` 设为 1，与异常开关独立；`misa.M` 随配置反映 |
| `ENABLE_D0_BRAM=0` | `soc_axi_lite_top` 默认保留 AXI RAM；D0 配置设为 1，在 D-Cache 后将 RAM 地址译至同步 BRAM |
| `ENABLE_TRAPS=0` | 通用 CPU 默认保持兼容模式；设为 1 开启最小 M 模式同步异常与 CSR |
| `ENABLE_TIMER_IRQ=0` | 设为 1 开启机器定时器中断，同时要求 `ENABLE_TRAPS=1` |
| `ENABLE_EXTERNAL_IRQ=0`／`ENABLE_SOFTWARE_IRQ=0` | 设为 1 开启对应机器中断源，同时要求 `ENABLE_TRAPS=1`；外部输入为 `irq_external` |
| `ENABLE_ICACHE=0` | `soc_axi_lite_top` 默认关闭指令 Cache；`icache_board_top` 显式开启 |
| `ENABLE_DCACHE=0` | `soc_axi_lite_top` 默认关闭数据 Cache；`dcache_board_top` 显式开启 I/D Cache |
| `ENABLE_BRANCH_PRED=0`／`BTB_ENTRIES=64` | 通用 CPU／SoC 默认关闭预测器；`btb_board`、`coremark_axi_btb`、`coremark_d0_btb` 和 `coremark_d0_m_btb` 显式开启 64 项 BTB |
| `IMEM_WORDS`／`DMEM_WORDS` | 通用存储容量参数；当前板级固件与构建保护按 8192／4096 字配置 |

扩大 ROM／RAM 时，需要同步修改顶层容量、`software/link.ld`、镜像生成器及构建保护检查，并重新验证资源和时序。只修改链接脚本不会增加硬件存储容量。

## CPU 与 SoC 结构

CPU 保持 IF → EX → WB。EX 级执行译码、ALU 运算、分支判断和访存请求，WB 级写回并向 EX 前递结果。访存等待时暂停相关流水线；分支、跳转和异常重定向时冲刷错误路径。

在 SoC 中，取指路径为 CPU → 可选指令 Cache → 片上 ROM。默认数据路径为 CPU → 可选 D-Cache → AXI4-Lite 主桥 → RAM／控制设备；D0 配置在 D-Cache 后增加 SoC 区域译码，`0x00010000`–`0x00013FFF` 进入本地同步 BRAM，其余数据区域保留 AXI4-Lite。写成功响应仍等待真实 RAM 写入，CPU 等响应退休，保留精确 STORE 异常。UART、GPIO、性能计数器和机器定时器使用独立的本地 MMIO 路径，完整请求与副作用已整体打一拍，RAM／D-Cache 请求不经过该拍。

支持的常用整数指令：

| 类别 | 指令 |
| --- | --- |
| 加减 | ADD、ADDI、SUB |
| 逻辑 | AND、OR、XOR、ANDI、ORI、XORI |
| 移位 | SLL、SRL、SRA、SLLI、SRLI、SRAI |
| 比较 | SLT、SLTU、SLTI、SLTIU |
| 高位立即数／PC 相对 | LUI、AUIPC |
| 条件分支 | BEQ、BNE、BLT、BGE、BLTU、BGEU |
| 跳转 | JAL、JALR |
| 加载 | LB、LBU、LH、LHU、LW |
| 存储 | SB、SH、SW |

异常模式另支持 FENCE、ECALL、EBREAK、CSRRW／CSRRS／CSRRC 及其立即数形式、MRET。`ENABLE_M=1` 时另支持 MUL、MULH、MULHSU、MULHU、DIV、DIVU、REM、REMU；乘法共享 APM 乘积，除法／余数共享迭代单元，覆盖除零和有符号溢出的定义结果。通用配置默认关闭 M，原 RV32I 固件继续使用软件乘除法。浮点和压缩指令尚未实现。

主要地址：

| 地址／范围 | 用途 | 软件定义 |
| --- | --- | --- |
| `0x20000000`／`0x20000004` | 周期／退休指令计数器低 32 位 | [mmio.h](software/mmio.h) |
| `0x20000010`／`0x20000014` | UART TX 数据／忙状态 | [mmio.h](software/mmio.h) |
| `0x20000018`／`0x2000001C` | UART RX 数据／FIFO 状态 | [uart_rx.h](software/uart_rx.h) |
| `0x20000020`–`0x20000034` | GPIO 输出、输入、使能、置位、清零、翻转 | [gpio.h](software/gpio.h) |
| `0x20000040`／`0x20000044` | mtime 低／高 32 位 | [timer.h](software/timer.h) |
| `0x20000048`／`0x2000004C` | mtimecmp 低／高 32 位 | [timer.h](software/timer.h) |
| `0x20000050` | 启用软件中断时的 MSIP，对齐 LW／SW，bit0 置位／清除 | [machine_irq.h](software/machine_irq.h) |
| `0x30000000` 起 | AXI 演示控制设备、Cache 统计设备或独立中断演示源，依顶层选择 | [axi_control.h](software/axi_control.h)、[I-cache 统计](docs/icache.md)、[D-cache 统计](docs/dcache.md)、[中断演示源](docs/machine_irq.md) |

`cycle_count`、`instret_count` 还有 64 位 RTL 观测端口；周期计数从首条有效指令进入 EX 后开始。CoreMark 使用复位释放后持续运行的 64 位 mtime 计时，两者不能直接混用。`0x30000000` 是现有演示／自检映射，真实 CNN 的地址与寄存器协议仍需约定。

## 工程目录与工具

| 目录／文件 | 用途 |
| --- | --- |
| `rtl/` | CPU、Cache、UART、GPIO、定时器、SoC、AXI 和各板级顶层 |
| `software/` | 裸机 C／汇编、启动代码、链接脚本、MMIO 头文件、CoreMark 移植层 |
| `benchmarks/coremark/` | CoreMark 原始算法、框架和许可证 |
| `programs/` | 配套指令 HEX、RAM 初始化 HEX 和生成配置 |
| `tb/` | 模块、CPU、SoC、板级及综合网表自检平台 |
| `tools/`、`build_*.bat` | 固件／镜像生成和 PDS 构建工具 |
| `run_*.do` | ModelSim 一键自检入口 |
| `run_regression.bat` | 统一回归双击菜单；可选择测试组、查看清单或生成未运行计划 |
| `export_cpu_package.bat` | CPU 源码交接双击菜单；导出 ZIP 或只列打包计划 |
| `pds/` | 板卡引脚和时序约束 |
| `docs/` | 操作、验证记录和历史说明 |
| `build/` | 本机生成的 ELF、MAP、反汇编、日志、报告、波形和独立 PDS 工程；不纳入 Git |

开发使用 RISC-V GCC、Python 3、ModelSim 和 Pango Design Suite。当前验证环境为 xPack RISC-V GCC 15.2.0、Python 3.11、ModelSim 10.6e、PDS 2022.2-SP6.4。

GCC 将 C／汇编编译成 CPU 执行的固件；ModelSim 仿真 Verilog；PDS 将硬件设计生成 FPGA 位流。Git Bash 只是运行下列命令的终端。`.bat` 也可从 CMD 或资源管理器运行，带参数的版本需要传入对应选项。修改 C 程序后应重建固件；要让板上使用新固件，还应重新生成并下载配套位流。

建议将仓库放在英文路径，例如 `D:/FPGA/riscv_3stage`，避免 ModelSim 和 PDS 的路径兼容问题。固件构建需要 `python` 可用及匹配的 RISC-V 工具链；部分生成器也支持 `--cross` 指定工具链前缀。

## 快速开始：先运行一次仿真

首次获取工程，在 Git Bash 执行：

```bash
cd /d/FPGA
git clone https://github.com/a-learner-1/riscv_3stage.git
cd riscv_3stage
```

打开 ModelSim，在 Transcript 中切到仓库根目录，先运行已有 UART 集成自检：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart.do
```

仓库中的配套 HEX 可直接用于相应仿真。修改 `software/uart_demo.c` 后，先在 Git Bash 运行 `cmd.exe //c build_uart.bat`，再重新执行上面的自检。

自检以 Transcript 中的 PASS 和 `test_pass=1` 为准。脚本可能只加入通过标志、完成标志等少量波形；查看 CPU 内部信号时，可在仿真启动后添加所需层级，检查 PC、有效位、写回和请求／响应握手。旧波形可用 `vsim -view` 打开对应 WLF，无需重新运行。

## 板级版本与构建

所有命令从 `D:/FPGA/riscv_3stage` 执行。每个版本先构建固件，再用匹配的 `--variant` 和 `--firmware` 生成位流。

| 用途 | 固件构建入口 | PDS variant／firmware | 现象与验证状态 |
| --- | --- | --- | --- |
| CPU、UART TX、GPIO 基线 | `build_board.bat` | `default`／`board_demo` | `Hello RISC-V`、LED 心跳、按键 |
| UART RX 回显 | `build_uart_rx.bat` | `default`／`uart_rx_echo` | 发送 `CPU123` 后收到相同文本 |
| AXI 控制自检 | `build_axi_control_board.bat` | `axi_control_board`／`axi_control_board` | `AXI CTRL PASS` |
| 同步异常自检 | `build_trap_board.bat` | `trap_board`／`trap_board` | `TRAP BOARD PASS` |
| 定时器中断自检 | `build_timer_irq_board.bat` | `timer_irq_board`／`timer_irq_board` | `TIMER IRQ PASS` |
| 外部／软件／定时器三源自检 | `build_machine_irq_board.bat` | `machine_irq_board`／`machine_irq_board` | 预期 `MACHINE IRQ PASS`，本轮未验证 |
| 两路指令 Cache 自检 | `build_icache_board.bat` | `icache_board`／`icache_board` | `ICACHE PASS` |
| 两路数据 Cache 自检（同时开启 I-cache） | `build_dcache_board.bat` | `dcache_board`／`dcache_board` | 预期 `DCACHE PASS`；实物待确认 |
| CoreMark 性能基线 | `build_coremark.bat --profile performance` | `coremark_board`／`coremark_performance` | `COREMARK RESULT: FORMAL PASS` |
| CoreMark 校验运行 | `build_coremark.bat --profile validation` | `coremark_board`／`coremark_validation` | `COREMARK RESULT: FORMAL PASS` |
| AXI CoreMark，Cache 关闭 | `build_coremark_axi.bat --cache off --profile performance` | `coremark_axi_off`／`coremark_axi_cache_off_performance` | performance／validation 实测 `FORMAL PASS`；38.108122 CoreMark |
| AXI CoreMark，双 Cache 开启 | `build_coremark_axi.bat --cache on --profile performance` | `coremark_axi_on`／`coremark_axi_cache_on_performance` | performance 实测 `FORMAL PASS`，46.049672 CoreMark；validation 也已实测通过 |
| AXI CoreMark，双 Cache＋BTB | `build_coremark_axi.bat --cache on --btb on --profile performance` | `coremark_axi_btb`／`coremark_axi_cache_on_btb_performance` | performance 实测 `FORMAL PASS`，49.603719 CoreMark；performance／validation 均实测通过 |
| BTB／动态分支预测自检 | `build_btb_board.bat` | `btb_board`／`btb_board` | 预期 `BTB BOARD PASS`，专用实物待验证 |
| D0 RV32I CoreMark＋双 Cache＋BTB | `python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32i --profile performance` | `coremark_d0_btb`／`coremark_d0_cache_on_btb_performance` | 两种子正式配对通过；55.333377791 CoreMark |
| D0 RV32IM CoreMark＋双 Cache＋BTB | `python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile performance` | `coremark_d0_m_btb`／`coremark_d0_m_cache_on_btb_performance` | 两种子正式配对通过；**117.958048697 CoreMark**；validation 使用对应 profile 和固件名 |
| AXI4 读突发独立演示 | `python -B tools/build_axi_burst_demo_images.py` | `axi_burst_demo_board`／`axi_burst_demo_board` | 真实 CPU/C 仿真及独立 P&R 通过；尚未生成演示位流、上板或 CNN 联调 |

以当前两路指令 Cache 版本为例，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_icache_board.bat
cmd.exe //c build_pds_board.bat --variant icache_board --firmware icache_board --stage bitstream
```

生成工程为 `build/pds_icache_board/board_demo.pds`，位流为 `build/pds_icache_board/generate_bitstream/board_top.sbit`。固件／源码匹配检查、布局布线和最终 STA 通过后才生成候选位流；通过 PDS 下载器手动进行 JTAG SRAM 下载。

串口使用板载 USB-UART 连接。SSCOM 选择实际 COM 口（已验证环境为 COM8），设置 115200、8N1、无流控。先打开串口，再下载或按 KEY1 重启。回显测试输入 `CPU123` 时关闭“HEX 发送”，使用文本发送。KEY1 重启 CPU；REPROGRAM 用于重新加载 FPGA 配置。

其他版本按表替换构建入口及参数，使用对应 `build/pds_*/generate_bitstream/board_top.sbit`，不要混用不同自检固件的位流。

## 两路组相联指令 Cache

独立的 `icache_board` 版本增加 **2 KiB、两路、64 组、每行 16 字节**的指令 Cache，优先填充无效路，其次按 LRU 替换。命中响应延迟一拍，已预热的连续命中可每拍接受一次请求；缺失时暂停当前取指，依次读取 ROM 的四个 32 位字并填充整行。

Cache 接在取指接口与只读 ROM 之间，保留原 IF → EX → WB。既有 SoC 默认关闭 Cache；专用顶层显式开启。当前仅支持固定只读程序镜像，不支持自修改代码、FENCE.I 或缓存一致性。

自检检查冲突函数调用、Cache 计数器快照以及三次定时器 IRQ／MRET。成功后输出 `ICACHE PASS`，LED2 常亮、LED1 约每 0.5 秒切换；按下并释放 KEY1 后再次自检并恢复心跳。2026-10-04 用户已确认串口、LED 和 KEY1 现象均正常。

ModelSim 可分别运行：

```tcl
cd D:/FPGA/riscv_3stage
do run_icache.do
do run_icache_board_netlist.do
```

第二条需要已有配套 PDS 综合网表。详细协议、统计寄存器、测试范围与限制见[指令 Cache 说明](docs/icache.md)，时序、网表模型告警及位流哈希见[验证记录](docs/icache_verification_20261003.md)。

2026-10-07 的双 Cache 步骤调整了指令 Cache 的 LRU 更新路径，并补验连续命中后立即同组缺失时的替换；命中响应和每拍接受一次请求的行为不变。上述 2026-10-04 实物记录属于原指令 Cache 版本，当前双 Cache 位流的实物结果另行记录。

## 两路组相联数据 Cache

新增 **2 KiB、两路、64 组、16 字节行**的数据 Cache，采用写穿透、写缺失不分配。RAM 读命中一拍返回；读缺失逐字填充整行。SB／SH／SW 写成功后更新命中行；写响应错误保持该行无效，下一次读取重新访问 RAM。范围外请求旁路，保留原请求的地址、大小和字节掩码。

独立 `dcache_board` 同时开启 I/D Cache、同步异常与定时器中断，检查两路冲突替换、字节／半字读写、后端 RAM 写入、统计快照和三次 IRQ／MRET。在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_dcache_board.bat
cmd.exe //c build_pds_board.bat --variant dcache_board --firmware dcache_board --stage bitstream
```

位流在 `build/pds_dcache_board/generate_bitstream/board_top.sbit`。上板预期：115200／8N1 收到 `DCACHE PASS`，LED2 常亮、LED1 心跳；KEY1 重启后再次 PASS。本版本的实物验证仍待用户确认。

ModelSim 使用 `do run_dcache.do`；旧版本兼容回归使用 `do run_dcache_baseline.do`；配套综合网表使用 `do run_dcache_board_netlist.do`。协议、寄存器、错误与复位说明见[数据 Cache 说明](docs/dcache.md)，具体验证结果见[验证记录](docs/dcache_verification_20261007.md)。

当前没有 DMA 一致性或缓存失效指令。双 Cache 已随 AXI、D0/RV32I 和 D0/RV32IM 的 CoreMark 完成正式实板运行；专用数据 Cache 演示程序的 `DCACHE PASS` 实物验收仍独立记录。最新成绩见下一节，历史 AXI 对照见[操作说明](docs/coremark_axi.md)。

## 当前 CoreMark 正式板测：RV32IM＋D0

2026-10-21，MES50HP、50 MHz、GCC 15.2.0、`-march=rv32im -mabi=ilp32 -O2`、总数据 2000 字节、D0 同步 BRAM、2 KiB 两路 I/D Cache、64 项 23 bit BTB。两组均自动校准为 2,000 次迭代，完整 CRC、`Correct operation validated` 和 `COREMARK RESULT: FORMAL PASS` 已核验。

| 运行 | 时间（秒） | CoreMark | CoreMark/MHz | CPI |
| --- | ---: | ---: | ---: | ---: |
| performance | 16.955180440 | **117.958048697** | **2.359160974** | 1.463126049 |
| validation | 16.983204880 | 117.763402970 | 2.355268059 | 1.464395358 |

正式成绩取 performance，validation 不参与平均。相对旧 D0/RV32I 的 **55.333377791 CoreMark／1.106667556 CoreMark/MHz**，整版速度提升 **113.18%**，每轮耗时减少 **53.09%**；不同迭代次数按速率比较。M 多周期等待计入 `work_other`，不能用 CPI 单项判断跨 ISA 收益。

本版资源为 **8,643 LUT、7,031 FF、4 APM**；本轮独立构建的 RV32I 对照为 8,078 LUT、6,780 FF、0 APM。两份正式 M 位流分别完成独立 P&R、最终 STA 与板测；Setup、Hold、Recovery、Removal 和脉宽检查全部满足 50 MHz 约束。详见 [M 实现、时序与板测记录](docs/rv32m_execution_20261021.md)及[原始证据](docs/evidence/rv32m_board_20261021/README.md)。

重新构建正式 performance 和 validation，在工程根目录执行：

```bash
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile performance
python -B tools/build_pds_board.py --variant coremark_d0_m_btb --firmware coremark_d0_m_cache_on_btb_performance --stage bitstream
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile validation
python -B tools/build_pds_board.py --variant coremark_d0_m_btb --firmware coremark_d0_m_cache_on_btb_validation --stage bitstream
```

位流分别在 `build/pds_coremark_d0_m_cache_on_btb_performance/generate_bitstream/board_top.sbit` 与 `build/pds_coremark_d0_m_cache_on_btb_validation/generate_bitstream/board_top.sbit`。本机已交付副本为 `build/board_release_rv32m_20261020/Mperformance.sbit`、`Mvalidation.sbit`；`build/` 不纳入 Git，重新克隆后需要构建。固件、ISA 与 PDS variant 必须匹配，过期镜像会被来源守卫拒绝。

M 专项短测先准备两份匹配镜像：

```bash
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile smoke
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile smoke-validation
```

再在 ModelSim 的工程根目录分别执行 `do run_rv32m.do`（单元与 CPU）和 `do run_coremark_m.do`（真实 CoreMark 双种子）。smoke 少于 10 秒时的 `Errors detected`／时间提示属于短测预期；正式成绩必须运行不少于 10 秒并完成 CRC 验证。

## 历史内部 RAM CoreMark 基线

用户已在 50 MHz 板级配置上完成 performance 与 validation 两次正式模式运行，并提供完整串口结果。测试使用 xPack GCC 15.2.0、`-march=rv32i -mabi=ilp32 -O2`，总测试数据 2000 字节、静态分配、ROM 32 KiB、RAM 16 KiB、无 Cache，核心与存储时钟为 1:1。

| 运行 | 实际迭代数 | 完整 ticks | 算法耗时 | 迭代速度 | 结果 |
| --- | --- | --- | --- | --- | --- |
| performance | 1100 | 1,046,129,783 | 20.922595660 s | 52.574738712 次/s | `FORMAL PASS` |
| validation | 600 | 610,559,442 | 12.211188840 s | 49.135265031 次/s | `FORMAL PASS` |

**历史内部 RAM 性能基线：52.574739 CoreMark，1.051494774 CoreMark/MHz。** validation 使用另一组种子验证正确性，其速度不与 performance 求平均。本记录表示板上实测和固件正式模式检查通过，未声明 EEMBC 注册或认证。当前 AXI 平台对照使用另测的 38.108122 CoreMark 基线。

重新构建两种正式版本，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark.bat --profile performance
cmd.exe //c build_pds_board.bat --variant coremark_board --firmware coremark_performance --stage bitstream
cmd.exe //c build_coremark.bat --profile validation
cmd.exe //c build_pds_board.bat --variant coremark_board --firmware coremark_validation --stage bitstream
```

位流分别在 `build/pds_coremark_performance/`、`build/pds_coremark_validation/` 下。两次分别下载，等待自动校准和完整结果，保存串口文本。算法时间来自 64 位 mtime，不使用串口接收时间戳计分。

`smoke`、`smoke-validation` 仅用于短程功能检查；`formal-short` 刻意验证短时运行被拒绝，预期固件 FAIL，属于通过的负测。配置、种子／CRC、换算和仿真方法见[CoreMark 说明](docs/coremark.md)。后续增加 Cache／BTB 或调整编译选项时，应保留本基线并重新测量对应配置。

## 历史 AXI SoC 的 CoreMark 对照

提供 `coremark_axi_off`、`coremark_axi_on` 和新增的 `coremark_axi_btb` 三个独立板级版本，均采用 50 MHz、32 KiB ROM、16 KiB AXI RAM 和相同等待参数，分别运行 AXI 基线、双 Cache、双 Cache＋64 项 BTB。正式速度仍由原 64 位 mtime 计算，START／STOP 在同一 AR 握手边沿冻结周期数、退休指令数、I/D Cache 和七项 BP 计数。

两个统计采样点位于 mtime 计时边界之外，因此计数包含边界开销；CPI 仅用于辅助分析。自动校准会预热 Cache、训练预测器。三个配置使用独立镜像名和 PDS 目录；原内部 RAM 无 Cache 成绩继续作为历史基线。AXI off/on 比较 Cache 效果，AXI on/on＋BTB 比较预测器效果。

三配置六项正式板测已于 2026-10-16 完成，详见[历史测量记录](docs/coremark_axi_results_20261015.md)。这些成绩属于对应历史构建，源码继续变化后需正常重建并重新测量。复跑三配置固件，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark_compare.bat --profile performance
cmd.exe //c build_coremark_compare.bat --profile validation
```

对照入口一次解析公共参数并串行构建三个版本。原 `--cache off/on/both` 入口保持兼容，预测器默认关闭。统计接口升级为 schema 3，新增六类互斥的 64 位周期统计；全部 AXI 固件需重新构建。六种短仿真、六个正式版本的 PDS 命令、预期路径、统计有效性及结果记录方式见[AXI CoreMark 说明](docs/coremark_axi.md)。

## BTB 与动态分支预测

使用默认 64 项的直接映射 BTB。默认 32 KiB ROM 下，每项为 7 bit ROM 字地址 tag、13 bit word target 和 3 bit 六状态编码，共 **23 bit**；保留两位饱和方向计数语义。查询、训练 PC 和训练目标均先做完整地址的 ROM 范围及四字节对齐检查，避免高地址别名污染。条件分支和 JAL 可提前选择取指地址；JALR 保留 EX 解析。预测元数据随请求冻结，成功完成的指令才训练；异常、中断和 MRET 保持更高优先级，详见[瘦身与边界验收](docs/btb_step4_20261020.md)。

`cpu_top` 与 `soc_axi_lite_top` 的 `ENABLE_BRANCH_PRED` 默认 0，`BTB_ENTRIES` 默认 64。AXI＋BTB、D0/RV32I＋BTB 和 D0/RV32IM＋BTB 的两种子均已有正式板测。BTB 瘦身保持容量和方向策略，未测得同配置 CPI 改善；其收益为资源及布线时序。独立 `btb_board` 的实物验收单独记录。

后续需要构建时，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_btb_board.bat
cmd.exe //c build_pds_board.bat --variant btb_board --firmware btb_board --stage bitstream
```

专用 BTB 演示复跑后的预期位流路径为 `build/pds_btb_board/generate_bitstream/board_top.sbit`。板顶 RTL 已验证，实物验收仍需串口 `BTB BOARD PASS`、LED2 常亮、LED1 心跳及 KEY1 重启后再次自检；CoreMark 配对通过不代替该专用演示验收。操作见[BTB 说明](docs/btb.md)。

## 机器外部与软件中断（代码准备）

通用 CPU 的机器外部／软件中断开关默认关闭；独立 `machine_irq_board` 显式开启三类机器中断，使用 AXI 演示外设自动产生外部电平请求，软件 MSIP 和现有定时器产生另外两类请求。RTL 已检查屏蔽挂起、外部→软件→定时器优先级、MRET 恢复和前台校验和；专用板顶实物验收待完成。说明与构建命令见[机器中断说明](docs/machine_irq.md)，真实 CNN 完成通知仍需约定来源清除协议。

## CPU 源码交接包（代码准备）

双击 `export_cpu_package.bat`，选择导出或只列计划。默认导出已提交的源码，要求已跟踪文件和暂存区没有修改，且打包范围内没有未跟踪源码；建议先提交本步工具再导出。需要保留未提交修改时，显式使用 `--include-uncommitted`，此时 Git HEAD 只是基线，实际交接版本以文件清单与哈希为准。

以后需要使用时，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c export_cpu_package.bat --plan
cmd.exe //c export_cpu_package.bat --export
```

输出位于 `build/handoff/<run_id>/cpu_source.zip`，包内根目录为 `riscv_3stage/`。配套清单记录提交、来源模式与各文件 SHA-256；打包成功仅说明源码文件已导出，不代表编译、仿真或硬件验证通过。包内包含源码、说明、约束和允许的文本镜像，不携带本机工作库、构建报告、网表、位流或工具安装。部分仿真需要的构建报告须由接收方重新生成，原前置检查继续保留。

当前三级 CPU 的 AXI、时钟复位、存储、中断和 Cache 边界见[交接说明](docs/cpu_handoff.md)。真实 CNN 的寄存器、数据格式与缓冲区仍待双方约定；以后升级五级时，应保持约定的 SoC 接口并重新完成集成验证。本轮未运行打包入口，也未升级流水线。

## 统一回归入口

双击 `run_regression.bat` 进入中文菜单，选择基础兼容、Cache、BTB、中断、CoreMark 或三源中断模拟板级组。实际选择运行后才启动 ModelSim；入口不会自动构建固件。缺少或过期的配套镜像显示 `BLOCKED` 并给出构建提示，未选和仅计划的测试保持 `NOT_RUN`。

后续可在 Git Bash 查看清单或生成计划：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c run_regression.bat --list
cmd.exe //c run_regression.bat --group all --plan
```

`--list`／`--plan` 不启动仿真或固件检查子进程，计划不能作为通过记录。使用 `--group btb`、`--group irq,board` 或 `--group all` 实际运行，`all` 取当前清单全部分组。M 交付验证中的已提交基线清单 12 项全部 PASS，M 专项另行通过；工作区额外画像分组不包含在该 12 项结论中。日志与 JSON／中文汇总保存在 `build/regression/<run_id>/`，范围与证据规则见[统一回归说明](docs/regression.md)和[M 交付记录](docs/rv32m_execution_20261021.md)。

## 常用仿真入口

在 ModelSim 的仓库根目录执行 `do 脚本名`。根据本次修改选择受影响的自检；综合网表测试需要对应 PDS 生成文件。

| 测试范围 | 脚本 |
| --- | --- |
| 整数、分支、跳转 | `run_cpu.do`、`run_branch.do`、`run_compare_branch.do`、`run_jump.do` |
| 加载／存储及子字访问 | `run_load_store.do`、`run_subword_mem.do` |
| GCC C 程序与计数器 | `run_c_program.do`、`run_performance.do` |
| 取指／数据握手 | `run_fetch_handshake.do`、`run_data_handshake.do` |
| UART／GPIO | `run_uart.do`、`run_uart_rx.do`、`run_gpio.do` |
| SoC／AXI | `run_soc.do`、`run_axi_lite.do`、`run_axi_control.do` |
| 同步异常 | `run_trap.do`、`run_trap_edges.do`、`run_trap_c.do` |
| 定时器中断 | `run_timer_irq.do`、`run_timer_irq_board.do` |
| 外部／软件中断、三源优先级及 AXI 演示源 | `run_machine_irq.do`；RTL 已通过，实物另验 |
| 三源独立板级固件与 KEY1 重启 | `run_machine_irq_board.do`，先构建匹配镜像；实物另验 |
| 两路指令 Cache | `run_icache.do`、`run_icache_board_netlist.do` |
| 两路数据 Cache／双 Cache | `run_dcache.do`、`run_dcache_fault.do`、`run_dcache_baseline.do`、`run_dcache_board_netlist.do` |
| CoreMark 短程和移植层 | `run_coremark_prepare.do`，先按[说明](docs/coremark.md)准备对应镜像 |
| AXI CoreMark 统计接口及三配置×两种子共六种短组合 | `run_coremark_axi.do`，先按[说明](docs/coremark_axi.md)准备当前匹配镜像 |
| BTB 单元、取指预测元数据及 CPU 对照 | `run_btb.do`、`run_btb_compact_equivalence.do`、`run_btb_rom_boundary_cpu.do` |
| BTB 独立板级固件 | `run_btb_board.do`，先构建配套镜像；RTL 已通过，实物另验 |
| RV32M 单元、CPU 与真实 CoreMark | `run_rv32m.do`、`run_coremark_m.do`，后者先按上文准备两份 M 短测镜像 |
| 本地 MMIO 打拍 | `run_mmio_stage_latency.do`、`run_mmio_stage_contract.do` |
| D0 同步 BRAM 数据后端 | `run_d0_native_backend.do`、`run_d0_cpu_integration.do`、`run_d0_causal_latency.do`；真实程序观测用 `run_coremark_d0_measure.do` |
| AXI4 读突发独立演示 | `run_axi4_burst_fabric.do`、`run_axi4_burst_reader.do`、`run_axi4_burst_soc.do`，先按[记录](docs/axi4_read_burst_step5_20261020.md)准备配套镜像 |

普通有限 C 仿真使用 `tohost` 结束协议；板级自检程序完成检查后持续维持 LED 心跳或回显，按 KEY1 重启。两类程序的结束方式不同，应使用配套顶层和测试平台。

## 后续开发与 CNN 协作

当前可复现性能基线为 50 MHz、RV32IM＋D0＋双 Cache＋64 项 BTB：117.958048697 CoreMark／2.359160974 CoreMark/MHz，两种子正式通过。AXI 三配置与 D0/RV32I 成绩保留为各版本历史对照。后续按功能逐项独立回归、P&R 和板测，保存固件、最终 STA、位流哈希和完整 UART；比较 ISA 或编译选项不同时，按整版配置和每迭代速率解释。专用 BTB／三源中断板级版本的实物验收仍按各自说明完成。

CPU 已具备裸机 C、RV32M、UART、GPIO、定时器、两路 Cache、动态分支预测和 AXI4-Lite 控制基础。独立 AXI4 演示已实现 CPU 发命令后一次 AR、四次 R 的 INCR 读取，路由目标保持锁定，中途错误排空至 RLAST；它不改 CPU 普通访存，不代表突发写、真实 CNN/DMA 或 ILA 已交付。真实 CNN 接入前还需约定寄存器地址、启动／完成／清除流程、结果格式、缓冲区、时钟与复位，以及共享内存与 D-Cache 的一致性策略。

比赛要求的“两路指令与数据 Cache”“动态分支预测”“完整异常／中断”和 AI 加速，不能仅凭现有 CPU 自检 PASS 宣称全部完成。当前优先保留可复现的已验证基线，再逐项增加功能和验收证据。

## 文档索引

- [RV32M：实现、回归、资源、时序与最新双种子正式成绩](docs/rv32m_execution_20261021.md)
- [RV32IM 原始 UART、单次记录、配对结果及 SHA-256 清单](docs/evidence/rv32m_board_20261021/README.md)
- [D0 同步 BRAM 数据后端与精确 STORE 语义](docs/d0_bram_step3_20261020.md)
- [本地 MMIO 请求整体打一拍](docs/mmio_pipeline_step2_20261019.md)
- [64 项 BTB 的 23 bit 瘦身与 ROM 守卫](docs/btb_step4_20261020.md)
- [独立 AXI4 四拍 INCR 读突发演示及验收边界](docs/axi4_read_burst_step5_20261020.md)
- [历史 AXI CoreMark 板级测量：三配置六项正式结果与性能对照](docs/coremark_axi_results_20261015.md)
- [CPU 源码交接包：导出、版本清单、接口及五级升级边界](docs/cpu_handoff.md)
- [统一回归：双击菜单、分组、前置检查与结果汇总](docs/regression.md)
- [指令 Cache：结构、协议、统计与操作](docs/icache.md)
- [指令 Cache：RTL、PDS、网表和实物验证记录](docs/icache_verification_20261003.md)
- [数据 Cache：结构、写策略、MMIO 与上板步骤](docs/dcache.md)
- [双 Cache：RTL、PDS 与实物验收状态](docs/dcache_verification_20261007.md)
- [定时器中断板级自检与实物验证](docs/timer_irq_board.md)
- [机器外部／软件中断：接口、优先级和待验证入口](docs/machine_irq.md)
- [CoreMark：配置、板级基线与验证](docs/coremark.md)
- [AXI CoreMark：基线、双 Cache、双 Cache＋BTB 与原子统计](docs/coremark_axi.md)
- [BTB：动态分支预测、误预测恢复与待验证入口](docs/btb.md)
- [开发阶段历史记录](docs/development_history.md)：保留整理前的详细 README；历史状态与性能数值按原文版本理解，当前状态以本页为准。

## 周期瓶颈统计（2026-10-16）

六类周期为取指等待、数据读等待、数据写等待、本地 MMIO 等待、重定向后等待和工作／其他，沿用同一 START／STOP 快照并校验分类总和等于 counter_cycles。寄存器与统计边界见[周期统计说明](docs/cycle_profile.md)。本次 M 正式板测两组均完成分类闭合；work_other 包含 M 多周期等待，不等于退休指令数。49.603719 CoreMark 是统计扩展前的历史 AXI 配置成绩，最新正式成绩见上文。

## AXI 低延迟改进（2026-10-16）

AXI 路由器在 AW/W 最后一个通道握手边沿完成配对；RAM 的零等待 B/R 响应分别在真实写提交／同步读捕获边沿置为有效，非零人工等待保持原时序。原三级 CPU、AXI4-Lite 端口和精确错误处理保留。2026-10-16 阶段的双 Cache＋BTB 最终 Setup WNS +1.300 ns、最小 Hold +0.026 ns，属于历史 AXI 时序基线；后续 MMIO、D0、BTB 瘦身和 M 均有独立验收，不把旧报告沿用为新位流证据。详见[低延迟说明](docs/axi_latency.md)、[历史时序修复](docs/timing_fix_20261016.md)和[最新 M 记录](docs/rv32m_execution_20261021.md)。

### D1 独立测量与时序基线

ModelSim 中执行 `do run_coremark_d1_measure.do`，独立观测双 Cache＋BTB 两种真实 CoreMark 短程的 STORE 间距与方向错误拆分。D1 不接入统一回归。历史固定镜像均有两次原始 START，选最后一次对应的 epoch 2；当前 D1 分析器仍按 `raw==2 && selected==1 && epoch==2 && stop==1 && crossings==0` 验收。后续 D0 分析器已使用 `raw>=1 && selected==1 && epoch==raw && stop==1 && crossings==0`，两者不要混用。测量仍须原 workload 自检及 M1／M2 冻结账本对账，投影与真实 RTL 性能分别记录。

D1 时序基线采用已归档最终 STA：Slow Setup +1.300 ns，Slow／Fast Hold +0.035／+0.026 ns，两角最小 Hold **+0.026 ns**。过程报告中的 Fast Hold +0.015 ns 仅作过程参考。布局布线后 LUT 为 **9185**（5731 + 3454），综合映射后为 **9178**（9070 + 108）；报告哈希、历史资源对照及 50 MHz 工作点见[时序修复记录](docs/timing_fix_20261016.md)，后续延迟目标与方向错误率定义见[AXI 低延迟说明](docs/axi_latency.md)。

### AXI 写通路分段分析

新增 ModelSim `axi_write_profile_tb` 和 `run_axi_write_profile.do`，由 CPU STORE 测量 D-cache、桥、路由器、RAM 与 B 响应各段周期，输出逐事务及 min/max/mean CSV。统一入口为 `cmd.exe //c run_regression.bat --group axi-write-profile`，同时复查既有错误及复位恢复。采样口径与验证记录见 [写通路分析](docs/axi_write_profile.md)。

### 真实 CoreMark 写通路画像

双 Cache＋BTB 的两种真实 C 短程可用 `cmd.exe //c run_regression.bat --group coremark-axi-write-profile` 取得逐 STORE、分阶段及 START／STOP 窗口内写等待统计。复用原 CRC／UART／计数器自检，先分析再决定 RTL 优化；详见 [真实程序写通路分析](docs/coremark_axi_write_profile.md)。
