# CPU5 机器 IRQ 阶段合同

2026-10-24。基线 `baa2275d5a2ccb204f23b37414bc7a59f746ecaa`，延续设计合同 §6 及归档 v0.3 §5。本轮范围：CPU5 三路机器中断原始电平输入、独立同步/候选控制器、mie/mip、MEM 精确入口、已有 MRET/owner 联动。设备、MMIO、Cache/AXI/SoC、Stats、板顶和性能不在本轮范围。

## 接口与 CSR

`ENABLE_EXTERNAL_IRQ`、`ENABLE_SOFTWARE_IRQ`、`ENABLE_TIMER_IRQ` 均为布尔参数，默认 0。任一路开启需要非骨架 CPU5、CSR、同步 Trap 与控制流；top 同时需要历史 ENABLE_TRAPS 门开启。输入 `irq_external`、`irq_software`、`irq_timer` 各自经过两个寄存器同步。关闭的源固定为 0，不加入 pending。没有额外总 IRQ 开关。

任一路开启时 mie(304)/mip(344) 为合法 CSR。mie 仅保存已启用源的 MEIE/MSIE/MTIE（bit11/3/7），其他位读零、写忽略。mip 返回同步的硬件电平，与 mie 和 mstatus.MIE 无关，六种 CSR 操作均合法且写入忽略。三路全部关闭时二者继续精确非法。CPU 不清除设备源，外部提供者负责撤销原始电平；本轮软件/计时中断输入也由外部电平驱动，未实现定时器或软件中断 MMIO 寄存器。

CSR 仍只在最老 MEM 正常退休时 RMW。mip 是动态读值，MEM→ID/EX 的 ready 仅在 mem_enable 且 WB 可接收时成立，使提前分支捕获值等于同边沿 CSR 返回值。其他静态 CSR 保留既有的 WB 回压期间早前递行为。软件写出的 mtvec/mepc 等 WARL 与上一阶段保持一致。

## 唯一边沿仲裁

E 前状态决定本边沿动作：reset > 最老 MEM 同步 fault > 已 armed、当前仍 eligible 且安全的 IRQ > 正常 MEM 退休（含 CSR/MRET）> 年轻 redirect。IRQ 与 retire 恒互斥，不增加 instret，不训练 BP，不产生新 WB 包；更老的已退休 WB 可以独立写回或持有。

`eligible = committed mstatus.MIE && |(committed mie & synchronized pending)`。irq_take 只使用旧 irq_arm_q 与本边沿重新计算的 eligible。pending 撤销或屏蔽立即撤销资格，优先级为 external > software > timer。正常退休获得授权后，候选的下一状态使用该退休的 post-CSR 状态；因此 T0 CSR 开启 mstatus.MIE/mie 或 MRET 恢复 MIE 后，持续 pending 在 T1 可 take，不能多等 T2。已经 armed 且安全的 IRQ 会先于尚未退休的关中断 CSR/MRET 生效。

安全边界：已呈现 STORE 在 held、accepted、complete/待退休期间始终不可抢占；成功 STORE 先在完成边沿退休，下一安全边沿才可 IRQ。最老存活 MEM LOAD 也先完成/退休，错误则同步 Trap 优先。尚未首次呈现的 MEM STORE 可被抢占，禁止产生第一次 request。EX M 可取消，不挡 IRQ；已经 killed 的后台 D/M owner 不挡无关 ALU/CSR 或中断入口。mem_enable=0 和外部 flush_valid 挡住 IRQ。

入口 mepc 与诊断 trap_pc 都取 **E 前 arch_next_pc_q**，不能取 IF/EX/MEM 当前 PC 或推测目标。mcause 为 8000000b/80000003/80000007，mtval=0。以已提交 mtvec 重定向，mstatus.MPIE←旧 MIE、MIE←0，MPP 固定 M。MRET 正常退休恢复 MIE←MPIE、MPIE←1，跳转已提交 mepc。

IRQ 清除全部尚未退休级包/前端，以 cut=0 取消所有未退休 D/M owner，屏蔽新 D/M 发起、转级、年轻跳转与退休。先前 held 的 killed 纯 LOAD 请求仍须稳定并可继续握手/排空，响应错误只 drop；运行中 killed DIV 同样排空一次，handler 新 MUL 等资源释放后获得新 generation。Fetch epoch 仍只作用于 IF。

## 诊断与验收口径

内部 `trap_fire` 保留同步故障专用语义；寄存 `trap_valid` 包含同步 Trap 或 IRQ。IRQ 的 trap_seq/redirect_seq 为 MEM、EX、当前 IF 输入中首个现有边界序号，无包时为全 1；它是边界诊断，不是新分配的故障 owner，可重复或非单调，不能要求它已被接受。正常退休 seq 仍严格递增且唯一，支持跨 bit32，不允许回卷。

验收含八种源参数组合的独立控制器/CSR 模型、ID/EX 定向控制、真实 IF 机器字程序参考、真实 RTL 功能变异与独立 guard、坏 CSV/RAM/GPR 副本拒绝，以及全部前阶段同源兼容链。旧 CPU5 TB 只补显式零电平端口，每份反向还原后必须逐字节等于基线 Git blob；证明单列在 legacy_ports JSON，不改旧刺激、预期或断言。

A12/A14/A16 仅报告上述可执行子句的局部验证；完整 A01–A16、设备级中断、系统集成、STA、CPU5 资源/频率和板测均未签核。原三级产品与用户未提交文件按原始 SHA 保护，不推送、不下载。
