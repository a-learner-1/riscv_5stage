# CPU5 机器定时器与软件中断设备合同

2026-10-24。基线 `d74836b60f5d313cff408956e373b0a7aa79cc1a`。延续 IRQ 仲裁与最小 MMIO 的冻结合同，本阶段接入 mtime/mtimecmp/MSIP 设备及其到原 IRQ 同步器的连接。原三级产品、机器定时器实现、CPU5 核心/CSR/IRQ/owner 和旧 MMIO 模块保持原样。

## 配置与来源

top 新增 `ENABLE_TIMER_DEVICE=0`、`ENABLE_SOFTWARE_DEVICE=0`，均须为布尔值，任一开启要求 ENABLE_MMIO=1。两参数只控制设备存在和本地地址映射；原 `ENABLE_TIMER_IRQ` / `ENABLE_SOFTWARE_IRQ` 控制 CPU 是否实现对应中断源，二者独立。设备存在而源开关关闭时，软件可轮询，设备仍正常计时/保存 MSIP；关闭源不使设备停钟或清除状态。

设备中断与既有原始输入分别取 OR：`timer_source = irq_timer || machine_timer_irq`，`software_source = irq_software || machine_software_irq`。结果统一进入原 CPU5 两级同步、旧 arm/当前资格复核；同域设备不绕过同步器。清除设备寄存器不能抹掉仍为高电平的原始引脚。未使用的原始输入须显式接 0。

CPU 源开关开启仍需要原有非骨架、CSR、同步 Trap/ENABLE_TRAPS、控制流配置；本阶段不增加全局 IRQ 总门。三类源全部关闭时，mie/mip 继续精确非法；只关闭 timer/software 而其他源开启时，mie/mip 合法但对应关闭位为零。MSIP 寄存器不是 mip CSR，软件写 mip 仍不能改变硬件源。

## MMIO 寄存器与逐边沿语义

| 地址 | 存在条件 | 合法访问 |
|---|---|---|
| 20000040 / 20000044 | ENABLE_TIMER_DEVICE | mtime 低/高 32 位，aligned LW/SW |
| 20000048 / 2000004c | ENABLE_TIMER_DEVICE | mtimecmp 低/高 32 位，aligned LW/SW |
| 20000050 | ENABLE_SOFTWARE_DEVICE | MSIP，aligned LW 返回 bit0，SW 只保存写入 bit0 |

读要求 size=2、strobe=0；写要求 size=2、strobe=f，地址准确对齐。禁用、未知地址或错误形状返回 error、数据 0，不执行寄存器写；自然计时不受非法请求影响。禁用设备地址继续由旧本地端点精确报错，不得漏到外部 RAM。

复位：mtime=0、mtimecmp=ffffffffffffffff、MSIP=0。`machine_timer.v` 原样复用，mtime 在每个非复位输入 clk 边沿加 1，按无符号 64 位回卷；没有分频或 CPU 退休使能。写 mtime 某半字替换整个该边沿的加一结果，另一半保存 **E 前**值，包括低位进位/全宽回卷边界。写 mtimecmp 不阻止 mtime 正常加一，另一半同样保存旧值。

MTIP 是无符号 `mtime >= mtimecmp` 的持续电平；软件将比较值移到未来以清除。MSIP 保持到软件写 0 或 reset，不因读、响应消费、CSR mip 写、Trap 或 IRQ 入口自动清除。中断清源仍经过两级同步；不能承诺 MMIO 写入同一边沿即从 mip 消失。

RV32 的四个 timer 字是独立访问，不提供隐含原子 64 位快照或原子双字写。读取一致时间可采用 high/low/high 重读；更新比较器可先写 high=ffffffff、再 low、最后目标 high。测试分别检查安全三写、旧半字保持与预边沿读值。

## 事务、路由与退休

新 `cpu5_machine_endpoint` 使用 IDLE→STAGED→RESPONSE：接受时捕获完整描述符，下一边沿唯一 endpoint_fire 执行并冻结预边沿读值；响应长回压不重复写或重新读取。reset 可取消执行前描述符，执行后未消费响应单列弃置，不能伪称已经响应。

新 wrapper 只截取启用设备所在的字节范围，其他访问交给原 `cpu5_mmio_router`。wrapper 保存已接受 machine/normal 路由；旧响应数据/READY 不受实时新地址影响。machine 与 normal 跨界不做同拍交接；normal→normal 仍受原路由与 owner 的纯 RAM LOAD 限制。两设备默认关闭时，top 保持原 `g_mmio.u_router` 层次、请求/响应直连时序和端点行为，旧 TB 无需适配。

core 的最老 MEM 授权、IO 不可撤销锁、已退休 WB 保留、flush/IRQ/错误响应规则全部沿用 S10。mtime/MSIP 的读写都不能在 EX 首次呈现，错路径年轻设备写无副作用。错误读/写分别精确 cause5/7，PC/tval/seq 绑定同一个 owner。

IRQ 唯一优先级仍为同步 fault > armed+当前 eligible+安全 IRQ > 正常退休 > 年轻 redirect，external > software > timer。IRQ 与退休互斥，mepc 取 E 前 arch_next_pc；CSR 开启 MIE/mie 或 MRET 后可在紧接边沿处理持续 pending。设备仅提供电平，不修改该仲裁、不在入口自动清源。

## 验收与边界

独立 endpoint 模型覆盖四种设备组合、完整非法矩阵、64 位写入/进位/回卷、比较与 MSIP、回压/reset；路由单元改变实时地址并混合普通/机器设备响应；真实 top 测试包括设备轮询、CPU 源关闭、原始引脚 OR 保留、bank-only 请求及未来比较值自然计时到点。真实 IF 程序逐机器字/退休/WB/GPR/RAM/设备/请求与独立数学模型核对三源优先级、ISR 清源及 MRET，mtime gold 按时钟和已验证写事件独立更新。

每个真实 RTL 变异必须先独立零 Warning/Error 编译，再被指定语义 Fatal 拒绝；非法参数单列 guard，坏证据使用副本且好输入 SHA 不变。只归档最终完整 run_id，完整旧兼容链同源重跑后本地提交。原始证据、源码 LF Git blob、4506 份保护文件及 5 份正式发布物逐项检查，不推送、不下载。

本轮不是 PLIC、嵌套/向量中断、S/U 模式或完整特权架构签核。FENCE、本地 BP 计数设备、十类 Stats、Cache/AXI/正式 SoC、CPU5 P&R/STA/资源/性能和板测仍未完成或未接入；A01–A16 只报告本轮可执行子句，不能写全量 PASS。
