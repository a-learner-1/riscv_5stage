# CPU5 最小 MMIO 与有序非 RAM 访问合同

2026-10-24。基线 `fb5d1a48776b87976b1bdcbe0c98a301d757b753`。延续冻结设计合同 §4/§6 与 v0.3 的副作用/退休边界。该阶段实现最小本地 UART/GPIO/计数器读取，以及所有非 RAM 地址的 MEM 授权；不接正式三级板顶，不扩展 Cache/AXI/Stats 设备或系统计时器。

## 地址类别与参数

`ENABLE_MMIO` 是 core/top/唯一 D owner 的布尔参数，默认 0。关闭时保持已有 RAM 范围外 cause5/7，不实例化本地 MMIO 路由或外设；开启要求 ENABLE_RAM=1，top 要求 SKELETON_ONLY=0、EXTERNAL_DMEM=1。配置普通 RAM 与本地页 `0x20000000..0x200000ff` 不得重叠，避免 EX 纯读被包装层截成设备读。范围与访问末字节使用扩展宽度比较，不能回卷比较。

只有完整位于普通 RAM 白名单、对齐合法的 LOAD 可在 EX 首次呈现。所有 STORE、非 RAM LOAD 都等最老 MEM：mem_enable、live、无 fault/flush/IRQ、无已绑定 owner 时才可首次呈现。非 RAM 包括本地 MMIO、`0x30000000` Stats 窗口和任何未知地址；`!local_mmio` 不意味着纯读。未对齐访问由 EX 保存异常，在最老 MEM 精确 Trap，不发 D 请求。

非 RAM 有效地址和写数据在 EX 完整保存，MEM 以同一个描述符发起；`is_store` 仍是实际读写方向。LOAD 不可伪装为 STORE，必须继续获得 LOAD 格式、GPR 返回值与读错误 cause5。

## Owner、不可撤销与唯一仲裁

D 请求优先级仍为 held descriptor > 最老获准 MEM > 合格 EX RAM LOAD。owner 在 issue_fire、即首次呈现边沿建立，独立保存 IO 类别；从此设备读与 STORE 都不可撤销，直到成功退休或错误同步 Trap 确认。历史信号 `ram_store_lock/store_lock` 现在覆盖 STORE 或非 RAM 请求；`owner_is_store/completion_is_store` 保留真实 write 语义。

覆盖锁定 owner 的外部 flush（cut≤owner.seq）必须拒绝，调用方保持请求；cut>owner 的年轻取消仍可接受。IRQ 等锁解除；同步错误响应可在本边沿确认故障源并释放 owner，不能被锁永久挡住。成功完成但 MEM 暂停或 WB 满时，缓存完整响应与 owner，继续保持锁，不重复发送或执行副作用。reset 是清空事务与设备状态的独立边界，不承诺撤回 reset 前已经执行的外部副作用。

纯 RAM LOAD 被 kill 时保持原有发送/排空/drop 行为；fetch epoch 不决定 D owner。已呈现非 RAM LOAD 即使还未 ready 也不可取消。只有旧 owner 与新请求 **均为成功、存活、纯 RAM LOAD** 才可同边沿响应/请求交接；STORE、IO、error、killed drain 都至少空一个边沿。所有非 RAM READ 也挡住年轻不同地址 RAM LOAD。

保留 S9 的安全边界：存活最老 MEM LOAD（包括尚未呈现的 IO LOAD）先完成/退休，下一安全边沿 IRQ；尚未呈现的 STORE 可被 IRQ 抢占，仍在 EX 的 IO 可被取消。IRQ 与退休互斥，mepc 取边沿前 arch_next_pc。错误响应按实际 LOAD/STORE 报 cause5/7，tval=原始字节地址，PC/seq 为同一最老 MEM owner。

## 路由与端点执行边沿

`cpu5_mmio_router` 将本地页送至新 CPU5 endpoint，其余 RAM/Stats/未知地址仍使用原公开 D 端口。路由在 request_fire 保存，响应仅按已接受旧事务选择，不能跟随实时请求地址。支持外部纯 RAM LOAD A→B 的原有交接；本地/外部跨界不做同拍交接。外部零延迟端点仍须保持 VALID，直到 owner 在接受后的 READY 边沿消费。

本地端点只在 IDLE 接受，完整捕获 addr/write/size/wdata/wstrb 后跨一拍。唯一 `endpoint_fire` 执行副作用，并同沿捕获读返回值；RESPONSE 状态保持数据/error，直到 rsp_ready，期间不重放 pop/写，不接受新请求。reset 在执行前可取消 staged 描述符；执行后 reset 丢弃待消费响应并清设备，账本单列已执行/未返回项。

cycle/instret 读取返回 **endpoint_fire 的 E 前**计数低 32 位。RX_DATA 返回同边沿 pre-pop 旧队首，pop 至多一次；不能在响应消费时重新读取队首或计数器。返回数据、错误和副作用必须绑定同一个捕获描述符。

## 本地最小设备表

| 地址 | 合法访问与行为 |
|---|---|
| 20000000 / 20000004 | aligned LW，cycle / instret 低 32 位，只读 |
| 20000010 | 准确基址的 SB/SH/SW，strobe 分别 1/3/f，发送低 8 位；执行边沿 busy 时访问错误且零发送 |
| 20000014 | aligned LW，UART busy bit0，只读 |
| 20000018 | aligned LW，RX 旧队首字节并 pop，空队列返回 0 |
| 2000001c | aligned LW 读取 RX 状态；aligned SW/WSTRB=f 对 bit2/3 W1C，新增事件优先 |
| 20000020 / 20000028 | aligned LW/SW，GPIO OUT / OE，仅低 8 位实现 |
| 20000024 | aligned LW，GPIO 两级同步输入，只读 |
| 2000002c / 20000030 / 20000034 | aligned SW，GPIO SET / CLR / XOR，仅低 8 位实现，禁止读 |

除 TX 明确的宽度外，只接受 size=2；读 strobe=0，写 strobe=f。未映射、错误方向、尺寸、对齐或 strobe 均返回 error、数据 0，零设备副作用。原 `uart_tx.v`、`uart_rx.v`、`uart_rx_fifo.v`、`uart_rx_mmio.v`、`gpio_mmio.v` 原样复用。端点 UART 参数须至少 4 clocks/bit，FIFO 深度 1..255；这些是仿真与配置 guard，不是板级时钟签核。

本轮不实现 `mtime/mtimecmp/MSIP`、本地 BP 计数寄存器或 schema4/2 Stats 设备，对应本地未映射地址报错；外部 Stats/未知地址 fixture 的返回值只验证有序协议，不表示真实 Stats/AXI 已接入。FENCE、Cache/AXI/SoC/十类统计、CPU5 STA/资源/性能和板测仍未签核。

## 验收与保护

核心 ID/EX 定向覆盖首次请求年龄、不可撤销三阶段、flush/IRQ、精确错误、真实 RAM 交接与 reset 分类账本；独立端点 oracle 覆盖物理 UART、GPIO、非法矩阵和响应回压；路由单元故意改变实时地址并提供错侧响应；真实 IF 程序逐退休/WB/GPR/RAM/请求/副作用与独立机器字参考对账。真实 RTL 变异必须先零 Warning/Error 编译，再由指定语义断言拒绝，非法参数另计。全部前阶段依赖同源完整重跑后，才冻结原始证据并本地独立提交。

A01/A03/A06–A13/A16 只报告本阶段实现的局部子句，不写完整 A01–A16 PASS。原三级文件、旧外设与正式发布物保持原始 SHA，用户未提交工作保留，不推送、不下载。
