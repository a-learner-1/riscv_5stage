# AXI CoreMark 板级测量记录（2026-10-15～16）

结果来源为用户提供的完整 UART 文本。三种 AXI 配置的 performance／validation **六项正式运行均已实测 `FORMAL PASS`，全部配对完成**。双 Cache＋BTB 的性能为 **49.603719 CoreMark／0.992074389 CoreMark/MHz**，比双 Cache 配置快 **7.72%**，比 AXI 无 Cache 基线快 **30.17%**。2026-10-16 续记，保留本文件路径供既有链接使用。

## AXI 无 Cache：performance

| 项目 | 结果 |
| --- | --- |
| 串口日志 | 两轮完整输出，数值一致，均为 `FORMAL PASS` |
| CPU／UART | 50 MHz／115200，8N1 |
| CoreMark | **38.108122**（完整值 38.108121931 次／秒） |
| CoreMark/MHz | **0.762162439** |
| 迭代次数 | 600，`ITERATIONS=0` 自动校准 |
| mtime ticks | 787233757 |
| 算法时间 | 15.744675140 秒 |
| seed1／seed2／seed3 | `0x0000`／`0x0000`／`0x0066` |
| seed／list／matrix／state CRC | `e9f5`／`e714`／`1fd7`／`8e3a` |
| 本次最终 CRC | `bd59`，只对应本次种子与迭代数 |
| 统计窗口周期／退休指令 | 787233847／439356525 |
| 统计窗口 CPI | 1.791788223 |
| 编译器 | xPack GNU RISC-V Embedded GCC 15.2.0 |
| 共同编译配置 | RV32I／ILP32／`-O2`，静态 2000 字节数据、单上下文 |
| 存储 | ROM 32 KiB、AXI4-Lite RAM 16 KiB，I/D Cache 与 BTB 关闭，所有人工等待为 0 |

独立复算 `787233757 / 50000000 = 15.744675140`，`600 / 15.744675140 = 38.108121931…`。计时超过 10 秒，performance 种子与 CRC 均匹配。统计窗口比 mtime 多 90 周期，即 1.8 微秒，符合 START／STOP 边界开销；它与算法计时不是同一窗口。关闭模式下 Cache／BP 统计读零，不能解释为程序没有访存。

旧内部 RAM、无 Cache 的 **52.574739 CoreMark／1.051494774 CoreMark/MHz** 属于另一条存储通路。后续 Cache 和 BTB 效果应与本次 AXI 基线对照；validation 速度不与 performance 求平均。

## AXI 无 Cache：validation

| 项目 | 结果 |
| --- | --- |
| 串口日志 | 一轮完整输出，`FORMAL PASS` |
| 迭代次数 | 600，`ITERATIONS=0` 自动校准 |
| mtime ticks／算法时间 | 828195167／16.563903340 秒 |
| 校验运行速度 | 36.223345892 次／秒，0.724466918 次／秒／MHz |
| seed1／seed2／seed3 | `0x3415`／`0x3415`／`0x0066` |
| seed／list／matrix／state CRC | `18f2`／`e3c1`／`0747`／`8d84` |
| 本次最终 CRC | `b8a0`，只对应本次种子与迭代数 |
| 统计窗口周期／退休指令 | 828195257／471207348 |
| 统计窗口 CPI | 1.757602594 |
| 共同配置 | 与上述 performance 相同的 AXI 无 Cache／无 BTB、50 MHz、GCC 15.2.0、RV32I／ILP32／`-O2` |

独立复算 `828195167 / 50000000 = 16.563903340`，`600 / 16.563903340 = 36.223345892…`。校验运行超过 10 秒，种子与 CRC 匹配，Cache／BP 计数均为零；统计窗口同样多 90 周期。两套种子配对完成后，本配置性能成绩引用 performance 的 **38.108122 CoreMark／0.762162439 CoreMark/MHz**。

## AXI 双 Cache／无 BTB：performance

