# AXI4 四拍 INCR 读突发：第5步验收

结论：保留 CPU 可触发的读突发演示通路。基线 7e4b785（D0＋64项23bit BTB）。本步独立回归、两套独立 P&R、单独本地提交。没有 CNN 联调、上板或正式分数。

## 交付范围

原 CPU、D-Cache、D0、MMIO、BTB 及 CoreMark 产品 RTL 全部逐字节不变。新增五个 RTL：AXI-Lite 命令端点/AXI4 读主机 axi_lite_burst_reader；AXI4 读路由 axi4_read_1x2；同步 BRAM 从机 axi4_read_ram；真实 CPU 集成 soc_axi_burst_demo_top；独立 MES50HP 板顶 axi_burst_demo_board_top。唯一修改的既有文件是 tools/build_pds_board.py，增加严格绑定的新 variant。
演示使用真实 CPU 软件发命令，主机发一次 AR，目标 BRAM 返 LEN+1 次 R；四次 Lite 单读不算本步突发。普通 RAM 仍经两路 D-Cache 后进入 D0，不自动扩读统计、UART 等有副作用寄存器。缓冲区有公开 seed 写端口，CPU 可编程实际字节数据，综合后不是常量演示。
支持单个隐式 ID、单笔在途、32 bit、ARLEN=0/3、ARSIZE=2、INCR=01 的 AXI4 读取子集。不交付 AXI4 突发写、多 ID、多个 outstanding、真实 CNN/DMA 或 ILA。seed 是独立 native 写接口，不能称为 AXI4 突发写。

| 演示地址 | 用途 |
|---|---|
| 0x00010000–0x00013fff | 原 D0 数据 RAM，D-Cache 在前 |
| 0x30000000–0x300001ff | 原 schema3 统计设备 |
| 0x30001000–0x300010ff | burst 命令与结果 CSR |
| 0x40000000–0x40000fff | 4 KiB buffer0，AXI4 读 / native seed |
| 0x40001000–0x40001fff | 4 KiB buffer1，AXI4 读 / native seed |

地址为参数化接口演示映射，尚未与 CNN 队友约定最终映射。原 CoreMark 顶层和镜像保持原配置，新 variant 名为 axi_burst_demo_board。

## 协议与 CSR 合同

路由器在 AR 受理时锁存目标和完整描述符，最后一拍被消费后才释放。中途 RRESP 错误不会释放目标；只有所选从机收到 RREADY，未选响应隔离。AR 和每拍 RDATA/RRESP/RLAST 在背压下保持稳定，计数只按 valid&&ready 前进。主机累计错误但消费全部预期拍，结束后才置 DONE/ERROR。
不支持的 LEN/SIZE/BURST、未对齐、跨目标、跨4KiB或地址溢出均本地产生规定拍数的错误响应，末拍 RLAST；合法格式但未映射起点返回 DECERR，其余非法描述符返回 SLVERR。即使 LEN255 被拒绝也返回 256 拍，不能一拍错误提前结束。exclusive end==2^32 合法，真正溢出才拒绝。
这些边界和错误排空门依据 [Arm AMBA AXI IHI0022H 的 A3.4（A3-48、A3-59/60）](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)：事务需完成约定拍数，单拍错误不会取消余下响应。路由纠正从机 RLAST 位置并标 SLVERR，但不承诺从机停止供拍后的超时恢复；没有超时机制。

| CSR offset | 作用 |
|---|---|
| +00 | 读 BUSY bit0/DONE bit1/ERROR bit2；写1 START，写2清 DONE/ERROR |
| +04 / +08 | SOURCE_ADDR / ARLEN（仅0或3） |
| +0c | 本命令已消费的 R 拍数 |
| +10/+14/+18/+1c | 四个结果 word |
| +20/+24/+28 | SEED_ADDR / SEED_DATA / SEED_STRB（低4bit） |
| +2c | 写1提交seed；读成功seed计数 |
| +30 / +34 | 累计 AR / R 握手数，包含错误拍 |
| +38 / +3c | ID=0x42525354 / version=1 |

CSR 仅对齐全字读写，错误访问 SLVERR 无副作用；buffer 部分字节写由 SEED_STRB 指定。AW/W 独立受理，任一受理沿或配对执行沿处于 BUSY 都拒绝，覆盖与末拍同沿到达的写。读 CSR 无副作用，受理时捕获值并保持响应。START 的 B 表示命令已接受，后续完成由 DONE 表示；seed 的 B 必须在实际 RAM 写握手之后。共享 reset 取消协议状态、不回滚已接受 seed、不清 RAM 内容。完整合同在证据 rtl_interface_contract_v1.txt。

## 功能证据

