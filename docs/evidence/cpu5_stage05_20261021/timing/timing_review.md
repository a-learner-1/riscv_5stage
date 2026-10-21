# CPU5 阶段 0.5-C：三级 RV32IM 最终路由 Top-3

2026-10-21。按 `cpu5_arch_spec_v0_3.md` §8.4 提取现有最终报告；本次未运行新 STA、P&R 或板测，未修改 RTL 或约束。

**已验收的 RV32IM performance 最慢路径是 `instr_x[26] → 译码/ALU → 对齐/异常/IRQ 选择 → redirect_pc_x → I-cache 查找与响应/状态`。Slow Top-3 的布线占 59.1%–61.0%，没有经过 M 单元 APM 或乘积高半修正。** 这只定位本报告的全局 Top-3，不证明乘法器所有路径都快，也不决定 CPU5 ID/EX 解析级。

## 来源与复核

冻结项目：`C:/Users/23123/.codex/visualizations/2026/10/19/01a151db-bb68-7633-bd17-5c52d2aa2890/m1/build/pds_coremark_d0_m_cache_on_btb_performance/`。

| 文件 | SHA-256 |
|---|---|
| `report_timing/board_top.rtr` | `e9f50dfa8f1be039b4056225b87cfa36deec7e9682f0fdaa396bcccdf1702dd3` |
| `place_route/board_top_pnr.adf` | `abd2ea9b0ca22a6a48324e40908e5e165d17223129d6cd0f0f6c6f2d1aeae618` |
| `build_manifest.json` | `beebad0c7874d6001997ee164d4241202dc7e1f8d74b87cc07d7c66adebe7e9c` |
| `pds/board_top.fdc`（冻结源目录） | `b2568c07d9d9c2cab16aa46aa1ebf923c05edd96c602f10411ac86875c76c1e3` |

工具为 Fabric Compiler 2022.2-SP6.4 build 146967；报告时间 Tue Oct 20 23:12:57 2026；器件 PGL50H-6 / FBG484。`final_sta_from_bitstream_flow=true`，P&R 种子均为 1。这里使用最终 `report_timing/board_top.rtr`，不使用 router 过程报告的 WNS。

只读分析器 `analyze_cpu5_routed_timing.py` 已实际执行并 PASS：报告与 route SHA、manifest 的八行最终签核、两角各四类各三条共 24 条路径全部闭合；31 份冻结源码/约束原始 SHA 与 manifest 一致，当前仓库同文件 LF 归一后完全相同。每条路径另校验 cell/route 逐弧求和、data arrival、clock skew、required/arrival/slack 关系及排序。`board_top.rtr.gz` 解压后为原始报告字节；JSON 保留全部端点、原报告行号、数据路径逐弧与时钟字段。

## Setup Top-3

所有六条路径共同起点为 `u_soc/u_core/u_cpu/u_if_stage/instr_x[26]/opit_0_inv_L5Q_perm/CLK`，Path Group 为 `clk_50m`，Path Class 为 sequential timing path。终点前缀 `I$ = u_soc/u_core/g_icache.u_cache/`。

| 角 / 排名 | 终点（接 I$ 前缀） | Slack ns | PDS 逻辑级数 | 数据总延迟 ns | Cell ns | Route ns | 原报告行 |
|---|---|---:|---:|---:|---:|---:|---:|
| Slow 1 | `state_reg[3]/opit_0_inv_L5Q_perm/L4` | +1.269 | 21 | 18.524 | 7.489 | 11.035 | 125 |
| Slow 2 | `state_reg[1]/opit_0_inv_L5Q_perm/L4` | +1.860 | 19 | 17.933 | 6.997 | 10.936 | 226 |
| Slow 3 | `rsp_rdata/opit_0_inv_MUX4TO1Q/I0` | +1.961 | 20 | 17.787 | 7.279 | 10.508 | 321 |
| Fast 1 | `state_reg[3]/opit_0_inv_L5Q_perm/L4` | +6.810 | 21 | 13.028 | 6.165 | 6.863 | 1091 |
| Fast 2 | `state_reg[1]/opit_0_inv_L5Q_perm/L4` | +7.158 | 20 | 12.694 | 5.950 | 6.744 | 1192 |
| Fast 3 | `rsp_rdata/opit_0_inv_MUX4TO1Q/I0` | +7.215 | 20 | 12.591 | 5.992 | 6.599 | 1291 |