| 项目 | 结果 |
| --- | --- |
| 串口日志 | 一轮完整输出，`FORMAL PASS` |
| CoreMark／CoreMark/MHz | **46.049672／0.920993449**，50 MHz |
| 相对 AXI 无 Cache 基线 | 性能提升 **20.839522%**；算法时间减少 **17.245618%** |
| 迭代次数／mtime ticks | 600／651470432 |
| 算法时间 | 13.029408640 秒 |
| seed1／seed2／seed3 | `0x0000`／`0x0000`／`0x0066` |
| seed／list／matrix／state CRC | `e9f5`／`e714`／`1fd7`／`8e3a`，与基线一致 |
| 本次最终 CRC | `bd59` |
| 统计窗口周期／退休指令 | 651470586／439356525 |
| 统计窗口 CPI | **1.482783455**，基线为 1.791788223 |
| I Cache 访问／命中／缺失 | 529014137／527929670／1084467 |
| I Cache 命中率 | **99.795002%**，`hit / access` |
| D Cache 读命中／读缺失 | 32855860／145951 |
| D Cache 读取命中率 | **99.557749%**，`hit / (hit + miss)` |
| D Cache 总访问／RAM 写入／旁路 | 41603074／8601262／1 |
| I／D refill words | 4337868／583804，均为对应缺失数的 4 倍 |
| 错误／预测器统计 | I/D Cache errors 均为 0；BTB 关闭，BP 计数均为 0 |
| Cache 配置 | I/D 各 2 KiB、2 路、64 组、16 字节行；D Cache 写直达、写不分配 |

复算 `600 / (651470432 / 50000000) = 46.049672443…`，计时超过 10 秒；对照为同一 AXI 存储通路、相同编译器／优化等级、种子、迭代数和等待参数，退休指令数也相同。性能提升按 `787233757 / 651470432 - 1` 计算。统计窗口比 mtime 多 154 周期（3.08 微秒），用于辅助分析的 CPI 包含此边界开销。

D Cache 依据 `rtl/data_cache.v` 分别统计 RAM 读取命中／缺失、RAM 写入和旁路。本次 `32855860 + 145951 + 8601262 + 1 = 41603074`；读取命中率不以所有访问为分母。同配置 validation 已通过，正式配对完成。

## AXI 双 Cache／无 BTB：validation

| 项目 | 结果 |
| --- | --- |
| 串口日志 | 一轮完整输出，`FORMAL PASS`；SSCOM 时间 23:58:32～33 |
| 迭代次数／mtime ticks | 600／691320589 |
| 算法时间 | 13.826411780 秒 |
| 校验运行速度 | 43.395206909 次／秒，0.867904138 次／秒／MHz |
| seed1／seed2／seed3 | `0x3415`／`0x3415`／`0x0066` |
| seed／list／matrix／state CRC | `18f2`／`e3c1`／`0747`／`8d84` |
| 本次最终 CRC | `b8a0` |
| 统计窗口周期／退休指令 | 691320709／471207348 |
| 统计窗口 CPI | 1.467126334 |
| I Cache 访问／命中／缺失／填充字 | 568741235／567653235／1088000／4352003 |
| D Cache 读命中／读缺失／填充字 | 33112946／160785／643140 |
| D Cache 总访问／RAM 写入／旁路 | 41818250／8544518／1 |
| 错误／预测器统计 | I/D Cache errors 均为 0；BTB 关闭，BP 计数均为 0 |

复算时间、速度和 CPI 与 UART 一致，计时超过 10 秒；种子、CRC、Cache／BTB 开关与固件配置匹配。统计窗口比 mtime 多 120 周期（2.4 微秒）。本配置配对后的性能成绩引用 performance 的 **46.049672 CoreMark／0.920993449 CoreMark/MHz**，不混入 validation 速度。

I Cache 的填充字数比缺失数四倍多 3。`rtl/instr_cache.v` 在接受缺失请求时统计 miss，在每个后端响应时统计 refill；START／STOP 同拍冻结统计但不会等待指令填充排空。因此跨边界填充会使窗口增量不严格满足 `refill_words = miss × 4`。本次仅记录净边界差 3 字，不推断某一笔具体事务，也不将它作为 CRC 失败。

## AXI 双 Cache＋BTB：performance

