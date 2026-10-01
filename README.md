# RV32I 三级流水线 CPU

这是一个使用 Verilog 实现的 RV32I 处理器软核，目前采用 **IF → EX → WB** 三级流水线，能够在 ModelSim 中加载外部 HEX 程序、运行裸机 RISC-V 汇编和 C 程序，并通过 `tohost` 协议自动报告运行结果。

当前版本已经完成37种 RV32I 指令、数据前递、分支与跳转冲刷、字及子字访存、同步指令/数据存储器、数据侧单笔请求/响应握手、RISC-V GCC 软件构建流程、性能计数器 MMIO、UART TX、带16字节接收FIFO的UART RX，以及8位 GPIO MMIO。数据握手版本已有RTL功能、PDS综合/布局布线、50 MHz最终STA及综合后功能网表验证；CoreMark单次功能校验保留为此前版本记录；开发板实物尚未验证。

项目的长期目标是作为紫光同创盘古 50 开发板上轻量化 CNN 推理系统的 RISC-V 主控。CPU 与平台部分负责处理器、外设和后续加速器接口，CNN 模型与部署由队友负责。后续仍需取指可变延迟、实际外部存储器及互联、异常/中断、Cache、BTB、CNN接口和板级实物验证。现阶段保持三级流水线，后续再评估五级升级；队友使用的参考 CPU 不替换本仓库的处理器。

## 队友快速上手：下载后先看这里

当前仓库包含 **CPU RTL、软件示例、仿真测试和最小板级工程生成脚本**。首次上板仅面向 MES50HP 的 PGL50H-6IFBG484，不包含 CNN、LCD、振动模块、外部存储器或 AXI；不能把别的开发板直接套用本仓库的引脚约束。仓库已包含预生成 HEX 程序镜像，第一次运行不需要先编译 C，也不需要复制原作者电脑上的 ModelSim 工程、工作库或波形。

### 1. 获取完整仓库

推荐使用 Git 克隆，便于后续同步更新。在 Git Bash 中执行：

```bash
mkdir -p /d/FPGA
cd /d/FPGA
git clone https://github.com/a-learner-1/riscv_3stage.git
cd riscv_3stage
git log -1 --oneline
```

上述命令用于第一次下载，目标目录应尚不存在。没有 D 盘时，换成自己的纯英文路径即可；后面的 ModelSim 路径也要对应修改。

也可以在 GitHub 使用 Code → Download ZIP，解压后将目录命名为 `riscv_3stage`。无论采用哪种方式，都应下载整个仓库，不能只下载 `cpu_top.v`，否则会缺少它依赖的 RTL 模块、测试平台和程序镜像。

### 2. 按需要安装工具

| 使用方式 | 所需工具 |
| --- | --- |
| 用 Git 下载和同步代码 | Git |
| 直接运行仓库已有程序的仿真 | ModelSim；不需要 GCC、Python 或 GNU Make |
| 修改 C/汇编并重新生成 HEX | RISC-V GCC 工具链、Python 3；运行验证时还需要 ModelSim |
| 使用 Makefile 构建 C 示例 | 在前述构建工具之外，还需要 GNU Make；不是首次仿真的必需工具 |
| 生成最小板级 FPGA 工程 | Python 3、PDS；已有 HEX 时不需要先安装 GCC |

当前已验证环境为 Windows、ModelSim SE-64 10.6e、RISC-V GCC 15.2.0 和 GNU binutils 2.45。其他工具版本和操作系统尚未完成同等验证；根目录的 `.bat` 构建脚本用于 Windows。

ModelSim 10.6e 对中文工程路径支持不稳定，请使用纯英文目录，例如 `D:\FPGA\riscv_3stage`。不需要另建或下载 `.mpf` 工程文件：根目录的 `.do` 脚本会编译所需模块并启动测试。

### 3. 首次只运行 UART 集成测试

在 ModelSim 的 Transcript 中执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart.do
```

预期输出：

```text
UART received: Hello RISC-V
UART: baud=115200 clocks_per_bit=868 bytes=13
PASS: CPU UART transmit test
```

这个测试运行仓库中的裸机 C 程序，经 CPU 和 MMIO 将字符送入 UART TX，再由独立的仿真接收器从串行线上解码。13字节包含12个可见字符和一个换行。

最后出现 `$stop` 和 `Break in Module` 表示测试平台主动结束，不是错误。波形中的 `received=13`、`uart_busy=0`、`uart_tx=1` 和 `tohost=1` 表示字符全部接收、发送器回到空闲、程序正常结束。

已有 HEX 镜像直接由仓库提供；首次测试不需要执行任何构建脚本，也不必把完整回归逐项重跑一遍。

### 4. 可选：检查 CPU 性能基线

UART 测试通过后，如需核对 CPU 运行和退休计数，再执行：

```tcl
do run_performance.do
```

仓库当前固定 C 镜像的预期结果：

```text
PERF: tohost=1
PERF: cycles=216
PERF: retired instructions=155
PERF: CPI=1.393
```

CoreMark 使用 `do run_coremark.do`，它是单次算法功能校验，不是正式有效跑分。首次上手不要求运行 CoreMark；有关 CRC、计时区间和十秒规则的说明见下文。

### 5. 修改 C 程序后重新构建

先将自己电脑上 RISC-V 工具链的 `bin` 目录加入 Windows 的 `PATH`，并确认以下命令可用：

```bash
riscv-none-elf-gcc --version
python --version
```

部分构建脚本保留了原作者电脑的 `D:\Tools\...` 工具链后备路径。该路径不是项目要求，也不需要在其他电脑上复刻；队友应优先配置自己的 `PATH`。ModelSim 的路径和许可证配置同样由各自电脑管理，不随仓库分发。

在工程根目录的 Git Bash 中，按修改的程序选择一条构建命令：

| 程序源码 | 构建命令 | 对应 ModelSim 测试 |
| --- | --- | --- |
| `software/uart_demo.c` | `cmd.exe //c build_uart.bat` | `do run_uart.do` |
| `software/gpio_test.c` | `cmd.exe //c build_gpio.bat` | `do run_gpio.do` |
| `software/main.c` | `cmd.exe //c build_program.bat` | `do run_c_program.do` |
| CoreMark 算法或裸机适配层 | `cmd.exe //c build_coremark.bat` | `do run_coremark.do` |
| `software/board_demo.c` | `cmd.exe //c build_board.bat` | `do run_board.do` |

Git Bash 中使用 `//c`，避免 MSYS 将 `/c` 转成路径。在 Windows CMD 中，直接执行相应 `.bat` 文件即可。

构建脚本会生成对应的指令 HEX 和数据 HEX，不会自动启动 ModelSim；编译成功后再运行对应测试。保持当前 `-march=rv32i`、`-mabi=ilp32` 等参数，不要改成包含乘除法或压缩指令的 ISA 配置；当前硬件没有这些扩展。

注意测试平台与程序之间的对应关系：

- UART 测试预期固定字符串 `Hello RISC-V\n`。如果改变输出内容，应同步调整 `tb/uart_cpu_tb.v` 的预期字节和长度。
- 性能测试检查当前 C 示例的155条退休指令。修改程序或更换编译配置后，动态指令数量可能变化；应先确认程序执行正确，再重新建立该程序的性能基线。
- 启动文件、链接脚本和数据镜像也属于程序运行依赖，不要只替换指令 HEX 而漏掉配套数据 HEX。

### 6. 后续同步更新

对于通过 Git 克隆且没有本地未提交修改的工程，在 Git Bash 中执行：

```bash
cd /d/FPGA/riscv_3stage
git status -sb
git pull --ff-only
```

如果已有自己的修改或提交，应先保存并处理分支差异，再同步团队代码；不要使用强制覆盖或删除工程的方式更新。通过 ZIP 下载的目录没有 Git 历史，需要重新下载新版本，或改用 Git 克隆。

### 7. 工程文件如何使用

