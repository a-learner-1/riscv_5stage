# RISC-V 三级流水线 CPU

这是一个用于学习 Verilog 和 RISC-V 指令执行过程的 **RV32I 部分指令实现**。处理器采用 **IF → EX → WB** 三级流水线，当前支持 **19 种指令**。仓库包含 RTL 源码、测试平台，以及在 ModelSim 中运行 CPU 集成仿真的脚本。

> 当前工程是教学原型。取指 ROM 内置固定测试程序，尚不能运行通用 RISC-V 软件；分支、跳转、访存、异常处理等功能尚未实现。

## 已实现指令

| 类别 | 指令 |
| --- | --- |
| 加减法 | `ADDI`、`ADD`、`SUB` |
| 寄存器逻辑运算 | `AND`、`OR`、`XOR` |
| 立即数逻辑运算 | `ANDI`、`ORI`、`XORI` |
| 寄存器移位 | `SLL`、`SRL`、`SRA` |
| 立即数移位 | `SLLI`、`SRLI`、`SRAI` |
| 寄存器比较 | `SLT`、`SLTU` |
| 立即数比较 | `SLTI`、`SLTIU` |

这里的 **19 种**指指令类型；后文的 **63 条**指取指 ROM 中测试程序的指令数量。

比较指令把结果 `0` 或 `1` 写入目标寄存器。`SLT`、`SLTI` 按有符号数比较，`SLTU`、`SLTIU` 按无符号数比较。`SLTIU` 的 12 位立即数**先符号扩展，再进行无符号比较**：例如立即数 `-1` 扩展后是 `0xffffffff`。

## 数据通路

处理器包含取指 ROM、指令译码器、32 个 32 位寄存器、支持 **10 种运算**的 ALU，以及 **WB → EX** 的 `rs1`、`rs2` 数据前递。寄存器 `x0` 始终读出 0，写入 `x0` 不改变处理器状态。

- **IF**：根据 PC 从内置 ROM 取指，并保存到 IF/EX 寄存器。ROM 未列出的地址返回 NOP。
- **EX**：译码、读取源寄存器、处理前递，选择 ALU 操作和第二操作数。
- **WB**：保存目标寄存器编号、计算结果和写使能，由寄存器堆在时钟上升沿写入。

普通 I 型运算使用符号扩展的 12 位立即数。`SLLI`、`SRLI`、`SRAI` 的移位量取指令的 `[24:20]`；寄存器移位取 `rs2` 值的低 5 位。立即数指令不会把 `[24:20]` 误判为第二源寄存器并触发 `rs2` 前递。

## 目录结构

```text
rtl/
  if_stage.v       取指 ROM、PC 和 IF/EX 寄存器
  decoder.v        指令字段与类型译码
  regfile.v        两读一写寄存器堆
  alu.v            加减、逻辑、移位和比较运算
  cpu_top.v        数据通路、前递和 EX/WB 寄存器
tb/
  if_stage_tb.v    取指测试
  decoder_tb.v     译码测试
  regfile_tb.v     寄存器堆测试
  alu_tb.v         ALU 测试
  cpu_top_tb.v     CPU 集成测试
run_cpu.do         ModelSim 编译、波形与集成仿真脚本
README.md          项目说明
```

## 运行仿真

本项目在 **ModelSim SE-64 10.6e** 中验证，使用 `vlog -sv` 编译 Verilog 文件。在 ModelSim 的 **Transcript** 窗口输入：

```tcl
cd D:/FPGA/riscv_3stage
do run_cpu.do
```

如果工程放在其他位置，请将 `cd` 后的路径改成实际仓库目录。脚本会创建或映射 `work` 库、编译 RTL 和主要测试平台、加载 `cpu_top_tb`、加入波形并运行集成测试。成功时会看到：

```text
PASS: signed/unsigned comparison, negative immediates and forwarding checked
PASS: cpu_top comparison integration test passed, 63 instructions
```

测试平台在约 **656 ns** 执行 `$stop`，表示测试正常暂停。`work/` 和 `.wlf` 是本地仿真产物。

编译完成后，也可以在 Transcript 中单独运行其他测试平台。例如运行译码器测试：

```tcl
quit -sim
vsim -voptargs=+acc -onfinish stop work.decoder_tb
run -all
```

将 `work.decoder_tb` 换为 `work.alu_tb` 或 `work.if_stage_tb`，即可运行相应测试。`regfile_tb.v` 不在 `run_cpu.do` 的编译列表中；如需单独运行寄存器堆测试，先输入：

```tcl
quit -sim
vlog -sv -work work rtl/regfile.v tb/regfile_tb.v
vsim -voptargs=+acc -onfinish stop work.regfile_tb
run -all
```

## 已验证的测试

| 测试平台 | 通过结果 | 主要检查内容 |
| --- | --- | --- |
| `alu_tb` | 62 例 | 加减、逻辑、移位、有符号与无符号比较及边界值 |
| `decoder_tb` | 426 例 | 指令字段、立即数、合法编码与错误编码 |
| `if_stage_tb` | 63 条程序指令及末尾 NOP | PC 递增和 ROM 指令顺序 |
| `cpu_top_tb` | 63 条程序指令，约 656 ns | 运算结果、数据前递、写回、`x0` 写入抑制 |

内置程序保留了原先的 41 条指令测试，并新增 22 条比较指令测试。比较测试覆盖正负数、有符号与无符号结果不同的情况、相等、`-2048` 和 `2047` 立即数、相邻指令前递、立即数字段与寄存器编号碰撞，以及写入 `x0`。

这些结果说明上述测试用例通过，不能据此推断已实现完整 RV32I 指令集。

## 后续计划

- 加入 `LUI`、`AUIPC`，扩展立即数和写回数据通路。
- 实现分支与跳转指令，并处理控制冒险。
- 加入数据存储器与 Load/Store 指令，处理访存相关的数据冒险。

## 参考资料

- [RISC-V RV32I 基础整数指令集](https://docs.riscv.org/reference/isa/v20240411/unpriv/rv32.html)
