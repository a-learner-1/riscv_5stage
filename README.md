# RISC-V 三级流水线 CPU

这是一个用于学习 Verilog 和 RISC-V 指令执行过程的 **RV32I 部分指令实现**。处理器采用 **IF → EX → WB** 三级流水线，目前支持 15 种算术、按位逻辑和移位指令。仓库提供 RTL、对应测试平台，以及在 ModelSim 中运行集成仿真的脚本。

> 当前工程是教学原型，尚不能运行通用 RISC-V 程序；它没有实现分支跳转、访存、异常处理等完整处理器功能。

## 当前功能

| 类别 | 已实现指令 |
| --- | --- |
| 加减法 | `ADDI`、`ADD`、`SUB` |
| 寄存器逻辑运算 | `AND`、`OR`、`XOR` |
| 立即数逻辑运算 | `ANDI`、`ORI`、`XORI` |
| 寄存器移位 | `SLL`、`SRL`、`SRA` |
| 立即数移位 | `SLLI`、`SRLI`、`SRAI` |

数据通路包括一个内置测试程序的取指 ROM、指令译码器、32 个 32 位寄存器、8 种运算的 ALU，以及 **WB → EX 的 rs1、rs2 前推**。寄存器 `x0` 固定读出 0，写入 `x0` 不改变处理器状态。

立即数逻辑运算使用 12 位符号扩展立即数。`SLLI`、`SRLI`、`SRAI` 的移位量取自指令的 `[24:20]`；寄存器移位使用 `rs2` 值的低 5 位。立即数指令不把指令中的 `[24:20]` 误当成第二源寄存器去前推。

## 目录结构

```text
rtl/
  if_stage.v       取指 ROM、PC 和 IF/EX 寄存器
  decoder.v        指令字段与类型译码
  regfile.v        两读一写寄存器堆
  alu.v            加减、按位逻辑、移位运算
  cpu_top.v        数据通路、前推和 EX/WB 寄存器
tb/
  if_stage_tb.v    取指测试
  decoder_tb.v     译码测试
  regfile_tb.v     寄存器堆测试
  alu_tb.v         ALU 测试
  cpu_top_tb.v     CPU 集成测试
run_cpu.do         ModelSim 仿真脚本
```

## 运行仿真

开发和测试环境为 **ModelSim SE-64 10.6e**，Verilog 文件使用 `vlog -sv` 编译。在 ModelSim 的 **Transcript** 窗口中，先切换到仓库根目录，再运行脚本：

```tcl
cd D:/FPGA/riscv_3stage
do run_cpu.do
```

如果工程放在其他位置，将第一行改为你自己的路径。脚本会创建或映射 `work` 编译库，编译 RTL 与测试平台，加载 `cpu_top_tb`，加入常用波形信号并运行。看到下面的输出表示集成测试通过：

```text
PASS: original 25 instructions preserved
PASS: cpu_top immediate shift integration test passed, 41 instructions
```

测试平台在约 **436 ns** 执行 `$stop`，这是正常暂停。`work/` 和 `.wlf` 是本地仿真生成的文件，不是需要手动编辑的源码。

脚本编译完成后，也可以在 Transcript 中分别运行单元测试。每次切换测试顶层前，先退出当前仿真：

```tcl
quit -sim
vsim -voptargs=+acc -onfinish stop work.decoder_tb
run -all
```

将 `work.decoder_tb` 改为 `work.alu_tb` 或 `work.if_stage_tb`，即可运行相应测试。

## 已验证的测试

| 测试 | 通过结果 | 覆盖重点 |
| --- | --- | --- |
| `decoder_tb` | 408 例 | 指令编码、所有 5 位立即数移位量、错误编码拒绝 |
| `alu_tb` | 46 例 | 加减、逻辑、移位及边界值 |
| `if_stage_tb` | 41 条程序与末尾 NOP | PC、ROM 指令顺序 |
| `cpu_top_tb` | 41 条程序，约 436 ns | 运算结果、前推、写回、写 `x0` 抑制 |

以上为当前测试覆盖范围，不能据此推断已经实现全部 RV32I 指令。内置程序依次执行 41 条测试指令，涵盖负立即数、移位量 `0`、`1`、`31`、相邻指令依赖、立即数位段与寄存器地址碰撞等情况。

## 实现说明

1. **IF** 按 PC 从 `if_stage.v` 内置 ROM 取指，保存到 IF/EX 寄存器；未列出的 PC 返回 NOP。
2. **EX** 译码并读取源寄存器，在需要时从 WB 前推最新结果，再选择 ALU 运算和第二操作数。
3. **WB** 保存目标寄存器编号、结果和写使能；寄存器堆在时钟上升沿完成写入。

一次指令进入 WB 与结果实际写入寄存器堆之间存在一个时钟周期的差别。测试平台分别检查 EX 结果、WB 状态和最终寄存器值。

## 后续计划

- 补充更系统的复位、非法编码和边界值测试。
- 扩展比较、分支和跳转指令，并处理控制冒险。
- 加入数据存储器与 Load/Store 指令，处理相关数据冒险。

## 参考资料

- [RISC-V RV32I 基础整数指令集](https://docs.riscv.org/reference/isa/v20240411/unpriv/rv32.html)
