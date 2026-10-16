# CPU 周期瓶颈统计

本步骤在 `D:\FPGA\riscv_3stage` 的现有三级 CPU 和 AXI CoreMark 平台增加观测接口。CPU 只输出寄存后的分类事件；六个 64 位计数器位于专用 CoreMark 统计从设备中。流水线、Cache 策略、AXI 事务和软件算法保持原实现。

## 六类周期

每个 `cycle_count` 增长的周期恰好归入一类，优先级从上至下：

| 分类／串口字段 | 定义 |
| --- | --- |
| `cycle_local_mmio_wait` | CPU 被数据事务阻塞，目标为 CPU 本地 `0x2000xxxx` 外设 |
| `cycle_data_write_wait` | CPU 被非本地 MMIO 写事务阻塞，包括首次请求和等待响应 |
| `cycle_data_read_wait` | CPU 被非本地 MMIO 读事务阻塞，包括首次请求和等待响应 |
| `cycle_redirect_wait` | 正常分支／跳转重定向之后，到下一条有效 EX 指令到达之前的空周期 |
| `cycle_ifetch_wait` | 其余 EX 无有效指令、且没有粘滞取指／数据故障的周期 |
| `cycle_work_other` | 不属于上述等待的其余周期，含正常执行、数据事务成功完成边沿及故障等情况 |

数据等待的精确条件为 `stall_x && (mem_active || mem_start_x)`，使用当前或已锁存的事务方向及本地 MMIO 属性。成功响应使 `stall_x` 解除，该完成边沿归入 `work_other`。分类包括 CPU 端看到的 Cache 命中延迟、缺失填充和 AXI 延迟，不能直接等同于 AXI 单独的开销。统计从设备位于 `0x30000000`，访问它产生的少量边界周期也属于非本地数据等待。

`redirect_wait` 包括取指通路等待和 Cache 缺失、旧请求排空等时间，覆盖普通条件分支、JAL、JALR 的实际重定向；它不是预测器失误次数，也不能全部归为可由预测器消除的惩罚。异常、中断和 MRET 结束旧的正常重定向区间。`work_other` 不等于退休指令数，因此不能用它代替 IPC/CPI。

## 快照与边界

专用统计接口升级到 schema **3**，配置校验仍读取 `BASE+0x18`。旧 I/D/BP 银行地址不变。新增银行中的顺序为 `work_other`、`ifetch_wait`、`data_read_wait`、`data_write_wait`、`local_mmio_wait`、`redirect_wait`。

| 项目 | 地址／格式 |
| --- | --- |
| 统计基址 | `0x30000000` |
| 统计窗口 | `0x200` 字节 |
| START／STOP 触发读 | 偏移 `0x00`／`0x04`，与原 CPU/I/D/BP 快照同一接受边沿 |
| 周期分类 START 银行 | 偏移 `0x100`～`0x12c` |
| 周期分类 STOP 银行 | 偏移 `0x140`～`0x16c` |
| 每个类别 | 64 位，低字在前、高字在后，相邻类别间隔 8 字节 |

分类事件在 CPU 中寄存一拍。快照捕获每个计数器的“当前值＋本拍待累加事件”，与同一边沿采到的 CPU `cycle_count` 对齐；不是把延迟一拍的旧分类计数直接与总周期比较。复位清空待计事件、计数器和两个银行。打印读取冻结银行，不重新采样活动计数器。

固件输出 `cycle_profile_schema=1`、六个分类增量、`cycle_profile_sum` 和 `cycle_profile_valid`。只有每类增量不大于窗口总周期、分类总和等于 `counter_cycles`、且原统计有效性检查通过时才有效。有效性失败会传播到正式运行失败；CRC、种子与至少 10 秒等现有正式规则继续生效。Cache/BP 原计数器仍为 32 位，现有小于 `2^32` 周期的统计窗口限制保持不变。

## 验证步骤

