# CPU5 S14 AXI4-Lite 数据桥接合同

起始日期 2026-10-24，验收续跑日期 2026-10-25，基线 `88466d9764bd5c36265439720e28bebfd7c684c2`。仅新增独立 `cpu5_axi_lite_top`，连接原 `cpu5_cached_top` 的 external native D 后端与原 `dmem_axi_lite_bridge`。native I 后端仍暴露；外部连接 AXI4-Lite slave。原 CPU5/CPU3、Cache、桥、RAM、设备及正式 SoC/板顶全部保持原样。

封装完整保留 cachedtop 参数和非 native-D 观察端口，19 个 AXI 数据主端口与原桥逐项同名同向。`u_cached` 为原 cachedtop，`u_bridge` 为原桥，`native_dmem_*` 为二者之间的 Cache 后端描述符。`EXTERNAL_DMEM` 必须为 1；原 CPU5/Cache/CSR/IRQ 使能、范围和几何 guard 保持原合同，不复制旧三级 SoC 的额外地址限制。

CPU5 本地 MMIO 仍由 `u_cached.u_cpu` 截获，Cache 只接其 external D 口，AXI 桥位于 D Cache 之后。native 请求保留字节地址和 size；wdata/wstrb 已在核心一起移位，封装不再移位。桥接受时对 AXI 地址进行整字对齐；R 返回完整 32 位字，核心保留原地址用于 lane 提取与故障 tval。不要将 Cache refill 地址或 AXI 对齐地址误作原指令有效地址。

桥为原单 outstanding 状态机。native 接受后保存完整描述符；AWVALID/WVALID 各自独立呈现，不等待 READY，也不因另一个通道未完成而重复已经握手的通道。分别记住 AW/W 完成，两者都完成后等待 B；读为 AR 后等待 R。AW/W/AR 的 VALID 与 payload 在回压时保持。没有新的 AXI ID、多 outstanding、burst 或写缓冲。

原桥只将 B/R 响应 `00` 视为成功，`01/10/11` 均为错误；错误读数据归零。非法 native size/对齐/write strobe 在桥本地完成错误，零 AXI 访问。CPU5 自身的更早译码/范围错误仍按原精确 Trap 合同处理。

B/R 在原桥 WAIT_B/WAIT_R 中的 READY 不受 CPU 最终 response-ready 控制。桥捕获 AXI 响应后，在独立 CPU_RSP 槽保存数据/错误，直到 native 消费；此时不接受新请求，消费后才回 IDLE。需分别统计 AW/W/AR 等待、slave B/R 延迟、实际 B/R 有效保持、CPU 最终响应回压；不将 CPU 回压冒称长期 AXI B/R 回压，不为了得到覆盖数而违反 slave 的响应先后规则。

core D owner 直到 Cache 最终响应才完成；D Cache 的每个 refill beat/写穿透请求又要等待桥与 AXI 响应，所以原 FENCE 排空自然覆盖全部 AXI 操作。原 STORE/未知 I/O 的不可撤销授权、错误优先级、IRQ 安全边界、旧已退休 WB 和 killed RAM LOAD drain 不变。错误仍归属原 PC/有效地址，错误 LOAD 不写 GPR；已出现物理写的错误 STORE 不承诺回滚。

CPU、Cache、桥和外部 AXI slave 必须共享 reset。reset 取消协议状态，AXI slave 丢弃未配对 AW-only/W-only 和未完成响应；此前已经配对并完成的物理写保留。没有额外 transaction ID/generation 来屏蔽未共享 reset 的旧 slave 迟到响应，因此不能承诺该错误接法安全。

验收分层：旧独立 bridge BFM 与真实 AXI RAM 测试；Cache→桥→独立 slave 的 native/AXI/物理字节账本；core+Cache+桥 的故障/取消/FENCE/IRQ/reset；真实 cachedtop 经桥接真实 `axi_lite_ram` 的完整程序、原64配置×AW先/W先/同拍三顺序矩阵。每层均检查真实握手、保持、唯一性、错误与共享 reset，独立核对完整 RAM/GPR/退休/CSR/Cache counter；负例必须独立零告警编译后以指定语义拒绝。

本阶段从头重跑 S13 完整 CPU5 兼容链，最后仅在所有旧依赖 SHA 匹配时纳入。新代码/测试/脚本/合同原始及 LF 身份、实际私有坏源、原始刺激/CSV/日志/波形/物理状态按最终完整批次冻结。仅新文件白名单本地提交，保留用户脏工作区/未跟踪文件和正式 CPU3 release，不推送、不下载。

范围仍不含 D0 本地 RAM 路由、AXI4 burst、外部地址 fabric、Stats MMIO、正式 SoC/板顶、FENCE.I、自修改代码或 DMA 一致性。Cache 原计数仅诊断，十类周期事件未接入。无 CPU5 STA/P&R/资源/Fmax/CoreMark/板测与新性能结论。
