# CPU5 D0 片上数据 RAM 接入合同

日期：2026-10-25。基线：`aad84b44eae382cf243a4929a3114c5db6980198`（S14）。

本阶段增加独立 `cpu5_d0_backend` 和 `cpu5_d0_axi_lite_top`，复用原 CPU5、Cache、region router、同步 RAM 和 AXI4-Lite bridge。原模块源码不变。正式三级板顶及发布包不在本阶段替换范围。此文约束设计；实测结果见同日期阶段报告与冻结证据。

## 接口与默认行为

`ENABLE_D0_BRAM=0` 为默认值。关闭时 Cache 后的数据请求直通原 `dmem_axi_lite_bridge`；开启时由原 `dmem_region_router` 将普通 RAM 区间送往原 `soc_data_mem`，其他地址送往原 bridge。取指后端仍为 native IF。原 `cpu5_axi_lite_top` 不变。

`DMEM_BASE_ADDR`、`DMEM_WORDS` 在 CPU/Cache/路由/RAM 之间一致传递。D0 区间为 64 位计算的 `[BASE, BASE+4*WORDS)`；WORDS 必须为正、BASE 按词对齐、结束地址不超过 2^32，结束地址等于 2^32 合法。路由按首字节地址选择；大小、对齐和写掩码是否合法由端点判定。首字节落在 D0 的非法请求在 D0 返回 error，不能改走 AXI。

`DATA_FILE` 初始化本地 D0，默认空字符串沿用 `data_mem` 的初始清零；它不初始化外部 AXI 从设备。外部设备由集成方提供和初始化。D0 使用单独的 `D0_REQ_WAIT_CYCLES`、`D0_RSP_WAIT_CYCLES`；不把历史 `DMEM_*WAIT*` 参数重新解释为 D0 等待。

顶层要求 `EXTERNAL_DMEM=1`；D0 开启还要求 `SKELETON_ONLY=0` 且 `ENABLE_RAM=1`。D0 开关只接受 0/1。其他历史功能开关保持原语义。普通 MMIO/机器设备仍由 CPU 上游路由截获，不经过 Cache/D0/AXI 后端。

## 所有权与副作用

请求仅在 valid && ready 边沿接受，目标在接受时锁存，直到对应响应被消费。未选中的响应不能泄漏或被消费。路由没有同边沿完成旧响应并接受新请求的旁路。该约束适用于 D0 路由后端；Cache 命中仍遵守原 Cache 的接口时序，不能据此宣称全局访存 II 固定。

RAM 同步读，成功写仅在接受边沿产生一次物理 WE。响应等待、背压、重复呈现均不能重写；非法大小、对齐、掩码或越界请求不能产生 RAM WE/RE。原 Cache 为阻塞式、write-through/no-write-allocate，无脏行、写缓冲及 DMA 一致性功能。

CPU、Cache、D0、bridge 和外部从设备共享复位。复位撤销协议状态和未完成响应，已接受的物理 RAM 写保留且不回滚；RAM 数据不因复位重新初始化。独立复位外部设备不在合同范围。

核心的年龄、唯一 D owner、killed LOAD drain、STORE 不可撤销区、精确 Trap、IRQ 边界和 FENCE 规则沿用原合同。FENCE.I 仍非法。错误响应归属原请求，LOAD access fault=5，STORE access fault=7，保留原虚拟地址到 mtval。

## 验证边界

后端单元直接覆盖非法 D0 请求、地址上边界、背压、目标隔离、复位和物理写。核心已经对合法 RAM 请求的地址/形状做检查；配置一致时，软件发出的合法 RAM 请求不能自然制造 D0 端点错误。核心错误路径采用真实非 RAM AXI DECERR，不能用 force/deposit 注入一个不可达的 D0 错误后声称端到端覆盖。

程序矩阵为 ID/EX × BP × wait × forwarding × ICache × DCache × 三种 AW/W 顺序 × D0 开关，共 384 组。D0 开启的程序仍包含非 RAM LOAD/STORE，以验证 AXI 旁路和精确错误；同时检查完整 RAM、已定义 GPR、Cache 标签/计数、每条 native/AXI 请求与响应、物理 WE，以及本地和外部两个 RAM 的独立终态。

旧 S14 兼容性使用固定提交中的完整冻结原始证据复核：逐文件 manifest、ZIP 全条目 SHA/CRC、212 份依赖规范 LF 一致，以及原编译/日志/波形引用。这是原实测证据复用，不记为本阶段重新运行旧全套仿真。新 D0 开关矩阵和新控制/后端套件必须重新仿真。

本阶段没有十类周期分类 Stats、完整 SoC fabric、CPU5 CoreMark 性能、P&R/STA、资源/Fmax 或上板测量，不构成 A01–A16 全部签署。功能仿真的 50 MHz 时钟不构成时序收敛证明。
