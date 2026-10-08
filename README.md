# RV32I 三级流水线 CPU

自研的 32 位 RISC-V 裸机处理器，采用 **IF → EX → WB** 三级流水线，使用 Verilog 实现 CPU、存储接口和基础外设，在紫光同创 MES50HP 开发板上验证。工程提供 GCC 固件构建、ModelSim 自动自检和 PDS 独立板级构建入口，可作为后续 CNN 加速器的控制处理器。

**更新时间：2026-10-08。** CPU 基础功能、串口收发、AXI 控制、同步异常、定时器中断和两路指令 Cache 的独立板级自检已有验证记录。两路数据 Cache 的实物确认、AXI CoreMark 对照测量仍待完成。本轮新增默认关闭的 64 项 BTB、2 位动态方向预测及独立自检入口，只编写代码，未编译、仿真、运行 PDS 或上板。此次修改涉及 CPU／IF 通路，关闭预测器的兼容回归也待执行；下表已有通过记录属于相应历史版本。真实 CNN 联调仍待完成。

## 功能与验证状态

| 功能 | 当前实现 | 验证状态 |
| --- | --- | --- |
| RV32I 整数指令 | 37 种常用整数指令；开启异常模式后支持 FENCE、ECALL、EBREAK | 指令、裸机 C 和 CoreMark 验证通过 |
| 三级流水线 | WB → EX 前递、访存等待、六种分支、JAL/JALR、跳转冲刷 | RTL 回归和板级程序通过 |
| 取指／数据握手 | 单笔在途、请求背压、响应等待、错误响应；跳转后丢弃旧取指响应 | 可变延迟、复位和错误路径自检通过 |
| 片上 ROM／RAM | 独立程序与数据镜像，默认 32 KiB ROM、16 KiB RAM | 仿真、PDS 和板级运行通过 |
| UART TX／RX | 115200、8N1；RX 默认 16 字节 FIFO，软件轮询回显 | `Hello RISC-V`、`CPU123` 回显实物验证通过 |
| GPIO | 8 位输入／输出／输出使能，SET／CLEAR／TOGGLE，按键输入同步 | LED、按键和 KEY1 复位实物验证通过 |
| AXI4-Lite | 32 位数据主桥、AXI RAM、1 主 2 从地址分发、演示控制设备 | 协议自检、CPU 集成和 `AXI CTRL PASS` 实物验证通过 |
| 最小 M 模式同步异常 | 6 种 Zicsr、MRET、必要 CSR；非法指令、ECALL／EBREAK、取指／访存错误 | `TRAP BOARD PASS` 实物验证通过 |
| 机器定时器中断 | 64 位 mtime／mtimecmp、MTIE／MTIP、屏蔽与挂起、中断返回 | `TIMER IRQ PASS` 实物验证通过，见[验证记录](docs/timer_irq_board.md) |
| 两路指令 Cache | 2 KiB、64 组、16 字节行、LRU，可选择启用 | RTL、50 MHz 时序、综合网表及 2026-10-04 实物验证通过，见[验证记录](docs/icache_verification_20261003.md) |
| CoreMark | performance／validation 独立正式模式，64 位计时和 CRC 检查 | 两次均 `FORMAL PASS`；无 Cache 性能为 **52.574739 CoreMark** |
| AXI SoC 的 CoreMark 对照 | 同一 AXI RAM 上关闭／开启 I/D Cache；开始／结束原子快照、周期与退休指令、Cache 统计 | 已编写独立构建、仿真与板级入口；本轮未运行验证，见[操作说明](docs/coremark_axi.md) |
| 两路数据 Cache | 2 KiB、两路、64 组、16 字节行、LRU；写穿透、写缺失不分配；RAM 之外旁路 | RTL、真实 CPU 错误恢复、50 MHz PDS 与综合网表通过；实物待确认，见[说明](docs/dcache.md) |
| 动态分支预测／BTB | 已编写默认关闭的 64 项 BTB、2 位饱和方向计数器；预测条件分支与 JAL，EX 核对并恢复错误预测 | 新功能及关闭模式兼容性均待验证，见[说明](docs/btb.md) |
| 更完整的异常／中断 | 当前仅最小 M 模式同步异常与机器定时器中断 | 外部／软件中断、PLIC、嵌套中断等尚未实现 |
| CNN／DDR／DMA | 已有 AXI4-Lite 控制接口基础 | 真实 CNN 联调、AXI4 突发传输、DDR／DMA 尚未实现 |