在 Git Bash 中先运行无需 GCC 的分类定向自检：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c run_regression.bat --group cycle-profile
```

在 ModelSim Transcript 中也可执行 `do run_cpu_cycle_profile.do`。随后重建三配置的六种短镜像并验证真实 C 程序、CRC、冻结银行及串口输出：

```bash
cmd.exe //c build_coremark_compare.bat --profile smoke
cmd.exe //c build_coremark_compare.bat --profile smoke-validation
cmd.exe //c run_regression.bat --group coremark-axi-profile
```

这两组只做功能仿真。新接口与旧 schema 2 固件不匹配时，守卫会拒绝；需要使用新源码重新构建。

后续上板先对双 Cache＋BTB 生成新的 performance 和 validation 固件：

```bash
cmd.exe //c build_coremark_axi.bat --cache on --btb on --profile performance
cmd.exe //c build_coremark_axi.bat --cache on --btb on --profile validation
cmd.exe //c build_pds_board.bat --variant coremark_axi_btb --firmware coremark_axi_cache_on_btb_performance --stage bitstream
cmd.exe //c build_pds_board.bat --variant coremark_axi_btb --firmware coremark_axi_cache_on_btb_validation --stage bitstream
```

检查新 PDS 时序，再分别下载匹配位流，使用 115200／8N1 接收完整日志。需同时看到 `cycle_profile_valid=1` 和 `COREMARK RESULT: FORMAL PASS`。新增计数器和快照寄存器会增加资源及布线，功能仿真通过不能代替新版本时序或实物验收。历史 **49.603719 CoreMark** 属于扩展前版本，不是本版本的实测成绩。

## 本次验证记录

2026-10-16 在英文临时目录的隔离源码副本完成验证，随后核对并安装同内容源码到主工程。回归 `20261016T020723Z_2f6673df0bbe` 的六个测试项全部 PASS，运行前后输入 SHA-256 未变化：

- 原 CPU／外设／总线／同步异常 25 项完整兼容组。
- BTB 单元及 CPU 预测恢复、定时器中断、机器外部／软件中断。
- 三种统计配置的 35 字段快照、进位、64 位回绕及 AXI 背压／错误／复位。
- AXI 三配置×两种子的六个真实 C 短程用例：CRC、六类周期总和、冻结银行、RAM 和串口输出一致。
- 五个 CPU 分类场景：预测开关×总线延迟四组合，加关闭异常的跳转目标取指故障停机；检查精确退休、写入不重放和待计事件复位。

额外真实 C 负测在 STOP 后将冻结类别加 1，固件输出 `cycle_profile_valid=0`、`counter_valid=0`、`SMOKE FAIL`，并成功提交 `tohost=2`；未打印 PASS。构建合同的 16 项正负检查通过，包括重算配置文件哈希后的错误 schema／类别数／位宽／银行地址／窗口拒绝，以及过期源码拒绝。

六个短程和双 Cache＋BTB 的两个正式固件均构建成功；正式 performance 指令区 30388 字节、validation 30384 字节，均小于 32768 字节，栈余量均为 8532 字节。正式固件这里只完成构建／合同检查，没有进行正式运行。

本地证据：`build/regression/20261016T020723Z_2f6673df0bbe/summary.json`、`build/verification/cycle_profile_negative/negative.transcript.log`、`build/verification/cycle_profile_20261016/summary.json`。这些文件保留隔离测试目录信息，安装记录用源文件哈希关联主工程；`build/` 继续属于本地构建产物。上述记录对应周期统计加入时的功能验证。后续 AXI 低延迟组合版本首次 50 MHz 构建曾出现 **−0.523 ns** Setup 违例；响应路由修复后，performance／validation 的最终时序均通过，Setup WNS **＋1.300 ns**、最小 Hold 裕量 **＋0.026 ns**。新版上板跑分待验证；最新证据见 [时序修复记录](timing_fix_20261016.md)。
