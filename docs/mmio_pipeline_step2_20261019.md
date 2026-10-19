# 本地 MMIO 请求打一拍：第2步验收

实现：仅 cpu_top.v 的产品 RTL 变化；完整地址、wdata、wstrb、size、write、is_mmio 先捕获，再在同一实际受理边沿完成全部写副作用、UART RX pop 和两份 pre-pop 数据捕获。
公开地址命中仅在 staged descriptor 有效时出现，避免旧地址影响后续 RAM 读监控。RAM/外部 D-Cache 不进入新拍。

统一回归：10/10 PASS；run_id=20261019T150018Z_21cddf577b03（包含25场景兼容组、Cache、BTB、timer/machine IRQ、AXI/CoreMark三配置双种子、周期分类及写平台）。
原 run_uart_rx.do PASS：32字节物理回显、32次RX读取、复位帧忽略。
定向对照：84笔非MMIO描述符/数据/四段延迟完全不变；12笔MMIO仅launch→accept和total各增加1拍。
MMIO合同：全部外设、完整描述符、同沿pre-pop、五类精确异常及GPIO/mtime/MSIP/UART读四类新拍复位取消通过；四进程0 Error/0 Warning。

双种子真实 CoreMark 最后START窗口：
smoke: data_write_wait=86094（不变）；data_read_wait=62719（不变）；周期 966808→966812（+4）；MMIO等待 6→12；退休=732299（不变）；逐STORE全阶段指纹 14349 笔不变。
smoke-validation: data_write_wait=85464（不变）；data_read_wait=63793（不变）；周期 1023002→1023007（+5）；MMIO等待 6→12；退休=785265（不变）；逐STORE全阶段指纹 14244 笔不变。

独立 performance P&R，50 MHz / 20 ns，多角最终 STA：
Slow Setup: 1.497→2.269 ns（+0.772）
Slow Hold: 0.162→0.153 ns（-0.009）
Slow Recovery: 13.080→13.065 ns（-0.015）
Slow Removal: 0.639→0.746 ns（+0.107）
Slow Minimum Pulse Width: 8.100→8.100 ns（+0.000）
Fast Setup: 6.947→7.560 ns（+0.613）
Fast Hold: 0.114→0.111 ns（-0.003）
Fast Recovery: 14.982→15.058 ns（+0.076）
Fast Removal: 0.478→0.537 ns（+0.059）
Fast Minimum Pulse Width: 8.480→8.480 ns（+0.000）

mtime/CE已离开两角最差Setup路径。mmio_rdata_q在前一步报告已不出现，本步保持，不能归因为本步首次移除。
所有角Setup/Hold/Recovery/Removal/Pulse均为正，无失败端点；此次记录变化，不据此承诺频率。

证据范围：本步仅完成timing，没有生成新位流，也没有下载板卡。正式CoreMark >=10s成绩尚未上板验证。
主工程默认programs/和旧build/产物保留；因RTL哈希变化，再跑真实CoreMark前须正常重建固件，或使用本次归档中匹配的firmware与对应报告。

执行记录：第一版公开hit保持旧地址被原CoreMark监控拒绝，相关PDS/回归已中止归档；修正后所有证据重新运行。补测TB首轮误将MMIO观察寄存器要求施加给RAM读，修正断言作用域后双版本均重跑通过，产品RTL未为此改变。
统一回归machine-irq首次编译等待已终止进程10964留下的库锁。确认旧PID不存在后，仅清理该实验库的_lock文件；本次case继续完成编译和完整PASS，相关等待警告保留在原始日志。未修改回归诊断规则或输入。

新增测试范围：六夹具的外部后端是同步模型，完整真实AXI回归另已通过。新增reset测试聚焦捕获后/实际受理前；已有接受后复位和响应等待覆盖保留在原回归。

下一独立实验：方案D0同步BRAM数据后端，D-Cache保持在前、soc层译码、保留AXI区域；按原计划限时4天并独立验收。

复跑定向测试：

```tcl
do run_mmio_stage_latency.do
do run_mmio_stage_contract.do
```

原版 `run_uart_rx.do` 和统一回归入口均保留。原基线比较使用 `38c6094`，在独立目录运行，合同入口可设 `mmio_expected_stage=0`，候选默认为1。

完整原始证据位于 `build/verification/mmio_step2_20261019/`；STA路径起止点、报告行号和SHA见 `sta_comparison.json`，逐笔延迟见 `targeted_results/verification_summary.json`。