上述板级结果来自用户提供的串口记录、截图和现象确认，具体资源、时序与镜像哈希按各版本验证记录区分。构建脚本不会自动下载 FPGA；生成 manifest 中的 `hardware_verified=false` 表示构建器自身未执行实物验收。

## 硬件与默认配置

| 项目 | 配置 |
| --- | --- |
| 开发板／FPGA | MES50HP／PGL50H-6IFBG484 |
| 板级 CPU 时钟 | 50 MHz，板载晶振；当前板级入口不使用 PLL |
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
| `ENABLE_TRAPS=0` | 通用 CPU 默认保持兼容模式；设为 1 开启最小 M 模式同步异常与 CSR |
| `ENABLE_TIMER_IRQ=0` | 设为 1 开启机器定时器中断，同时要求 `ENABLE_TRAPS=1` |
| `ENABLE_ICACHE=0` | `soc_axi_lite_top` 默认关闭指令 Cache；`icache_board_top` 显式开启 |
| `ENABLE_DCACHE=0` | `soc_axi_lite_top` 默认关闭数据 Cache；`dcache_board_top` 显式开启 I/D Cache |
| `IMEM_WORDS`／`DMEM_WORDS` | 通用存储容量参数；当前板级固件与构建保护按 8192／4096 字配置 |

扩大 ROM／RAM 时，需要同步修改顶层容量、`software/link.ld`、镜像生成器及构建保护检查，并重新验证资源和时序。只修改链接脚本不会增加硬件存储容量。

## CPU 与 SoC 结构

CPU 保持 IF → EX → WB。EX 级执行译码、ALU 运算、分支判断和访存请求，WB 级写回并向 EX 前递结果。访存等待时暂停相关流水线；分支、跳转和异常重定向时冲刷错误路径。

在 AXI SoC 版本中，取指路径为 CPU → 可选指令 Cache → 片上 ROM；普通数据访存经可选数据 Cache、AXI4-Lite 主桥到 RAM 或控制设备。仅配置的普通 RAM 地址可以缓存，范围外请求旁路。UART、GPIO、性能计数器和机器定时器沿用 CPU 的本地 MMIO 路径。演示控制设备、指令 Cache 统计设备和数据 Cache 统计设备分别属于不同自检顶层。

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

异常模式另支持 FENCE、ECALL、EBREAK、CSRRW／CSRRS／CSRRC 及其立即数形式、MRET。当前无硬件乘除法、浮点或压缩指令；RV32I C 程序所需的乘除法与软件浮点由相应的 libgcc 提供。

主要地址：

| 地址／范围 | 用途 | 软件定义 |
| --- | --- | --- |
| `0x20000000`／`0x20000004` | 周期／退休指令计数器低 32 位 | [mmio.h](software/mmio.h) |
| `0x20000010`／`0x20000014` | UART TX 数据／忙状态 | [mmio.h](software/mmio.h) |
| `0x20000018`／`0x2000001C` | UART RX 数据／FIFO 状态 | [uart_rx.h](software/uart_rx.h) |
| `0x20000020`–`0x20000034` | GPIO 输出、输入、使能、置位、清零、翻转 | [gpio.h](software/gpio.h) |
| `0x20000040`／`0x20000044` | mtime 低／高 32 位 | [timer.h](software/timer.h) |
| `0x20000048`／`0x2000004C` | mtimecmp 低／高 32 位 | [timer.h](software/timer.h) |
| `0x30000000` 起 | AXI 演示控制设备，或 I/D Cache 自检统计设备，依顶层选择 | [axi_control.h](software/axi_control.h)、[I-cache 统计](docs/icache.md)、[D-cache 统计](docs/dcache.md) |

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

