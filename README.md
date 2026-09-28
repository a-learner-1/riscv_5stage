# RV32I 三级流水线 CPU

这是一个使用 Verilog 实现的 RV32I 处理器软核，目前采用 **IF → EX → WB** 三级流水线，能够在 ModelSim 中加载外部 HEX 程序、运行裸机 RISC-V 汇编和 C 程序，并通过 `tohost` 协议自动报告运行结果。

当前版本已经完成37种 RV32I 指令、数据前递、分支与跳转冲刷、字及子字访存、RISC-V GCC 软件构建流程，以及周期数、退休指令数和 CPI 性能统计。当前重点仍是功能仿真与软件运行基础设施，暂未进入 PDS 综合和 FPGA 上板阶段。

项目的长期目标是作为紫光同创盘古 50 开发板上轻量化 CNN 推理系统的 RISC-V 主控，后续将继续加入同步 Block RAM、Cache、BTB、UART、GPIO、AXI 总线和 CNN 加速器控制接口。

## 当前状态

更新时间：2026-09-29。

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
| 同步 Block RAM 与 load-use stall | 尚未完成 |
| CoreMark | 尚未完成 |
| Cache、BTB、AXI、UART、GPIO | 尚未完成 |
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
| 指令存储器 | 4 KiB，1024×32位 |
| 数据存储器 | 1 KiB，256×32位 |
| 字节序 | 小端 |
| 通用寄存器 | `x0`–`x31`，其中 `x0` 固定为0 |
| 分支解析 | EX级 |
| 当前存储器模型 | 组合读取、同步写入的仿真模型 |

### 流水线控制

- 使用 `valid_x` 区分有效指令和流水线气泡。
- ALU、分支、跳转、加载和存储均可使用 WB → EX 前递结果。
- 立即数指令不会把立即数字段误判为 `rs2` 数据相关。
- 分支或跳转在 EX 级确定目标地址，错误路径指令会被冲刷。
- `JALR` 目标地址最低位强制清零。
- 写入 `x0` 的操作被抑制。
- 当前数据 RAM 为组合读取，因此加载结果可以进入现有前递路径；改用同步 Block RAM 后需要增加 load-use 停顿。

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

当前固定的 `c_demo.hex` 测试结果：

```text
PASS: performance counters and C program completed
PERF: tohost=1
PERF: cycles=174
PERF: retired instructions=150
PERF: CPI=1.160
```

`performance_tb.v` 会检查精确的150条退休指令，用于发现错误计入气泡或错误路径指令的问题。如果修改并重新编译 `software/main.c`，动态指令数量可能变化，此时需要同步调整测试平台中的 `EXPECTED_INSTRET`。

## 工程目录

```text
rtl/
  instr_mem.v           外部 HEX 指令存储器
  if_stage.v            PC、取指、IF/EX寄存器和重定向冲刷
  decoder.v             指令译码和立即数生成
  regfile.v             两读一写寄存器堆
  alu.v                 算术、逻辑、移位和比较
  data_mem.v            1 KiB 小端数据 RAM
  cpu_top.v             顶层数据通路、前递、访存和性能计数

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

software/
  start.S               初始化栈、清零.bss、调用main并写tohost
  main.c                裸机C测试程序
  link.ld               链接脚本和内存布局
  prebuilt_demo.S       预生成程序的汇编源文件

programs/
  rv32i_regression.hex  指令回归程序
  program_load_test.hex 外部程序加载测试
  toolchain_demo.hex    无需GCC即可运行的预生成程序
  c_demo.hex            由当前C程序生成的指令镜像

tools/
  bin_to_hex.py         BIN转32位小端HEX
```

根目录中的 `run_*.do` 是各组 ModelSim 一键测试脚本。

## 环境要求

