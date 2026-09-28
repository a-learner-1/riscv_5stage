# RISC-V 三级流水线 CPU

用于学习和 FPGA 赛题开发的 RV32I 部分指令实现，使用 Verilog，采用 IF → EX → WB 三级流水线。目前实现 31 种指令类型，提供 ModelSim 自检测试。本项目仍是教学原型，尚不能据此宣称支持完整 RV32I 或运行 CoreMark。

## 已实现指令

| 类别 | 指令 |
| --- | --- |
| 加减 | ADDI、ADD、SUB |
| 寄存器逻辑 | AND、OR、XOR |
| 立即数逻辑 | ANDI、ORI、XORI |
| 寄存器移位 | SLL、SRL、SRA |
| 立即数移位 | SLLI、SRLI、SRAI |
| 比较 | SLT、SLTU、SLTI、SLTIU |
| U 型 | LUI、AUIPC |
| 条件分支 | BEQ、BNE、BLT、BGE、BLTU、BGEU |
| 跳转 | JAL、JALR |
| 字访问 | LW、SW |

支持 WB→EX 的 rs1、rs2 前递。分支和跳转在 EX 决定目标，重定向时冲刷一条顺序路径指令。x0 读出 0，写入被抑制；LW 的目标为 x0 时仍执行内存读取。

## 本版 LW/SW 实现

- 地址按字节计数，使用 `rs1 + 符号扩展的 12 位偏移`。LW 使用 I 型立即数，SW 使用 S 型立即数。
- SW 的地址与存储数据是两条独立路径：ALU 计算地址，经过前递的 rs2 提供写入数据。SW 不写寄存器。
- LW 在 EX 读取 RAM，结果进入 WB，并可前递给下一条指令。LW 的立即数字段不能触发 rs2 前递。
- 数据 RAM 与指令 ROM 分离，容量 1 KiB，合法字起始地址为 0、4、…、1020。
- RAM 使用组合读、上升沿写，未写过的单元没有规定初值，复位不清空 RAM。测试先写后读。

本版 RAM 时序允许加载数据在 EX 周期内返回，因此没有增加 load-use 停顿。将来接入同步 Block RAM、总线或可变延迟存储器时，需要重新设计响应时序和停顿/前递控制，不能直接套用当前假设。

仅支持对齐的 LW/SW。访问越界或不对齐时，RAM 禁止写入且不会截断高地址产生别名；CPU 在功能仿真中用 `$fatal` 报错。尚未实现相应的硬件异常入口与 trap 机制，这不代表已完成异常处理。

## 目录

```text
rtl/
  if_stage.v              内置指令 ROM、PC、IF/EX 寄存器及冲刷
  decoder.v               指令译码与 I/S/U/B/J 型立即数
  regfile.v               两读一写寄存器堆
  alu.v                   运算单元
  data_mem.v              1 KiB 数据 RAM
  cpu_top.v               数据通路、前递、访存控制和 EX/WB 寄存器
tb/
  alu_tb.v                ALU 回归
  decoder_tb.v            原有运算、立即数与 U 型译码回归
  if_stage_tb.v           原有 77 条指令取指回归
  regfile_tb.v            寄存器堆回归
  cpu_top_tb.v            原有 77 条指令 CPU 回归
  branch_tb.v             BEQ/BNE 回归
  jump_tb.v               JAL/JALR 回归
  compare_branch_tb.v     比较分支回归
  data_mem_tb.v           RAM 单元测试
  load_store_decoder_tb.v LW/SW 译码测试
  load_store_tb.v         LW/SW 集成测试
run_cpu.do
run_branch.do
run_jump.do
run_compare_branch.do
run_load_store.do
```

## ModelSim 运行

将本包文件复制到项目对应位置。所有旧 CPU 脚本也需要更新，因为 cpu_top 新增了 data_mem 模块依赖。如果 ModelSim 提示外部文件已修改，选择 Reload 读取刚复制的文件。

在 Transcript 中输入下列两行（代码块标签 `tcl` 不是命令）：

```tcl
cd D:/FPGA/riscv_3stage
do run_load_store.do
```

预期在 2436 ns 输出：

```text
PASS: LW/SW 49 instructions, 18 loads, 15 stores
PASS: load-use, store address/data forwarding, signed offsets, x0 and squash
```

随后 `$stop` 暂停属于正常结束。脚本已编译 RAM 与访存译码单元测试，可分别运行：

```tcl
quit -sim
vsim -onfinish stop work.data_mem_tb
run -all
quit -sim
vsim -onfinish stop work.load_store_decoder_tb
run -all
```

旧功能回归使用 `do run_cpu.do`、`do run_branch.do`、`do run_jump.do` 和 `do run_compare_branch.do`。

## 验证结果

本包已在 ModelSim SE-64 10.6e 中通过以下 11 个测试顶层。新访存程序从 PC=704 开始，保留此前 ROM 程序。

| 测试 | 结果或覆盖范围 |
| --- | --- |
| alu_tb | 62 例 |
| decoder_tb | 442 例 |
| if_stage_tb | 原有 77 条取指 |
| regfile_tb | x0、读写 |
| cpu_top_tb | 原有 77 条执行指令 |
| branch_tb | BEQ/BNE、循环与冲刷 |
| jump_tb | JAL/JALR、链接值、前递与冲刷 |
| compare_branch_tb | 22 次比较分支决策 |
| data_mem_tb | 边界地址、非法地址不产生别名、读写使能 |
| load_store_decoder_tb | 21 例，funct3 与 I/S 型偏移边界 |
| load_store_tb | 49 条执行指令，18 次加载、15 次存储 |

访存集成测试覆盖 ALU→SW、LW→ALU、LW→SW、LW→LW 地址依赖、LW→分支、rs1/rs2 同时前递、连续覆盖同一地址、负偏移、x0、最低与最高合法字地址，以及分支/跳转冲刷后的访存禁止。

测试通过说明这些场景已验证，不等于完整 ISA 一致性验证。本步仅完成 ModelSim 功能仿真，没有进行 PDS 仿真或上板测试。

## 后续工作

- 加入 LB/LBU/LH/LHU/SB/SH 及字节写掩码。
- 外部程序加载、启动代码、链接脚本和 C 程序验证。
- 面向同步存储器的等待控制、异常处理与剩余基础指令。
- UART/GPIO、计时设施、FPGA 实现和 CoreMark 测试。

参考：[RISC-V RV32I 指令集规范](https://docs.riscv.org/reference/isa/v20240411/unpriv/rv32.html)。