| 项目 | 结果 |
| --- | --- |
| 串口日志 | 一轮完整输出，`FORMAL PASS`；SSCOM 时间 09:23:12 |
| CoreMark／CoreMark/MHz | **49.603719／0.992074389**，50 MHz |
| 相对双 Cache／无 BTB | 速度提升 **7.717855%**，算法时间减少 **7.164880%** |
| 相对 AXI 无 Cache 基线 | 速度提升 **30.165741%**，算法时间减少 **23.174870%** |
| 迭代次数／mtime ticks | 600／604793357 |
| 算法时间 | 12.095867140 秒 |
| 种子及 CRC | `0000/0000/0066`；`e9f5/e714/1fd7/8e3a`，最终 `bd59` |
| 配置 | Cache=3，BP=1，64 项 BTB，配置字 `0x00400001` |
| 统计窗口周期／退休指令 | 604793511／439356525 |
| 统计窗口 CPI | **1.376543824** |
| I Cache 访问／命中／缺失／填充字 | 482435086／481355569／1079517／4318068 |
| I Cache 命中率 | 99.776236% |
| D Cache 读命中／读缺失／填充字 | 32851672／150139／600556 |
| D Cache 总访问／RAM 写入／旁路 | 41603074／8601262／1 |
| D Cache 读取命中率 | 99.545058% |
| Cache 错误 | I/D errors 均为 0 |
| BP lookup／hit／predicted taken | 482435086／115998421／78458831 |
| BP resolved／next-PC mismatch | 121300505／43078561 |
| BP direction error／target error | 29619041／0 |

复算 `600 / (604793357 / 50000000) = 49.603719440…`，计时超过 10 秒，种子／CRC 与前两种 performance 匹配，退休指令数同为 439356525。统计窗口比 mtime 多 154 周期（3.08 微秒），CPI 包含这一边界开销。预测器已通过自动校准训练，测量前不显式清空。

BP 活动计数与启用配置相符。next-PC mismatch 包括 JALR 等额外恢复，不能以 mismatch／resolved 表示预测错误率；hit／lookup 表示采用预测的覆盖比例，包含重定向旁路口径，不是方向准确率。target error 为 0 仅描述该类事件，没有给出总体准确率。

上述增幅表示各已测构建配置的整体差异，包含各自的固件布局和本轮时序实现。MAP 显示双 Cache 的 `static_memblk` 位于 `0x0001150c`，BTB 版本位于 `0x0001155c`；工作数据的 Cache 映射并非完全相同。比较采用相同 AXI 接口、时钟、等待参数、编译器／优化等级、数据规模与种子，版本由各自镜像和源码哈希绑定。BTB validation 现已实测通过，本配置正式配对完成。

## AXI 双 Cache＋BTB：validation

| 项目 | 结果 |
| --- | --- |
| 串口日志 | 一轮完整输出，`FORMAL PASS`；SSCOM 时间 09:33:56 |
| 迭代次数／mtime ticks | 600／638619386 |
| 算法时间 | **12.772387720 秒** |
| 校验运行速度 | 46.976337796 次／秒，0.939526756 次／秒／MHz |
| 种子及 CRC | `3415/3415/0066`；`18f2/e3c1/0747/8d84`，最终 `b8a0` |
| 配置 | Cache=3，BP=1，64 项 BTB，配置字 `0x00400001` |
| 统计窗口周期／退休指令 | 638619506／471207348 |
| 统计窗口 CPI | **1.355283420** |
| I Cache 访问／命中／缺失／填充字 | 515913289／514829830／1083459／4333839 |
| D Cache 读命中／读缺失／填充字 | 33109497／164234／656936 |
| D Cache 总访问／RAM 写入／旁路 | 41818250／8544518／1 |
| Cache 错误 | I/D errors 均为 0 |
| BP lookup／hit／predicted taken | 515913289／127403436／86500222 |
| BP resolved／next-PC mismatch | 132686185／44705941 |
| BP direction error／target error | 31255741／0 |

独立复算 `638619386 / 50000000 = 12.772387720`，`600 / 12.772387720 = 46.976337796…`，计时超过 10 秒，validation 种子与 CRC 正确。统计窗口多 120 周期（2.4 微秒），窗口有效。I Cache 填充字数比缺失数四倍多 3，按前述跨窗口填充口径保留原值；D Cache 分类合计及填充数相符。三配置已完成正式配对，性能成绩仍仅使用 performance，不将 validation 速度并入成绩。

## 完成状态

| AXI 配置 | performance | validation |
| --- | --- | --- |
| 无 Cache／无 BTB | 两轮 `FORMAL PASS`，38.108122 CoreMark | 一轮 `FORMAL PASS`，本配置配对完成 |
| 双 Cache／无 BTB | 一轮 `FORMAL PASS`，46.049672 CoreMark，相对基线 +20.84% | 一轮 `FORMAL PASS`，本配置配对完成 |
| 双 Cache＋BTB | 一轮 `FORMAL PASS`，49.603719 CoreMark；比双 Cache +7.72%，比 AXI 基线 +30.17% | 一轮 `FORMAL PASS`，本配置配对完成 |