- Windows 10/11。
- ModelSim SE-64 10.6e。
- Python 3，用于执行 `tools/bin_to_hex.py`。
- xPack GNU RISC-V Embedded GCC，命令前缀为 `riscv-none-elf-`。

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
PERF: cycles=174
PERF: retired instructions=150
PERF: CPI=1.160
```

最后出现的 `$stop` 和 `Break in Module performance_tb` 表示测试平台主动停止，不是错误。

## 构建并运行 C 程序

### Windows CMD

```bat
set "PATH=D:\Tools\xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64\xpack-riscv-none-elf-gcc-15.2.0-1\bin;%PATH%"
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
build/c_demo.bin     原始小端二进制
build/c_demo.dump    反汇编文件
build/c_demo.map     链接内存映射
programs/c_demo.hex  ModelSim指令镜像
```

随后在 ModelSim 中运行：

```tcl
do run_c_program.do
do run_performance.do
```

## tohost 程序结束协议

数据 RAM 最后一个字被保留为 `tohost`：

```text
字节地址：0x000003FC
RAM字下标：255
测试平台路径：dut.u_data_mem.mem[255]
```

| 写入值 | 含义 |
| --- | --- |
| `1` | 程序成功 |
| `2`、`3`、`4`…… | 程序失败码 |

CPU程序把结果写入 `tohost` 后，测试平台会判断成功或失败并自动停止。该协议后续可以继续用于 CoreMark 和其他裸机基准程序。

## 当前存储器布局

| 地址范围 | 用途 |
| --- | --- |
| `0x000–0x1FF` | `.text`、`.rodata`，当前链接脚本限制为512 B |
| `0x200–0x3DF` | `.data`、`.bss` 和运行时数据 |
| `0x3E0` | 初始栈顶，栈向低地址增长 |
| `0x3FC` | `tohost` |

指令 ROM 实际容量为4 KiB，数据 RAM 为1 KiB。当前链接脚本的较小程序区用于配合现有数据空间；移植 CoreMark 前必须重新规划并扩大存储器。

## 完整回归测试

可以在 ModelSim Transcript 中分别运行：

```tcl
do run_cpu.do
do run_branch.do
do run_compare_branch.do
do run_jump.do
do run_load_store.do
do run_subword_mem.do
do run_program.do
do run_toolchain.do
do run_c_program.do
do run_performance.do
```

当前版本已经在 ModelSim SE-64 10.6e 下完成上述全部回归：

- 77条基础 CPU 集成测试通过。
- 六种条件分支以及有符号、无符号比较通过。
- JAL/JALR链接地址、前递、最低位清零和冲刷通过。
- LW/SW及load-use、存储地址/数据前递通过。
- LB/LBU/LH/LHU/SB/SH符号扩展、小端字节通道和边界测试通过。
- 外部HEX、预生成程序和GCC C程序通过。
- 性能测试结果为174周期、150条退休指令、CPI 1.160。

## 波形观察

`run_performance.do` 已加入以下关键信号：

```text
clk、rst_n、pc_x、instr_x、valid_x
wb_pc、retire_valid、cycle_count、instret_count
mem_addr_x、mem_wdata_x、mem_we_x、mem[255]
```

查看程序结束过程时，可以在 Transcript 输入：

```tcl
wave zoom range 1650ns 1780ns
```

最后一次有效存储应满足：

```text
mem_we_x    = 1
mem_addr_x  = 0x000003FC
mem_wdata_x = 0x00000001
mem[255]    = 1
```

## 已知问题

- 必须尽量在纯英文路径运行 ModelSim，否则可能出现数据库路径乱码或 `vlog-9`。
- 如果出现 `Failed to open readmem file`，应检查 ModelSim 当前目录以及 `programs/*.hex` 是否存在。
- 如果出现 `Unable to remove locked optimized design` 或 WLF 文件被占用，请关闭其他 ModelSim 仿真实例后重试。
- Git 的 LF/CRLF 提示只是 Windows 换行格式提醒，不是编译错误。
- 不要提交 `build/`、`work/`、`modelsim.ini`、`transcript` 和 `wlf*` 等本地产物。

## 当前限制

- 尚未实现异常、中断、CSR和操作系统支持。
- 尚未实现 UART、GPIO、Cache、BTB 和 AXI 接口。
- 指令存储器和数据存储器仍使用组合读取模型，不是最终 FPGA Block RAM 时序。
- 没有完整的存储器 `stall/ready/valid` 握手接口。
- 目前的程序和数据空间不足以直接运行 CoreMark。
- 尚未进行 PDS 综合、资源统计、静态时序分析和盘古 50 上板验证。

## 后续路线

1. 扩大指令存储器和数据存储器，重新规划链接地址。
2. 移植 CoreMark，建立 CPU 基准性能数据。
3. 将组合存储器改造为同步 Block RAM。
4. 增加 load-use stall 和统一存储器握手。
5. 实现 UART、GPIO 和板级顶层。
6. 实现二路组相联 Cache 和 BTB 分支预测器。
7. 增加 AXI 接口并连接 CNN 加速器。
8. 进入 PDS 综合、资源分析、时序优化和盘古 50 上板验证。

## 当前性能基线

本阶段的 C 示例主要用于验证工具链、访存、分支、流水线冲刷和性能计数器，并不代表最终 CPU 或 CNN 性能。当前基线的价值在于：后续加入同步存储器、Cache、BTB 或 CNN 加速器后，可以使用相同的计数方法进行可重复比较。
