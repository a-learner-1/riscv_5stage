# CPU5 独立板级构建与下载文件（2026-10-26）

本阶段将五级 CPU 接到 MES50HP 板级顶层，完成 50 MHz 布局布线和下载文件准备。工作仓库为 `D:/FPGA/riscv_3stage_github_lfs`；原 `D:/FPGA/riscv_3stage` 保留。所有实测身份以冻结证据、源码提交和文件 SHA-256 为准。

CPU5 尚未下载到板卡，没有正式 CoreMark 板测成绩。本文中的短程运行均为一迭代功能检查；原三级 CPU 的正式成绩不能移作 CPU5 成绩。

## 固定板级配置

| 项目 | 配置 |
|---|---|
| FPGA | Logos PGL50H、-6、FBG484（MES50HP） |
| CPU | 真实 `cpu5_stats_axi_lite_top`，RV32IM，整数前递，EX 分支解析 |
| 时钟／串口 | 50 MHz、115200、8N1 |
| ROM／RAM | 32 KiB ROM；16 KiB D0 同步 BRAM，起址 `0x00010000` |
| I/D Cache | 各 2 KiB，两路、64 组、16 字节 Cache line |
| 分支预测 | 64 项 BTB |
| 统计 | schema4，profile2，十类互斥 64 位周期计数 |
| 复位 | KEY1 低有效，双拍同步释放，再保持 50000 周期 |
| 外部 IRQ 输入 | 本板测顶层固定为 0；内部机器定时器保留 |

独立文件 `rtl/cpu5_coremark_board_top.v` 不替换原三级顶层。生成时将固件路径和复位参数绑定为 `board_top` 的 localparam，避免 PDS 参数覆盖使固件与硬件配置失配。引脚及约束沿用现有 `pds/board_top.fdc`；内部时钟仍为 20 ns，没有新增内部 false path、multicycle 或降频例外。

## 实际 RTL 调整

1. `cpu5_csr_unit` 的 `irq_pending` 输入去掉声明中的默认值，解决本机 PDS Verilog 前端不接受该写法的问题。全部现有实例已经显式连接该输入。
2. 访存完成包与 MEM 的匹配不再依赖本周期组合生成的 killed 标记，解除 `fault → trap → kill → completion → fault` 的物理组合反馈。既有 MEM kill／IRQ 条件仍约束退休和异常；新增仿真断言检查 killed owner 不得匹配有效的 MEM 包。
3. 用一个寄存位记录当前 MEM 包是否已经取得唯一 D owner，替代关键控制路径上的 64 位 seq 相等比较。完整年龄仍保留，仿真断言逐周期检查寄存关系与 owner seq 一致。
4. CPU5 取指先锁存重定向地址，再向 I-cache 查询，切断数据 Cache 到分支判断再到取指 tag 查询的长组合路径。已经呈现且受背压的请求仍按原地址排空。共享 `if_stage` 新参数默认为 0，原三级保持原来的重定向旁路；CPU5 显式选择寄存地址。

先前失败的综合／时序尝试单独保留，不能作为下载依据。最终证据没有 `STA-3001` 自动切断时序弧。综合日志仍含常量删除、空闲节点、常量探测循环、名称重命名、未采用 ASYNC_REG 属性和异步 I/O 约束提示，完整日志保留；没有宣称 PDS 零 Warning。

## 资源与时序

performance 和 validation 分别执行综合、布局布线及独立 STA，随后各自生成位流，并重新验收该生成流程产生的路由数据库与最终 STA。

| 项目 | performance | validation |
|---|---:|---:|
| 综合 LUT | 10837 | 10837 |
| 寄存器 | 8870 | 8870 |
| 锁存器 | 0 | 0 |
| DRM18K 等价资源（工具统计） | 28 | 28 |
| APM | 4 | 4 |
| Slow Setup WNS | +0.021 ns | +0.021 ns |
| Slow Hold | +0.159 ns | +0.159 ns |
| Fast Hold | +0.112 ns | +0.112 ns |

两种子的八行 setup／hold／recovery／removal 及两行 pulse-width 均通过，TNS 为 0、失败端点为 0。路由摘要也单独检查。`u_backend/g_d0.u_ram/u_data_mem` 在最终网表中有八个真实 DRM18K 实例，不能仅凭总 BRAM 数推断后端已映射。这里验收的是 50 MHz 工作点；+0.021 ns 余量较小，不作更高频率或独立 Fmax 扫描结论。

## 功能验证与范围