| 用途 | 固件构建入口 | PDS variant／firmware | 已验证现象 |
| --- | --- | --- | --- |
| CPU、UART TX、GPIO 基线 | `build_board.bat` | `default`／`board_demo` | `Hello RISC-V`、LED 心跳、按键 |
| UART RX 回显 | `build_uart_rx.bat` | `default`／`uart_rx_echo` | 发送 `CPU123` 后收到相同文本 |
| AXI 控制自检 | `build_axi_control_board.bat` | `axi_control_board`／`axi_control_board` | `AXI CTRL PASS` |
| 同步异常自检 | `build_trap_board.bat` | `trap_board`／`trap_board` | `TRAP BOARD PASS` |
| 定时器中断自检 | `build_timer_irq_board.bat` | `timer_irq_board`／`timer_irq_board` | `TIMER IRQ PASS` |
| 两路指令 Cache 自检 | `build_icache_board.bat` | `icache_board`／`icache_board` | `ICACHE PASS` |
| 两路数据 Cache 自检（同时开启 I-cache） | `build_dcache_board.bat` | `dcache_board`／`dcache_board` | 预期 `DCACHE PASS`；实物待确认 |
| CoreMark 性能基线 | `build_coremark.bat --profile performance` | `coremark_board`／`coremark_performance` | `COREMARK RESULT: FORMAL PASS` |
| CoreMark 校验运行 | `build_coremark.bat --profile validation` | `coremark_board`／`coremark_validation` | `COREMARK RESULT: FORMAL PASS` |
| AXI CoreMark，Cache 关闭 | `build_coremark_axi.bat --cache off --profile performance` | `coremark_axi_off`／`coremark_axi_cache_off_performance` | 本轮仅编写代码，待验证 |
| AXI CoreMark，双 Cache 开启 | `build_coremark_axi.bat --cache on --profile performance` | `coremark_axi_on`／`coremark_axi_cache_on_performance` | 本轮仅编写代码，待验证 |
| BTB／动态分支预测自检 | `build_btb_board.bat` | `btb_board`／`btb_board` | 预期 `BTB BOARD PASS`，本轮未验证 |

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

当前没有 DMA 一致性或缓存失效指令。带 Cache 的 CoreMark 尚未重测，下节成绩仍属于原无 Cache 配置。新的 AXI 对照入口见[操作说明](docs/coremark_axi.md)。

## CoreMark 板级性能基线

用户已在 50 MHz 板级配置上完成 performance 与 validation 两次正式模式运行，并提供完整串口结果。测试使用 xPack GCC 15.2.0、`-march=rv32i -mabi=ilp32 -O2`，总测试数据 2000 字节、静态分配、ROM 32 KiB、RAM 16 KiB、无 Cache，核心与存储时钟为 1:1。

| 运行 | 实际迭代数 | 完整 ticks | 算法耗时 | 迭代速度 | 结果 |
| --- | --- | --- | --- | --- | --- |
| performance | 1100 | 1,046,129,783 | 20.922595660 s | 52.574738712 次/s | `FORMAL PASS` |
| validation | 600 | 610,559,442 | 12.211188840 s | 49.135265031 次/s | `FORMAL PASS` |

**当前性能基线：52.574739 CoreMark，1.051494774 CoreMark/MHz。** validation 使用另一组种子验证正确性，其速度不与 performance 求平均。本记录表示板上实测和固件正式模式检查通过，未声明 EEMBC 注册或认证。

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

## AXI SoC 的 CoreMark 对照入口

新增 `coremark_axi_off` 和 `coremark_axi_on` 两个独立板级版本，均采用 50 MHz、32 KiB ROM、16 KiB AXI RAM 和相同的等待参数，分别关闭或同时开启两路 I/D Cache。正式速度仍由原 64 位 mtime 计算，附加 START／STOP 原子快照提供周期数、退休指令数、CPI 及 I/D Cache 计数。

两个统计采样点位于 mtime 计时边界之外，因此计数包含边界开销；CPI 仅用于辅助分析。自动校准会预热 Cache。本入口采用独立镜像名字与 PDS 目录，原内部 RAM 无 Cache 成绩继续作为历史基线；AXI off/on 才是同存储路径的 Cache 对照。

