# CPU5 机器定时器与软件中断设备

2026-10-24，基线 `d74836b60f5d313cff408956e373b0a7aa79cc1a`。状态：**PARTIAL VERIFIED：机器 timer/MSIP 设备**。本轮完成 mtime/mtimecmp/MSIP MMIO 与既有 IRQ 入口的连接，范围和边沿合同见 [本轮合同](cpu5_machine_contract_20261024.md)。

## 实现与配置

```verilog
cpu5_top #(.SKELETON_ONLY(0), .ENABLE_FORWARDING(1),
           .ENABLE_CONTROL_FLOW(1), .ENABLE_RAM(1), .ENABLE_MMIO(1),
           .ENABLE_SYNC_TRAPS(1), .ENABLE_TRAPS(1), .ENABLE_CSR(1),
           .ENABLE_EXTERNAL_IRQ(1), .ENABLE_TIMER_IRQ(1), .ENABLE_SOFTWARE_IRQ(1),
           .ENABLE_TIMER_DEVICE(1), .ENABLE_SOFTWARE_DEVICE(1)) ...;
// 未使用的 irq_external / irq_timer / irq_software 原始输入显式接0。
```

两个新设备开关默认关闭，开启需要 ENABLE_MMIO。设备存在与 CPU 中断源开关独立：可在源关闭时轮询；源开启仍遵守原 CSR/Trap/控制流 guard。默认配置保留原 g_mmio.u_router 层次与延迟，旧 TB/工具无需适配。

本地 20000040/44 为 mtime 低/高，48/4c 为 mtimecmp 低/高，50 为 MSIP（共同前缀 200000）；仅 aligned LW/SW 与匹配 strobe 合法。MSIP 只保留 bit0，禁用设备地址和非法形状精确错误、零寄存器写。自然计时不会被非法请求暂停。

`machine_timer.v` 原样复用：每个 clk 边沿计时，无符号 64 位比较/回卷；mtime 某半字写入替换整个该边沿的 increment，另一半保存旧值；写 mtimecmp 时 mtime 继续加一。读返回 endpoint_fire 的预边沿值，响应回压不重新读或重复写。64 位分字访问不提供隐含原子快照，比较器支持安全 high=ffffffff / low / high 三写方式。

新 `cpu5_machine_endpoint` 捕获完整请求后下一边沿执行。新 wrapper 保存 machine/normal 响应路由，其他访问继续交给原 MMIO router/endpoint。跨机器/普通路径不允许同拍交接，原纯 RAM LOAD 捷径保留。CPU5 core、CSR、IRQ 控制器、D owner、旧 UART/GPIO/MMIO 与原定时器实现均未修改。

设备电平与原始引脚分别 OR 后进入原两级同步器，没有同域旁路。软件通过 MSIP=0 或将 mtimecmp 移到未来清源；读、响应消费、mip CSR 写和中断入口均不自动清除。原始引脚仍高时，清 bank 不能抹掉它。外部>软件>定时器优先级、旧 arm/当前资格、IRQ/退休互斥及 mepc=旧 arch_next_pc 继续由原核心执行。

## 实测验收