Cell 为 PDS 打印的 `Logic`，包含 launch tco；数据总延迟为 Logic+Route，**不含时钟插入延迟**。例如 Slow 1 arrival=23.951 ns，launch clock delay=5.427 ns，所以 data delay=18.524 ns。不能把 23.951 ns 当数据组合延迟。

时钟源端口 `clk_50m`，20.000 ns，波形 `{0.0000 10.0000}`，6,610 clock loads。Setup 均为上升沿到下一上升沿，时钟 uncertainty 的报告带符号贡献为 -0.050 ns。

| 角 / 排名 | Launch clock ns | Capture clock ns | CPR ns | Skew ns | Setup time（带符号）ns | Required ns |
|---|---:|---:|---:|---:|---:|---:|
| Slow 1 | 5.427 | 5.095 | +0.296 | -0.036 | -0.121 | 25.220 |
| Slow 2 | 5.427 | 5.095 | +0.296 | -0.036 | -0.121 | 25.220 |
| Slow 3 | 5.427 | 5.095 | +0.296 | -0.036 | -0.166 | 25.175 |
| Fast 1 | 3.367 | 3.165 | +0.183 | -0.019 | -0.093 | 23.205 |
| Fast 2 | 3.367 | 3.165 | +0.183 | -0.019 | -0.079 | 23.219 |
| Fast 3 | 3.367 | 3.165 | +0.183 | -0.019 | -0.125 | 23.173 |

Slow 1 的可见数据网依次包括 `imm_x[6]`、`is_srai_x`、`alu_b_x[1]`、`alu_result_x[1]`、`dmem_req_addr[1]`、`irq_event`、`trap_event`、`redirect_pc_x[8]`、`imem_req_addr[8]` 和 I-cache tag0/比较/FSM。Slow 2 的 I-cache 末段偏向地址/范围和 miss-event 决策；Slow 3 的末段进入响应数据选择。其共同前缀指向“EX 译码/地址与异常选择到重定向取指查找”的跨模块组合链。

## Hold Top-3

端点采用报告的逻辑引脚名，不能用物理引脚 CE 的名字改写成用户 RTL 的写使能端口。

| 角 / 排名 | 起点 → 终点（前缀 `u_soc/u_core/`） | Slack ns | PDS 逻辑级数 | Cell ns | Route ns | Data ns | 原报告行 |
|---|---|---:|---:|---:|---:|---:|---:|
| Slow 1 | `u_cpu/wb_rd[4]/.../CLK` → `u_cpu/u_regfile/regs_11/ram32x1dp/WADM4` | +0.026 | 0 | 0.224 | 0.218 | 0.442 | 420 |
| Slow 2 | `u_cpu/wb_rd[4]/.../CLK` → `u_cpu/u_regfile/regs_19/ram32x1dp/WADM4` | +0.080 | 0 | 0.224 | 0.272 | 0.496 | 477 |
| Slow 3 | `g_dcache.u_cache/addr_q[8]/.../CLK` → `g_dcache.u_cache/tag1_0_0/ram32x1dp/WADM4` | +0.172 | 0 | 0.224 | 0.357 | 0.581 | 534 |
| Fast 1 | `u_cpu/wb_rd[4]/.../CLK` → `u_cpu/u_regfile/regs_11/ram32x1dp/WADM4` | +0.022 | 0 | 0.180 | 0.154 | 0.334 | 1390 |
| Fast 2 | `u_cpu/wb_rd[4]/.../CLK` → `u_cpu/u_regfile/regs_19/ram32x1dp/WADM4` | +0.056 | 0 | 0.180 | 0.188 | 0.368 | 1447 |
| Fast 3 | `g_dcache.u_cache/addr_q[8]/.../CLK` → `g_dcache.u_cache/tag1_0_0/ram32x1dp/WADM4` | +0.123 | 0 | 0.180 | 0.251 | 0.431 | 1504 |

上表起点中的 `...` 均为 `opit_0_inv_L5Q_perm`。0 级逻辑仍含 launch tco，不等于零延迟。Hold 都是同上升沿约束，uncertainty 贡献 0.000 ns。

