# CPU5 S13 native Cache 接入合同

2026-10-24，基线 `40f92eb6b5da71898f824425a880e7b172c3b85a`。本阶段新增独立 `cpu5_cache_adapter` 和 `cpu5_cached_top`，原 CPU5 core/top、CPU3、I/D Cache、设备、桥与正式 SoC/板顶全部保持原样。先验证 Cache 接入，AXI/D0/Stats 另阶段实现。

`cpu5_cached_top` 保留 `cpu5_top` 的全部参数和观察端口。`u_cpu` 为原核心包装，`u_memory` 为新 Cache adapter。新增 `ENABLE_ICACHE=0` / `ENABLE_DCACHE=0`；Cache 开启要求 active CPU（SKELETON_ONLY=0），D Cache 另需 ENABLE_RAM=1。两开关为布尔量。原功能、CSR/IRQ/MMIO 的参数要求不变；Cache 几何沿用原模块 guard。默认两路 64 组、每行 4 字，I/D 容量各 2 KiB。

adapter 接受 CPU native I/D ready/valid，输出同样的后端 I/D 协议。前端与后端请求/响应各自配对，不能将 refill beat 当作新 CPU 动态指令。D Cache 放在 `cpu5_top` external D 口后，本地 MMIO 已在 `u_cpu` 内截获；不能将 Cache 插到本地 MMIO 前。关闭通道为原协议直接连线，诊断计数恒零。I/D 可独立同时执行，互不抢占或交换响应。

保持字节地址、size、一起移位的 wdata/wstrb；读响应是完整对齐的 32 位字，LB/LH 的 lane 和符号扩展仍在核心执行。只有 DMEM 白名单 RAM 可填充；未知/Stats/其他地址只按原已获 MEM 授权的一笔描述符旁路，不因 Cache 存在而开放 EX 投机。I Cache 只服务固定只读指令空间，越界/错位出错归属原 PC。

原 Cache 均为阻塞式，每通道最多一个 CPU 事务、一个后端事务。读 miss 逐字完成整行；错误归属原请求，只在全行成功后安装。D 写穿透、不写分配、无脏行/写缓冲；最终后端写成功后才完成 CPU STORE 并更新命中行。错误写命中保持失效，不提供物理写回滚。不能将 Cache 入口 hit 接受能力冒充 CPU5 全链 II=1。

核心原 D owner 一直持有到 Cache 最终响应，因此既有 FENCE 排空自然覆盖全部填充/写穿透后端访问；最后响应沿不旁路 FENCE，退休沿仍挡年轻 D/M。killed 纯 RAM LOAD 不取消 Cache refill：完整 drain 后只丢核心结果，错误也不能复活成 Trap。IF redirect 同理不取消 Cache，旧 IF adapter 负责 stale 最终响应/错误，不向 Cache 传 fetch epoch kill。

CPU、adapter、Cache 和后端必须共享同一 reset。reset 清协议与有效位，取消在途响应；此前已完成的 RAM 写保留。不以每个 Cache 行清零掩盖未定义存储值。后端等待时 VALID/字段保持；CPU 响应回压不重复发请求或副作用。

12 个原 Cache counter 作为诊断输出，沿用原延迟事件边沿。它们不是新的 Stats MMIO ABI，`perf_cycle_events` 仍为原未接入的十位接口。不得宣称实现十类周期统计、FENCE.I、自修改代码、DMA 一致性、AXI、正式 SoC/板级接入或新的性能/资源/时序结论。

验收分为三层：adapter 前后端独立事务及 I/D Cache 参考模型；真实 core+adapter 的取消、FENCE、错误和 reset 边界；真实 IF 程序的四种 Cache 组合×ID/EX×BP×I/D 等待×前递矩阵。完整退休/WB/GPR/RAM、前端/后端账本、错误原 PC/有效地址、本地设备零外泄、hit/miss/refill、byte/halfword/write-through/noallocate/bypass、指定坏证据和真实 RTL 变异均按实测列出；未到达路径不冒称命中。

本阶段在独立目录从头重跑 S12 完整 CPU5 兼容链；最终仅在所有旧依赖 SHA 匹配时纳入其结果。新模块、新测试、合同和脚本的依赖 SHA 在运行前后相同，冻结保存规范 LF 与原始字节两种身份、原始日志/波形/刺激/实际坏源，以及逐 ZIP 条目摘要。按明确新文件清单本地提交，保留用户未提交工作，不推送、不下载。
