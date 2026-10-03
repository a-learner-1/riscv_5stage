# 指令 Cache 验证记录（2026-10-03 构建，2026-10-04 上板）

工程：`D:/FPGA/riscv_3stage`。基线提交：`e13eaea`。
2026-10-04 用户完成物理上板验证，确认串口、LED 和 KEY1 复位现象均正常。

| 检查 | 结果 |
| --- | --- |
| GCC 固件构建 | PASS；RV32I + Zicsr、ILP32、O2、Wall/Wextra/Werror |
| 硬件／仿真固件一致性 | 指令相同；RAM 仅心跳周期不同 |
| 两路 Cache 独立模型 | 快速／延迟 ROM 各 193 次检查；LRU、所有填充错误位置、随机访问、复位、背压及每周期一次命中通过 |
| AXI 统计设备 | 原子快照、AW/W 独立到达、只读错误响应、背压及复位通过 |
| 真实 IF + Cache | 旧路径错误丢弃、跳转／错误同拍、当前路径精确错误及 EX 停顿通过 |
| CPU 自检 RTL | 正常、延迟 ROM、ISR 内复位、真实 FAIL 后恢复四种场景通过 |
| Cache 关闭基线 | 原定时器板级、AXI CPU、异常 C、定时器 C 程序通过 |
| 固件构建保护 | 修改 ROM／仿真 RAM／源码以及错误时钟、Cache 开关、RAM 容量均被拒绝 |
| PDS 50 MHz | 综合、布局布线、最终 STA、比特流生成通过 |
| 综合网表功能仿真 | 50 MHz／115200；两次 13 字节 PASS、LED2 和 KEY1 再启动通过；无 SDF |
| 物理板验证 | PASS；2026-10-04 用户提供串口截图并确认全部现象正常 |

ROM 代码 6004 字节，默认 ROM 32 KiB、RAM 16 KiB。
Cache 为 2 KiB、两路、64 组、16 字节行、LRU。三个冲突函数地址
分别是 `0x400`、`0x800`、`0xC00`，映射到相同组、不同标签。

RTL 正常场景观察到请求 72839、命中 72330、缺失 509，错误 0。
这些数字属于自检程序的取指流量，不能作为 CoreMark 成绩或通用命中率。
所有 RTL 与基线 ModelSim 日志为 0 errors / 0 warnings。

PDS 布线报告慢角 setup WNS `+0.708 ns`；独立最终 STA 慢角 setup
WNS `+0.251 ns`、hold `+0.147 ns`，其余 setup/hold/recovery/removal/pulse-width
检查均通过。比特流生成后再次核对报告和 manifest，一致且满足约束。
时序余量仅对应当前 50 MHz 工程配置。

综合网表日志为 0 errors / 20 warnings。20 条告警均来自 PDS 自带
`GTP_DRM9K.v` 的 `vopt-2697`，指向文件初始化分支中的 `ini_mem` 位选。
综合网表的两个 Cache 数据 RAM 使用 32 位 `GTP_DRM9K`，均配置
`INIT_FILE="NONE"`；这些文件初始化语句不会执行。实际填充、冲突调用、
计数器、中断返回和两次串口 PASS 均通过。厂商模型保持原样，告警未屏蔽。

可复查的本地生成文件：

- `build/icache_rtl_test.log`
- `build/icache_disabled_regression.log`
- `build/icache_netlist_test.log`
- `build/icache_board_firmware/build_report.json`
- `build/pds_icache_board/build_manifest.json`
- `build/pds_icache_board/report_timing/board_top.rtr`

板级文件：`build/pds_icache_board/generate_bitstream/board_top.sbit`。
SHA256：`e774547c3eb617cb67eae2c0381c989d84f07362e07bba47a9fca05595860223`。

上板现象：115200／8N1 收到 `ICACHE PASS`，LED2 常亮、LED1 约每
0.5 秒切换；按下并释放 KEY1 后再次 PASS、心跳恢复。此步骤通过后，
继续实现两路数据 Cache。动态分支预测和完整异常／中断覆盖仍需后续完成。
尚未重测带 Cache 的 CoreMark，原 52.574739 分的基线不变。

## 2026-10-04 物理板验证

用户提供的 SSCOM 截图显示 COM8、115200 bps、8N1，完整收到 `ICACHE PASS`，接收计数 R:13、发送计数 S:0。截图展示一次完整 PASS。用户同时确认 LED2 常亮、LED1 心跳和 KEY1 复位后再启动现象均正常。

该结果是用户在实体板上的观察；构建脚本的自动 manifest 继续记录 `hardware_verified=false`，物理验证证据以本记录为准。带 Cache 的 CoreMark 尚未重测；两路数据 Cache、动态分支预测和完整异常／中断覆盖仍为后续任务。