本轮按“暂时不验证”仅完成源代码，未生成新固件、位流或成绩。后续需要构建时，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_coremark_axi.bat --cache both --profile performance
cmd.exe //c build_coremark_axi.bat --cache both --profile validation
```

短仿真、四个正式版本的 PDS 命令、预期路径、统计有效性及结果记录方式见[AXI CoreMark 说明](docs/coremark_axi.md)。

## BTB 与动态分支预测

新增默认 64 项的直接映射 BTB，保存完整 PC 标签、跳转目标和条件分支的 2 位饱和方向计数器。条件分支和 JAL 可提前选择取指地址；JALR 保留 EX 阶段解析。预测信息随请求冻结并送入 EX，成功完成的指令才更新预测器；错误预测恢复正确下一 PC，异常、中断和 MRET 保持更高优先级。

`cpu_top` 与 `soc_axi_lite_top` 的 `ENABLE_BRANCH_PRED` 默认 0，`BTB_ENTRIES` 默认 64。原 CoreMark 入口保持预测器关闭；本轮没有生成带预测器的 CoreMark 成绩。独立 `btb_board` 使用内部 ROM／RAM，明确开启预测器并输出诊断计数，供后续功能验收。

后续需要构建时，在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_btb_board.bat
cmd.exe //c build_pds_board.bat --variant btb_board --firmware btb_board --stage bitstream
```

预期位流路径为 `build/pds_btb_board/generate_bitstream/board_top.sbit`。功能、关闭模式回归和 50 MHz 时序通过后再上板；预期串口 `BTB BOARD PASS`，LED2 常亮、LED1 心跳，KEY1 重启后再次自检。以上均为待验证行为，当前未生成本版镜像或位流。结构、统计口径和未来仿真步骤见[BTB 说明](docs/btb.md)。

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
| 两路指令 Cache | `run_icache.do`、`run_icache_board_netlist.do` |
| 两路数据 Cache／双 Cache | `run_dcache.do`、`run_dcache_fault.do`、`run_dcache_baseline.do`、`run_dcache_board_netlist.do` |
| CoreMark 短程和移植层 | `run_coremark_prepare.do`，先按[说明](docs/coremark.md)准备对应镜像 |
| AXI CoreMark 统计接口及 Cache off/on 四种短组合 | `run_coremark_axi.do`，先按[说明](docs/coremark_axi.md)准备镜像；新增入口尚未运行 |
| BTB 单元、取指预测元数据及 CPU 对照 | `run_btb.do`；新增入口尚未运行 |
| BTB 独立板级固件 | `run_btb_board.do`，先构建配套镜像；新增入口尚未运行 |

普通有限 C 仿真使用 `tohost` 结束协议；板级自检程序完成检查后持续维持 LED 心跳或回显，按 KEY1 重启。两类程序的结束方式不同，应使用配套顶层和测试平台。

## 后续开发与 CNN 协作

双 Cache CoreMark 对照和 BTB／动态分支预测入口已编写，验证待执行。恢复验证后先回归关闭预测器的原 CPU、握手、异常、中断和 Cache 功能，再执行 BTB 定向测试和独立板级验收。完成双 Cache 功能验收及 AXI CoreMark 对照测量后，再增加 Cache＋BTB 的独立 CoreMark 版本，并保留预测器关闭的对照结果。

CPU 已具备裸机 C、UART、GPIO、定时器和 AXI4-Lite 控制基础，可交给队友作为控制接口参考。真实 CNN 接入前还需约定寄存器地址、启动／完成／清除流程、结果格式、数据缓冲区、时钟与复位；若后续使用 DMA，还需明确数据 Cache 与加速器共享内存的一致性策略。

比赛要求的“两路指令与数据 Cache”“动态分支预测”“完整异常／中断”和 AI 加速，不能仅凭现有 CPU 自检 PASS 宣称全部完成。当前优先保留可复现的已验证基线，再逐项增加功能和验收证据。

## 文档索引

- [指令 Cache：结构、协议、统计与操作](docs/icache.md)
- [指令 Cache：RTL、PDS、网表和实物验证记录](docs/icache_verification_20261003.md)
- [数据 Cache：结构、写策略、MMIO 与上板步骤](docs/dcache.md)
- [双 Cache：RTL、PDS 与实物验收状态](docs/dcache_verification_20261007.md)
- [定时器中断板级自检与实物验证](docs/timer_irq_board.md)
- [CoreMark：配置、板级基线与验证](docs/coremark.md)
- [AXI CoreMark：Cache off/on、统计与后续构建步骤](docs/coremark_axi.md)
- [BTB：动态分支预测、误预测恢复与待验证入口](docs/btb.md)
- [开发阶段历史记录](docs/development_history.md)：保留整理前的详细 README；历史状态与性能数值按原文版本理解，当前状态以本页为准。
