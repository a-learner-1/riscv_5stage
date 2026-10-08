# 两路组相联数据 Cache

本步骤在 `soc_axi_lite_top` 的 CPU 数据请求与 AXI4-Lite 主桥之间加入数据 Cache，提供独立 `dcache_board` 自检版本。原有 SoC 默认 `ENABLE_DCACHE=0`；专用板级版本同时开启指令 Cache、数据 Cache、同步异常和机器定时器中断。

## 配置与访问策略

| 项目 | 当前配置 |
| --- | --- |
| 数据容量 | 2 KiB；两路 × 64 组 × 16 字节 |
| Cache 行 | 4 个 32 位字，小端；每次缺失填充整行 |
| 替换 | 优先无效路，其次 LRU |
| 读命中 | 同步 RAM 读取，一拍后返回完整 32 位字；CPU 按 LB/LBU/LH/LHU/LW 提取与扩展 |
| 写策略 | 写穿透，不在写缺失时分配 Cache 行 |
| 在途请求 | 阻塞式，CPU 与后端各最多一笔事务 |
| 可缓存范围 | 默认 RAM：`0x00010000`–`0x00013FFF` |
| 时钟与镜像 | 50 MHz、115200／8N1；ROM 32 KiB、RAM 16 KiB |

SB／SH／SW 均先提交后端；只有成功响应后才更新已命中的缓存字节。写操作返回后，后端 RAM 已完成该次写入，没有脏行或待刷新的写缓冲。写缺失直接写 RAM，不分配缓存行。

只有配置的普通 RAM 范围可以填充。范围外的合法请求按原地址、大小和字节掩码旁路，每次 CPU 请求只产生一次后端请求。UART、GPIO、机器定时器沿用 CPU 本地 MMIO 路径，不经过这个 Cache；专用统计设备经 AXI 旁路访问。非法大小、未对齐访问或错误写掩码在 Cache 中返回错误，不向后端发出访问。

数据 Cache 的数据 RAM 使用无复位的同步读、单写端口及逐字节写使能；复位只清除有效位、控制状态与统计量。指令 Cache 将命中 LRU 更新通过一拍元数据提交，并向紧接着的同组请求前递最新值；命中延迟和每拍接受一次预热命中的能力保持不变。

## 错误、复位和一致性

读缺失先使被替换路无效，再逐字填充。任一填充字返回错误时，不安装部分行；另一路仍保留。错误返回给 CPU 的是原始加载请求，CPU 保存原指令 PC 和原有效地址，不把后端填充地址当成故障地址。

写命中在等待后端时暂时使该行无效。后端报错时保持无效，即使后端已部分提交写入，下一次读取也会重新取 RAM。真实 CPU 测试检查加载访问错误 `mcause=5`、存储访问错误 `mcause=7`、正确 mepc/mtval、MRET 恢复及错误加载不写回。

CPU、Cache、AXI 桥和 RAM 协议必须共用复位。复位取消协议状态，已完成的 RAM 写入保留；启动代码重新清零自己的 BSS。该版本不支持 DMA 一致性、共享内存失效指令或自修改代码。FENCE 可等待当前阻塞访问完成，但不能使外部主设备改写后的缓存行自动失效；未来 CNN／DMA 共享 RAM 时必须另行规定非缓存区或失效机制。

## 自检统计设备

专用 `soc_dcache_stats_top` 将 `0x30000000` 映射为只读数据 Cache 统计设备。它不与指令 Cache 的统计顶层或演示 CNN 控制顶层共用寄存器定义。

| 偏移 | 含义 |
| --- | --- |
| `0x00` | ID：`0x44433241`；读取时同时锁存下列七个计数器 |
| `0x04` | 几何配置：默认 `0x02400010`，表示两路、64 组、16 字节行 |
| `0x08` | 已接受 CPU 数据请求数 |
| `0x0C` | RAM 读命中数 |
| `0x10` | RAM 读缺失数 |
| `0x14` | 成功填充字数 |
| `0x18` | 非法请求与后端错误响应数 |
| `0x1C` | 合法、可缓存 RAM 写请求数 |
| `0x20` | 合法、范围外旁路请求数 |

先读 ID，再读其他寄存器，得到同一时刻的快照。计数事件统一延迟一拍，计数器为 32 位；统计设备自身访问属于旁路流量。错误路径之外，稳定快照满足：请求数 = 读命中 + 读缺失 + RAM 写 + 旁路。无填充错误时，填充字数 = 读缺失 × 4。只读设备的所有写入及无效／未对齐读取返回 SLVERR。

## 构建和仿真

在 Git Bash 执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_dcache_board.bat
cmd.exe //c build_pds_board.bat --variant dcache_board --firmware dcache_board --stage bitstream
```

固件构建检查三组冲突数据地址、指令镜像一致性与 RAM 镜像差异；硬件和仿真仅心跳周期不同。PDS 使用硬件数据镜像，检查开关、容量、频率与源码／镜像 SHA256，并要求布线报告和独立最终 STA 均满足约束。

ModelSim Transcript：

```tcl
cd D:/FPGA/riscv_3stage
do run_dcache.do
do run_dcache_baseline.do
do run_dcache_board_netlist.do
```

第一条运行 Cache 独立参考模型、统计协议、真实 CPU 访问故障、异常 C 固件及板级 C 固件；第二条回归指令 Cache 和关闭 D-cache 的旧版本；第三条需先生成配套 PDS 网表，按实际 50 MHz／115200 检查串口、LED 和两次启动。只检查 CPU 故障时可运行 `do run_dcache_fault.do`。

## 上板验收

下载 `build/pds_dcache_board/generate_bitstream/board_top.sbit`。串口终端设为 115200／8N1、无校验、无流控；先打开实际 COM 口，再下载或按 KEY1。

1. 收到完整 `DCACHE PASS`，含 CR/LF 共 13 字节；该程序无需发送串口命令。
2. LED2 常亮，LED1 约每 0.5 秒切换，失败指示 LED3 不亮。
3. 按下并释放 KEY1，再次收到 `DCACHE PASS`，心跳恢复。

若出现 `DCACHE FAIL XXXXXXXX`，保留完整错误码与下载文件路径。实物验收记录见[验证记录](dcache_verification_20261007.md)。原无 Cache CoreMark 成绩保持作为基线，本自检不输出或估算带 Cache 的 CoreMark 分数。