| 位置 | 用途 |
| --- | --- |
| `rtl/` | CPU、存储器、UART 等硬件源码，是后续硬件集成的基础 |
| `tb/` | 仿真测试平台，用于验证，不作为 FPGA 电路参与综合 |
| `software/` | 裸机 C/汇编、启动文件、链接脚本与 MMIO 辅助函数 |
| `programs/` | 与测试配套的预生成指令/数据 HEX，便于下载后直接验证 |
| `benchmarks/coremark/` | CoreMark 原始算法源码、许可证和来源记录 |
| `tools/` | 二进制转 HEX 等辅助工具 |
| `pds/board_top.fdc` | MES50HP 的 50 MHz 时钟、UART、LED 和按键约束 |
| 根目录 `run_*.do` / `build_*.bat` | 仿真和软件构建入口；目前保持在根目录，避免破坏已有使用方式 |

需要保留并提交源码、测试平台、构建脚本、配套 HEX 和许可证。不需要提交 `build/`、`work/`、`uart_work/`、`uart_unit_work/`、`gpio_work/`、`gpio_unit_work/`、`modelsim.ini`、`transcript`、`*.wlf` 或本机 `.mpf` 工程；这些文件由工具在各自电脑上生成，已由 `.gitignore` 排除。

## CPU 与 CNN 协作边界

CPU 与平台部分负责处理器、存储器、外设和后续加速器接入；CNN 模型与部署由队友负责。双方可以分别开发与验证自己的模块，但当前仓库尚未实现 AXI 总线和 CNN 加速器控制/数据接口，不能把现有 UART TX 或计数器 MMIO 当作已完成的 CNN 接口。

当前 C 示例与 CoreMark 配置使用32 KiB指令区、16 KiB数据区。它们是现阶段的软件运行资源，不代表完整 CNN 权重、音频特征和中间结果都能容纳，也不代表后续最终系统的存储容量。

**CPU 与 CNN 的详细联调约定后续再写，依据实际搭建的 CPU 与系统接口确定，并由双方确认。** 本阶段不预先指定加速器寄存器地址、AXI 类型、数据缓冲区地址或中断号，也不发布一份可能与后续实现不一致的固定接口协议。

待 CPU 总线和加速器接入方式确定后，再文档化实际的控制/状态寄存器、输入输出数据格式、数据传输路径、握手时序、时钟复位和联调测试。后续文档应与 RTL、C 驱动和测试平台一起维护，并明确哪些能力已验证、哪些仍待实现。

## 当前状态

更新时间：2026-10-01。

| 项目 | 状态 |
| --- | --- |
| RV32I 常用整数指令 | 已完成37种 |
| IF/EX/WB 三级流水线 | 已完成 |
| WB → EX 数据前递 | 已完成 |
| 六种条件分支 | 已完成 |
| JAL/JALR | 已完成 |
| 分支与跳转冲刷 | 已完成 |
| LB/LBU/LH/LHU/LW | 已完成 |
| SB/SH/SW | 已完成 |
| 外部 HEX 程序加载 | 已完成 |
| RISC-V GCC 裸机 C 程序 | 已完成 |
| `tohost` 结束协议 | 已完成 |
| 周期、退休指令和 CPI 统计 | 已完成 |
| 指令/数据存储器参数化与扩容 | 已完成 |
| 独立指令/数据 HEX 镜像 | 已完成 |
| `.data`/`.rodata` 预初始化 | 已完成 |
| 同步指令/数据 RAM 与 load-use stall | RTL/仿真已完成；板级演示数据 RAM 映射为8个 DRM18K，小指令镜像被优化为 LUT ROM |
| 数据侧请求/响应握手 | 单笔在途、请求背压、响应等待、外部RAM端口及错误停机；可变延迟/复位/MMIO唯一性测试通过 |
| 性能计数器 MMIO | 已完成 |
| CoreMark v1.01 | 单次算法/CRC 校验已通过；不是正式跑分 |
| UART TX | 已完成 RTL 与串行线仿真验证 |
| 8位 GPIO MMIO | 输出、输入同步、输出使能及 SET/CLEAR/TOGGLE；模块和 CPU/C 仿真已通过 |
| UART RX＋16字节FIFO | 模块/MMIO、CPU软件回显、50 MHz板级RTL及硬件镜像综合网表通过；无RX中断 |
| Cache、BTB、AXI | 尚未完成 |
| MES50HP 最小板级顶层 | UART TX、LED、按键及上电/KEY1 复位仿真通过 |
| PDS 综合、布局布线与 50 MHz 时序 | PDS 2022.2-SP6.4 验证通过，存在复用引脚等告警，见板级章节 |
| 盘古 50 实物验证 | 尚未完成；工具通过不等于实物通过 |

## CPU 架构

```text
外部 HEX
   │
   ▼
指令存储器 → IF → EX → WB → 寄存器堆
                  │      ▲
                  │      │
                  ├──────┘ WB→EX 前递
                  │
                  └→ 数据存储器 / tohost
```

主要参数：

| 参数 | 当前配置 |
| --- | --- |
| ISA | RV32I 子集，共37种指令 |
| 数据宽度 | 32位 |
| 流水级 | IF、EX、WB |
| 指令存储器 | 32 KiB，8192×32位，可参数化 |
| 数据存储器 | 16 KiB，4096×32位，可参数化基址 |
| 字节序 | 小端 |
| 通用寄存器 | `x0`–`x31`，其中 `x0` 固定为0 |
| 分支解析 | EX级 |
| 当前存储器模型 | 同步读取；数据 RAM 同步写入 |

### 流水线控制

- 使用 `valid_x` 区分有效指令和流水线气泡。
- ALU、分支、跳转、加载和存储均可使用 WB → EX 前递结果。
- 立即数指令不会把立即数字段误判为 `rs2` 数据相关。
- 分支或跳转在 EX 级确定目标地址，错误路径指令会被冲刷。
- `JALR` 目标地址最低位强制清零。
- 写入 `x0` 的操作被抑制。
- 数据侧使用单笔请求/响应握手，LOAD和STORE均等待完成；等待期间IF/EX停顿。LOAD响应写回后进入WB前递路径，MMIO副作用仅在请求接受时执行一次。

## 已实现指令

| 类别 | 指令 |
| --- | --- |
| 加减 | `ADDI`、`ADD`、`SUB` |
| 逻辑 | `AND`、`OR`、`XOR`、`ANDI`、`ORI`、`XORI` |
| 移位 | `SLL`、`SRL`、`SRA`、`SLLI`、`SRLI`、`SRAI` |
| 比较 | `SLT`、`SLTU`、`SLTI`、`SLTIU` |
| U型 | `LUI`、`AUIPC` |
| 条件分支 | `BEQ`、`BNE`、`BLT`、`BGE`、`BLTU`、`BGEU` |
| 跳转 | `JAL`、`JALR` |
| 加载 | `LB`、`LBU`、`LH`、`LHU`、`LW` |
| 存储 | `SB`、`SH`、`SW` |

当前不支持 `FENCE`、`ECALL`、`EBREAK`、CSR、异常、中断、乘除法扩展和压缩指令。

## 性能计数器

`cpu_top` 提供三个性能观测端口：

| 信号 | 宽度 | 含义 |
| --- | --- | --- |
| `cycle_count` | 64位 | 从第一条受支持的有效指令进入 EX 后开始累计周期 |
| `instret_count` | 64位 | 已退休的有效指令数量 |
| `retire_valid` | 1位 | 当前 WB/退休点存在一条有效指令 |

退休计数规则：

- 算术、加载、分支、跳转和存储都属于退休指令。
- 分支和存储即使不写通用寄存器，也必须计入 `instret_count`。
- 复位气泡、分支冲刷产生的错误路径指令、越界取指和不支持的指令不计入。
- 性能测试在写入 `tohost` 的存储指令退休后停止。

CPI 由测试平台计算：

```text
CPI = cycle_count / instret_count
```

当前固定的 `c_demo.hex` 与 `c_demo_data.hex` 测试结果：

```text
PASS: performance counters and C program completed
PERF: tohost=1
PERF: cycles=216
PERF: retired instructions=155
PERF: CPI=1.393
```

