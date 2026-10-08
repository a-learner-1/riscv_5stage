# 双 Cache 验证记录（2026-10-07）

工程：`D:/FPGA/riscv_3stage`；开发基线：`7e6182d`。本步骤增加两路数据 Cache 及独立 `dcache_board` 版本，同时开启两路指令 Cache、最小 M 模式同步异常和机器定时器中断。实物上板验收待用户确认，构建 manifest 保持 `hardware_verified=false`。

## 固件与 RTL 验证

| 检查 | 结果与范围 |
| --- | --- |
| GCC 固件构建 | PASS；xPack GCC 15.2.0、RV32I + Zicsr、ILP32、O2、Wall/Wextra/Werror |
| 硬件／仿真固件一致性 | PASS；指令二进制及符号相同，RAM 仅心跳周期 25,000,000／2,000 不同 |
| 数据 Cache 独立模型 | PASS；快速／延迟后端各 310 次独立参考模型请求，含 240 次可重复随机访问 |
| Cache 边界与协议 | PASS；两路冲突／LRU、子字写命中、写缺失不分配、请求／响应背压、全部四个填充错误位置、部分提交写错误、共享复位 |
| MMIO 旁路 | PASS；副作用读取每次只触发一笔后端访问，重复读取返回不同值；旁路写只执行一次 |
| AXI 统计设备 | PASS；七计数器同拍快照、独立 AW/W 到达、只读写错误、无效读取、背压与复位 |
| 真实 CPU 访问故障 | PASS；快／慢加载错误和快／慢存储错误四组；精确原始 PC/tval、加载不写回、故障指令不退休、MRET 恢复、部分写入后的重新填充 |
| 真实异常 C 固件，I/D Cache 开启 | PASS；快、AW 先到、W 先到三组；四次同步异常与寄存器恢复、CSR/FENCE、RAM 日志、UART42 |
| 真实板级 C 固件，I/D Cache 开启 | PASS；正常、延迟 ROM/RAM、ISR 内复位、真实 FAIL 后恢复四组；每组检查两次启动 |
| 指令 Cache 时序修正 | PASS；快速／延迟后端各 195 次模型检查，另检查每拍命中与交替路命中后立即同组缺失的 LRU 前递 |
| D-cache 关闭兼容回归 | PASS；指令 Cache 单元／板级、定时器板级、异常 C、AXI 控制系统、定时器 C |
| 新固件构建保护 | PASS；配套配置接受，缺失报告、镜像／符号／源码修改、错误时钟／容量／开关／写策略被拒绝 |

新增测试与兼容回归 ModelSim 日志均为 0 errors / 0 warnings。主自检结束标志为 `DCACHE ALL TESTS PASS`，兼容回归为 `DCACHE DISABLED BASELINE ALL TESTS PASS`。

板级固件保留原定时器自检的三次 IRQ／MRET、x1..x31 保存与恢复、屏蔽后挂起、2048 步主程序运算和校验和 `0x569EA33C`。新增 RAM 冲突读写结果为 3520，指令冲突函数结果为 704；SB/SH 后缓存和后端 RAM 均得到 `0xBEEFA500`，有符号／无符号子字加载均检查。

普通 RTL 场景的稳定快照：请求 6168、读命中 560、读缺失 180、成功填充字 720、RAM 写请求 5419、旁路 9、错误 0。满足 `6168 = 560 + 180 + 5419 + 9`。这些是自检程序流量，不能作为 CoreMark 分数或通用命中率。

ROM 代码 6500 字节、初始化数据 44 字节。D-cache 冲突数组 A/B/C 地址分别为 `0x00011400`／`0x00011000`／`0x00010C00`，映射到同组、不同标签；字节写测试缓冲区为 `0x00010800`。ROM/RAM 仍为 32 KiB／16 KiB。

## PDS 资源与时序

PDS 2022.2-SP6.4、PGL50H-6IFBG484、50 MHz；未更改已有时钟与引脚约束。综合、布局布线、独立最终 STA 和位流生成通过。位流生成后再次核对当前报告、manifest 与输入文件 SHA256，结果一致。

数据 Cache 的八个逻辑 256 × 8 位数组映射为 `GTP_DRM9K`，采用同步读及字节写使能；两路指令 Cache 的两个 256 × 32 位数组也映射为 `GTP_DRM9K`。没有将 Cache 数据阵列实现为大量触发器或 LUT RAM。

| 资源 | 使用／可用 |
| --- | --- |
| DRM | 37／134 |
| CLMA LUT | 2979／25800 |
| CLMS LUT | 1744／17000 |
| 分布式 RAM | 108 个，用于小型标签／其他存储 |
| DSP/APM | 0／84 |

| 时序检查 | 布线摘要 | 独立最终 STA |
| --- | --- | --- |
| 慢角 setup WNS | +1.214 ns | +0.823 ns |
| 慢角 hold WHS | +0.012 ns | +0.032 ns |
| 快角 setup WNS | +6.783 ns | +6.477 ns |
| 快角 hold WHS | +0.011 ns | +0.026 ns |

最终 STA 的 setup、hold、recovery、removal、pulse-width 两个角检查均通过，违例端点为 0。时序结论对应当前 50 MHz 约束；日志仍保留已有异步按键／UART／LED 端口缺少外部时序约束等工具告警。

## 综合网表与实物状态

综合网表功能仿真 PASS：两次启动均完整收到 13 字节 `DCACHE PASS`，PASS LED 与 KEY1 再启动检查通过；结束时间为 8,422,730 ns。使用硬件 ROM/RAM 初始化、实际 50 MHz／115200 UART、KEY1 默认约 1 ms 释放延时，不修改 RAM，不加载 SDF。完整 0.5 秒心跳周期使用仅缩短心跳常量的 RTL 测试覆盖。

综合网表日志为 0 errors / 20 warnings。20 条均为 `vopt-2697`，来自 PDS 自带 `GTP_DRM9K.v` 的文件初始化分支 `ini_mem` 位选。Cache RAM 均配置 `INIT_FILE="NONE"`，这些文件初始化语句不执行。厂商模型保持原样，告警未屏蔽；实际填充、冲突访问、计数器、IRQ/MRET 和两次完整串口 PASS 均通过。

位流：`build/pds_dcache_board/generate_bitstream/board_top.sbit`。
SHA256：`58ead407ee1821ccbf653f84eccdef8e6719ff79fb7d1e3a2e922aad95eb2999`。

上板验收预期：115200／8N1 收到完整 `DCACHE PASS`（13 字节），LED2 常亮、LED1 约每 0.5 秒切换、LED3 不亮；KEY1 重启后再次 PASS。当前尚无该双 Cache 位流的用户实物记录。

## 复查入口

- `build/dcache_board_firmware/build_report.json`
- `build/dcache_complete_validation.log`
- `build/dcache_lru_validation.log`
- `build/dcache_netlist_validation.log`
- `build/pds_dcache_board/build_manifest.json`
- `build/pds_dcache_board/synthesize/apm_drm_lutram_utilization.log`
- `build/pds_dcache_board/place_route/board_top_timing_summary_after_hold_fix.txt`
- `build/pds_dcache_board/report_timing/board_top.rtr`

构建与操作命令见[数据 Cache 说明](dcache.md)。带 Cache CoreMark 尚未重测；原无 Cache 基线仍为 52.574739 CoreMark、1.051494774 CoreMark/MHz。动态分支预测、完整异常／中断与真实 CNN 联调仍需后续完成。