- RAM、Trap、CSR/MRET、IRQ、M-owner、FENCE 六组控制回归通过，共 344 个定向场景。检查 killed response 排空、同边沿交接、异常、旧 WB 和访存 owner。
- 原取指七项门控通过，独立公开端口账本完成 456 项检查；新增 11 项检查覆盖新鲜重定向、陈旧错误排空、epoch／seq、故障恢复，并同时检查共享 IF 默认的三级行为。
- 四种 AXI／D0 × Cache 开关 CoreMark 兼容配置再次运行。独立 RV32IM 解释器核对全部 2,409,425 条退休指令及物理 WB，算法窗口合计 3,129,696 周期，与调整前一致。这组沿用 S18 的 128 B Cache／BTB16／模拟加速串口，仅用于兼容性；本阶段没有重新宣称完成全部历史功能变异验收。
- 新板级配置另运行 performance／validation 两组一迭代固件，采用真实 2 KiB Cache／BTB64／115200。检查 KEY1 抖动、真实接受的 BSS STORE 后复位、十类独立计数、native 请求响应、退休与 WB 对应关系、4096 词 RAM 物理写重建，以及 TX 引脚逐帧解码与端点字节一致。
- 板级测试等待完成标志对应的 WB，并确认程序通过栈恢复进入启动代码的空闲循环后再收尾。程序写完 tohost 后尚有正常返回 LOAD，不能在 tohost WB 的瞬间要求 D 通道已经空闲。
- 47 个错误配置／路径／证据输入被拒绝，复用的 9 项最终 STA／位流新鲜度测试通过。正常仿真保持零 Warning／Error；序号耗尽等独立拒绝用例的预期 Fatal 单独记录。

正式 performance／validation 镜像均为 2000 迭代。固件要求 CRC 与对应种子匹配、实际运行不少于 10 秒，才会输出 `COREMARK RESULT: FORMAL PASS`。当前仅构建它们，没有在 FPGA 上执行。

## 复现与证据

在 ASCII 路径的干净工作目录运行；本机需要 RISC-V GCC、ModelSim 和 PDS，路径可通过工具参数覆盖。新 clone 先按 README 完成 Git LFS 与历史基线初始化。

```powershell
python tools/build_cpu5_board_images.py --profile all
python tools/run_cpu5_board_regressions.py
python tools/test_cpu5_board_delivery.py
python tools/run_cpu5_board_smoke.py
python tools/run_cpu5_coremark.py
python tools/verify_cpu5_coremark.py --skip-negative
python tools/build_cpu5_pds.py --stage timing --profile performance --seed 1
python tools/build_cpu5_bitstream.py --record build/cpu5_s19/pds_performance.json
python tools/build_cpu5_pds.py --stage timing --profile validation --seed 1
python tools/build_cpu5_bitstream.py --record build/cpu5_s19/pds_validation.json
python tools/verify_cpu5_board_build.py
```

`verify_cpu5_board_build.py` 独立核对原始文件、全部源码快照、固定硬件／固件配置、最终路由、STA、SBIT/BIN、控制回归、板级 UART，并重新执行四配置指令回放。交付时再用 `--source-commit <完整源码提交> --repository <Git仓库>` 逐一核对 Git 的规范 LF blob。冻结包与可离线复核入口见 `docs/evidence/cpu5_board_20261026/README.md`。

## 接下来上板

本机只读检查尚未发现 COM 口或匹配的 Pango／JTAG／FTDI 设备，因此没有执行下载。连接并供电 MES50HP，同时接好 JTAG 下载器和板载 USB-UART 后，按以下次序验收：

1. 串口选择实际 COM 口，115200／8N1／无流控，先开始保存完整原始文本。
2. 使用 PDS 下载器对 FPGA 作 JTAG SRAM 下载，选择本阶段 performance 的 SBIT；按 KEY1 重新开始，保存本次固件和位流哈希、完整输出及实际运行时间。
3. 核对 `platform=cpu5`、`isa=rv32im`、D0、Cache geometry `37748752`、BTB64、schema4／profile2、十类闭合、performance CRC 和 `FORMAL PASS`，且计时至少 500,000,000 ticks。
4. 切换本阶段 validation 的 SBIT，重复保存与核验。两份结果齐全后才生成 CPU5 正式成绩与三级／五级整版配置对照。

performance CRC 为 e9f5／e714／1fd7／8e3a；validation CRC 为 18f2／e3c1／0747／8d84。下载文件名称、SHA-256 和源提交身份以交付清单为准。KEY1 重启 CPU；REPROGRAM 会重新装载 FPGA 配置，不能混用。