三配置各两套种子的六种短程功能测试已在统一回归中通过，六项正式 profile 也已分别上板通过。此结论针对本轮 AXI CoreMark 三配置测量；CPU 交接导出、独立专项板级版本及真实 CNN 联调按各自记录验收。

## BTB 位流准备中的时序修正

首次双 Cache＋BTB performance 的 50 MHz PDS 构建未通过，实际最终 STA setup 为 −0.578 ns、43 个失败端点，未生成下载位流。已报告的最坏路径通向 IF 的 hit／taken 统计计数器 CE。失败报告、构建日志与修改前的 `if_stage.v` 保存在 `build/verification/btb_timing_failure_20261016_4e6288bec35b/`。

随后将 IF 的三类完整统计事件统一寄存一拍，并补充请求刚接受后立即复位、释放后无待计数事件重放的测试。预测和取指路径未调整，算法 mtime 计时方法未变；BP 开启时前三类统计事件延迟一拍可见，详见[统计口径](coremark_axi.md)。重新构建与相关回归结果另行记录。此前无 Cache／双 Cache 的 BP 关闭生成路径功能未改，原始实测记录与配对证据保留；旧构建报告对当前源码的哈希守卫过期，不回写历史报告来绕过守卫。

第二次构建的最坏路径已转移到 MMIO 读数据选择和指令 Cache 的 LRU 元数据 CE，最终 STA setup 为 −0.579 ns、61 个失败端点，仍未生成位流。报告与当时源码保存在 `build/verification/btb_timing_after_event_registers_20261016_423d09575cf9/`。随后把互斥 MMIO 地址的数据选择改为并行掩码 OR；LRU 元数据每拍采样，由原有 `lru_pending` 决定是否提交和旁路，保持请求响应节拍及替换行为。五组八项回归在 `build/regression/20261016T005745Z_975422d427ef/` 全部 PASS，源码／镜像指纹前后一致；这一版第三次 PDS 仍为 −1.857 ns、265 个 setup 失败端点，报告与源码保存在 `build/verification/btb_timing_parallel_mmio_lru_20261016_a1e45cc02957/`，未生成位流。

第三次最坏路径为 EX 重定向地址经 BTB 查询进入下一 PC。后续把 BTB 查询地址固定为寄存 `pc_f`，新重定向请求当拍采用目标加 4 的预测后继，后续请求恢复正常查询；held 快照、stale 排空及 EX 恢复逻辑保留。新增定向测试同时训练旧 PC、重定向目的 PC 和其顺序后继，检查重定向旁路元数据以及随后预测恢复；独立 BTB 回归 `build/regression/20261016T010926Z_47b54c0e5a69/` PASS。此策略可能影响 BTB 覆盖率与成绩，不能沿用旧版 BTB 性能假设。

最终实现的 BTB、定时器、机器外部／软件中断、原 CoreMark 移植层及 AXI 三配置六种短程对照五项回归全部 PASS，源码／镜像指纹前后一致；记录为 `build/regression/20261016T011023Z_12dfb81910ac/`。配套 performance 位流已生成，实际最终 50 MHz STA setup 裕量 **0.383 ns**、最小 hold 裕量 **0.055 ns**，setup／hold／recovery／removal／pulse-width 检查均通过。

已保存的无 Cache／双 Cache 板级成绩对应各自下载时的源码和位流版本，历史证据不因本次组合逻辑重排而回写为新版上板结果。

## 本地证据

支持性的统一回归共有六个分组、九个场景，已分组通过：baseline（1）、cache（2）、btb（1）、irq（2）、board（1）、coremark（2）。对应本地运行目录均在 `build/regression/` 下：

| 分组 | 运行编号 |
| --- | --- |
| baseline | `20261013T154823Z_840ee639e908` |
| cache | `20261013T161301Z_b2ad0f298fb3` |
| btb | `20261013T161537Z_a1406630982a` |
| irq 两个场景 | `20261013T161849Z_7617b160c82d` |
| board 补跑 | `20261013T162103Z_77df76eefc46` |
| coremark 两个场景 | `20261013T163124Z_327a86c105dd` |

最初 `irq,board` 的总汇总为 BLOCKED，其中两个 irq 场景已 PASS，board 缺少固件；补建后 board 单独运行 PASS。以上不能写成一次 `--group all` 全通过。独立 BTB 板顶 RTL 的 0 错误／0 警告复核记录另见 `build/verification/btb_ports_20261014_90baa4aa3f3d/`。

