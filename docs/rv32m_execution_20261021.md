# RV32M 实现与交付记录

交付日期：2026-10-21。代码基线：75c43aabb0581ec303664e0f51b48c387e1962db。

## 实现范围

完整支持 RV32M 八条指令：MUL、MULH、MULHSU、MULHU、DIV、DIVU、REM、REMU。新增 `rtl/rv32m_unit.v`，通过 `ENABLE_M` 参数接入原三级 CPU；默认值为 0，既有 RV32I 配置保持关闭。新 CoreMark 配置 `coremark_d0_m_btb` 显式启用 M，`misa` 为 0x40001100；关闭时仍为 0x40000100。

四条乘法共享一个 32×32 无符号乘积及高半字符号修正，综合实际使用 4 个 APM。四条除法/余数指令共享逐位迭代单元，按截零规则计算商，非零有符号余数跟随被除数符号。除零返回全 1 商/原被除数余数；INT_MIN/-1 返回 INT_MIN 商和 0 余数，不产生算术异常。

单元启动沿锁存 WB 旁路后的操作数。乘法在启动后第二个时钟沿置 done；普通除法在启动后第 32 个时钟沿置 done，CPU 在后续沿提交。不能把单元这两个延迟直接写成 CPU 指令 CPI。除零和有符号溢出采用定义结果的快速路径。

M 指令等待时保持 EX，不重复写回、退休或预测器解析；开始前中断可以抢占，开始后的中断延迟至结果提交之后。复位取消在途运算。原 D-Cache、D0 RAM、MMIO、BTB64 容量及 AXI 合同保留，没有加入写缓冲、RAS、压缩指令或五级流水线。

## 功能验证

- 独立 Python 大整数黄金模型共 11,904 个算术向量，每条 M 指令 1,488 个，覆盖随机值、位边界、除零、溢出和余数符号。
- 单元覆盖输入锁存、busy 时忽略新请求、连续请求、done/result 保持及运算中复位。
- CPU 共 7 个场景；五条完整启用轨迹各含 1,089 条指令、393 条 M 指令、96 次 STORE，均恰好退休/写入一次。覆盖 BTB 开关、依赖、x0、错误路径、启动前/除法中/完成沿中断，以及 CPU 中途复位。
- 关闭 M 时，8 条 M 指令均产生精确非法指令异常，8 次 MRET 和 misa.M=0 通过。
- 48 项构建/固件/时序守卫通过。RV32I 验证器继续拒绝 M；RV32IM 验证器检查全部链接代码，不接受 C、A、F 或未支持编码。
- 已提交基线回归清单中的 12 项全部 PASS，包括 25 个原 CPU 集成测试、I/D Cache、BTB、三源中断、CoreMark 移植层、三配置×双种子 AXI 短测及 AXI 故障/延迟/写通路测试。

权威完整回归为 `20261020T150812Z_7d6a039dcc8f`：全局及各 case 前后 486 个输入文件哈希一致，退出码/完成标记/诊断门通过。更早因并行生成固件和补充测试而失去来源闭合的 `145350Z` 运行保留为 FAIL，没有混入最终通过结论。

主工程合入后另运行 `run_rv32m.do` 和 `run_coremark_m.do`，退出码 0，全部 M 单元、CPU 和双种子 CoreMark 通过。M 单元/CPU 为 0 Error、0 Warning；CoreMark 保留每个 seed 原有的两条 `irq_external` 未连接告警。没有宣称完成综合网表功能仿真或新版本板测。

## CoreMark 短程结果

相同 50 MHz、O2、两路 I/D Cache、D0 RAM、64 项 BTB，固定一迭代。

| 项目 | RV32I smoke | RV32IM smoke | RV32I validation seed | RV32IM validation seed |
|---|---:|---:|---:|---:|
| 窗口周期 | 904,538 | 425,003 | 960,825 | 425,367 |
| 退休指令 | 732,299 | 289,747 | 785,265 | 289,855 |
| 周期减少 | — | 53.01% | — | 55.73% |
| 相同迭代数速度比 | — | 2.1283× | — | 2.2588× |

两个种子的 CRC、成功 tohost、mtime、I/D/BP 冻结统计和六类周期闭合全部通过。关闭 M 的 D0 双种子周期仍精确等于 904,538/960,825。

M CPI 分别为 1.466807249/1.467516517。M 多周期等待计入原 schema 的 work_other，因此该项不再等于退休数；这不破坏六类互斥分区。不同指令集减少了每轮指令数，不能用 CPI 单项判断收益。

这些是一迭代功能仿真结果，不能替代不少于 10 秒的正式上板成绩。当前已确认的旧版板测 performance 分数仍是 55.333377791 CoreMark / 1.106667556 CoreMark/MHz；新的 M 正式成绩尚未测得。未执行热点测量。