`performance_tb.v` 会检查精确的155条退休指令，用于发现错误计入气泡或错误路径指令的问题。如果修改并重新编译 `software/main.c`，动态指令数量可能变化，此时需要同步调整测试平台中的 `EXPECTED_INSTRET`。

## 工程目录

```text
rtl/
  instr_mem.v           外部 HEX 指令存储器
  if_stage.v            PC、取指、IF/EX寄存器和重定向冲刷
  decoder.v             指令译码和立即数生成
  regfile.v             两读一写寄存器堆
  alu.v                 算术、逻辑、移位和比较
  data_mem.v            参数化小端数据 RAM、基址和初始化镜像
  cpu_top.v             顶层数据通路、前递、访存和性能计数
  uart_tx.v             UART 8N1 发送器、波特率分频和 busy/done
  uart_rx.v             两级同步、中心采样、假起始过滤和帧错误检测
  uart_rx_fifo.v        可参数化接收队列，默认16字节
  uart_rx_mmio.v        接收数据、状态、占用数及W1C错误寄存器
  gpio_mmio.v           8位 GPIO 寄存器、输入同步及输出使能
  board_reset.v         KEY1 异步置复位、同步延迟释放及上电初值
  board_top.v           MES50HP 50 MHz 板级封装，不改变三级 CPU

tb/
  cpu_top_tb.v          ALU、比较及U型指令集成回归
  branch_tb.v           BEQ/BNE测试
  compare_branch_tb.v   BLT/BGE/BLTU/BGEU测试
  jump_tb.v             JAL/JALR测试
  load_store_tb.v       LW/SW测试
  subword_mem_tb.v      子字加载和存储测试
  program_load_tb.v     外部HEX程序测试
  toolchain_program_tb.v 预生成独立程序测试
  c_program_tb.v        GCC生成的C程序测试
  performance_tb.v      周期、退休指令和CPI测试
  mmio_tb.v             性能计数器 MMIO 和字符写入测试
  coremark_tb.v         CoreMark 单次功能校验
  uart_tx_tb.v          UART 位时序、字节模式、忙状态及复位测试
  uart_cpu_tb.v         C 程序经 CPU/MMIO/TX 串行线的端到端测试
  gpio_unit_tb.v        GPIO 寄存器译码、同步延迟及复位测试
  gpio_cpu_tb.v         C 程序经 CPU/MMIO 访问 GPIO 的集成测试
  board_top_tb.v        50 MHz UART、LED 闪烁、按键和复位重启测试
  board_netlist_tb.v    可选：TX/GPIO演示的综合后功能网表检查
  uart_rx*_tb.v         RX/FIFO/MMIO、CPU回显、板级回显及综合网表测试

software/
  start.S               初始化栈、清零.bss、调用main并写tohost
  main.c                裸机C测试程序
  link.ld               链接脚本和内存布局
  prebuilt_demo.S       预生成程序的汇编源文件
  mmio.h                计数器读取、UART 忙状态轮询和字符输出
  uart_demo.c           发送 Hello RISC-V 并等待最后一帧结束
  uart_rx.h             接收数据、状态、队列占用及清错辅助函数
  uart_rx_echo.c        轮询回显：硬件无限模式、仿真有限32字节模式
  gpio.h                GPIO MMIO 地址及读写辅助函数
  gpio_test.c           有限 GPIO 功能自测，不是板级 LED 闪烁程序
  board_demo.c          持续运行的 UART 启动消息、LED 心跳及按键程序
  coremark_port/        RV32I 裸机计时、格式化输出和结束适配层

benchmarks/coremark/    CoreMark v1.01 原始算法源码与许可证

programs/
  rv32i_regression.hex  指令回归程序
  program_load_test.hex 外部程序加载测试
  toolchain_demo.hex    无需GCC即可运行的预生成程序
  c_demo.hex            由当前C程序生成的指令镜像
  c_demo_data.hex       由当前C程序生成的数据初始化镜像
  data_mem_init_test.hex 数据RAM初始化回归镜像
  uart_demo.hex         UART C 程序指令镜像
  uart_demo_data.hex    UART 字符串初始化镜像
  gpio_test.hex         GPIO C 自测指令镜像
  gpio_test_data.hex    GPIO C 自测初始化数据镜像
  coremark.hex          已接入 UART 忙状态轮询的 CoreMark 指令镜像
  coremark_data.hex     CoreMark 初始化数据镜像
  board_demo.hex        满深度8192字的板级指令镜像，余下填充 NOP
  board_demo_data.hex   满深度4096字的板级数据镜像，0.5秒闪烁间隔
  board_demo_sim_data.hex 同一程序的加速仿真数据镜像，仅缩短闪烁间隔
  uart_rx_echo*.hex     独立的无限回显与有限32字节测试的指令/数据镜像

tools/
  bin_to_hex.py         BIN转32位小端HEX
  build_board_images.py 构建配套板级/仿真镜像并检查指令镜像相同
  build_pds_board.py    按固件生成独立PDS工程，核对路由/最终STA后生成候选位流
  build_uart_rx_images.py 构建RX回显的硬件和有限测试镜像

pds/
  board_top.fdc         PGL50H-6FBG484 的 MES50HP 引脚及时序约束
```

根目录中的 `run_*.do` 是各组 ModelSim 一键测试脚本。

## 环境要求

- 当前验证平台为 Windows，仿真使用 ModelSim SE-64 10.6e。
- 直接使用仓库已有 HEX 运行仿真时，不需要 Python 或 RISC-V GCC。
- 修改软件并重新生成 HEX 时，需要 Python 3 和 xPack GNU RISC-V Embedded GCC，命令前缀为 `riscv-none-elf-`。
- 构建时先配置自己电脑的工具链 `PATH`，不要把文档中的示例路径当作固定安装要求。

已验证的工具链版本：

```text
riscv-none-elf-gcc 15.2.0
GNU binutils 2.45
```

构建参数固定为：

```text
-march=rv32i
-mabi=ilp32
-mno-relax
-msmall-data-limit=0
-nostdlib
-nostartfiles
```

这些参数避免生成乘除法、压缩指令、操作系统调用以及依赖未初始化 `gp` 的小数据区访问。

## 快速运行性能测试

ModelSim 10.6e 对中文工程路径支持不稳定，请将工程放在纯英文路径，例如：

```text
D:\FPGA\riscv_3stage
```

在 ModelSim Transcript 中运行：

```tcl
quit -sim
cd D:/FPGA/riscv_3stage
do run_performance.do
```

测试成功时应看到：

```text
Errors: 0, Warnings: 0
PASS: performance counters and C program completed
PERF: tohost=1
PERF: cycles=216
PERF: retired instructions=155
PERF: CPI=1.393
```

最后出现的 `$stop` 和 `Break in Module performance_tb` 表示测试平台主动停止，不是错误。

## 构建并运行 C 程序

### Windows CMD

先将自己安装的 RISC-V 工具链 `bin` 目录加入 `PATH`，然后从工程根目录执行：

```bat
cd /d D:\FPGA\riscv_3stage
build_program.bat
```

### Git Bash

如果已经安装 GNU Make，并且工具链位于 `PATH`：

```bash
cd /d/FPGA/riscv_3stage
make CROSS=riscv-none-elf-
```

生成文件：

```text
build/c_demo.elf     带符号的可执行文件
build/c_demo_text.bin       指令段小端二进制
build/c_demo_data.bin       初始化数据段小端二进制
build/c_demo.dump           反汇编文件
build/c_demo.map            链接内存映射
programs/c_demo.hex         ModelSim指令镜像
programs/c_demo_data.hex    ModelSim数据初始化镜像
```

随后在 ModelSim 中运行：

```tcl
do run_c_program.do
do run_performance.do
```

## tohost 程序结束协议

GCC C 程序配置的数据 RAM 最后一个字被保留为 `tohost`：

```text
数据RAM基址：0x00010000
字节地址：0x00013FFC
RAM字下标：4095
测试平台路径：dut.u_data_mem.mem[4095]
```

| 写入值 | 含义 |
| --- | --- |
| `1` | 程序成功 |
| `2`、`3`、`4`…… | 程序失败码 |

