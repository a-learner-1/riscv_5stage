# CPU5 S12 基础 FENCE 合同

2026-10-24。基线 `ea03aba50e22ee9ca59c07abe3a7dd4f6f6905c3`。

`cpu5_top` / `cpu5_alu_pipeline` 新增布尔参数 `ENABLE_FENCE=0`。顶层开启需 `SKELETON_ONLY=0`；其他可选功能沿用各自 guard。不开 RAM 时无旧 D owner，FENCE 仍正常退休。默认关闭保留旧子集行为。

opcode=0x0f、funct3=0 的全部编码均实现保守的全数据屏障：忽略 fm/pred/succ 和保留 rs1/rd，包括空掩码及 FENCE.TSO。无寄存器读依赖，无 GPR 写；诊断 rd/value 固定 0，成功退休 next-PC=PC+4。funct3=1 的 FENCE.I 和其他 funct3 继续非法，不提供取指缓存维护。此取舍依据 [RISC-V RV32I 内存顺序章节](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html)允许的保守实现。

FENCE 带 `is_fence` / `fence_op` 元数据经过 EX、MEM。在 MEM 仅当**预边沿 D owner 已空**、结果有效、MEM 使能、WB 可接收，且没有更高优先级取消/异常/IRQ 时才正常退休。旧 owner 包括已取消的纯 RAM 读，其 held 请求、accepted 响应、错误响应仍必须物理排空。最后响应握手当拍不旁路退休 FENCE。

活 FENCE 在 MEM 的所有边沿（包含成功退休边沿）阻止年轻 EX→MEM、D owner 分配和 M owner 分配；下一拍才允许后继推进。旧 STORE/有副作用 I/O 先按原最老 MEM 合同完成，FENCE 不重新执行它们。没有新增 D owner 状态或多 outstanding 路径。不等待无关的已取消 M 运算或 IF 事务。

外部 flush、同步 fault、IRQ 优先级沿用既有实现。等待中的 FENCE 本身无不可撤销副作用，可被 IRQ/flush 取消。IRQ 使用旧 arch-next-PC，不能退休被取消 FENCE；旧已退休 WB 可保持并独立写回。携带 FENCE 指令位的 fetch-error 按取指错误精确 Trap，不受 FENCE drain 等待阻塞。

旧错误预测包在 EX 修复为 PC+4，即使分支选择 ID 判定；FENCE 在 ID 不先行重定向。成功退休沿用普通非控制指令的 BP 通知，分支/JAL/taken 均为零，可清理旧 BTB 项；不声称“没有 BP 通知”。不改变现有统计事件定义。

真实顶层无外部 flush 入口，已发射普通 LOAD 同时成为活 MEM 且阻止 IRQ，所以真实 top 程序不声称覆盖“IRQ 取消已发射 LOAD 后 FENCE 等待”。该物理 drain 路径由合法核心外部 flush 接口的定向测试覆盖；不使用 force/deposit，不增加产品接口。错误预测包的 EX 归属也由核心输入包测试，顶层程序覆盖真实 IF/BP 正常执行。

单 outstanding D 响应定义本阶段的访问完成点，不扩展为外部设备中断信号、其他 hart、Cache/AXI/写缓冲的额外保证。原 CPU3、IF、CSR、IRQ、D/M owner、UART/GPIO、timer、MMIO 设备保持原样。Cache、统计设备、正式 SoC、CPU5 STA/P&R/板测和性能结论另阶段验收。

验收要求：真实 core 四组 4096 字段矩阵、默认关闭与非法/取指错误；ID/EX 定向 drain/退休沿屏障/M启动/取消/WB/IRQ/Trap/预测恢复；真实 IF 16 配置 RAM/设备/ISR/MRET 程序；固定机器字解释器、完整 GPR/RAM/事务逐沿核对、坏证据拒绝、独立零告警编译后真实 RTL 语义变异及参数 guard；同源从头重跑全部旧 CPU5 链。

旧 S11 验证工具默认仍校验原不可变核心。S12 通过显式 `--allow-core-extension` 只豁免 `rtl/cpu5_alu_pipeline.v` 与 S11 基线的相等性；其他旧模块、逐运行 SHA、所有原刺激/期望/功能及负例 gate 均保留。结果明确记录唯一豁免，不将新核心误报为旧源码未改。