原始 UART、去 SSCOM 分包标记后的文本和结构化算术核对记录保存在：

```text
build/coremark_board_results/axi_cache_off_performance_20261015_9821859a54c4/
  uart_original.txt
  uart_normalized.txt
  result.json
build/coremark_board_results/axi_cache_off_validation_20261015_6f33c4c30294/
  uart_original.txt
  uart_normalized.txt
  result.json
  pair_summary.json
build/coremark_board_results/axi_cache_on_performance_20261015_6d8a60a0d4db/
  uart_original.txt
  uart_normalized.txt
  result.json
build/coremark_board_results/axi_cache_on_validation_20261016_ee065bd39a38/
  uart_original.txt
  uart_normalized.txt
  result.json
  pair_summary.json
build/coremark_board_results/axi_cache_on_btb_performance_20261016_61ee5b110ae4/
  uart_original.txt
  uart_normalized.txt
  result.json
build/coremark_board_results/axi_cache_on_btb_validation_20261016_e13b940a313c/
  uart_original.txt
  uart_normalized.txt
  result.json
  pair_summary.json
build/coremark_board_results/comparison_20261016_6ad33318bb5f/
  summary.json
```

无 Cache performance 的 `result.json` 保留两轮字段；双 Cache、双 Cache＋BTB performance 各保留一轮字段与原文哈希。各 validation 的 `result.json` 保存本轮字段与聊天粘贴文本，`pair_summary.json` 关联同配置的两份结果及其哈希。原 performance 记录保留收到当时的状态，配对后的最新状态以各自 `pair_summary.json` 为准；最终 `summary.json` 校验三份配对记录及原始证据哈希，汇总三种配置的六项正式结果。记录关联本流程准备的预期下载位流、PDS manifest 哈希；UART 本身未自报位流 SHA-256，因此这是按操作流程关联的记录。PDS 构建器的 `hardware_verified=false` 保留原义，不因收到串口日志而回写为 true。

performance 下载前审计：`build/verification/coremark_axi_cache_off_performance_download_20261015_c94ae75dd810/report.json`。validation 下载前审计：`build/verification/coremark_axi_cache_off_validation_download_20261015_d3202e046669/report.json`。两份审计均核对实际最终布局布线／独立 STA、源码、镜像与位流哈希；实测通过另由上述 UART 记录支持。

双 Cache／无 BTB 的 performance 位流为 `build/pds_coremark_axi_cache_on_performance/generate_bitstream/board_top.sbit`。已复核实际最终 50 MHz 布局布线与 STA，setup 裕量 0.800 ns、最小 hold 裕量 0.113 ns，源码／镜像／位流哈希匹配；下载前审计见 `build/verification/coremark_axi_cache_on_performance_download_20261015_66d8d08f2233/report.json`，实物结果见新增的 cache-on performance UART 记录。

双 Cache／无 BTB 的 validation 位流为 `build/pds_coremark_axi_cache_on_validation/generate_bitstream/board_top.sbit`。下载前已核对当时源码／镜像／位流哈希、实际最终布局布线和独立 STA，50 MHz setup 裕量 0.800 ns、最小 hold 裕量 0.113 ns。下载前审计为 `build/verification/coremark_axi_cache_on_validation_download_20261015_c6f19ae3f61b/report.json`，实测通过另由上述 cache-on validation UART 记录支持。

双 Cache＋BTB performance 位流为 `build/pds_coremark_axi_cache_on_btb_performance/generate_bitstream/board_top.sbit`，使用上述时序修正后的实现。下载前审计 `build/verification/coremark_axi_cache_on_btb_performance_download_20261016_1e3640a57f62/report.json` 核对实际最终布局布线／独立 STA、源码、配套固件及位流哈希；实物结果见新增的 BTB performance UART 记录。

BTB validation 位流为 `build/pds_coremark_axi_cache_on_btb_validation/generate_bitstream/board_top.sbit`。下载前已核对源码、固件、位流哈希与实际最终 50 MHz 时序，setup 裕量 0.383 ns、最小 hold 裕量 0.055 ns；下载前审计为 `build/verification/coremark_axi_cache_on_btb_validation_download_20261016_ee90e010f2c9/report.json`。该 validation 的实物 UART 已收到并核对通过，配对完成记录见上述目录。

`build/` 为本机生成目录，不纳入 Git 或源码交接 ZIP；复核原始证据时需另行取得对应日志和报告。构建及测量方法见 [AXI CoreMark 操作说明](coremark_axi.md)。