CPU程序把结果写入 `tohost` 后，测试平台会判断成功或失败并自动停止。该协议后续可以继续用于 CoreMark 和其他裸机基准程序。

旧的预生成汇编回归仍使用低地址兼容配置，其 `tohost` 保持在 `0x000003FC`（字下标255），因此旧测试无需重写。

## UART TX：发送接口

TX保持单帧发送、软件轮询，没有发送FIFO。新增接收器和RX FIFO见后面的接收章节；串口接收中断尚未实现。发送格式为 8N1：一个低电平起始位、八个数据位、一个高电平停止位，低位先发送，空闲电平为高。

| MMIO 地址 | 访问 | 含义 |
| --- | --- | --- |
| `0x20000000` | 对齐 LW 读取 | 周期计数器低32位 |
| `0x20000004` | 对齐 LW 读取 | 退休指令计数器低32位 |
| `0x20000010` | SB/SH/SW 写入 | 低8位作为一个发送字符 |
| `0x20000014` | 对齐 LW 读取 | bit0=1 表示 UART 正在发送，0 表示可以写下一字符 |

软件必须先轮询 busy，再写字符。硬件没有发送 FIFO：忙时写入会被忽略；仿真会报错提醒错误用法。`software/mmio.h` 中的 `mmio_putchar()` 已封装轮询，`mmio_uart_flush()` 等待最后一个停止位发完，程序结束前应调用。

`cpu_top` 新增 `uart_tx` 输出端口，以及 `UART_CLOCK_HZ`、`UART_BAUD` 参数，默认分别为100 MHz、115200。分频按最接近的整数取值，这组参数对应每位868个时钟。这里100 MHz是本次仿真的时钟，不是已确认的开发板输入频率；上板时必须按实际 CPU 时钟修改，并添加引脚约束。

### 直接运行一次集成测试

仓库已经包含 HEX 镜像，第一次验证不需要重新编译 C。将完整仓库下载到英文工程目录后，在 ModelSim Transcript 中执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart.do
```

脚本会编译新增 UART 模块，启动 C 程序并自动检查 TX 串行线。预期输出：

```text
UART received: Hello RISC-V
UART: baud=115200 clocks_per_bit=868 bytes=13
PASS: CPU UART transmit test
```

这个测试从 TX 引脚的实际位流采样解码，不依赖 CPU 中的 `$write` 调试打印。测试同时检查 busy/idle 读取、字符顺序、停止位、MMIO 不访问普通 RAM、`tohost=1` 和最后一帧发送完成。

可选的独立模块测试为 `do run_uart_unit.do`。本次交付前两项 UART 测试和旧 CPU 回归均已在 ModelSim SE-64 10.6e 中验证；日常验证不必每次重复全套测试。

### 修改 C 程序后重新构建

在 Git Bash 中执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_uart.bat
```

在 Windows CMD 中则直接执行 `build_uart.bat`。Git Bash 中使用 `//c` 是为了避免 MSYS 把 `/c` 转成路径。编译脚本优先使用 PATH 中的 RISC-V GCC，否则尝试本机已安装的 xPack 路径；其他电脑请调整 `UART_CROSS`。

本次还更新了所有使用 CPU 的仿真脚本，加入 `rtl/uart_tx.v` 编译依赖，以及旧测试平台的新增端口连接。不能只替换 `cpu_top.v` 而漏掉 UART 模块和脚本。

## CoreMark 功能校验说明

本节数据来自数据握手改动前的版本（`621d935`及其历史）。本次没有重复运行CoreMark算法；新增STORE响应等待改变周期数，以下性能值不代表当前握手版本。

原始 CoreMark 算法源码与许可证保存在 `benchmarks/coremark/`，本次未修改算法源码。适配层改用 UART 忙状态轮询，并在写入 `tohost` 前等待最后一个字符发完。仓库的 CoreMark HEX 已按新适配层重新构建，旧的不轮询镜像不能继续用于新 UART。

`run_coremark.do` 配套的测试平台使用100 MHz时钟、5 Mbaud的加速仿真 UART，缩短打印等待时间；UART 集成测试仍按115200 baud执行。加速仿真波特率不代表上板配置。

本次单次测试的算法计时为936687周期，CRC分别为：

```text
seedcrc    = 0xe9f5
crclist    = 0xe714
crcmatrix  = 0x1fd7
crcstate   = 0x8e3a
crcfinal   = 0xe714
PASS: CoreMark official algorithms validated
```

从启动到打印结束的整程序统计为1081207周期、826143条退休指令、CPI 1.308；它包含 UART 轮询和格式化输出，不能与仅算法计时混用，也不能作为正式 CoreMark 分数。`ITERATIONS=1` 是功能冒烟测试，未满足官方至少10秒的计时要求，因此原始输出仍会提示十秒规则不满足。正式分数与上板频率、迭代次数、编译参数及完整运行规则需要后续单独验证。

## 当前存储器布局

| 地址范围 | 用途 |
| --- | --- |
| `0x00000000–0x00007FFF` | 指令 RAM中的 `.text`，32 KiB |
| `0x00010000–0x00013FDF` | 数据 RAM中的 `.rodata`、`.data`、`.bss` 和运行时数据 |
| `0x00013FE0` | 初始栈顶，栈向低地址增长 |
| `0x00013FFC` | `tohost` |

程序构建时会把 ELF 分成独立的指令 HEX 和数据 HEX。数据 RAM 启动时先清零，再用 `c_demo_data.hex` 覆盖初始化数据，因此普通 C 全局初始化变量和只读数据不再依赖未实现的数据复制流程。

## 完整回归测试

可以在 ModelSim Transcript 中分别运行：

```tcl
do run_cpu.do
do run_branch.do
do run_compare_branch.do
do run_jump.do
do run_load_store.do
do run_memory_expansion.do
do run_subword_mem.do
do run_program.do
do run_toolchain.do
do run_c_program.do
do run_performance.do
do run_mmio.do
do run_uart_unit.do
do run_uart.do
do run_coremark.do
```

以下是此前阶段在 ModelSim SE-64 10.6e 中通过的回归记录。RX增量只重测受MMIO/顶层改动影响的TX、GPIO、MMIO和板级演示；其它算法未重复运行，见接收章节：

- 77条基础 CPU 集成测试通过。
- 六种条件分支以及有符号、无符号比较通过。
- JAL/JALR链接地址、前递、最低位清零和冲刷通过。
- LW/SW及load-use、存储地址/数据前递通过。
- LB/LBU/LH/LHU/SB/SH符号扩展、小端字节通道和边界测试通过。
- 非零数据 RAM 基址、参数化容量和外部数据 HEX 初始化通过。
- 外部HEX、预生成程序和GCC C程序通过。
- 性能测试结果为192周期、155条退休指令、CPI 1.238。
- UART 位时序、模式字节、复位和 CPU C 程序串行输出通过。
- CoreMark 单次算法 CRC 校验通过；尚无正式有效分数。

## 波形观察

`run_performance.do` 已加入以下关键信号：

```text
clk、rst_n、pc_x、instr_x、valid_x
wb_pc、retire_valid、cycle_count、instret_count
mem_addr_x、mem_wdata_x、mem_we_x、mem[4095]
```

查看程序结束过程时，可以在 Transcript 输入：

```tcl
wave zoom range 1850ns 2000ns
```

最后一次有效存储应满足：

```text
mem_we_x    = 1
mem_addr_x  = 0x00013FFC
mem_wdata_x = 0x00000001
mem[4095]   = 1
```

## GPIO MMIO：三级 CPU 的本次增量

本次保持 IF → EX → WB 架构、原 UART 地址和计数器地址不变。新增独立外设 `rtl/gpio_mmio.v`；GPIO 读取沿用已有的一拍 load-pending 路径，GPIO 存储在有效 EX 存储事务上接受，不访问普通数据 RAM。