## 独立实现与资源

| PDS 报告口径 | 本次 RV32I 对照 | 最终 RV32IM | 差值 |
|---|---:|---:|---:|
| Routed LUT | 8,078 | 8,643 | +565 |
| FF | 6,780 | 7,031 | +251 |
| APM | 0 | 4 | +4 |
| DRM | 36 | 36 | 0 |

M 单元层级为 541 LUT、245 FF、4 APM。全设计约占器件 LUT 的 20.2%，APM 的 4.76%。本次对照不等同于旧版 8,129 LUT 路由结果；不要宣称旧配置网表或资源逐字节不变。

两份正式 M 位流均独立综合、布局布线，并核验位流流程最终路由数据库和 STA。目标保持 MES50HP/PGL50H-6IFBG484，50 MHz、UART 115200。

| 最终独立 STA，ns | Slow | Fast |
|---|---:|---:|
| Setup | +1.269 | +6.810 |
| Hold | +0.026 | +0.022 |
| Recovery | +12.511 | +14.626 |
| Removal | +0.771 | +0.548 |
| Pulse Width | +8.100 | +8.480 |

Router 的 Hold 为 +0.014/+0.012 ns；Router 八项、最终 STA 八项与两项脉宽均通过，零失败端点。

默认种子的首轮 Router Hold 为 -0.007/-0.028 ns，因此拒绝交付；额外 Hold 修复试验虽改善最终 DB，但 Router 摘要未同步刷新，也未被接纳。最终正常流程使用工具支持的 `pnr -gplace_seed 1 -groute_seed 1`，仅对 M variant 固定种子。未改时钟约束、内部假路径、多周期约束或验收阈值；失败试验完整归档。

## 固件、位流与来源

四份 M 固件使用 rv32im/ilp32 专用 multilib、GCC 15.2.0、O2，全部链接代码检查通过。正式 performance/validation 代码分别 27,292/27,288 字节。RV32I 正式代码仍为 30,428 字节。

主工程迁移复核曾因旧文件 CRLF/LF 差异被原始来源哈希守卫拒绝。随后在主工程重建四份固件：ROM、RAM、Verilog config 三件套与位流构建输入逐字节相同，ELF 所有可加载段及地址/大小相同。ELF 仅非加载 `.strtab` 的 GCC 临时对象名不同。保留原拒绝日志、原构建报告、重建报告及一致性记录；没有放宽哈希守卫。位流构建源码与本次 Git 索引逐文件核对，仅有 CRLF/LF 差异，换行归一化后完全相同；原始哈希和归一化哈希分别记录，不能混称字节一致。

下载文件位于 `build/board_release_rv32m_20261020/`：

| 文件 | 字节数 | SHA-256 |
|---|---:|---|
| Mperformance.sbit | 2,101,696 | 89dae084687d4614ee4d38928c594dbea71c78fa6858f4a3d8dd29e49fe523df |
| Mvalidation.sbit | 2,101,696 | 6cd716153fe82d290234cc6e72a73f6503b104a600191645b8127d50673a8cc9 |

两份位流已做独立只读审计，31 项 PDS 源码/约束、48 项公共固件源码、初始化镜像、最终 route/RTR 与 SBIT 哈希闭合。`release_manifest.json` 保留原始构建来源；主工程镜像记录见 `build/verification/rv32m_20261021/`。原 RV32I 发布目录没有覆盖。

用户自行下载；没有执行 JTAG 下载、Flash 烧写或串口访问。下载后应分别确认 `COREMARK isa=rv32im`、CRC、运行不少于 10 秒、`Correct operation validated` 和 `COREMARK RESULT: FORMAL PASS`。

## 复跑入口

在工程根目录准备当前匹配镜像：

```powershell
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile smoke
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile smoke-validation
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile performance
python -B tools/build_coremark_axi_images.py --backend bram --cache on --btb on --isa rv32im --profile validation
```

ModelSim 工程根目录：

```tcl
do run_rv32m.do
do run_coremark_m.do
```

独立生成两份正式位流，不下载硬件：

```powershell
python -B tools/build_pds_board.py --variant coremark_d0_m_btb --firmware coremark_d0_m_cache_on_btb_performance --stage bitstream
python -B tools/build_pds_board.py --variant coremark_d0_m_btb --firmware coremark_d0_m_cache_on_btb_validation --stage bitstream
```

重跑旧回归时也需按其 build_hints 生成当前来源的旧固件，不能用历史报告跳过 stale 检查。用户原有未提交 README、回归文档、回归清单及 `coremark_axi_tb` 的 STOP_ON_PASS 修改保留，不并入本次提交；用户未提交的额外观察分组不包含在上述基线 12 项结论中。
