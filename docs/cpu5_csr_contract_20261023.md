# CPU5 最小机器 CSR / MRET 范围冻结

2026-10-23，基线 `5be17af25087ab82eb85d913b4e37193b83db164`。本文件冻结 s7 实现范围，验收结果另见阶段报告。独立 CPU5；不修改原三级、IF、M 单元、正式 SoC/固件/位流。

`ENABLE_CSR=0` 默认保留原行为。启用要求执行模式、控制流和同步 Trap 同时启用；非法参数在仿真 time0 拒绝。没有 IRQ、M、MMIO、软件计数器或性能签核。

| 地址 | 语义 |
|---|---|
| 300 mstatus | reset=1800；写=1800 OR (value AND 88)，MPP 固定 M，只有 MIE/MPIE 可写 |
| 301 misa | 固定 40000100（RV32I），写合法且忽略；不使用尚未接入的 ENABLE_M 宣称 M |
| 305 mtvec | reset=TRAP_VECTOR；Direct，软件写清低两位 |
| 340 mscratch | reset=0，完整32位读写 |
| 341 mepc | reset=0，软件写及 Trap 写清低两位，IALIGN=32 |
| 342 mcause / 343 mtval | reset=0，完整32位读写，沿用原三级实现 |
| F11–F15 ID | 只读零；任何写意图非法 |
| mie/mip/计数器/其他地址 | 精确非法，不以零值假实现 |

除 mtvec reset 使用原 CPU5 的 TRAP_VECTOR（三级为0）外，以上 WARL/状态规则沿用旧 `cpu_top.v` 的 CSR 表与状态更新。`misa` 反映实际 CPU5 子集。

只接受六种 CSR funct3=1/2/3/5/6/7，及精确 MRET=30200073。CSRRW/I 总有写意图；RS/RC 只在编码 rs1/zimm 非零时有写意图，与寄存器实际值无关。rd=x0 抑制 GPR 写回，不免除权限检查；无读副作用 CSR 的组合读取不造成架构副作用。

CSR 在最老 MEM 读取最新已提交状态、RMW、写一次，旧值走 MEM 结果与 WB/前递。ID 对年轻 CSR/MRET 保守等待老 CSR/MRET 离开 EX/MEM，不引入早读缓存。故障、bubble、kill、未退休和 MEM/WB 回压不能写 CSR。

同步 Trap 胜出时使用边沿前已提交 mtvec，写 mepc=faultPC、mcause/mtval，MPIE←MIE、MIE←0、MPP←M。软件 CSR 与外部 trap_pc/cause/tval/seq 事件描述符分开；软件写不改变诊断事件。MRET 在 MEM 获准时正常退休，PC←已提交 mepc，MIE←MPIE、MPIE←1、MPP←M，压年轻 redirect/新D请求，排空已被取消的纯读。老已退休 WB 保留；MEM 暂停或 WB 槽回压持有 MRET。CSR/MRET 不作为 BP 控制指令训练。

依据：冻结 v0.3 §5.2、设计合同 §§2–6、旧三级 `rtl/cpu_top.v`。规范核对：[Zicsr](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html)、[机器级规范](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)。仅验收 A01–A13/A15 可达子句和 A12 的 MRET 部分；A14/M 与 A16/IRQ 未实现，不宣称完整 A01–A16 PASS。