| 地址 | 权限 | 低8位含义 |
| --- | --- | --- |
| `0x20000020` | LW/SW | 输出锁存值 OUT |
| `0x20000024` | LW | 两级同步后的外部输入 IN |
| `0x20000028` | LW/SW | 输出使能 OE，1=允许对应引脚输出 |
| `0x2000002C` | SW | SET，掩码为1的输出位置1 |
| `0x20000030` | SW | CLEAR，掩码为1的输出位清0 |
| `0x20000034` | SW | TOGGLE，掩码为1的输出位翻转 |

GPIO 仅接受对齐的32位 LW/SW，高24位写入忽略、读取为0。SET/CLEAR/TOGGLE 为只写，不支持读取；IN 为只读。非法访问沿用当前 CPU 的仿真 `$fatal` 检查，并不代表硬件已实现访问异常处理。

CPU 新增 `gpio_in[7:0]`、`gpio_out[7:0]`、`gpio_oe[7:0]` 端口。复位后 OUT=0、OE=0；OUT 锁存器可以在 OE=0 时写入，IN 始终采样外部输入。OE 只是单独输出的掩码，尚不是实际 FPGA 引脚方向控制：板级顶层需要实现 I/O 三态或使用掩码门控专用 LED 引脚。不要将裸电机等负载直接接 GPIO。

输入采用两级同步，适用于低速独立输入，没有按键消抖功能，也不能作为高速多位数据总线的完整跨时钟处理。自定义旧测试平台可连接 `.gpio_in(8'd0), .gpio_out(), .gpio_oe()`；所有实例化 CPU 的编译脚本必须加入 `rtl/gpio_mmio.v`。包内已同步更新原脚本和原测试平台。

在仓库根目录的 ModelSim Transcript 中首次只运行一次：

```tcl
do run_gpio.do
```

已包含预生成 HEX，不需要先编译 C。预期输出：

```text
GPIO: tohost=1 writes=14 reads=17 input=A5->3C
GPIO: output=AA direction=00 before reset; reset output=00 direction=00
PASS: CPU GPIO C program, readback, SET/CLEAR/TOGGLE, squash and RAM isolation
```

测试平台会模拟输入从 A5 变为 3C，检查输出回读、OE、SET/CLEAR/TOGGLE、高位掩码、错误路径存储冲刷、x0 读取、普通 RAM 隔离和复位清零。最终 `$stop` 和 `Break` 是正常结束；结束时测试平台重新拉低复位，所以波形末尾 OUT/OE 为0，复位前最后一个输出锁存值是 AA。

可选模块测试为 `do run_gpio_unit.do`，不要求首次重复运行。修改 C 后，在 Git Bash 中用 `cmd.exe //c build_gpio.bat` 重新生成两份 HEX。构建优先使用 PATH 中的 RISC-V GCC，也可通过 `GPIO_CROSS` 指定工具链前缀。保留 `-march=rv32i -mabi=ilp32`。

2026-10-01 验证：GPIO 模块、GPIO CPU/C、原性能、UART CPU、CPU 指令集、分支、比较分支、跳转、LW/SW、子字访存、MMIO 和独立程序共12项测试通过；所有现有测试平台编译为0错误、0警告。固定 C 基线仍为192周期、155条退休指令、CPI 1.238。CoreMark 本次仅编译测试平台，没有重跑算法；GPIO 实物接线及 PDS 上板尚未验证。

## 数据侧请求与响应握手

本增量从已提交的UART RX版本 `621d935` 开始，仍为 IF → EX → WB，取指仍使用同步指令存储器。数据侧一次最多有一笔在途事务，LOAD和STORE都在完成响应后退休。首次遇到访存指令时锁存地址、字节使能、写入数据及写回信息；请求等待与响应等待期间保持这些信息稳定。

默认继续使用内部RAM和既有MMIO。`data_bus_adapter.v` 接受请求后产生响应；参数 `DMEM_REQ_WAIT_CYCLES` / `DMEM_RSP_WAIT_CYCLES` 分别增加请求接受前与响应可用前的等待周期，默认均为0。默认情况下，请求在一个上升沿接受，响应在接下来一个周期可用，并在下一个上升沿完成。STORE比此前直接在EX完成的版本增加等待周期，旧版CPI不可直接作为当前版本的成绩。

### 外部RAM接口

`cpu_top` 设置 `EXTERNAL_DMEM=1` 时，非MMIO的数据请求交给以下端口；地址位于 `0x2000xxxx` 的MMIO仍由本地外设处理。该接口是单笔事务的项目内部接口，尚未实现AXI或外部DDR控制器。

| 端口 | CPU方向 | 含义 |
| --- | --- | --- |
| `dmem_req_valid` / `dmem_req_ready` | 输出 / 输入 | 两者同时为1的上升沿接受一次请求 |
| `dmem_req_write` | 输出 | 1为写，0为读 |
| `dmem_req_addr[31:0]` | 输出 | 字节地址 |
| `dmem_req_size[1:0]` | 输出 | 0/1/2分别为字节、半字、字 |
| `dmem_req_wdata[31:0]` / `dmem_req_wstrb[3:0]` | 输出 | 数据已移至对应字节通道；使能位选择实际写入通道 |
| `dmem_rsp_valid` / `dmem_rsp_ready` | 输入 / 输出 | 两者同时为1的上升沿完成请求 |
| `dmem_rsp_rdata[31:0]` | 输入 | 返回包含目标字节的整个32位字；CPU按地址取位并扩展 |
| `dmem_rsp_error` | 输入 | 本次事务出错；与响应同时有效 |
| `dmem_fault` | 输出 | 错误响应锁存后置1，CPU停止推进直到复位 |

请求被接受前必须保持valid及描述符；响应被消费前必须保持valid、数据及error。写请求也需要完成响应。外部设备可以在接受请求后立即准备响应，但CPU从下一周期开始接收它；设备必须保持到握手完成。外部RAM的合法地址范围由响应设备决定，不沿用内部RAM的容量检查。

CPU与响应设备必须使用同一复位，并同时丢弃旧在途事务；接口没有事务ID，不能隔离一个不参与复位的设备在重启后送来的陈旧响应。复位不会清空RAM，也不会撤销已经接受的写操作或MMIO副作用。`dmem_fault` 是停止机制，不是RISC-V异常入口、CSR或可恢复总线异常实现。

### 外设副作用与调试

RAM写、GPIO写、UART发送、RX状态W1C和RX FIFO弹出均由一次 `mem_req_fire` 接受事件触发。MMIO读取在接受沿保存快照，RX保存弹出前的队首；多拍等待期间不会重复弹出。`mem_rsp_fire` 为完成响应事件，LOAD仅此时写回，LOAD/STORE仅此时退休。

波形中优先观察 `mem_active`、`req_sent`、`mem_req_valid`、`mem_req_ready`、`mem_req_fire`、`mem_rsp_valid`、`mem_rsp_ready`、`mem_rsp_fire`、`stall_x` 和 `dmem_fault`。历史监视名 `load_issue_x` 现在表示已接受的LOAD请求，`load_pending` 表示已接受且尚未完成的LOAD。

新测试入口（ModelSim Transcript）：

```tcl
cd D:/FPGA/riscv_3stage
do run_data_handshake.do
```

本次修改CPU控制及退休逻辑，因此需运行新握手测试和受影响的CPU/访存/MMIO/外设检查；RX/FIFO等未修改模块的已通过单测不重复运行。历史CoreMark算法不作为本次增量回归；其数据只能引用为旧版本记录。

新的板级构建使用独立目录，避免覆盖已保存的验收版本：

```bash
cmd.exe //c build_pds_board.bat --firmware uart_rx_echo --variant data_handshake --stage bitstream
```

输出位于 `build/pds_data_handshake/`。综合后功能检查入口为 `do run_data_handshake_netlist.do`。板级仍为50 MHz、115200、8N1，默认等待参数为0；外部RAM端口在此最小板级工程中未接入。新版本需要自己的PDS报告和实物验收证据，不能沿用下节RX版本的资源及STA数值。

### 本次验证记录（2026-10-02）

