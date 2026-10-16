# AXI 路由与 RAM 零等待延迟优化

2026-10-16，在现有三级 RV32I、双 Cache、BTB 和 schema 3 周期统计基础上，压缩 AXI4-Lite 路由与 RAM 端点的额外状态等待。端口、地址布局、单笔事务限制、Cache 写穿透策略和 CPU 精确访存异常处理沿用原实现。

## 修改内容

1. `axi_lite_1x2` 在接受 AW/W 最后一个通道的边沿完成写配对。AW 已经接受时使用锁存地址；AW 本拍才接受时使用本拍地址。下一周期仍由寄存的地址、数据和路由驱动下游 VALID，AW/W 各自独立握手。
2. `axi_lite_ram` 在 `B_WAIT_CYCLES=0` 时，真实写提交边沿同时寄存 BRESP 和 BVALID。有效地址写入完成后才返回成功；非法地址返回 DECERR 且不写 RAM。
3. `axi_lite_ram` 在 `R_WAIT_CYCLES=0` 时，同步 RAM 读数据捕获边沿同时寄存 RDATA 和 RVALID。RREADY 拉低时继续保持原响应，不跟随后续 RAM 写入而变化。

非零 `B_WAIT_CYCLES`／`R_WAIT_CYCLES` 保持原实现的周期关系。AW／W／AR 接受等待、共享单端口读写优先级、复位取消协议状态及已完成 RAM 写入保留的规则保持原样。CPU 仍等待真实响应；本步骤没有增加提前退休的写缓冲。

## 延迟口径

| 观察范围 | 原实现 | 本次实现 |
| --- | --- | --- |
| 路由器：最后一个 AW/W 握手后，下游写 VALID 出现 | 多一个配对空周期 | 握手边沿更新寄存状态，随后的周期即可呈现 VALID |
| RAM：最后一个 AW/W 握手到首次 BVALID，B_WAIT=0 | 2 个周期 | 1 个周期 |
| RAM：AR 握手到首次 RVALID，R_WAIT=0 | 2 个周期 | 1 个周期 |
| RAM：B/R_WAIT=N，N>0 | N+2 个周期 | N+2 个周期 |

表中 RAM 延迟从请求接受边沿计到首次响应 VALID 在 NBA 后可见的边沿，不等于完整 CPU 访存延迟，也不包含接收方继续拉低 READY 的时间。路由器改善的是配对后转发延迟，不表示每拍都能接受新事务。

## 验证命令

在 Git Bash 中执行定向仿真：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c run_regression.bat --group axi-latency
```

也可在 ModelSim Transcript 执行 `do run_axi_latency.do`。入口依次运行真实 AXI RAM、1x2 路由器、0/1/3 等待延迟测试、CPU 桥、CPU 集成、DCache 故障及真实 trap C 程序共七个自检平台。定向延迟平台不依赖新 GCC 固件；其它平台使用既有 `c_demo`／`trap_demo` 和空白测试镜像。

对三配置、两种子重新构建六个短程 CoreMark 固件后验证：

```bash
cmd.exe //c build_coremark_compare.bat --profile smoke
cmd.exe //c build_coremark_compare.bat --profile smoke-validation
cmd.exe //c run_regression.bat --group coremark-axi-profile
```

RTL 输入哈希发生变化，原 CoreMark 固件报告不再与本版本匹配，必须重建；原正式位流及成绩继续属于旧版本。新增精确延迟断言从公开 AW/W/AR 握手和 B/R VALID 测量，覆盖三种写通道到达顺序、背压、数据稳定、非法地址、部分字节写、复位及单次读写效果。

后续正式测量仍需重建 performance／validation、检查新 PDS 时序并下载匹配位流，步骤见 [周期统计说明](cycle_profile.md)。这次短程结果不能作为正式上板 CoreMark 成绩。

## 参考与实现范围

研究时参考了 [PicoRV32 的 AXI 适配器](https://github.com/YosysHQ/picorv32/blob/main/picorv32.v) 与 [wb2axip 的独立通道／背压设计](https://github.com/ZipCPU/wb2axip)。本次修改基于本工程现有状态机，CPU 端仍保留响应寄存及真实错误传播，未替换处理器或复制外部 IP。

## 本次验证记录

2026-10-16 在隔离源码副本完成以下 ModelSim 验证，随后按文件 SHA-256 核对并写入主工程：

- 专项 `20261016T063527Z_53c4f9c7ccfa`：七个测试平台全部 PASS，涵盖三个 RAM 等待配置、AW/W 三顺序、两个从设备地址窗口、非法访问、背压、部分字节写、单次读写、共享复位、CPU 故障及 Cache 写错误恢复。
- 回归 `20261016T063602Z_98b283fa6b3e`：25 项旧 CPU 完整兼容、机器定时器／外部／软件中断，以及三配置×两种子的六个真实 C 短程用例全部 PASS。每项运行前后输入哈希保持不变。
- 用旧 RTL 分别运行新增 RAM 延迟断言和路由配对断言，均检出预期额外等待，证明测试能区分本次优化。

与上一轮周期统计版本 `20261016T020723Z_2f6673df0bbe` 比较，六种配置各自的 ROM、初始 RAM 及配置头 SHA-256 完全相同，退休指令数一致：

| 短程固件 | 原窗口周期 | 新窗口周期 | 周期减少 |
| --- | --- | --- | --- |
| axi_cache_off_smoke | 1312231 | 1228524 | 6.379% |
| axi_cache_off_smoke_validation | 1380120 | 1296197 | 6.081% |
| axi_cache_on_smoke | 1088673 | 1058787 | 2.745% |
| axi_cache_on_smoke_validation | 1155173 | 1125375 | 2.580% |
| axi_cache_on_btb_smoke | 1010869 | 981022 | 2.953% |
| axi_cache_on_btb_smoke_validation | 1066832 | 1037099 | 2.787% |

这些是单次短程仿真的同固件对照。它们验证功能及等待周期变化，不构成正式成绩，也不代表新版本已通过物理时序。完整比较与构建身份见 `build/verification/axi_latency_20261016/summary.json`，专项及回归日志位于相应 `build/regression/<运行编号>/`。**当前状态（2026-10-16）：功能仿真通过；响应路由时序修复后，双 Cache＋BTB performance／validation 的 50 MHz PDS 最终时序均已通过，正式上板跑分待验证。**

本轮最终报告 `build/pds_coremark_axi_cache_on_btb_performance/report_timing/board_top.rtr`（2026-10-16 17:57）记录慢角 Setup WNS 为 **−0.523 ns**，11 个失败端点。该目录原有 `board_top.sbit` 与 `build_manifest.json` 仍是当日 09:17 的旧产物，不能作为本次优化的通过证据。后续先修复时序，再重新生成并验证 performance／validation 配套位流；历史板级成绩保持原版本归属。

后续修复将 CPU 响应来源改为已捕获事务的 `mem_mmio_q`，请求侧与总线延迟保持原样。两个正式固件配置均通过最终时序，Setup WNS **＋1.300 ns**、最小 Hold 裕量 **＋0.026 ns**；六个短程窗口周期及退休数与修复前一致。以上失败记录作为首次尝试保留，最新报告和版本边界以 [时序修复记录](timing_fix_20261016.md) 为准。
