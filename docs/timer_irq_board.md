# MES50HP 定时器中断板级自检

本版本使用自研 CPU、AXI4-Lite RAM 和原有机器定时器；顶层固定开启
`ENABLE_TRAPS=1`、`ENABLE_TIMER_IRQ=1`，50 MHz、UART 115200、ROM 32 KiB、RAM 16 KiB。

程序先验证全局中断屏蔽时 MTIP 可挂起，再开启 MTIE/MIE，响应三次机器定时器中断。
每次记录 cause/PC/tval/status/64 位时间，处理函数返回原 mepc，由原有汇编入口恢复寄存器并 MRET。
主程序执行 2048 次 checksum 更新，期望结果 0x569EA33C，再检查日志、次数、时间间隔及中断关闭状态。
成功后停止中断自检并持续输出 LED 心跳；本版本没有测试外部中断、嵌套中断或 WFI。

## 构建与下载

在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_timer_irq_board.bat
cmd.exe //c build_pds_board.bat --variant timer_irq_board --firmware timer_irq_board --stage bitstream
```

两条命令均成功后，PDS 下载器选择
`build/pds_timer_irq_board/generate_bitstream/board_top.sbit`，通过 JTAG 下载到 SRAM。
生成工程为 `build/pds_timer_irq_board/board_demo.pds`。构建程序会先检查布局布线和最终 STA
的 setup/hold/recovery/removal/pulse-width，再生成位流。工程脚本只构建，不执行硬件下载。

打开 SSCOM，选择板子的串口（此前为 COM8），115200、8N1、无流控；先打开串口，再按 KEY1。

- 成功：每次启动输出一行 `TIMER IRQ PASS`；LED2 常亮，LED1 每约 0.5 秒翻转，LED3 熄灭。
- 失败：输出 `TIMER IRQ FAIL XXXXXXXX`，LED3 常亮；保存完整错误码用于定位。
- 再按 KEY1：灯暂时熄灭，重新完成三次中断自检，再输出 PASS 和恢复心跳。
- 在自检中按 KEY1：取消当前处理并从复位重新启动。

错误码 1=初始化/mtvec/heartbeat；2=第一次屏蔽检查；3=MTIE 打开但 MIE 关闭检查；
4=等待中断超时；5=最终次数/checksum/CSR；6=中断日志；7=重装间隔；0x10..0x12=ISR 描述符/状态。

## 仿真与证据

ModelSim 切到工程目录，执行：

```tcl
do run_timer_irq_board.do
```

三组 RTL 用例覆盖正常启动、ISR 中 KEY1 复位、真实 RAM guard 故障及修复后复位。
校验物理波特率下的 UART 字节、三次 IRQ/MRET、x1..x31 恢复、原 PC 继续、2048 次逐项运算、
软件日志、中断屏蔽、LED 心跳、共享复位和 RAM 保留。仿真使用相同指令镜像，只有 RAM 中心跳周期改为 2000。

生成 PDS 位流后可执行 `do run_timer_irq_board_netlist.do`，用未经修改的硬件 ROM/RAM 和器件模型
检查两次真实速率 PASS、LED 和 KEY1。此测试为综合网表功能仿真，不加载 SDF。

固件证据：`build/timer_irq_board_firmware/`；PDS 时序和镜像/源码 SHA：
`build/pds_timer_irq_board/build_manifest.json`。生成器保留 `hardware_verified=false`，
实物验收结果单独记录于末节，构建器字段表示其自身没有执行硬件验收。

## 本次本地验证（2026-10-03）

固件 GCC O2/Werror 构建通过，text 1984 字节、data 48 字节。三组板级 RTL
于 4,651,650 ns 完成，编译/仿真 0 错误 0 警告；九项新旧构建检查通过。
共享构建器默认模式生成的三个旧 timer_irq 镜像与原工程逐文件 SHA 一致。
PDS 综合、布局布线及最终 STA 全部通过；50 MHz 慢角 setup WNS +2.178 ns、
hold WHS +0.162 ns。综合网表使用硬件镜像，两个启动均输出 UART PASS，LED 与 KEY1 检查通过。

本次 sbit SHA-256：`a434da417e53f5310e3c04539156a0f08e3cd22a261ca6c26e7e7f39a9372ea4`。
日志为 `build/timer_irq_board_validation.log`、`build/timer_irq_board_netlist_validation.log`，
摘要和源码/镜像绑定为 `build/timer_irq_board_validation_sources.json`。

## 用户实物验收（2026-10-03）

用户按本节流程上板，提供了 SSCOM 截图：COM8、115200、8N1，三次启动/复位后
各输出一行 `TIMER IRQ PASS`，接收计数 `R:48`（三条消息各 16 字节）。
用户确认现象正常，涵盖 LED2 常亮、LED1 心跳、LED3 熄灭和 KEY1 重新自检。
因此本版定时器中断独立板级自检通过。该实物结果来自用户截图及确认；
助手没有执行硬件下载，也没有独立核对板上实际加载位流的 SHA。