新增适配器单测检查响应背压下的MMIO快照与错误保持，以及请求未接受、已接受待响应、响应有效未消费时的复位。CPU握手测试包括零额外等待、固定等待和确定种子随机等待三种外部RAM场景，每种15次请求/响应、26次唯一退休；并检查字节通道、扩展、前递、LW x0、分支/JAL冲刷、描述符稳定及外部地址范围独立性。另检查本地MMIO请求等待3拍、响应等待7拍时GPIO TOGGLE、TX帧、RX弹出及W1C唯一性；外部LOAD/STORE错误不写回、不退休，复位后恢复。

13项受影响的集成检查通过：基础CPU、分支、跳转、LW/SW、子字访存、MMIO、GPIO、UART TX、UART RX回显、C程序、退休计数、原板级演示和RX板级回显。新增两个测试入口及这13项均通过；旧RX/FIFO/MMIO模块单测和CoreMark算法未重跑。当前固定C示例为216周期、155条退休指令、CPI 1.393，较旧版本的192周期增加24个周期；这仅是同一小程序的控制逻辑基线，不是CNN性能或正式CoreMark分数。

| 握手版本板级检查 | 结果 |
| --- | --- |
| PDS目标与固件 | PGL50H / -6 / FBG484，50 MHz；无限UART回显 |
| 布局布线使用资源 | 1537 LUT、509 FF、8 DRM18K、72分布式RAM、19 IO |
| 最终Slow setup/hold | +5.050 ns / +0.169 ns，0失败端点 |
| 最终Fast setup/hold | +9.427 ns / +0.117 ns，0失败端点 |
| 最终recovery/removal/pulse width | 两个corner全部通过 |
| 综合后功能网表 | 实际硬件镜像8字节回显及KEY1重启通过；无SDF |
| 位流 | `build/pds_data_handshake/generate_bitstream/board_top.sbit`；实物尚未验收 |

资源取布局布线实际使用汇总；同一报告的模块归属汇总为1535 LUT。最终STA取独立 `report_timing/board_top.rtr`，不混用路由器摘要。配置复用引脚及通用 `ASYNC_REG` 属性相关告警仍存在，外部异步IO路径的限制与RX版本相同；工具检查不代替实物验证。已提交的RX版本 `621d935` 和首次板级基线 `6f97477` 可单独恢复；本次未执行下载、Flash烧写或远程平台操作。

## UART RX、FIFO与CPU软件回显

此增量以 `6f97477` 为基线，保留三级流水线、TX地址及旧程序镜像。新增接收模块接入CPU的MMIO，电脑发送的字节经FIFO暂存，CPU执行C程序读取并交给原TX发送器。UART用于命令和调试，不替代音频I2S采集或CNN接口。

### 接收寄存器与副作用

| 地址 | 访问 | 行为 |
| --- | --- | --- |
| `0x20000018` RX_DATA | 对齐LW | 返回队首低8位并弹出一次；空队列返回0且不弹出 |
| `0x2000001C` RX_STATUS | 对齐LW | bit0非空、bit1满、bit2溢出、bit3帧错、bits15:8占用数 |
| `0x2000001C` RX_STATUS | 对齐SW | 写bit2/3为1清除对应粘滞错误，其余位忽略；新错误优先 |

两个错误标志保持到软件W1C或复位；清错不清队列。队列满时丢弃新字节并报溢出；若同一时钟沿有效弹出旧队首，则新字节可以入队。空队列同时读和新数据入队时，读返回0，新字节保留供下一次读取。合法字节0x00与空读均返回0，软件必须先检查非空位。

RX_DATA读取沿用 `load_issue_x` 的MMIO快照：发起沿保存弹出前的数据，后续 `load_pending` 停顿沿不再弹出。非法子字/错位访问沿用CPU的仿真检查；硬件访问异常仍未实现。

`uart_rx.v` 使用两级同步、8N1中心单点采样、假起始过滤和停止位检查；坏停止位不入队，持续低电平break只报一次帧错并等待高电平再接收。时钟/波特率参数至少要求4时钟/位，队列支持非二次幂深度，CPU默认16字节，MMIO占用字段允许深度1至255。无16倍过采样、自适应波特率、接收中断或硬件流控。TX也仍无FIFO，连续长突发可能超过回显处理速度，应检查溢出位。

### 软件与入口

`software/uart_rx.h` 包含状态、接收和清错函数；主程序的硬件模式为：

```c
#include "uart_rx.h"
int main(void)
{
    for (;;)
        mmio_putchar((char)uart_rx_getchar());
}
```

`build_uart_rx.bat` 生成独立的 `uart_rx_echo.hex` / `_data.hex`（无限回显）和 `uart_rx_echo_test.hex` / `_data.hex`（32字节后写tohost）。指令镜像满深度8192字，数据镜像4096字；硬件代码136字节，有限测试188字节，均没有初始化数据负载，数据镜像填0。旧 `board_demo`、TX、GPIO和CoreMark镜像没有重建或覆盖。

需要修改C并重建时，在Git Bash运行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_uart_rx.bat
```

工具链支持 `UART_RX_CROSS` 或 `BOARD_CROSS`，保持 `-march=rv32i -mabi=ilp32`。已有随源码提供的HEX时无需先安装GCC。

本次下面的测试均已运行通过，代码不变时无需再跑。修改相关逻辑后的ModelSim入口为：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart_rx.do
```

该入口检查32字节真实串行输入/输出，包含00/FF/55/AA/CR/LF、复位期间输入忽略、32次DATA读取、pending禁止二次读取、RAM隔离和最终tohost=1。`run_uart_rx_unit.do` 检查RX/FIFO/MMIO边界；`run_uart_rx_board.do` 用无限硬件固件检查50 MHz/115200回显16字节及KEY1帧中复位。所有使用CPU的旧脚本已增加RX模块依赖，旧测试将RX明确接空闲高电平。

### 独立板级构建与历史证据（621d935）

RX接MES50HP R8，TX接R9，LVCMOS33/3.3 V；依据硬件手册V1.1 PDF第27页表3-5。CPU输入为 `uart_rx`，新增参数 `UART_RX_FIFO_DEPTH`；板级顶层也有 `uart_rx` 输入。默认 `board_top` 仍加载原LED演示；选回显固件需运行：

```bash
cmd.exe //c build_pds_board.bat --firmware uart_rx_echo --stage bitstream
```

输出在 `build/pds_uart_rx/`，原 `build/pds_board/` 与备份的基线位流保留。脚本分别检查路由器摘要及最终 `report_timing/board_top.rtr`，清单记录二者，全部通过才生成候选位流。

2026-10-01已完成：三个模块单测、CPU回显、板级RTL回显，以及受MMIO/顶层改动影响的旧TX、GPIO、MMIO、板级演示，共9项RTL测试。全部30个测试平台编译为0错误/0警告；回归流程曾遇到已有work库锁定提示，但四项关联测试均完成PASS。没有重跑CoreMark算法、固定性能或其它无关指令回归。

| 新回显工程检查 | 结果 |
| --- | --- |
| PDS目标 | Logos / PGL50H / -6 / FBG484，50 MHz |
| 当前资源 | 1439 LUT、426寄存器、8 DRM18K；RX FIFO使用分布式RAM |
| 最终STA Slow setup/hold | +4.625 ns / +0.142 ns，0失败端点 |
| 最终STA Fast setup/hold | +9.237 ns / +0.101 ns，0失败端点 |
| 最终recovery/removal及pulse width | 两个corner均通过 |
| 综合后功能网表 | 实际无限硬件镜像回显8字节、KEY1重启通过；无SDF |
| 候选位流 | `build/pds_uart_rx/generate_bitstream/board_top.sbit`；实物待验证 |

资源仅对应这份136字节回显固件，不能作为完整CNN系统资源或新CoreMark性能。综合网表检查入口 `do run_uart_rx_netlist.do` 引用安装目录的官方仿真模型，不复制模型源码。

配置复用引脚仍有3条critical warning，Persist Pin保持None。异步RX与按键pad路径设为false path；RX同步级间及CPU内部仍计时。PDS忽略通用 `ASYNC_REG` 属性并发告警，综合网表已核对RX两级触发器及串接关系存在；该属性不能当作PDS已完成同步器布局/MTBF验证的依据。外部IO无同步delay模型，工具通过不等于电气与实物通过。