| 角 / 排名 | Launch clock ns | Capture clock ns | CPR ns | Skew ns | Hold time ns | Required ns |
|---|---:|---:|---:|---:|---:|---:|
| Slow 1 | 5.095 | 5.427 | -0.296 | +0.036 | 0.380 | 5.511 |
| Slow 2 | 5.095 | 5.427 | -0.296 | +0.036 | 0.380 | 5.511 |
| Slow 3 | 5.095 | 5.427 | -0.303 | +0.029 | 0.380 | 5.504 |
| Fast 1 | 3.165 | 3.367 | -0.183 | +0.019 | 0.293 | 3.477 |
| Fast 2 | 3.165 | 3.367 | -0.183 | +0.019 | 0.293 | 3.477 |
| Fast 3 | 3.165 | 3.367 | -0.187 | +0.015 | 0.293 | 3.473 |

## RTL 定位与 CPU5 决策边界

下列行号以当前仓库为准，与冻结源 LF 归一后相同。优化后的网名存在逻辑共用；这里只按报告中的实际网和 RTL 公式定位，未做门级功能敏化证明。

| 候选 | 当前证据 | 对 CPU5 的含义 |
|---|---|---|
| 译码/ALU → 异常/IRQ → 取指重定向 | 两角 Setup Top-3 均出现。`cpu_top.v:967` ALU B，`:816` 地址对齐，`:821` EX 异常，`:843` 同步 Trap，`:851` IRQ 抑制，`:874` 重定向地址；`if_stage.v:145` 取指地址；`instr_cache.v:34` tag hit、`:93` 地址判定、`:97` hit 与响应/FSM | 五级中显式切开阶段和异常/重定向合同值得优先设计；不能单独据此锁死 ID 或 EX 解析，也不能随意删除异常判断 |
| `rv32m_unit` APM 乘积/高半修正 | `rv32m_unit.v:65`、`:69` 是实际候选，但本报告 Top-3 Setup/Hold 均未经过这些单元 | 专项 WNS 未提取，不能把跨构建 Setup 1.178 ns 的差值归到乘法器，也不能声称其可达某频率 |
| `instr_x → decode → stall_x → IF` | 当前 Top-3 经过 decode 与 IF 地址，但没有名为 `stall_x` 的数据网；可见主链为 Trap/IRQ/redirect 选择。`cpu_top.v:1334` 与 `if_stage.v:138` 的 stall 控制仍是候选 | 区分已出现的 redirect 链与尚无专项路径数字的 stall 链 |
| D-cache tag/rsp | Setup 中出现优化器命名的 `g_dcache...addr_q[1].../Z`，随后为 `dmem_req_addr[1]`；这不等于 D-cache tag/响应主导。Hold 排名 3 确实为 D-cache tag 写地址 | 新 CPU5 必须同时检查最短路，不能只看 Setup；D-cache Setup 专项 WNS 未提取 |
| BTB / CPU5 ID branch | 六条 Setup 中无 BTB 资源；CPU5 ID branch 尚未实现 | BTB/ID 专项 WNS、CPU5 50 MHz A/B 均 NOT RUN |

最终签核摘要保留原值：Slow/Fast Setup `+1.269/+6.810 ns`，Hold `+0.026/+0.022 ns`，Recovery `+12.511/+14.626 ns`，Removal `+0.771/+0.548 ns`，Pulse Width `+8.100/+8.480 ns`。对应端点失败数均为 0。约束是 50 MHz；报告工具估算频率不作为 CPU5 已验证 Fmax。

## 复跑

```powershell
python -B analyze_cpu5_routed_timing.py `
  --build '<冻结 m1>/build/pds_coremark_d0_m_cache_on_btb_performance' `
  --source-root '<冻结 m1>' `
  --compare-root 'D:/FPGA/riscv_3stage' `
  --out '<独立结果目录>'
```

分析器仅用 Python 标准库，读取已有报告/route/源码；不调用 PDS，不写原冻结项目。`routed_timing.json` 是完整机器可审计结果，包含四种约束的全部 24 条路径，正文仅展示要求的 Setup/Hold。
