# CPU5 十类周期统计与 schema4/profile2 接口合同

日期：2026-10-25。实现基线：`102806a554a9ebee497289d4830e59d22bccbdef`（S15）。原 `cpu5_cycle_profile_contract.json` 保留为冻结设计依据；本文件补充本阶段实际实现规则，验收结果见同日期 Stats 阶段报告。

## 周期生产者

CPU5 活动流水线在每个 `rst_n=1` 边沿将 `cycle_count` 加一，同边沿注册一个十位 one-hot 事件。复位输出零。metadata-only scaffold 的 `cycle_count` 和事件均为零。当前核心没有另一个软件计数使能；外部级使能或 WB 暂停没有停止总周期计数，而由未归入有效等待原因的 `work_other` 计数。

十类位序沿用冻结 JSON：0 work/other、1 IF、2 数据读、3 数据写、4 本地 MMIO、5 重定向恢复、6 MUL、7 DIV/REM、8 load-use、9 其他 ID 依赖。分类是独立观察块，不反向控制任何流水动作。core 新增正规输出端口，原 CPU5 顶层和 Cache/AXI/D0 包装逐层传递十位；旧直接 core TB 只补显式空输出端口，以保留 `.*` 的 ModelSim 兼容性。

分类先筛除被年长动作或容量掩盖的原因，再按 local-MMIO、数据写、数据读、MUL、DIV/REM、load-use、其他 ID、redirect、IF、work 顺序选择。它不是各阶段 RAW/busy 状态的简单优先编码。

- MEM 数据等待要求 live MEM 的访存实际已拥有事务或本拍获准提出请求、MEM/WB 容量允许其推进、尚无 matching 完成；能够本拍退休或报 Trap 的最终响应边沿不算这类等待。
- FENCE 真实等待旧 D owner 排空，以及 EX 新纯 RAM LOAD 被旧 owner 占用而阻塞，也归对应 D 原因；FENCE 使用 pre-edge owner，因此最后 drain 边沿仍等待。后台 killed D 没阻塞当前工作时不计 D 等待。
- 本地 MMIO 按 CPU5 的 `0x20000000..0x200000ff` 分类。Stats、AXI、普通 RAM 均按非本地读/写计数；D0 本地 RAM 不属于 local-MMIO 类。
- M 等待要求当前 live EX M 指令确实等待资源或结果，且无更老风险/容量/源依赖阻挡。按当前指令 MUL/DIV 家族分类，不使用 `unit_busy` 代替所有权。零除等快路径也需要计入真实等待边沿；后台 killed M 排空时 ALU/CSR 仍能工作，不能误计 M 等待。
- ID 依赖按消费者实际使用的寄存器、最新匹配 writer 和前递路径是否可用判断。FWD 关闭时 RF 尚不能读取本拍 WB 写入；ID 分支路径没有 EX 到 ID 前递。LOAD 依赖和其余 RAW/CSR 串行分开计。
- ID/IF 归因还要求老 MEM 本拍可离开，不能因 EX 空槽或 `in_ready` 为真就越过老 MEM 的外部暂停/WB 阻塞。取指缺口只在无可用 IF/ID 包且有真实消费意图和下游容量时成立。
- winning redirect 开始恢复区间；新 redirect 优先，首个后续 ID 接受或外部 flush 清除。重定向动作边沿属于 work；后续符合 IF 消费条件的缺口才属于 redirect。恢复期间无真实供给缺口的周期不计 redirect。

## Stats 端点与窗口

新增 `axi_lite_cpu5_stats` 独立模块，保留原 `axi_lite_coremark_stats` schema3/profile1 六位模块、旧固件及旧 reader 原文。新硬件 `0x18` 返回 schema=4；新 C header 和 host reader 共同要求 profile=2、fields=10、counter_bits=64、window=0x200。profile 版本/位宽是软件构建合同，不能声称硬件提供了不存在的独立版本寄存器。

默认地址为 `0x30000000`。START/STOP 仍分别为 offset 0/4 的读触发，触发边沿为 AR valid&&ready；R 背压不重复采样。原普通计数/BP/几何参数地址保持；schema4 的 `0x1c` 始终返回明确后端身份 0（AXI RAM）或 1（D0），旧 schema3 的条件行为保持原样。所有写均 SLVERR，AW/W 可独立接受；不识别或不对齐的读返回 SLVERR。

| 字段 | START 低/高 | STOP 低/高 |
|---|---|---|
| 0..5 | `0x100+8*i` / `+4` | `0x140+8*i` / `+4` |
| 6..9 | `0x180+8*(i-6)` / `+4` | `0x1c0+8*(i-6)` / `+4` |

`0x130..0x13c`、`0x170..0x17c` 保留，不能把十字段解释成一条连续线性 bank。原模块的全部 16 个新增地址仍必须 SLVERR。

CPU 输出已注册事件；端点在下一个边沿消费它，触发边沿快照使用 `profile_next=旧计数+输入事件`，从而与该边沿看到的 CPU pre-edge `cycle_count` 对齐。64 位计数按模 2^64 加法；低高快照在打印期间稳定，读 bank 不重新采样。

最后一次 START 覆盖前次 START；测量接受条件是 raw_start>=1、selected_start=1、selected_epoch=raw_start、STOP=1，且正窗口内十类差分之和等于 cycle 差分。窗口跨 D/M owner 必须显式审计，不能偷偷排除边界周期或把事件次数当作等待周期。Stats 端点可消费任意 synthetic 位模式以便单元测试；CPU 真实 one-hot 和窗口总和由分类/程序/系统分层验证。

## 系统和验证边界

新增 `cpu5_stats_axi_lite_top` 组合 CPU5 D0 壳、原 native 同步取指端点、原 AXI 1x2 路由、AXI RAM 和新 Stats。共享复位；D0 开启时普通 RAM 不再进入 AXI RAM，Stats 仍通过 CPU 的真实有序 AXI 读访问。它没有接入正式板顶，也没有修改三级 SoC。

验证分层：定向 core 测试覆盖全部十类与掩盖/排空/快路径；端点单元覆盖 64 位进位/回卷、地址、背压和复位；384 程序配置保留 S15 独立 ISA/Cache/D0/AXI 金账并新增逐拍分类与独立读主机窗口；真实 RV32IM C 固件验证 CPU 自读 Stats、版本/身份、最后 START、一次 STOP、全部 profile bank 和冻结重读。前者原程序没有 DIV，不能把其 div_wait=0 称为漏计，DIV 非零覆盖由定向和 C 系统测试承担。

另有真实 M-owner 跨窗口套件：普通 MUL/DIV 在 owner 在途时触发 START/STOP；快路径 START 放在 owner 分配同边沿，STOP 在结果 owner 有效时；killed DIV 后台窗口不发新 M，其 MUL/DIV 差分必须为零。序号、世代、独立原语延迟和半开窗口账本与 D-owner 跨窗分开验证。

旧 S15/S14 原始证据逐条 SHA/CRC 与固定提交锚定。新增观察块、空测试端口及注释可严格逆变换回 S15；这只证明原功能文本保持，不冒称新旧全套同源或正式等价验证。原控制套件另做新源码实跑，程序完整矩阵另复用原架构金账重新验证。

本阶段不包含完整 CoreMark 验收、CPU5 P&R/STA、LUT/APM/Fmax、bitstream 或上板性能测量，不构成 A01–A16 全部签署。
