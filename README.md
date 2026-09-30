# RV32I 三级流水线 CPU

这是一个使用 Verilog 实现的 RV32I 处理器软核，目前采用 **IF → EX → WB** 三级流水线，能够在 ModelSim 中加载外部 HEX 程序、运行裸机 RISC-V 汇编和 C 程序，并通过 `tohost` 协议自动报告运行结果。

当前版本已经完成37种 RV32I 指令、数据前递、分支与跳转冲刷、字及子字访存、同步指令/数据存储器、load-use 停顿、RISC-V GCC 软件构建流程、性能计数器 MMIO、CoreMark 单次功能校验，以及 UART TX 串行发送。当前重点仍是功能仿真与软件运行基础设施，暂未进入 PDS 综合和 FPGA 上板阶段。

项目的长期目标是作为紫光同创盘古 50 开发板上轻量化 CNN 推理系统的 RISC-V 主控。CPU 与平台部分负责处理器、外设和后续加速器接口，CNN 模型与部署由队友负责。后续仍需 UART RX、GPIO、Cache、BTB、AXI 和板级验证。

## 队友快速上手：下载后先看这里

当前仓库是 **CPU RTL、软件示例和仿真测试工程**，不是可以下载后直接烧录的完整板级工程。仓库已包含预生成 HEX 程序镜像，第一次运行不需要先编译 C，也不需要复制原作者电脑上的 ModelSim 工程、工作库或波形。

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
PERF: cycles=192
PERF: retired instructions=155
PERF: CPI=1.238
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
| `software/main.c` | `cmd.exe //c build_program.bat` | `do run_c_program.do` |
| CoreMark 算法或裸机适配层 | `cmd.exe //c build_coremark.bat` | `do run_coremark.do` |

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
| 根目录 `run_*.do` / `build_*.bat` | 仿真和软件构建入口；目前保持在根目录，避免破坏已有使用方式 |

需要保留并提交源码、测试平台、构建脚本、配套 HEX 和许可证。不需要提交 `build/`、`work/`、`uart_work/`、`uart_unit_work/`、`modelsim.ini`、`transcript`、`*.wlf` 或本机 `.mpf` 工程；这些文件由工具在各自电脑上生成，已由 `.gitignore` 排除。

## CPU 与 CNN 协作边界

CPU 与平台部分负责处理器、存储器、外设和后续加速器接入；CNN 模型与部署由队友负责。双方可以分别开发与验证自己的模块，但当前仓库尚未实现 AXI 总线和 CNN 加速器控制/数据接口，不能把现有 UART TX 或计数器 MMIO 当作已完成的 CNN 接口。

当前 C 示例与 CoreMark 配置使用32 KiB指令区、16 KiB数据区。它们是现阶段的软件运行资源，不代表完整 CNN 权重、音频特征和中间结果都能容纳，也不代表后续最终系统的存储容量。

**CPU 与 CNN 的详细联调约定后续再写，依据实际搭建的 CPU 与系统接口确定，并由双方确认。** 本阶段不预先指定加速器寄存器地址、AXI 类型、数据缓冲区地址或中断号，也不发布一份可能与后续实现不一致的固定接口协议。

待 CPU 总线和加速器接入方式确定后，再文档化实际的控制/状态寄存器、输入输出数据格式、数据传输路径、握手时序、时钟复位和联调测试。后续文档应与 RTL、C 驱动和测试平台一起维护，并明确哪些能力已验证、哪些仍待实现。

## 当前状态

更新时间：2026-09-30。

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
| 同步指令/数据 RAM 与 load-use stall | RTL 时序及仿真已完成；实际 BRAM 映射待综合确认 |
| 性能计数器 MMIO | 已完成 |
| CoreMark v1.01 | 单次算法/CRC 校验已通过；不是正式跑分 |
| UART TX | 已完成 RTL 与串行线仿真验证 |
| UART RX、GPIO、Cache、BTB、AXI | 尚未完成 |
| PDS 综合与盘古 50 上板 | 尚未完成 |

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
- 数据 RAM 同步读取，加载指令通过 `load_issue_x` / `load_pending` 分两步完成，取指与 EX 在发起加载时停顿，返回数据随后进入 WB 前递路径。

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
PERF: cycles=192
PERF: retired instructions=155
PERF: CPI=1.238
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

software/
  start.S               初始化栈、清零.bss、调用main并写tohost
  main.c                裸机C测试程序
  link.ld               链接脚本和内存布局
  prebuilt_demo.S       预生成程序的汇编源文件
  mmio.h                计数器读取、UART 忙状态轮询和字符输出
  uart_demo.c           发送 Hello RISC-V 并等待最后一帧结束
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
  coremark.hex          已接入 UART 忙状态轮询的 CoreMark 指令镜像
  coremark_data.hex     CoreMark 初始化数据镜像

tools/
  bin_to_hex.py         BIN转32位小端HEX
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
PERF: cycles=192
PERF: retired instructions=155
PERF: CPI=1.238
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

## UART TX：本次新增功能

本阶段只实现发送端 TX，没有实现 RX、FIFO 或串口接收中断。发送格式为 8N1：一个低电平起始位、八个数据位、一个高电平停止位，低位先发送，空闲电平为高。

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

当前版本已经在 ModelSim SE-64 10.6e 下完成上述全部回归：

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

## 已知问题

- 必须尽量在纯英文路径运行 ModelSim，否则可能出现数据库路径乱码或 `vlog-9`。
- 如果出现 `Failed to open readmem file`，应检查 ModelSim 当前目录以及 `programs/*.hex` 是否存在。
- 如果出现 `Unable to remove locked optimized design` 或 WLF 文件被占用，请关闭其他 ModelSim 仿真实例后重试。
- Git 的 LF/CRLF 提示只是 Windows 换行格式提醒，不是编译错误。
- 不要提交 `build/`、`work/`、`uart_work/`、`uart_unit_work/`、`modelsim.ini`、`transcript` 和 `wlf*` 等本地产物。

## 当前限制

- 尚未实现异常、中断、CSR和操作系统支持。
- 尚未实现 UART RX、GPIO、Cache、BTB 和 AXI 接口；UART TX 无 FIFO，使用软件轮询。
- 指令存储器和数据存储器已使用同步读取时序，但是否推断为目标器件 BRAM、初始化能否上板生效，需要 PDS 综合验证。
- 没有完整的存储器 `stall/ready/valid` 握手接口。
- 32 KiB指令区和16 KiB数据区已运行本阶段的 CoreMark 单次程序，但不代表可以容纳后续完整音频特征提取和 CNN 输入数据。
- 尚未进行 PDS 综合、资源统计、静态时序分析和盘古 50 上板验证。

## 后续路线

1. 实现 GPIO 和板级顶层，核对实际时钟、复位与 UART TX 引脚。
2. 在 PDS 中确认 BRAM 推断、程序初始化、资源使用和基本时序，进行首次上板串口输出验证。
3. 按系统需要补充 UART RX、FIFO 和统一存储器握手。
4. 实现二路组相联 Cache 和 BTB 分支预测器，使用相同程序比较性能。
5. 增加 AXI 接口，与队友约定 CNN 加速器控制/状态/数据格式后进行联调。
6. 建立正式 CoreMark 测试配置和系统端到端验证，评估资源、推理延迟及准确率。

## 当前性能基线

本阶段的 C 示例主要用于验证工具链、访存、分支、流水线冲刷和性能计数器，并不代表最终 CPU 或 CNN 性能。当前基线的价值在于：后续加入同步存储器、Cache、BTB 或 CNN 加速器后，可以使用相同的计数方法进行可重复比较。