首次实物仍先验收已保存的 `6f97477` TX/GPIO位流，再单独验收此RX候选版本。回显固件不输出Hello，也不执行LED心跳；发送少量字符才有串口回显。未执行下载、Flash烧写或远程平台操作。

## MES50HP 首次上板：最小 CPU + UART + LED 工程

本节保留首次实物验收基线 `6f97477`（其父提交是GPIO版本 `8fc6459`）的程序行为及构建证据。当前RX分支仍采用 IF → EX → WB，并增加了接收器；其独立工程见上一章。本节的资源、时序及旧综合网表记录均属于已保存的TX/GPIO基线。若要重建原基线，使用 `6f97477` 源码快照；在当前分支运行本节构建命令会使用新增RX后的RTL，不等于原候选位流。

### 1. 目标硬件和引脚

约束依据《MES50HP开发板硬件使用手册_1V1》，PDF 第10、27、33、34页。目标芯片为 **PGL50H-6IFBG484**，PDS 中选 Logos / PGL50H / -6 / FBG484。下载前必须核对自己开发板的型号、版本、芯片丝印及原理图；不同板卡不要沿用这些引脚。

| 板上资源 | 顶层端口 | FPGA 引脚 | 电平/用途 |
| --- | --- | --- | --- |
| 50 MHz 晶振 | `clk_50m` | P20 | 20 ns 主时钟，不使用 PLL |
| KEY1 | `key1_n` | K18 | 低有效；本工程作为 CPU 复位 |
| KEY2–KEY8 | `keys_n[0]`–`keys_n[6]` | L15、J17、K16、J16、J19、H20、H17 | 低有效；依次对应 LED2–LED8 |
| LED1–LED8 | `led[0]`–`led[7]` | B2、A2、B3、A3、C5、A5、F7、F8 | 高电平点亮 |
| 板载 USB-UART TX | `uart_tx` | R9 | 115200、8N1、无流控 |

这些 IO 使用 LVCMOS33、3.3 V。基线 `6f97477` 未使用R8；当前RX分支已增加 `uart_rx` 输入和R8约束。使用板载 CP2102 的 UART Type-C 接口，不要将 UART 接口与 JTAG 配置接口混淆。

**REPROGRAM 按钮用于重新加载 FPGA 配置，不是 CPU 复位。** 按 KEY1 才会重新启动本 CPU 程序。KEY1 复位异步拉低，经过两级同步和50000个50 MHz时钟（约1 ms）后释放；配置时采用寄存器初值保证首次启动也先保持复位。按键回跳会重新延长释放等待。KEY2–KEY8 只有两级同步，没有完整机械消抖，本演示仅显示按下状态，不用于按键事件计数。

LED 输出是 `gpio_out & gpio_oe` 的专用输出门控，不是外部 GPIO 的双向三态。本工程不需要杜邦线或焊接外部模块，也不会驱动电机、屏幕或其他大电流负载。

### 2. 本程序在板上做什么

配置启动后，CPU 执行 `software/board_demo.c`：

- UART 发送一次 `Hello RISC-V\r\n`，共14字节，随后等待最后一帧发完。
- LED1 每约0.5秒翻转一次（完整亮灭周期约1秒）；延时由 CPU 读取周期计数器决定，不是独立硬件 LED 闪烁器。
- 按住 KEY2–KEY8 时，相应 LED2–LED8 点亮，松开熄灭。
- 按 KEY1 时 LED 熄灭、CPU 复位；松开后重新发启动消息并恢复运行。

这个程序一直运行，不返回 `main`，不会写 `tohost=1` 自动结束。这个 `board_demo` 固件只发送启动消息，不读取新增RX寄存器；回显功能由独立的 `uart_rx_echo` 固件提供。CPU 仍使用原来的32 KiB指令地址空间、16 KiB数据 RAM和 MMIO 地址；没有增加操作系统、CSR或中断。

### 3. 首次只运行新增板级仿真

已有旧测试通过后，不要求重跑全部回归。在 ModelSim Transcript 执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_board.do
```

预期：

```text
BOARD: boot=1 UART received Hello RISC-V (CR LF)
BOARD: boot=2 UART received Hello RISC-V (CR LF)
PASS: board power-on reset, 50MHz UART, CPU-driven LED blink, KEY2 and KEY1 restart
NOTE: short blink/reset delays used in simulation; physical board not tested
```

测试用实际 UART 引脚的位流解码，时钟为50 MHz、每位434个时钟，波特率约115207。与旧100 MHz UART 测试的868时钟/位不同，这不是旧串口测试结果发生错误。

为缩短测试，复位等待改为16周期，数据初始化镜像中的闪烁间隔改为2000周期；**指令 HEX 与硬件完全相同**。PDS 使用默认50000周期复位等待和 `board_demo_data.hex` 的25000000周期间隔，绝不使用 `board_demo_sim_data.hex`。测试内有一次有意的 KEY1 复位，因此收到两次启动消息，并非脚本无限重复仿真。最终 `$stop`/`Break` 为正常结束。

### 4. 修改板级 C 程序时才重新编译

在 Git Bash 的工程根目录执行：

```bash
cmd.exe //c build_board.bat
```

需要 Python 3 和 RV32I GCC；优先用 PATH 中的 `riscv-none-elf-gcc`，也可设置 `BOARD_CROSS` 工具链前缀。Windows CMD 直接执行 `build_board.bat`。脚本生成三份满深度 HEX，并检查硬件与仿真的指令二进制逐字节一致。

本次固件有效载荷为264字节指令、20字节初始化数据，其余指令填 NOP、数据填0。满深度填充用于明确 FPGA 初始化值，不代表固件已经占满存储器。改程序或编译参数后，指令镜像不一致时脚本会报错，不能继续沿用旧镜像。

### 5. 生成自己的 PDS 工程

将仓库放在纯英文目录。安装 PDS、配置有效许可证和 Python 3；优先使用 PATH 中的 `pds_shell`，也可把环境变量 `PDS_SHELL` 设为安装目录中 `pds_shell.exe` 的完整路径。脚本保留本机 `D:/pango/PDS_2022.2-SP6.4` 后备路径，不要求队友复制该安装路径。

首次可直接执行以下一条命令，完成编译、综合、映射、布局布线和时序分析：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_pds_board.bat --stage timing
```

如果先只检查综合，使用 `cmd.exe //c build_pds_board.bat`。所有产物生成在 `build/pds_board/`，核心文件为：

```text
build/pds_board/board_demo.pds
build/pds_board/board_generated.tcl
build/pds_board/board_top_init_paths.v
build/pds_board/compile/board_top_rtl.adf
build/pds_board/synthesize/board_top_syn.adf
build/pds_board/synthesize/board_top_syn.vm
build/pds_board/place_route/board_top.prr
build/pds_board/place_route/board_top_timing_summary_after_hold_fix.txt
build/pds_board/build_manifest.json
```

PDS 2022.2-SP6.4 使用 `compile -top_module board_top -loop_limit 10000` 后再执行 ADS 综合。不要将 `tb/` 文件加入硬件综合。

脚本生成一份仅用于综合的顶层副本，把两份硬件 HEX 默认值改为本机绝对路径，避免 PDS 切换工作目录后加载错文件；仓库中的 `rtl/board_top.v` 仍保持相对路径。**移动工程目录或修改 HEX 后必须重新运行生成脚本，不能复用别人电脑上的 PDS 输出工程或位流。**

生成完成后可以在 PDS 打开 `build/pds_board/board_demo.pds`，检查 Report Summary、管脚表、资源和时序。时钟约束为20 ns；仅异步按键输入和非源同步 LED/UART 输出被设为 false path，CPU、存储器和内部复位释放路径仍进行50 MHz时序检查。外部 IO 没有同步的 input/output delay 模型，工具会给出相关告警，不能宣称“零告警”或所有外部接口时序已验证。

