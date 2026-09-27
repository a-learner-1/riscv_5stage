# RISC-V 三级流水线 CPU

这是一个用于学习 Verilog 和 RISC-V 指令执行过程的 **RV32I 部分指令实现**。处理器采用 **IF → EX → WB** 三级流水线，目前支持 **23 种指令类型**。仓库包含 RTL、测试平台，以及 ModelSim 仿真脚本；原有 77 条顺序执行的测试指令仍保留，随后加入独立的分支测试程序段。

> 这是教学原型，尚不能运行通用 RISC-V 程序；目前只实现 `BEQ/BNE` 两种条件分支，其他分支、跳转、访存与异常处理尚未实现。

## 已实现指令

| 类别 | 指令 |
| --- | --- |
| 加减法 | `ADDI`、`ADD`、`SUB` |
| 寄存器逻辑 | `AND`、`OR`、`XOR` |
| 立即数逻辑 | `ANDI`、`ORI`、`XORI` |
| 寄存器移位 | `SLL`、`SRL`、`SRA` |
| 立即数移位 | `SLLI`、`SRLI`、`SRAI` |
| 有符号与无符号比较 | `SLT`、`SLTU`、`SLTI`、`SLTIU` |
| U 型立即数 | `LUI`、`AUIPC` |
| 条件分支 | `BEQ`、`BNE` |

数据通路包含内置测试程序的取指 ROM、指令译码器、32 个 32 位寄存器、支持 **10 种运算**的 ALU，以及 **WB → EX 的 `rs1`、`rs2` 前递**。寄存器 `x0` 始终读出 0，写入 `x0` 不改变处理器状态。

I 型算术与逻辑指令使用 12 位符号扩展立即数；立即数移位指令使用 `[24:20]` 中的 5 位移位量，寄存器移位使用 `rs2` 值的低 5 位。`SLT`、`SLTI` 按有符号数比较，`SLTU`、`SLTIU` 按无符号数比较，结果写入 `0` 或 `1`。`SLTIU` 的立即数**先符号扩展，再进行无符号比较**，例如 `-1` 扩展为 `0xffffffff`。

U 型指令使用 `{instr[31:12], 12'b0}`：`LUI` 将该值写入目标寄存器，`AUIPC` 将该值与**本条指令的 PC** 相加后写入目标寄存器。U 型指令没有源寄存器，因此不能把立即数字段中与 `rs1`、`rs2` 地址重叠的位误判为前递依赖。

`BEQ/BNE` 在 EX 比较经过 WB 前递后的两个源寄存器。B 型偏移按指令位段重排并符号扩展，目标地址为**该分支指令的 PC + 偏移**。分支成立时，IF 将顺序路径上的一条指令冲刷为无效气泡；分支和气泡均不写回寄存器。当前固定 32 位取指程序只测试 4 字节对齐的分支目标，未实现指令地址未对齐异常。

## 目录结构

```text
rtl/
  if_stage.v       取指 ROM、PC 和 IF/EX 寄存器
  decoder.v        指令字段、I/U/B 型立即数、指令类型译码
  regfile.v        两读一写寄存器堆
  alu.v            加减、比较、按位逻辑、移位运算
  cpu_top.v        数据通路、前递和 EX/WB 寄存器
tb/
  if_stage_tb.v    取指测试
  decoder_tb.v     译码测试
  regfile_tb.v     寄存器堆测试
  alu_tb.v         ALU 测试
  cpu_top_tb.v     CPU 集成测试
  branch_tb.v      BEQ/BNE 分支与控制冒险测试
run_cpu.do         ModelSim 仿真脚本
run_branch.do      ModelSim 分支仿真脚本
README.md          项目说明
```

## 运行仿真

验证环境为 **ModelSim SE-64 10.6e**。在 ModelSim 的 **Transcript** 中进入仓库根目录并运行：

```tcl
cd D:/FPGA/riscv_3stage
do run_cpu.do
do run_branch.do
```

如果工程放在其他位置，请替换第一行路径。两个脚本分别编译并运行旧的 CPU 集成测试与新的分支测试。成功时应分别看到：

```text
PASS: U-immediate, instruction PC, forwarding and x0 checked
PASS: cpu_top U-type integration test passed, 77 instructions
PASS: BEQ/BNE forward, taken/not-taken, backward loop and squash
```

两个测试平台分别约在 **796 ns** 和 **1106 ns** 执行 `$stop`，这是预设的暂停点，不是错误。`work/`、`*.wlf` 和 `modelsim.ini` 是本地仿真产物，不应作为功能代码提交。

脚本编译后，可以分别运行单元测试。切换测试顶层前先退出当前仿真：

```tcl
quit -sim
vsim -voptargs=+acc -onfinish stop work.decoder_tb
run -all
```

将 `work.decoder_tb` 换成 `work.alu_tb` 或 `work.if_stage_tb` 即可运行相应测试。`run_cpu.do` 没有编译 `regfile_tb.v`；如需单独运行寄存器堆测试，请输入：

```tcl
quit -sim
vlog -sv -work work rtl/regfile.v tb/regfile_tb.v
vsim -voptargs=+acc -onfinish stop work.regfile_tb
run -all
```

## 已验证的测试

| 测试 | 通过结果 | 主要检查 |
| --- | --- | --- |
| `decoder_tb` | 442 例 | 合法与非法编码、立即数提取、`LUI/AUIPC` 译码 |
| `alu_tb` | 62 例 | 加减、比较、逻辑、移位及边界值 |
| `if_stage_tb` | 原有 77 条指令 | PC 与原有 ROM 指令顺序 |
| `cpu_top_tb` | 77 条指令，约 796 ns | 运算、写回、前递、`x0` 抑制、U 型立即数及 AUIPC 的指令 PC |
| `branch_tb` | 6 次成立、4 次不成立的分支，约 1106 ns | 前递、后向循环、错误路径冲刷、分支与气泡无写回 |

前 63 条集成测试指令保留了旧功能的回归检查；新增 14 条覆盖 `LUI/AUIPC`、上下界立即数、相邻指令依赖，以及 U 型立即数字段与寄存器地址位段重叠时的假前递。上述测试结果只说明所列用例通过，不能推断已经实现完整 RV32I。

## 流水线实现

1. **IF** 按 PC 从内置 ROM 取指，保存到 IF/EX 寄存器；未列出的 PC 返回 NOP。EX 中的分支成立时改用目标 PC，并冲刷一条顺序路径指令。
2. **EX** 译码并读取寄存器；需要时从 WB 前递最新结果，再选择 ALU 操作和两个输入。`LUI` 的 A 输入为 0，`AUIPC` 的 A 输入为本条指令的 PC，二者的 B 输入为 U 型立即数。`BEQ/BNE` 用前递后的源操作数判定是否跳转。
3. **WB** 保存目标寄存器编号、结果和写使能；寄存器堆在时钟上升沿写入。分支及被冲刷的气泡没有写回。

测试平台分别检查 EX 结果、WB 状态和最终寄存器值，避免只凭最终寄存器内容判断前递是否正确。

## 后续计划

- 扩展 `BLT/BGE/BLTU/BGEU` 及 `JAL/JALR`，完善控制转移。
- 加入数据存储器与 Load/Store 指令，处理相关数据冒险。
- 扩展复位、非法编码和边界值回归测试。

## 参考资料

- [RISC-V RV32I 基础整数指令集](https://docs.riscv.org/reference/isa/v20240411/unpriv/rv32.html)