既有完整回归 10/10 PASS；构建器单测7项、PDS guard38项 PASS。新增 fabric、reader、真实 CPU/C 三组全部 exit0、0 Error、0 Warning。旧单拍/Cache故障/精确异常/写通路门未替换或放宽。
fabric：35 笔 router 事务、5类路由复位；真实 RAM18次读、72次seed、6类复位；覆盖 AR/R 背压、未选伪响应、目标锁定、首/中/末 SLVERR/DECERR 排空、RLAST异常、LEN255、相邻小region跨界、最高地址最后word/四word与真正溢出后恢复。
reader：14条完整命令、8类复位、4项 busy尾沿/splitAW-W拒绝；任何错误都完整排空，seed实际握手后才 B，复位后已提交写保留。
真实 C：8次全字＋4次部分字节 seed，共12次实际写；10次 AR、34次 R、10次 RLAST（2个单拍、8个四拍）。其中3次是本地未对齐/未映射/跨页错误，每次都有正常恢复；两个真实 buffer 各受理3/4次合法 AR，独立44行握手CSV和固定期望数据闭合，D0 scratch、统计Cache活动、UART成功尾行、tohost成功响应及退休均核验。首/中/末从机错误来自独立端口 mock 测试，不能说真实 C/CNN 已注入这些故障。
非法 CSR 另用真实 CPU：2次精确trap、2次MRET、15条精确退休，核对原load/store PC/cause/tval，禁止错误退休、burst或seed副作用。
仿真加载未修改的硬件 C HEX/DATA/config/ELF，时钟50MHz；SoC testbench 的 UART_BAUD=5,000,000 用于加速物理串口解码。硬件板顶、镜像元数据和 PDS 均固定115200。UART仿真通过不等于实板115200验收。

## 原 D0 保持

四套 D0 固件12个HEX/DATA/config与基线逐字节相同。smoke、smoke-validation 双种子的四个CSV字节相同、各62个UART字段及逐笔STORE绝对/相对phase全部相同，STORE仍2拍；没有本步CPI改善主张。

| profile | cycles | data_write_wait | STORE数 |
|---|---:|---:|---:|
| smoke | 904,538 | 28,698 | 14,349 |
| smoke-validation | 960,825 | 28,488 | 14,244 |

D0保留原有4条可选irq_external未连接警告（每seed两条），零警告门仍不通过；新链路三组为零警告。短程CoreMark <10秒提示与Errors detected为smoke预期；正式成绩仍需≥10秒、CRC和Correct operation validated，本步没有正式成绩。

## 独立 P&R

两个配置分别综合/布局布线/最终多角 STA：原 D0 performance 与新增独立 demo。二者ROM/软件/外设不同，demo总资源和时序不能当作同配置CoreMark优化对比。原D0对7e4b785各项时序和资源delta均为0。

| 配置 | Slow/Fast Setup ns | Slow/Fast Hold ns | Slow/Fast Removal ns | 映射/布线 LUT | DRM18K等效 |
|---|---|---|---|---:|---:|
| 原D0 | 2.447/7.579 | 0.163/0.110 | 0.803/0.593 | 8126/8129 | 36 |
| 独立demo | 2.027/7.441 | 0.147/0.105 | 0.763/0.542 | 9128/9135 | 40 |

全部8项多角时序＋2项脉宽检查正裕量、零失败端点。demo Recovery13.319/15.240 ns，脉宽8.100/8.480 ns。没有提频承诺。只有performance执行原D0 P&R，validation未另跑；demo是独立正式硬件初始化配置。
网表逐位/层次连接证明新通路保留：reader453 LUT/558 FF、router107/56、buffer0 213/88、buffer1 191/88；两buffer各1024×32、4个DRM9K（各等效2个DRM18K）。demo总体31个DRM18K＋18个DRM9K＝40个DRM18K等效，不能混称40个primitive。D0本地RAM8个DRM18K、D-Cache两路各4个DRM9K、I-Cache两路各1个DRM9K、BTB64×23＝1472 FF均保留。

## 证据与复跑

完整证据位于 build/verification/axi_burst_step5_20261020：burst_tests包含独立仿真、44行实际AR/R CSV、物理UART、退出码与SHA；regression_results包含10组回归；pds_performance和pds_burst_demo分别归档实现；demo_firmware包含新ELF/binary/完整硬件三件套；firmware为原D0固件；baseline为7e4b785对照。sta_comparison.json含原报告行号、SHA、DRM和状态逐位连接证明。
初次隔离副本漏D0元数据、TB错误码预期、tohost首EX周期PC采样、SV串口CRLF字面值等验证fixture失败与修正原因均保留在burst_tests历史记录；未改产品或旧测试绕过门。网表审计首次漏识别输出Q别名及onehot属性，修正为核对原cell名/完整位集合/精确Q连接，旧FAIL与修前脚本保留在audit_parser_initial_fail，详见audit_parser_resolution.json；没有为审计改产品或重跑PDS。

```powershell
python -B tools/build_axi_burst_demo_images.py
# ModelSim 项目根目录：
# do run_axi4_burst_fabric.do
# do run_axi4_burst_reader.do
# do run_axi4_burst_soc.do
python -B tools/build_pds_board.py --variant axi_burst_demo_board --firmware axi_burst_demo_board --stage timing
```

主工程原有未提交修改及旧programs/PDS产物保持。新配套镜像只在证据目录归档；复跑请使用builder生成当前匹配三件套，stale/错误variant或参数会被拒绝。未推送、未生成位流、未上板。后续真实CNN接口映射/联调与ILA仍需要独立工作。