如果助手沙箱运行 PDS 报 `Flow-0189`，应先用一个最小工程区分工具环境/权限问题与 RTL 错误。本次同样错误在最小单寄存器工程中出现；获准在沙箱外运行后最小工程与本工程均编译成功。普通用户本机运行不需要复制任何沙箱配置，不要据此关闭电脑安全设置。

### 6. 本次工具验证结果与告警边界

2026-10-01，PDS 2022.2-SP6.4、PGL50H-6FBG484、50 MHz、当前板级演示固件：

| 检查项 | 结果 |
| --- | --- |
| 板级 RTL 仿真 | 0编译错误、0编译警告；UART、LED闪烁、KEY2和KEY1重启通过 |
| ADS 综合资源 | 1417 LUT、377寄存器、8个 DRM18K；0锁存器、0 APM |
| 实际存储器映射 | 数据 RAM 为8个 DRM18K；264字节小指令程序优化为 LUT ROM，未强制占用32 KiB BRAM |
| 布局布线引脚检查 | 18个顶层端口均落在上述指定引脚 |
| Slow corner setup / hold | WNS +4.840 ns / WHS +0.155 ns，0失败端点 |
| Fast corner setup / hold | WNS +9.523 ns / WHS +0.111 ns，0失败端点 |
| 内部 recovery / removal | 两个 corner 均通过；外部异步按键路径不在此保证范围内 |
| 综合后功能网表 | 用实际硬件镜像检查上电、UART消息、KEY2及KEY1重启，通过 |
| 候选位流生成 | `board_top.sbit` 和 `board_top.bin` 已生成；未下载或烧写硬件 |
| 实物串口、LED、按键 | 尚未验证 |

上述裕量来自 `report_timing/board_top.rtr` 的最终独立静态时序分析。`place_route/board_top_timing_summary_after_hold_fix.txt` 与 `build_manifest.json` 中的 +5.092/+0.144 ns、+9.720/+0.099 ns 是路由器摘要；两份报告均通过，报告数值不能混用。

资源仅属于当前小程序和顶层，换 CoreMark/CNN 程序会改变 ROM 推断及资源，必须重新综合；不能把这一结果当作整个 CNN 系统已综合。

约束检查还有3个 `ConstraintEditor-2002` critical warning：K18、J19、H20属于配置复用引脚。布局布线管脚表已确认相应端口仍放在指定位置；PDS 手册说明配置中的 Persist Pin 默认释放这些端口给用户使用。生成位流时必须保持释放设置，不能启用保留配置复用引脚。此告警不是未经核对便可忽略的普通换行提醒。

综合日志还有 fanout 等告警，不能把综合成功理解为告警为0。当前有限演示的判断依据为映射结果、综合网表功能及约束下的布局布线时序；真实上板电气行为仍待检查。综合后网表检查不含 SDF 路由延迟，不能替代静态时序分析和实物验证。

可选的可重复网表检查入口为 `do run_board_netlist.do`，需要先生成 PDS 综合网表，并通过 `PDS_HOME`（安装根目录）或 `PDS_SHELL` 指向本机 PDS 安装。脚本引用安装目录的官方仿真模型，不复制或分发它们。此项已经在交付前检查，不是要求首次再次运行所有测试。

### 7. 生成候选位流与首次实物验收

确认上面的器件、引脚、复用引脚设置及时序后，在 Git Bash 执行：

```bash
cmd.exe //c build_pds_board.bat --stage bitstream
```

脚本先重新生成并检查布局布线时序，通过后才生成候选位流；**只生成文件，不自动连接、下载或烧写 FPGA**。配置使用 TCK 启动，适用于首次 JTAG 临时配置验证。本阶段不要改成 Flash 固化、加密或 efuse 操作。

候选文件路径为 `build/pds_board/generate_bitstream/board_top.sbit`（JTAG验收使用）及同目录的 `board_top.bin`。本次已验证生成流程，但代码包不分发本机生成的位流；在自己的英文工程目录重新生成，避免把旧程序或错误器件的文件下载到板上。

首次上板按以下顺序验收：

1. 核对实物确为 MES50HP / PGL50H-6IFBG484，使用开发板规定电源和下载线，先不连接 LCD、振动模块或其他外部负载。
2. 在 PDS Configuration 中选择本次生成的候选位流，通过 JTAG **仅下载到 FPGA SRAM**；不要选择烧写 Flash。成功仅表示配置完成，不等于程序功能通过。
3. 打开板载 USB-UART 对应 COM 口，设置115200、8数据位、无校验、1停止位、无流控；先打开终端再按 KEY1，预期收到 `Hello RISC-V`。
4. 松开 KEY1 后观察 LED1 大约每0.5秒翻转；按住 KEY2–KEY8，相应 LED 点亮；再按 KEY1，应熄灯、重新输出启动消息。
5. 保存串口截图、LED/按键现象和 PDS 时序报告，再把实物结果写回 README。没收到文字时依次检查 COM口、板载 UART接口、50 MHz时钟、复位、程序镜像和 TX引脚，不要直接跳到 CNN 联调。

当前尚未执行上述实物验收，README 不把“位流生成”写成“上板通过”。程序和硬件采用 JTAG 临时配置，断电后不会保留本次下载的设计。

新增源码、脚本、FDC、三份 HEX 和 README 应提交；`build/`、`board_work/`、综合网表、PDS本机工程、波形、许可证和候选位流不应提交。

## 已知问题

- 必须尽量在纯英文路径运行 ModelSim，否则可能出现数据库路径乱码或 `vlog-9`。
- 如果出现 `Failed to open readmem file`，应检查 ModelSim 当前目录以及 `programs/*.hex` 是否存在。
- 如果出现 `Unable to remove locked optimized design` 或 WLF 文件被占用，请关闭其他 ModelSim 仿真实例后重试。
- Git 的 LF/CRLF 提示只是 Windows 换行格式提醒，不是编译错误。
- 不要提交 `build/`、`work/`、`uart_work/`、`uart_unit_work/`、`gpio_work/`、`gpio_unit_work/`、`modelsim.ini`、`transcript` 和 `wlf*` 等本地产物。

## 当前限制

- 尚未实现异常、中断、CSR和操作系统支持。
- 尚未实现Cache、BTB和AXI接口；UART TX无FIFO，RX有16字节FIFO，但仍无接收中断、奇偶校验或硬件流控。GPIO已有RTL/MMIO和仿真，实际引脚三态及按键消抖仍需板级实现。
- 当前板级数据 RAM 已确认映射为 DRM18K、初始化已在综合网表中验证；小指令程序优化为 LUT ROM。其他程序映射和实物初始化行为仍需对应验证。
- 数据侧已有单笔请求/响应握手及外部RAM端口；取指仍为固定同步延迟，实际外部存储器控制器与互联尚未接入。
- 32 KiB指令区和16 KiB数据区已运行本阶段的 CoreMark 单次程序，但不代表可以容纳后续完整音频特征提取和 CNN 输入数据。
- 最小板级工程已完成 PDS 综合、资源统计和50 MHz静态时序分析；尚未完成盘古50实物验收，不代表 CNN 或完整 SoC 已上板。

## 后续路线

1. 按板级章节完成 JTAG 临时下载、串口启动消息、LED心跳和按键复位的首次实物验收。
2. 保存对应 PDS 报告和实物证据，依据真实问题修复并建立板级稳定基线；再接外部屏幕或其他外设。
3. 验收新增RX回显：115200、8N1发送少量字符并逐字节核对，单独记录RX版本的实物结果。
4. 与队友确定CNN控制、状态、缓冲区和数据格式，在现有数据握手基础上实现实际响应设备及相应互联；再扩展取指可变延迟。
5. 补齐基础指令边界、异常和中断；建立正式CoreMark基线后实现二路组相联Cache与BTB并比较性能。
6. 完成CNN及系统端到端验证，评估资源、推理延迟和准确率，再依据关键路径评估五级流水线。

## 当前性能基线

本阶段的 C 示例主要用于验证工具链、访存、分支、流水线冲刷和性能计数器，并不代表最终 CPU 或 CNN 性能。当前基线的价值在于：后续加入同步存储器、Cache、BTB 或 CNN 加速器后，可以使用相同的计数方法进行可重复比较。
