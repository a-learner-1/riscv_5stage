# 50 MHz 响应路由时序修复（2026-10-16）

## 原问题与修改

提交 `8777e7b` 的六类周期统计与 AXI 低延迟组合版本，首次 performance 构建的慢角 Setup WNS 为 −0.523 ns，有 11 个失败端点。最差路径从 EX 指令寄存器经过译码、地址生成、响应来源选择与异常／重定向控制，到 IF 的请求预测元数据使能。

`rtl/cpu_top.v` 新增组合线 `mem_rsp_external`，使用现有事务描述符 `mem_mmio_q` 选择响应 valid、data、error，并路由外部／本地响应 ready。请求侧仍允许首个 EX 周期发起请求。`mem_rsp_ready` 已要求 `mem_active && req_sent`，有效响应到达时事务描述符已经捕获；因此无需增加寄存器或等待周期，精确访存异常、MMIO 单次副作用和 FENCE 排序规则保持原样。时钟约束仍为 50 MHz，没有添加假路径或多周期例外。

构建脚本同时补充位流生成后的时序复查：PDS 的 `gen_bit_stream` 入口可能重新执行综合、布局布线和 STA，因此必须读取该轮新产生的报告，不能沿用位流生成前缓存的检查结果。最终报告、布线数据库与位流哈希分别记录。

## 无需上板的验证

隔离副本运行基础 CPU 25 项、BTB、定时器及机器外部／软件中断、周期分类、AXI 低延迟、I-cache、D-cache 和六种真实 C 短程 CoreMark。九个回归场景均获得 PASS，运行前后输入保持不变。

- 首轮 `20261016T131943Z_8d47276310aa`：七项 PASS；I-cache／D-cache 因隔离目录缺少固件构建报告标为 BLOCKED，原始汇总保留该状态。
- 补建两份 Cache 固件后，`20261016T132622Z_dc37b13eac92` 的 I-cache／D-cache 均 PASS。
- 两轮使用同一份修改后 CPU 源码；输入哈希、原始汇总及日志均归档。六种短程的窗口周期依次仍为 1228524、1296197、1058787、1125375、981022、1037099，退休数仍为 732299／785265。这些短程结果用于功能与周期一致性检查，不是正式性能成绩。

## 最终 PDS 结果

器件 PGL50H-6IFBG484，PDS 2022.2-SP6.4，时钟周期 20 ns。performance 与 validation 均为双 Cache＋64 项 BTB、schema 3，ROM 32 KiB／RAM 16 KiB。

| 固件配置 | 慢角 Setup WNS | 两角最小 Hold WHS | Setup／Hold／Recovery／Removal／脉宽 | 本次生成物 |
| --- | --- | --- | --- | --- |
| performance | ＋1.300 ns | ＋0.026 ns | 全部通过 | 匹配位流与最终报告 |
| validation | ＋1.300 ns | ＋0.026 ns | 全部通过 | 最终时序报告，未生成新位流 |

performance 位流生成流程中的第二轮 STA 与构建清单记录的数值一致，报告晚于最终布线数据库、早于位流；相关文件按 SHA-256 关联。

本地归档根目录为 `build/verification/timing_fix_20261016/`，包含 `summary.json`、两个原始回归目录、`before/board_top.rtr`、`pds_performance/`、`pds_validation/` 与配套固件证据。`installation.json` 记录隔离副本到主工程的文件哈希。归档保留真实隔离路径，不将其改写为主工程执行记录。

## 版本与后续使用

本次未下载 FPGA、未写 Flash、未执行新版正式 performance／validation 上板运行。历史 49.603719 CoreMark 继续属于旧版本，不能据此宣称新分数。

主工程默认 `build/pds_coremark_axi_cache_on_btb_*` 路径中的历史产物保持原样。以后上板时，应重新构建匹配当前源码的固件和位流，或使用上述归档明确配对的 performance 位流；validation 仍需先生成位流。未来构建步骤见 [周期统计说明](cycle_profile.md)。
