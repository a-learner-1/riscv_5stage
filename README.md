# RISC-V 三级流水线 CPU：工具链程序与 tohost 协议

本版在 37 种 RV32I 指令、分支/跳转、前递、子字访存和外部 HEX 指令存储器基础上，建立了独立程序运行流程。程序可以由标准 RISC-V GCC 生成 ELF，再自动转换为 `$readmemh` 使用的 32 位 HEX。

CPU 仍采用 **IF → EX → WB** 三级流水线。本阶段只进行 ModelSim 功能验证，暂不进行 PDS 联合仿真、综合或上板。

## 本阶段完成内容

- `software/start.S`：设置栈、清零 `.bss`、调用 `main`、写入程序返回值。
- `software/main.c`：无操作系统的 RV32I C 测试程序。
- `software/link.ld`：划分程序区和数据区，保留栈及 `tohost`。
- `tools/bin_to_hex.py`：把小端二进制转换为 32 位指令 HEX。
- `Makefile`、`build_program.bat`：自动完成 C → ELF → BIN → HEX。
- `software/prebuilt_demo.S`、`programs/toolchain_demo.hex`：无需安装编译器即可仿真的预生成汇编程序。
- `tb/toolchain_program_tb.v`：验证独立程序、循环、分支、前递和访存。
- `tb/c_program_tb.v`：验证由 GCC 生成的 C 程序。
- `run_toolchain.do`、`run_c_program.do`：ModelSim 一键脚本。

## tohost 程序结束协议

数据 RAM 最后一个字地址 `0x3FC` 被保留为 `tohost`：

| 写入值 | 含义 |
| --- | --- |
| `1` | 程序执行成功 |
| `2`、`3`、`4`…… | 程序检测到错误，数值表示错误码 |

程序完成后写 `tohost`，测试平台监视 `dut.u_data_mem.mem[255]` 并自动结束。该协议后续可以继续用于 C 程序、CoreMark 和竞赛跑分程序。

## 存储器布局

| 地址范围 | 用途 |
| --- | --- |
| `0x000–0x1FF` | `.text`、`.rodata`，最大 512 B |
| `0x200–0x3DF` | `.data`、`.bss`、运行时数据 |
| `0x3E0` | 初始栈顶，栈向低地址增长 |
| `0x3FC` | `tohost` |

指令 ROM 实际容量仍为 4 KiB。当前链接脚本把程序限制在 512 B，是为了和现有 1 KiB 数据 RAM 配合；后续扩容数据 RAM 后可同时调整 `link.ld`。

## 直接运行预生成程序

把本包内容复制到：

```text
D:/FPGA/riscv_3stage
```

在 ModelSim Transcript 中执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_toolchain.do
```

预期输出：

```text
PASS: RV32I standalone program completed through tohost
PASS: loop, branch, forwarding, word and byte memory checked
PASS: tohost=1 cycles=64
```

最后的 `$stop` 和 `Break in Module toolchain_program_tb` 表示测试正常结束。

## 使用 RISC-V GCC 编译 C 程序

需要将 `riscv64-unknown-elf-gcc`、`objcopy` 和 `objdump` 加入系统 `PATH`。工具链虽然名称带 `riscv64`，但参数 `-march=rv32i -mabi=ilp32` 会生成 32 位 RV32I 程序。

Git Bash 中执行：

```bash
cd /d/FPGA/riscv_3stage
make
```

或者在 Windows CMD 中执行：

```bat
cd /d D:\FPGA\riscv_3stage
build_program.bat
```

构建结果：

```text
build/c_demo.elf     带符号的可执行文件
build/c_demo.bin     原始小端二进制
build/c_demo.dump    反汇编文件
build/c_demo.map     链接内存映射
programs/c_demo.hex  ModelSim 指令镜像
```

随后在 ModelSim 运行：

```tcl
cd D:/FPGA/riscv_3stage
do run_c_program.do
```

预期输出：

```text
PASS: freestanding C program completed through tohost
PASS: tohost=1 cycles=...
```

## 编译约束

构建脚本固定使用：

```text
-march=rv32i
-mabi=ilp32
-mno-relax
-msmall-data-limit=0
-nostdlib
-nostartfiles
```

因此生成代码不会使用尚未实现的乘除法、压缩指令、操作系统调用或小数据区 `gp` 初始化。当前 C 程序也不依赖标准库。

## 验证结果

预生成程序已经在 ModelSim SE-64 10.6e 中通过：

- Verilog 编译：`0 errors, 0 warnings`。
- 程序通过外部 HEX 指令存储器运行。
- `1+2+...+10=55` 循环结果正确。
- `SW`、`SB`、`LBU` 和小端数据 RAM 正确。
- 循环相关、分支相关和访存相关前递正确。
- `tohost` 写入 `1`，测试在 64 个运行周期后结束。

当前环境未安装 RISC-V GCC，因此 `software/main.c` 的自动构建需要在工具链安装后执行；随包提供的 `toolchain_demo.hex` 不依赖工具链并已完成仿真验证。

## 当前限制

- 暂无标准库、系统调用和 UART 输出。
- 不支持初始化 `.data` 自动装载到独立数据 RAM；示例只使用 `.bss`。
- 程序区和数据区容量较小，尚不能运行 CoreMark。
- 指令存储器和数据存储器仍是组合读取仿真模型。
- 尚未统计指令数、周期数和 CPI。
- 尚未进行 PDS 综合、时序分析、联合仿真和上板验证。

## 下一阶段

下一步加入性能计数器和统一的程序测试接口：

1. 增加周期计数器 `mcycle` 和退休指令计数器 `minstret`。
2. 由测试平台计算 CPI。
3. 为后续 CoreMark 和竞赛跑分建立可比较的性能基线。