| 检查 | 结果 |
|---|---|
| 设备独立 oracle | 四种设备组合；1,152,952 检查，14,496 接受=14,492 执行+4 次执行前 reset 取消；14,492 执行=14,488 响应+4 次执行后 reset 弃置 |
| Timer/MSIP 边沿 | 14,394 非法拒绝、98 合法；34 timer 写、12 MSIP 写、25,128 回压周期；实际 MMIO 设置近进位值，4 次低位进位、2 次全 64 位回卷；unsigned 比较、mtime 写优先与安全比较器三写 |
| 真实 top 定向 | 18 场景；778 退休=WB，10 IRQ、24 精确 Trap、86 D 请求=响应，17,448 独立检查；四种设备映射、关闭源轮询、raw/bank OR、bank-only 请求与 2FF/arm/CSR/PC 对账 |
| 自然计时到点 | ID/EX 各一例：设置未来比较值 250 后保持 MIE 开启，前台自循环等待 226 边沿；独立模型确认到点后同步/arm 复核，在 pre-mtime=253 进入 IRQ，mepc 固定为程序 terminal PC；ISR 清源并 MRET 恢复 |
| 响应路由 | 19 接受=15 响应+4 reset 弃置；161 检查，7 machine 执行、5 普通本地执行、2 GPIO 写、5 外部接受；改变实时地址、回压、跨路边界与旧 RAM 交接均受检 |
| 真实 IF 程序 | ID/EX×BP×I/D 等待×前递开关，共 16 配置；2416 退休=WB、64 IRQ、16 非法设备 LB 精确 Trap、768 D 请求=响应、2899 IF 请求=响应 |
| 程序设备与恢复 | 304 次 machine 执行、96 timer 写、64 MSIP 写、32 普通 MMIO 执行、16 GPIO 写；每配置中断顺序 SW→external→SW→timer；32 次 MRET 紧接边沿 IRQ；ISR 清对应源、保存 CSR、前台/MUL 恢复与错路径年轻写零效果 |
| 独立参考 | 15 固定机器字+5 状态时序自检；8808 次逐边沿 mtime/cmp/MSIP/2FF/oldarm/CSR/take 检查；完整 64 词 RAM、32 物理 GPR（28 已定义含 x0、4 保持未知） |
| 坏证据 | 14 份实际 CSV/RAM/GPR 副本破坏由指定语义拒绝，良好输入 SHA 前后不变 |
| RTL/参数负例 | endpoint 21 + top/集成 15 + router 4，共 40 项真实 RTL 功能变异；另 5 项参数 guard；均先独立零 Warning/Error 编译，再由指定语义 Fatal 拒绝 |
| 兼容链 | 最终同源从头重跑 MMIO→IRQ→M→CSR/MRET→Trap→RAM→分支→前递→ALU→IF/默认骨架，包含全部前阶段负测，旧源/TB/工具保留 |

正常配置零 Error/Warning，真实坏样本/非法参数的指定 Fatal/非零退出单列。端点负例含私有副本中破坏旧 machine_timer 的算术与比较逻辑，实际交付旧模块未改；不能将该类坏源误认为产品修改。reset 的执行前取消和执行后响应弃置分别独立计数，无 reset 的程序事务全部闭合。

程序用独立机器字解释器核对退休/写回/CSR/GPR/RAM。timer gold 由完整时钟历史与已经独立核验的 endpoint 写描述符更新，不使用 DUT 返回值生成期望。先在 MIE=0 下置 MSIP 并验证 mip 写忽略，开中断后处理 SW；随后三源同时挂起，按优先级只清相应源，MRET 返回独立固定的前台 PC。独立逐周期模型确认两级同步与下一安全边沿，不从 DUT mepc 倒推期望。

独立只读集成审查确认设备/源使能分离、raw OR、默认旧层次、保存响应路由、不可撤销与 reset、正常 RAM 交接和组合依赖一致，未发现阻断项。

## 复跑、冻结与保护

```powershell
python -B tools/verify_cpu5_machine.py
python -B tools/freeze_cpu5_machine.py
```

只有完整 PASS 记录的每份实测依赖原始 SHA 全部相同时，才允许 `--reuse-reference` / `--reuse-suites`。本轮旧完整链已从头执行，新套件最终同源实测；ModelSim 根 ini 按序，所有新套件及坏样本采用私有 cwd/ini/库。

[冻结索引](evidence/cpu5_machine_20261024/README.md)包含 158 份测试依赖的原始/LF SHA、总验证、原始 CSV/程序/RAM/GPR/日志/波形/实际坏源与 ZIP 逐 entry 摘要。所有有 run_id 的套件只保留最终完整批次；源码 Git blob 逐项按 LF 检查，原始证据用独立 `.gitattributes` 保留字节。

原 4506 份保护文件只更新 `rtl/cpu5_top.v`，其余 4505 份及 5 份正式三级 release 文件逐字节保持；用户脏工作区与未跟踪工作保留。按明确清单本地提交，不推送、不下载；交付结果和源/归档校验写入 `build/verification/cpu5_machine_20261024/delivery_result.json`。

本轮不是完整 A01–A16 或完整特权架构签核。FENCE、本地 BP 计数设备、十类 Stats、Cache/AXI/正式 SoC 集成仍待后续；CPU5 P&R、STA、资源/Fmax、CoreMark 和板测未运行，没有五级性能结论。下一阶段可补齐 FENCE，再进入存储系统与统计集成。
