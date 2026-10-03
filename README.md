# RV32I 三级流水线 CPU

这是一个使用 Verilog 实现的 RV32I 处理器软核，目前采用 **IF → EX → WB** 三级流水线，能够在 ModelSim 中加载外部 HEX 程序、运行裸机 RISC-V 汇编和 C 程序，并通过 `tohost` 协议自动报告运行结果。

当前已有37种常用RV32I指令及流水线/存储/外设平台；`ENABLE_TRAPS=1` 模式补入FENCE、ECALL、EBREAK、6种Zicsr和MRET，以及最小机器模式同步异常环境。旧顶层默认 `ENABLE_TRAPS=0` 保持原固件和粘滞故障语义。AXI路径已有32位AXI4-Lite主桥、RAM从设备、1主2从地址分发器和通用控制设备；C程序能启动硬件任务。新增 `trap_board_top` 开启异常并提供50 MHz/115200串口、GPIO板级自检；已通过新板级RTL和本地PDS综合/布局布线时序，综合网表检查与实物验收状态见下节。旧AXI控制板级验收基线仍保留。CoreMark仅保留旧版本单次功能记录。

项目的长期目标是作为紫光同创盘古 50 开发板上轻量化 CNN 推理系统的 RISC-V 主控。CPU 与平台部分负责处理器、外设和后续加速器接口，CNN 模型与部署由队友负责。当前已有CPU外、FPGA内的独立ROM/RAM、最小SoC及AXI4-Lite控制演示闭合系统，以及可选的最小M模式同步异常和定时器中断；后续仍需实际外部存储器控制器、外部中断、Cache、BTB、正式CNN接口和板级实物验证。现阶段保持三级流水线，后续再评估五级升级；队友使用的参考 CPU 不替换本仓库的处理器。

## 新增：最小机器模式定时器中断

本轮以 `3f94f29` 为基线，在 `cpu_top` 和 `soc_axi_lite_top` 新增默认0的 `ENABLE_TIMER_IRQ`。同时设置 `.ENABLE_TRAPS(1), .ENABLE_TIMER_IRQ(1)` 才启用定时器和机器模式定时器中断。原有板级顶层没有开启此参数，旧软件与镜像保持原样。本轮不生成新的PDS位流；下节的已通过报告和候选位流对应 `3f94f29` 的源码，不能作为本轮新增中断的硬件验证。源码哈希改变后，旧网表脚本按设计拒绝重复使用其manifest。

```text
clk → 64位mtime → 与mtimecmp比较 → mip.MTIP
                                    │
                         mie.MTIE && mstatus.MIE
                                    │
                  完成在途访存 → 保存mepc/mcause → mtvec
                                    │
                     汇编保存寄存器 → C处理函数 → MRET
                                    │
                              恢复被打断的PC
```

| 本地MMIO地址 | 32位寄存器 | 读写规则 |
| --- | --- | --- |
| 0x20000040 / 0x20000044 | mtime低32位 / 高32位 | 只接受对齐LW/SW；复位0 |
| 0x20000048 / 0x2000004c | mtimecmp低32位 / 高32位 | 只接受对齐LW/SW；复位全1 |

mtime在每个clk上升沿加1，CPU取指/访存停顿时继续运行；本例100 MHz仿真时钟对应10 ns/tick，实际系统必须公布其固定时钟。写mtime的一拍以写入优先，另一半保留写前值；没有显式写入时正常进位/回绕。MMIO读在请求接受时取快照，写也只在请求接受时发生一次。`software/timer.h` 提供高—低—高重读的一致64位时间读取，以及低字全1—高字—最终低字的安全比较值更新。

CSR `mie(0x304)` 只实现MTIE(bit7)，其他位读0；`mip(0x344)` 只反映硬件MTIP(bit7)。写mip合法但不改变MTIP，软件通过把mtimecmp移到mtime之后清除pending。中断原因为 `mcause=0x80000007`、`mtval=0`。进入时MIE转存MPIE并清MIE，MRET恢复。返回地址是尚未执行的指令PC，不能像跳过ECALL那样给mepc加4。

处理器在开始下一条EX指令前接管中断，并阻止该指令的写回、退休、CSR和RAM/MMIO副作用。已经开始的LOAD/STORE必须先完成，成功响应后较早WB保留；当前同步异常优先。即使IF等待且EX为空，也通过记录架构下一PC响应中断，重定向时丢弃旧取指响应。MRET和mie/mstatus更新后的下一周期重新检查pending，未解除的level中断会再次进入。这里只支持单M模式、直接mtvec、单定时器；未增加外部IRQ、PLIC、WFI、嵌套、U/S模式或标准计数器CSR。

| 文件 | 用途 |
| --- | --- |
| rtl/machine_timer.v | 64位定时器、比较器和四个MMIO字 |
| rtl/cpu_top.v / soc_axi_lite_top.v | 精确中断接管、架构下一PC、mie/mip及使能透传 |
| software/timer.h / timer_entry.S / timer_irq.c | RV32时间访问、保存30个整数寄存器的128字节入口、真实C处理函数 |
| tools/build_timer_images.py / build_timer.bat | 新固件构建和ELF/map/dump、满深度镜像与符号宏 |
| tb/machine_timer_tb.v / timer_irq_tb.v / timer_irq_c_tb.v | 定时器单测、CPU精确性定向测试、三种AXI等待下的真实C |
| run_timer_irq.do | 本轮新增测试入口 |
| run_timer_affected.do | CPU修改后才运行的受影响集成检查 |

C程序先在屏蔽状态制造pending，开启MTIE/MIE后处理3次中断，期间执行2048步checksum计算。ISR记录原因、返回PC和时间，前两次重排20000 ticks，第三次关闭比较；检查结果 `0x569ea33c`、计数、RAM日志和CSR后，实际TX引脚输出16字节 `TIMER IRQ PASS\r\n`，main返回1，经startup写tohost。仿真使用100 MHz/5 Mbaud，尚未接到50 MHz板级顶层。入口沿用有效的16字节对齐可写栈，并预留128字节寄存器帧和C函数栈；不处理入口/handler再次异常或中断嵌套。

镜像已提供，只有修改新软件后才执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_timer.bat
```

本轮ModelSim入口：

```tcl
cd D:/FPGA/riscv_3stage
do run_timer_irq.do
```

本轮新增17组已通过：定时器单测结束570 ns，13组CPU定向结束8350 ns，3组真实C结束1742740 ns；三个顶层test_pass均为1，编译/仿真0错误0警告。C三组均3次IRQ/3次MRET、完整x1..x31恢复、2048个实际checksum/work写入和UART16，AXI RAM写/读为4236/197。fast配置47218 cycles/21598 retired，AW先与W先配置174263 cycles/20110 retired；轮询和等待不同，这些是功能记录，不能当CoreMark分数。CPU定向覆盖直接抢占branch/SW/GPIO、旧STORE背压/响应等待、IF空槽和陈旧错误、同步优先、MRET未解pending立即再入、默认关闭，以及timer非法子字/错位和读快照。

CPU功能改变后的25个受影响集成顶层也全部通过，0错误0警告，包含原有21个CPU/存储握手/SoC/AXI/板级集成和同步异常CPU、边界、C、板级四个顶层。原同步异常与板级镜像未变，只检查它们在新CPU上的兼容性；没有重跑旧PDS、综合网表、外设/RAM/AXI单测或CoreMark算法。

本轮日志为 `build/timer_validation.log`、`build/timer_affected_validation.log`，构建与镜像证据在 `build/timer_firmware/build_report.json`，对应输入SHA在 `build/timer_validation_sources.json`。查看已保存的新C波形，无需重新仿真：

```bash
vsim -view D:/FPGA/riscv_3stage/build/timer_new_timer_irq_c_tb.wlf
```

本轮只在CPU功能变化后检查受影响的集成，不重跑未改的UART/FIFO/GPIO、RAM、AXI单测或CoreMark算法。已通过且源码未改时，查看保存的WLF即可，不再重复运行。规范依据：[RISC-V Machine ISA：中断与机器定时器](https://docs.riscv.org/reference/isa/v20240411/priv/machine.html)。

## 新增：开启同步异常的盘古50板级验收版本

本轮以 `322eb66` 为基线，不修改CPU、decoder、前端、AXI桥/从设备、UART或GPIO模块。新增 `trap_board_top.v` 将原本仅在新测试中启用的同步异常模式接到MES50HP，并使用独立输出目录；其他板级顶层和固件保留各自的版本。

```text
trap_board_top       MES50HP / PGL50H-6IFBG484，50 MHz，UART115200
  ├─ board_reset    KEY1共同复位；上电/松键默认50000拍等待（约1ms）
  ├─ soc_axi_lite_top 三级CPU，ENABLE_TRAPS=1，独立指令ROM，AXI主桥
  │                     └─ axi_lite_ram：CPU外、同一FPGA内的16KiB RAM
  └─ LED            CPU软件GPIO输出；复位时全灭
```

新固件安装mtvec和有效栈，执行六种CSR、FENCE及四次异常：ECALL、EBREAK、非法指令0xffffffff、未知CSR0x77702073。每次检查mcause/mepc/mtval/mstatus，保存RAM日志，经MRET返回后继续执行。全部校验通过后打印17字节（包含CR LF）：

```text
TRAP BOARD PASS
```

LED2常亮，LED1每约0.5秒翻转（完整周期约1秒）。软件失败时LED3常亮并输出26字节 `TRAP BOARD FAIL XXXXXXXX` 加CR LF。错误码1为RAM guard不符或blink_cycles为0，2为mtvec不符，3–7为CSR读写校验失败，8为misa/mhartid不符，9为FENCE后RAM不符，10为异常返回后的最终状态不符；0x10+slot为异常描述不符，0x20+slot为RAM日志不符。KEY2–KEY8不控制本固件的LED。可恢复的imem_fault是前端待接管状态，因此新顶层不把它直接当成粘滞故障灯。

程序永不返回main、不写tohost；KEY1重新清除CSR、流水线、AXI和外设协议状态，然后重新运行并输出完整PASS。AXI RAM的物理内容保持，startup会再次清除自己的BSS，异常计数/日志将重新开始；已接受的写不能回滚。本例仍是单机器模式、无中断/嵌套的同步异常验收，入口使用当前有效的16字节对齐栈，详见下一节的入口限制。

| 新增文件 | 用途 |
| --- | --- |
| rtl/trap_board_top.v | 固定开启异常、50 MHz/115200、共同复位和LED |
| software/trap_board.c | 板级异常自检、PASS/FAIL和持续心跳；复用原trap_entry.S |
| tools/build_trap_board_images.py / build_trap_board.bat | RV32I_Zicsr/ILP32/O2/Werror构建，ELF/map/dump及源码/镜像SHA |
| programs/trap_board.hex / trap_board_data.hex / trap_board_sim_data.hex / trap_board_symbols.vh | 满深度硬件/仿真镜像与ELF地址宏 |
| tb/trap_board_tb.v / run_trap_board.do | 3组真实50 MHz/115200板级RTL测试 |
| tb/trap_board_netlist_tb.v / run_trap_board_netlist.do | 同一硬件镜像的综合网表功能验收，带源码/镜像/构建器过期检查 |

固件有效代码1764字节，初始化data68字节；ROM8192字、RAM4096字。硬件与仿真指令bin及所有符号地址逐字一致，RAM仅blink_cycles一个字不同：硬件25000000，仿真2000。当前blink_cycles=0x1003c、ram_guard=0x10040；异常标签/变量地址从ELF生成，不要求手工同步TB。串口和50 MHz时钟不加速。仓库已提供镜像，只有改新软件后才需要在Git Bash重新构建：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_trap_board.bat
```

相关新配置修改后的ModelSim入口：

```tcl
cd D:/FPGA/riscv_3stage
do run_trap_board.do
```

3组RTL已通过，done=3'h7/test_pass=1，结束3812072 ns，0错误0警告。测试逐字节验证实际115200 TX引脚、每次启动4trap/4MRET/1FENCE、软件RAM/CSR结果、完整加速心跳周期、普通KEY1重启、handler进行中复位，以及guard注入FAIL/修正RAM后KEY1恢复；共同复位保留独立RAM标记。没有重复上一阶段已通过且未改代码的15组异常测试和21个旧CPU集成。

专用本地PDS入口（生成文件，不下载或烧写Flash）：

```bash
cmd.exe //c build_pds_board.bat --variant trap_board --stage bitstream
```

这个variant自动选择trap_board硬件固件，混用旧固件会拒绝；输出为 `build/pds_trap_board/`。器件PGL50H/-6/FBG484，复用未修改的19个物理管脚及50 MHz FDC。仅合成副本改名board_top并替换硬件HEX绝对路径；不使用sim_data。路由器摘要及最终独立STA均须通过全部setup/hold/recovery/removal和脉宽检查，才生成 `generate_bitstream/board_top.sbit` / `.bin`；manifest记录source/image/builder/bitstream SHA和enable_traps=1、hardware_verified=false。

2026-10-02本次综合资源为2552 LUT（5.96%）、1148寄存器（1.79%）、31 DRM18K（23.13%）、19 IO、0 APM、0 latch。DRM中15块为独立指令ROM、8块为AXI RAM；另8块为仍被综合器保留的CPU内部RAM，在外部数据模式不提供本程序的数据访问。本轮不改核心移除此资源，不能将它计作额外可用程序RAM。最终50 MHz STA慢角setup/hold为+2.434/+0.146 ns，快角+7.717/+0.102 ns；recovery/removal和脉宽也全部通过。约56.928 MHz是该实现的工具估计，不是实测Fmax或CoreMark结果，也不能直接与其他顶层/固件的资源比较。

PDS仍有告警：K18/J19/H20是配置复用管脚（KEY1/KEY6/KEY7），constraint_check列为3项critical warning，实物须核对配置模式与手册；5处通用ASYNC_REG属性被PDS忽略，不能声称工具自动完成了CDC标注。18项Timing-4086/4087针对异步按钮/RX及LED/TX外部IO，本设计按既有FDC排除这些外部时序路径；内部50 MHz时序仍接受上述检查。同步器RTL保留，未发现内部时钟未约束或锁存器。本次工具通过仍须结合实物复位、串口和LED验收。

同一硬件镜像的综合网表入口：

```tcl
do run_trap_board_netlist.do
```

综合网表功能测试已通过，两次启动均逐字节收到完整17字节PASS，验证默认1ms上电/松键等待、PASS灯和KEY1重启；test_pass=1，结束5277130 ns，0错误0警告。ROM/RAM使用综合时嵌入的硬件初始化内容，没有修改网表存储器或加速串口。本检查不含SDF回标，50 MHz时序证据来自上述最终STA；硬件0.5秒心跳未在网表中跑满，其完整周期由RTL的单字数据缩短测试覆盖。

本次日志为 `build/trap_board_validation.log`、`build/trap_board_netlist_validation.log`，固件ELF/map/dump及镜像检查在 `build/trap_board_firmware/`，PDS候选及manifest在 `build/pds_trap_board/`。候选sbit的SHA-256为 `a7d7f407800f4994d157fc15eab27d393cc6607b0825f3d20ba8ef137d7f23b7`。本次功能源码与镜像冻结后未重复旧回归。

本次ModelSim/PDS在本机英文路径快照运行，按SHA核对对应源码后回存构建产物。PDS工程和报告记录该快照绝对路径；移机或改路径后应使用上述构建入口生成自己的工程。源码包不包含厂商模型、工具或许可证，综合网表脚本从本机PDS安装读取官方模型。

等板子在身边，核对MES50HP/PGL50H-6IFBG484和下载线后，仅将对应候选sbit临时下载到SRAM；UART115200、8N1、无流控，按KEY1后核对PASS、LED2和LED1心跳，再按KEY1确认完整重启。尚未做实物下载验收，本节工具通过不代表实物或CNN系统完成。旧AXI控制验收章节仍对应旧配置。

## 新增：FENCE、CSR与最小机器模式同步异常

本节记录以 `a2bfff0` 为基线的CPU同步异常里程碑。在 `cpu_top` 或 `soc_axi_lite_top` 实例中设置 `.ENABLE_TRAPS(1)`，开启以下指令与恢复机制；参数默认0，旧板级程序未安装异常处理函数，因此旧顶层仍保持兼容模式。新能力不是自动启用在旧位流中；本节之后新增的trap_board显式开启它并使用自己的源码/固件/候选位流，见上一节。

- FENCE：支持opcode=0x0f/funct3=0，包括空前驱/后继和保留字段；按保守屏障处理。现有CPU在LOAD/STORE响应完成前不能执行下一条EX指令，所以屏障无需新增总线请求，退休时较早数据事务已完成。
- ECALL/EBREAK：记录自身PC并进入软件处理程序，异常指令不退休。EBREAK的mtval记录自身PC，ECALL为0。
- Zicsr：CSRRW/CSRRS/CSRRC与三个立即数形式。读结果走WB前递；写意图依据编码的rs1=x0或zimm=0，不依据寄存器内容是否为0。未知CSR或只读CSR的写入产生非法指令异常。
- MRET：跳转到mepc，恢复MIE/MPIE；只有机器模式，MPP固定3。
- 同步异常：较早数据响应错误优先；取指错误等待较早EX和访存完成。异常指令及其年轻指令不产生退休、链接寄存器写入、CSR修改或错误路径RAM/MMIO操作；较早WB和已完成STORE保留。

| CSR | 地址 | 本轮行为 |
| --- | --- | --- |
| mstatus | 0x300 | 仅MIE[3]、MPIE[7]可写，MPP[12:11]固定3；其他位为0 |
| misa | 0x301 | 固定0x40000100；合法WARL写入忽略 |
| mtvec | 0x305 | 仅Direct模式；写入低2位清零；复位0 |
| mscratch | 0x340 | 32位读写，复位0 |
| mepc | 0x341 | 32位读写，IALIGN=32低2位清零 |
| mcause / mtval | 0x342 / 0x343 | 读写；异常覆盖为当前描述 |
| mvendorid / marchid / mimpid / mhartid / mconfigptr | 0xf11–0xf15 | 只读0；有写意图则非法 |

异常原因0为取指地址错位，1为取指访问错误，2为非法指令，3为断点，4/5为LOAD错位/访问错误，6/7为STORE错位/访问错误，11为机器模式ECALL。取指和数据地址错误的mtval保存地址，非法指令保存32位指令。取指目标错位归属于导致它的已取到的分支/JAL/JALR，mepc为控制指令PC且不写link；对齐目标访问错误归属于目标PC。数据错位在请求发出前阻止访问。已接受从设备的写不能由CPU回滚；错误响应只阻止该指令退休。

trap入口使用mtvec直接地址；入口时MPIE=MIE、MIE=0，MRET时MIE=MPIE、MPIE=1。新增调试输出 `trap_valid/trap_pc/trap_cause/trap_tval` 给出单拍异常及描述，内部CSR也可添加到ModelSim波形。使能模式的imem_fault是等待接管的前端描述，重定向后清除；数据错误直接转为trap，不再置粘滞dmem_fault。兼容模式原故障灯和复位恢复行为保持原样。

| 新文件 | 用途 |
| --- | --- |
| software/trap_entry.S | 保存30个整数寄存器、分配128字节栈帧并保持已有16字节对齐、调用C处理程序、恢复寄存器并MRET |
| software/trap_demo.c | 真正执行CSR/FENCE和4次异常，校验mepc/mcause/mtval/mstatus与返回后的RAM结果 |
| tools/build_trap_images.py / build_trap.bat | RV32I_Zicsr/ILP32构建；生成完整指令/数据HEX及基于ELF符号的TB地址宏 |
| programs/trap_demo.hex / trap_demo_data.hex / trap_demo_symbols.vh | 8192/4096字镜像、符号地址；本次1316字节text、76字节初始化data |
| tb/cpu_trap_tb.v / run_trap.do | 8组独立指令与精确异常测试 |
| tb/cpu_trap_edges_tb.v / run_trap_edges.do | 4组额外边界、优先级和握手状态复位测试 |
| tb/trap_c_tb.v / run_trap_c.do | 3组真实C经实际AXI RAM执行，AW/W不同等待顺序及UART引脚逐字节验证 |
| run_trap_affected.do | 仅在CPU相关修改后运行受影响集成，不调用旧外设/存储/AXI单测或CoreMark算法 |

新HEX已生成，首次查看无需编译C。修改新软件后执行 `cmd.exe //c build_trap.bat`。旧程序镜像、算法源、UART/FIFO/GPIO/AXI设备和存储模块功能均未改变。CPU、decoder、if_stage修改了功能；soc_axi_lite_top透传使能和debug；旧顶层及测试平台对新增输出补显式空连接，没有改刺激或断言。

ModelSim新入口（各组可独立运行，已通过且源码未改无需重跑）：

```tcl
cd D:/FPGA/riscv_3stage
do run_trap.do
# 8组，done=8'hff，test_pass=1，14600 ns
```

```tcl
do run_trap_edges.do
# 4组，done=4'hf，test_pass=1，4050 ns
```

```tcl
do run_trap_c.do
# 3组，done=3'h7，test_pass=1，173610 ns
```

C固件通过后UART输出42字节 `TRAP PASS FENCE CSR ECALL EBREAK ILLEGAL` 加CR LF，再经原startup写tohost=1。仿真UART用100 MHz/5 Mbaud（20拍/bit）加快验证，不是板级115200配置。handler仅针对演示的四条32位指令将mepc加4；通用程序必须按异常原因设计恢复，不能盲目跳过所有访存/取指错误。该入口不能直接替换旧板级演示固件，后续新板级顶层需要使能并重新构建/验收。

`trap_entry.S` 使用被打断程序的当前sp，要求进入前已有有效可写、16字节对齐的栈，并预留128字节寄存器帧及C handler自身的栈空间；减128不会修正原先未对齐的sp。本例由startup建立满足条件的栈。入口不提供独立异常栈，不支持入口/handler再次异常或中断嵌套。

2026-10-02新增15组全部通过，最终ModelSim编译/仿真0错误0警告。实际C程序每组4次异常与4次MRET、6CSR/FENCE，AXI RAM写/读217/208，UART42字节；三个配置的轮询量不同，退休指令数不能用来直接比较性能。异常测试覆盖所有本轮原因、RO/WARL、CSR前递与写抑制、错误路径CSR/RAM/GPIO、较早STORE完成、过期错误丢弃和CSR/协议复位。记录在 `build/trap_validation.log`、`trap_edges_validation.log`、`trap_c_validation.log` 及源码SHA清单。

本轮CPU/decoder/前端功能发生变化，因此补查21个受影响旧CPU、SoC、AXI与板级RTL集成顶层，全部功能通过；未重复未改功能的外设/存储/AXI单测或CoreMark算法。首段10组已通过后，脚本读取被优化的test_pass失败；改用+acc并从第11组继续，没有重跑前10组。旧输出空连接导致的警告随后只做连接修正和编译/展开检查，不改变刺激、断言或RTL功能，不再重复功能仿真。两个分段日志及最终编译检查记录在build目录。

该同步异常里程碑当时没有中断输入或mie/mip；后续新增的可选定时器中断与mie/mip见首节。仍无S/U模式、委托、PMP、标准mcycle/minstret CSR、FENCE.I或Cache。CPU同步异常里程碑可称RV32I的40项基础指令行为及Zicsr/MRET已实现和定向验证，不能称完整特权架构或标准一致性测试通过。旧CoreMark单次记录不作为新模式跑分。该里程碑当时没有PDS/位流/实物验证；随后trap_board的本地工具验证见上一节，实物仍未验收。manifest在其源码改变后会拒绝旧网表。规范依据：[RV32I](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html)、[Zicsr](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html)、[Machine ISA](https://docs.riscv.org/reference/isa/v20240411/priv/machine.html)。

## 新增：AXI 控制系统的盘古50板级自检

`axi_control_board_top.v` 将当前AXI控制系统接入MES50HP的50 MHz时钟、KEY1复位、UART与LED；新C固件把计算结果变为实物可以观察的串口文字和状态灯。本版本仍是通用加法控制演示，没有CNN推理或音频输入。本节的工具验证仅属于这一新增顶层和固件，不沿用其他版本的位流或时序结果。

```text
axi_control_board_top     MES50HP引脚；50MHz / UART115200
  ├─ board_reset         KEY1，默认上电/松键延迟50000拍
  ├─ soc_axi_control_top 自研三级CPU + 独立ROM + AXI主桥
  │                       └─ 1主2从分发器 → AXI RAM / 加法控制设备
  └─ LED状态             正常由CPU GPIO输出；CPU故障由顶层显示
```

新程序不返回 `main`，不使用 `tohost` 作为实物提示。初始化数据、3次任务、DONE保持/清除和RAM读回全部校验成功后，在板载串口输出以下55字节（两行末尾均CR LF）：

```text
AXI RESULTS 0000002A 00000001 80000000
AXI CTRL PASS
```

三项结果来自CPU实际读回并保存到RAM的值。UART为115200、8N1、无流控；50 MHz整数分频每位434拍。软件自检失败时输出 `AXI CTRL FAIL XXXXXXXX` 加CR LF，XXXXXXXX为8位大写十六进制错误码；CPU总线/取指故障会停止软件执行，由顶层点亮对应故障灯，不能期待停机后的CPU继续打印FAIL。

| LED状态 | 含义 |
| --- | --- |
| 全灭 | 复位或自检尚未完成 |
| LED2常亮，LED1每约0.5秒翻转 | 自检通过；完整心跳周期约1秒 |
| LED3常亮（0x04） | 软件自检失败，串口提供错误码 |
| LED7常亮（0x40） | 数据访问故障，CPU粘滞停止 |
| LED8常亮（0x80） | 取指故障，优先于数据故障显示 |

错误码2为启动RAM guard不符，3为控制设备初态异常，4为任务轮询超限或完成时仍BUSY，5为结果不符，6为重复读取/DONE/启动计数异常，7为CLEAR_DONE后状态异常，8为最终RAM校验不符。软件只启用GPIO低3位；本固件不将KEY2–KEY8作为LED按键演示。LED高电平点亮，引脚和电平复用原 `pds/board_top.fdc`，19个物理管脚已与本地MES50HP V1.1手册核对。

KEY1使整个CPU/AXI互联/从设备共同复位，控制任务和寄存器清零，协议状态清除，RAM物理内容保留。重新运行的 `start.S` 会清除 `.bss`，因此软件启动后的所有RAM变量不保证保持原值；测试使用栈顶以上的保留字检查RAM保留。按KEY1后应重新输出完整结果和PASS；这仍待实物验收。

| 新增或修改文件 | 作用 |
| --- | --- |
| `rtl/axi_control_board_top.v` | 新板级连接、50 MHz UART参数、复位与独立故障灯 |
| `software/axi_control_board.c` | 永不返回的板级自检、串口结果/错误码、心跳 |
| `tools/build_axi_control_board_images.py` / `build_axi_control_board.bat` | 只生成新板级指令、硬件数据和加速仿真数据 |
| `programs/axi_control_board.hex` / `axi_control_board_data.hex` / `axi_control_board_sim_data.hex` | 一份共同指令镜像及两份数据镜像 |
| `tb/axi_control_board_tb.v` / `run_axi_control_board.do` | 新板级5组RTL测试，使用独立工作库 |
| `tb/axi_control_board_netlist_tb.v` / `run_axi_control_board_netlist.do` | 本次实际硬件镜像的综合后功能检查 |
| `tools/build_pds_board.py` | 增加专用axi_control_board variant；旧入口保留 |

新固件有效载荷944字节指令、100字节初始化数据，满深度8192/4096个32位字。构建器使用RV32I/ILP32、O2和Werror，比较硬件/仿真指令bin逐字节一致；RAM镜像仅 `blink_cycles` 一个字不同（硬件25000000、仿真2000），UART和任务时钟不加速。当前 `ram_guard=0x1005c`、`blink_cycles=0x10060`、`observed=0x10064`；改固件布局后需同步检查FAIL注入测试的guard地址。

仓库已有新HEX，首次检查无需编译C。仅修改新固件后在Git Bash执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_axi_control_board.bat
```

构建日志、ELF/map/dump/symbols与镜像一致性报告在 `build/axi_control_board_firmware/`。工具链选择与上一阶段相同。

修改相关新路径后的ModelSim入口：

```tcl
cd D:/FPGA/riscv_3stage
do run_axi_control_board.do
```

最后应为 `done=5'h1f`、`test_pass=1`；已保存波形可用 `vsim -view axi_control_board_run.wlf` 查看。脚本只运行新板级测试，不调用旧CPU/AXI/外设/CoreMark回归。原相关代码未改且已通过时无需重复测试。

专用PDS构建入口在Git Bash执行：

```bash
cmd.exe //c build_pds_board.bat --variant axi_control_board --stage bitstream
```

该variant自动选 `axi_control_board` 固件；显式混用其他固件会报错。输出只写 `build/pds_axi_control_board/`，仅综合副本改名为board_top并使用硬件HEX绝对路径，仍复用原引脚约束。脚本先核对路由器摘要及最终独立STA，全部通过后生成 `generate_bitstream/board_top.sbit` 和 `.bin`，**不连接、不下载、不烧写Flash**。只检查时序可选 `--stage timing`。其他variant仍是各自原顶层，不包含本AXI板级版本。

完成本variant构建后，可运行本次新综合网表功能入口：

```tcl
do run_axi_control_board_netlist.do
```

脚本检查manifest的RTL/初始化文件SHA256，拒绝源码或镜像已变的旧网表；使用本机PDS官方模型，不分发模型。综合网表采用硬件数据和默认50000拍复位延迟，检查两次完整串口、PASS灯、KEY1重启；未缩短硬件镜像的心跳等待，也未在此测试模拟完整0.5秒翻转。心跳逻辑由同指令镜像、仅改变blink数据的RTL测试验证。综合网表无SDF，不能代替STA或实物验证。

本次本机验证（2026-10-02，PDS 2022.2-SP6.4，PGL50H-6IFBG484）：

| 检查 | 结果 |
| --- | --- |
| 新板级RTL 5组 | 两组正常/忙时复位、软件FAIL、真实数据/取指故障及恢复通过；55字节PASS/24字节FAIL、心跳、KEY1与RAM保留；9703470 ns；done=5'h1f/test_pass=1 |
| 本次硬件综合网表 | 真实硬件ROM/RAM初始化、三项结果、115200 UART、PASS灯、KEY1重启通过；11807570 ns；test_pass=1 |
| ModelSim最终编译/仿真 | 两个新入口均0错误、0警告；首次新RTL测试的CR字符串期望值表示已修正，仅复查该尚未通过的测试；未重跑旧测试 |
| ADS综合资源 | 2510 LUT、1509寄存器、72个分布式RAM单元、31个DRM18K；0锁存器、0 APM |
| 实际内存归属 | 外部取指ROM 15 DRM18K；实际AXI RAM 8 DRM18K；工具保留的CPU内部未用RAM 8 DRM18K |
| 最终STA Slow setup / hold | WNS +1.471 ns / WHS +0.029 ns，0失败端点 |
| 最终STA Fast setup / hold | WNS +7.088 ns / WHS +0.023 ns，0失败端点 |
| recovery / removal / pulse width | 两个corner均通过 |
| 管脚/位流 | 19管脚与FDC一致；本次sbit/bin已生成，未下载 |
| 实物/CNN | 尚未验收；没有CNN推理或端到端音频结果 |

STA来自 `report_timing/board_top.rtr`；路由器摘要的Slow +1.797/+0.018 ns、Fast +7.346/+0.014 ns另行记录，不能与最终报告混用。资源表属于当前固件和顶层，换程序后需要重新检查映射。原CPU内部RAM使能始终为0，RTL验证确认CPU实际经外部RAM路径访问，但PDS仍保留该8个DRM18K实例；本阶段未修改CPU来消除这部分资源。

PDS仍有三种配置复用管脚告警（K18/J19/H20，在约束与映射阶段各出现一次）、5条未识别 `ASYNC_REG` 属性告警及fanout等告警；不能称PDS零告警。布局布线管脚已核对，配置必须保持复用引脚释放。约束排除异步KEY/RX输入与非源同步LED/TX输出，未建立外部IO延迟模型；内部CPU/AXI/存储器/复位释放仍按50 MHz检查。

本次日志为 `build/axi_control_board_validation_final.log`、`build/axi_control_board_netlist_validation.log`，PDS证据在本variant目录。旧源码、主桥/分发器/设备、旧固件和旧测试入口保持不变。本轮不执行硬件下载；首次实物验收仍需实物器件、供电与下载线匹配后进行。板级自检版本的串口/LED预期以本节为准，不使用旧Hello或RX回显标准。

## 新增：AXI 地址分发与硬件控制流程

`soc_axi_control_top.v` 将上一阶段的CPU/主桥、真实RAM从设备与新增控制设备连接起来。CPU执行新的RV32I C镜像，配置两个操作数，写START，轮询STATUS，再读取RESULT。加法由 `axi_lite_ctrl.v` 在设定时钟数后完成。该设备用于验证控制流程，临时地址和寄存器不是正式CNN联调协议；当前没有CNN推理、音频输入、DDR或DMA。

```text
soc_axi_control_top
  └─ u_core: soc_axi_lite_top
       ├─ 自研 IF → EX → WB CPU + 独立取指ROM
       └─ CPU数据握手 → dmem_axi_lite_bridge
                         │ 32位 AXI4-Lite
                     u_router: axi_lite_1x2
                         ├─ m0 → u_ram: axi_lite_ram → data_mem
                         └─ m1 → u_ctrl: axi_lite_ctrl
```

取指仍使用独立ROM握手，只有数据访问经过本AXI路径。CPU内的 `0x2000xxxx` UART/GPIO/计数器MMIO继续在主桥之前译码。

| 新文件 | 作用 |
| --- | --- |
| `rtl/axi_lite_1x2.v` | 1主2从地址分发；独立AW/W缓存、目标锁定、B/R保持、未命中DECERR |
| `rtl/axi_lite_ctrl.v` | 可综合的通用控制设备；配置、START、BUSY/DONE、结果及启动计数 |
| `rtl/soc_axi_control_top.v` | 新闭合系统，连接原CPU/主桥、分发器、RAM与控制设备 |
| `software/axi_control.h` | 临时寄存器定义和volatile读写函数 |
| `software/axi_control_demo.c` | 真实C程序；3次配置/启动/查询/读结果，同时校验普通RAM |
| `tools/build_axi_control_images.py` / `build_axi_control.bat` | 只构建新固件与两份新HEX |
| `programs/axi_control_demo.hex` / `axi_control_demo_data.hex` | 已生成的满深度指令与初始化数据镜像 |
| `tb/axi_lite_1x2_tb.v` / `tb/axi_lite_ctrl_tb.v` | 新分发器和控制设备的独立协议/功能测试 |
| `tb/axi_control_system_tb.v` / `run_axi_control.do` | 新系统9组集成测试及本阶段独立入口 |

默认指令区为 `0x00000000–0x00007FFF`；AXI数据RAM为 `0x00010000–0x00013FFF`，`tohost=0x00013FFC`；控制设备窗口为 `0x30000000–0x300000FF`。最后一个窗口只为演示分配，可在HDL和软件同时修改。

控制设备寄存器均按32位字访问：

| 偏移 | 名称 | 访问 | 行为 |
| --- | --- | --- | --- |
| `0x00` | CTRL | RW | 读0；写bit0=START、bit1=CLEAR_DONE |
| `0x04` | STATUS | RO | bit0=BUSY，bit1=DONE |
| `0x08` | OPERAND_A | RW | 第一个32位操作数，WSTRB逐字节更新 |
| `0x0C` | OPERAND_B | RW | 第二个32位操作数，WSTRB逐字节更新 |
| `0x10` | RESULT | RO | 最近一次完成任务的32位结果 |
| `0x14` | START_COUNT | RO | 成功接受的START次数 |

成功START快照A/B、清DONE、置BUSY并将计数加1；经过 `JOB_CYCLES` 个时钟产生模2^32加法结果，清BUSY、置DONE。设备默认64拍，新系统默认256拍，便于CPU实际观察BUSY。任务进行中更新A/B只影响下一次任务；结果和DONE的读操作没有清除副作用。CLEAR_DONE不取消进行中的任务，同拍任务完成优先于清除。

CTRL命令只受WSTRB[0]控制；可写寄存器的零mask成功但无副作用。BUSY期间START返回SLVERR，整条命令不生效，包括同一条命令中的CLEAR_DONE。只读寄存器写入、未知偏移、从设备直接收到的未对齐/越界访问返回SLVERR，错误读数据为0。CPU主桥会先将合法子字地址对齐到32位字，AXI4-Lite没有size信号，设备无法从读地址区分CPU的LW与LB；软件控制接口因此使用32位读写。

分发器按两个半开地址窗口选择目标，不做地址平移；每路独立允许一笔读和一笔写，而原CPU主桥仍只允许一笔总事务。AW/W可任意先后到达，分发器收到两者后才向锁定的目标投递，并分别等待接受；未命中写也必须收到AW/W后才能产生DECERR。未命中读返回DECERR和0，均不触发从设备请求。地址上限使用33位计算，支持窗口结束于4 GiB；窗口需非空、字对齐且不重叠。

本系统使用同一时钟和共同复位。复位清除CPU/桥/分发器/从设备的协议状态，取消控制任务并清控制寄存器；RAM内容保留，已完成的写不回滚。设备读数据在AR接受时快照，B/R响应保持到消费。PROT传递到从设备，但演示设备不实施权限或安全隔离。这个旧控制顶层使用ENABLE_TRAPS=0，没有跨时钟、总线超时、异常入口或中断；设备返回错误仍使CPU粘滞停止，必须复位恢复。新增可选同步异常见首节。

更改基址/容量时需同步修改HDL、链接脚本、HEX和测试。RAM与控制设备都不能覆盖CPU本地 `0x2000xxxx` 窗口；新C镜像固定使用16 KiB数据RAM。仅更改控制基址可用下述构建选项，但仍需同步HDL参数与测试地址。构建器拒绝零基址，避免C命令寄存器访问成为空指针解引用；HDL窗口可配置不代表现有C可直接用于所有地址。

仓库已提供新HEX，首次检查不需要编译C。仅在修改新软件后，在Git Bash执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_axi_control.bat
# 更改演示基址时：cmd.exe //c build_axi_control.bat --ctrl-base 0x30001000
```

构建器使用RV32I/ILP32、O2、裸机链接、Wall/Wextra/Werror；工具链由 `AXI_CONTROL_CROSS`、`BOARD_CROSS`、PATH或本机后备路径查找。新镜像有效载荷444字节指令、40字节初始化数据，分别填充至8192/4096个32位字。只更新两份 `axi_control_demo*` HEX，原程序镜像不变。

新增测试入口在ModelSim Transcript中执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_axi_control.do
```

脚本只运行本阶段分发器、控制设备、闭合系统三组新测试，使用 `axi_control_work` 库。每组必须 `test_pass=1`；最后系统 `done=9'h1ff`、`test_pass=1`。`$stop`/Break为主动结束。已保存波形可用 `vsim -view axi_control_system_run.wlf` 查看，不再 `run -all`。修复某一组时先设置 `set axi_control_tests {router}`、`{ctrl}` 或 `{system}`，只执行受影响的组；源码不变且已经通过时无需重复仿真。

本次本机验证记录（2026-10-02）：

| 检查 | 结果 |
| --- | --- |
| 分发器两组 | 普通窗口及结束于4 GiB窗口；AW/W顺序、背压、错误传递、未命中、并行读写和复位通过；每组B=12/R=21、实际写11、写取消6/读取消2；5730 ns |
| 控制设备两组 | 34完整写/34完整读，7写错误/3读错误；4启动/3完成/1复位取消；五种复位、忙时拒绝、快照、部分写及JOB_CYCLES=1边界通过；9317 ns |
| 闭合系统9组 | 三组新C、四组实际DECERR/SLVERR及复位恢复、错路START抑制、忙时共同复位取消通过；20536 ns；done=9'h1ff/test_pass=1 |
| 新C程序结果 | 三组均tohost=1；任务结果42、1、80000000；START恰3次、RESULT读6次、控制写12次；RAM写8/读15 |
| 新C完成快照 | 无额外等待1281周期/523退休；AW先、W先延迟配置均2045周期/298退休；状态轮询次数不同，不能视为同指令数性能比较或硬件频率证明 |
| 编译及最终仿真 | 0错误、0警告；补充四个故障组的复位恢复后只复查system，补充固定覆盖数量断言后只复查router；未改的ctrl独立测试不重跑 |
| 原有CPU/主桥/RAM/外设/SoC/CoreMark | 相关源码未变，本轮未重复运行旧测试 |

记录保存在 `build/axi_control_validation.log`（首次三组）、`build/axi_control_system_validation.log`（补充故障恢复）和 `build/axi_control_router_validation.log`（补充覆盖数量断言）。本节保存该功能阶段的记录；后续新增板级自检/PDS证据见上方章节和专用variant，实物尚未验收。通用加法设备的通过不等于CNN已接入。

## 新增：32位 AXI4-Lite 数据主桥

`soc_axi_lite_top.v` 连接自研CPU、原独立取指ROM与新数据主桥，并导出32位AXI4-Lite主设备端口。测试中接入可综合的 `axi_lite_ram.v`，让既有C镜像真实执行的LOAD/STORE经过AW/W/B/AR/R通道。CPU、既有SoC、外设、固件与旧测试入口均保持原代码；本阶段只运行新增路径的测试。

```text
soc_axi_lite_top
  ├─ u_cpu       原IF → EX → WB；0x2000xxxx仍为本地MMIO
  ├─ u_imem      原soc_instr_mem取指ROM
  └─ u_bridge    CPU数据握手 → 32位AXI4-Lite主设备端口
                       │
                 axi_lite_ram → data_mem
```

| 文件 | 作用 |
| --- | --- |
| `rtl/dmem_axi_lite_bridge.v` | 单笔CPU请求转AXI读写；AW/W独立握手、响应保持、本地非法请求与总线错误返回 |
| `rtl/soc_axi_lite_top.v` | CPU、取指ROM和主桥的独立联调入口；AXI端口供外部从设备连接 |
| `rtl/axi_lite_ram.v` | 同步RAM的AXI从设备；分别缓存AW/W、按WSTRB一次写入、读快照与稳定响应 |
| `tb/axi_lite_bridge_tb.v` | 独立BFM检查主桥协议、字节通道、错误、背压和共同复位 |
| `tb/axi_lite_ram_tb.v` | 检查真实RAM从设备的独立通道、任意掩码、响应快照、端口仲裁及复位 |
| `tb/axi_lite_cpu_tb.v` | 三组真实C、两组定向指令、两组CPU总线故障与复位恢复；公开握手事务scoreboard |
| `run_axi_lite.do` | 只编译/运行上述新测试，独立 `axi_lite_work` 库与WLF |

主桥每次只处理一笔CPU事务，不做burst、ID、独占访问、缓存或时钟跨域。五条AXI通道以VALID与READY同沿握手，VALID及payload保持到接受；AW和W同时发起并分别记账，不要求READY同时出现。[Arm AMBA AXI协议规范](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)

CPU端size=0/1/2分别为字节/半字/字，按原字节地址先检查合法尺寸、对齐及精确写mask，再清AXI地址低两位。CPU已经移位WDATA/WSTRB，桥直接转发；AXI读回完整32位字，CPU继续提取与扩展。桥不预设设备地址范围，译码由从设备负责。两条PROT固定000（非特权、Secure、数据访问）；本RAM忽略该属性，未实现安全隔离。

CPU响应只在AXI B/R完成后产生，并保持到CPU接受。仅OKAY成功；其他RESP转 `dmem_rsp_error`，错误读与全部写返回0。ENABLE_TRAPS=0时将错误指令停止且不退休，等待复位；ENABLE_TRAPS=1时进入同步异常，见首节。仍无超时机制。错误响应不保证任意设备没有产生副作用，已经完成的写不能回滚。本RAM对未对齐/越界地址返回DECERR且无RAM读写使能。

CPU、桥、从设备使用同一时钟和共同复位。共同复位取消未配对AW/W、等待AXI响应及等待CPU消费的状态，但不初始化或清空RAM。只复位桥而让从设备保留旧响应不在本阶段支持范围内。RAM允许任意WSTRB（含0000成功no-op）；CPU主桥仅允许与CPU访问尺寸匹配的mask。

C程序仍使用 `0x00010000–0x00013FFF`，`tohost=0x00013FFC`，固件无需重新编译。RAM的AW/W/AR/B/R等待参数用于分别制造各通道等待；参数为0也仍有同步读捕获和响应状态机延迟，并非零周期访问。`soc_axi_lite_top` 的MMIO等待只控制CPU本地外设，不能当作AXI通道等待。

新增测试在ModelSim Transcript执行一次：

```tcl
cd D:/FPGA/riscv_3stage
do run_axi_lite.do
```

脚本依次运行桥、RAM从设备、CPU集成，三个 `test_pass=1` 才通过。最后停留在 `axi_lite_cpu_tb`，预期 `done=7'h7f`、`test_pass=1`。`$stop`/Break为测试主动结束，密集时钟及完成后CPU的结尾自循环不代表重新开始测试。C性能以第一次程序完成且最后访存响应消费后的日志为准，不能读取其等待其他case结束时继续累加的原始计数器，也不沿用原直连RAM的216周期断言。

需要修复某组新测试时，可先设置 `set axi_tests {bridge}`、`{ram}` 或 `{cpu}` 再 `do run_axi_lite.do`，只执行受影响的一组；已经通过且相关代码未变时不重复运行。已保存WLF时，可在ModelSim中用 `vsim -view axi_lite_cpu_run.wlf` 查看记录，无需再次 `run -all`。

本次本机ModelSim验证记录（2026-10-02）：

| 检查 | 结果 |
| --- | --- |
| 主桥独立测试 | CPU接受36/完成30/错误13/复位取消6；9种非法请求不发AXI；AW先/W先/同时、字节通道、SLVERR/DECERR和背压通过；5236 ns |
| 实际AXI RAM从设备 | 全16种WSTRB、B/R稳定、同步读快照、共享端口竞争、DECERR隔离和复位保留通过；3840 ns |
| CPU集成7组 | 三组C、两组定向指令、两组实际RAM总线错误及复位恢复通过；14126 ns；done=7'h7f、test_pass=1 |
| 固定C镜像结果 | 三组均tohost=1、初始化值12345678、155条退休；24次AXI写、13次AXI读，各通道恰好一次完成 |
| C程序完成周期快照 | 零额外等待364周期；AW先和W先的延迟配置均1402周期；仿真时钟100 MHz，不代表硬件最高频率 |
| 编译与最终仿真 | 0错误、0警告；首次CPU组有24个未连接调试输出告警，补齐连接后只复查CPU组，已通过桥/RAM不重跑 |
| 原CPU/外设/SoC/CoreMark | 相关代码未改变，本轮未重复运行旧测试 |

日志为 `build/axi_lite_validation.log`（首次三组）及 `build/axi_lite_cpu_validation.log`（修正输出连接后的CPU组）。本阶段不把仿真RAM当作已连接的CNN或实物板卡。

本节保存主桥功能阶段记录。后续新增AXI板级/PDS证据见上方 `axi_control_board` 章节；实物尚未验收。`build_pds_board.bat --variant soc` 仍构建原直连RAM版本，不包含AXI顶层；此前直连版本位流和50 MHz报告不能作为AXI版本证据。

CNN从设备、寄存器地址与数据格式尚待共同确定；`0x2000xxxx`仍不会经过主桥。此阶段只证明CPU通过AXI正确访存，尚未连接CNN、AXI4 DDR、DMA或AXI4-Stream数据通路。

## 新增：独立片上存储器的最小 SoC

`soc_top.v` 将 `cpu_top` 的 `EXTERNAL_IMEM`、`EXTERNAL_DMEM` 都设为1，实际连接独立的同步ROM/RAM响应模块。这里“外部”指CPU模块之外，ROM/RAM仍由同一片FPGA内部资源实现。取指与数据使用两条独立通道，各允许一笔已接受事务在途，能够并行活动；没有仲裁器、AXI、DDR、DMA或CNN加速器。

```text
soc_board_top       MES50HP 时钟、KEY1复位、LED与UART引脚
  └─ soc_top
       ├─ u_cpu    自研 IF → EX → WB；原UART/GPIO/计数器MMIO
       ├─ u_imem   soc_instr_mem → 同步指令ROM + 握手端点
       └─ u_dmem   soc_data_mem  → 同步数据RAM + 握手端点
```

| 新文件 | 作用 |
| --- | --- |
| `rtl/soc_top.v` | 连接CPU的外部取指、数据端口，导出退休/故障/计数调试信号 |
| `rtl/soc_instr_mem.v` | 请求接受沿读取ROM；支持响应保持、等待和消费响应同拍接受下一笔 |
| `rtl/soc_data_mem.v` | 请求接受沿执行一次RAM读写；检查范围、size、对齐和写字节使能 |
| `rtl/soc_board_top.v` | 与原板级入口同引脚的新SoC入口；原 `board_top.v` 保留 |
| `tb/soc_memory_tb.v` / `tb/soc_top_tb.v` / `tb/soc_board_tb.v` | 新端点、新SoC及新板级连接的验证 |
| `tb/soc_fault_tb.v` | 新ROM/RAM实际报错后的CPU停机、精确副作用及共同复位恢复 |
| `run_soc.do` / `run_soc_netlist.do` | 新RTL测试及新综合网表功能检查入口 |

软件仍使用指令区 `0x00000000–0x00007FFF`、数据区 `0x00010000–0x00013FFF`，`tohost=0x00013FFC`。既有C程序和板级固件镜像不变。`0x2000xxxx` 仍在CPU内部译码到UART、GPIO、计数器等外设，不会送入 `u_dmem`；这些地址尚未成为可接CNN的通用外部MMIO总线。

读请求返回包含目标字节的完整32位字，CPU完成LB/LBU/LH/LHU扩展。写数据已经由CPU按地址偏移移位，SB/SH/SW的 `wstrb` 必须与size、偏移匹配；非法请求只返回error，不读写RAM。写响应为0。非法取指响应为error及0数据。复位同时取消CPU与端点的协议状态，不清空RAM，也不撤销已经接受的写入；没有事务超时。

`soc_top` 的四个 `IMEM/DMEM_*_WAIT_CYCLES` 参数默认0，可为独立端点增加请求/响应等待；DMEM等待也作用于原CPU内部MMIO端点。当前均为同一时钟域。更改容量或基址时必须同时调整链接脚本、完整HEX容量和测试；数据RAM不能覆盖CPU保留的 `0x2000xxxx` 区域。

在ModelSim Transcript中查看本次新测试：

```tcl
cd D:/FPGA/riscv_3stage
do run_soc.do
```

脚本依次运行新存储端点、SoC故障、板级测试和SoC程序，最后保留 `soc_top_tb` 的波形。只有各组 `test_pass=1` 才算通过，`$stop` 表示测试主动结束。最后 `done=4'hf`、`test_pass=1`。已通过且相关代码未变的旧CPU、UART/FIFO模块测试与CoreMark无需重复运行。

在Git Bash构建新SoC候选工程：

```bash
cmd.exe //c build_pds_board.bat --firmware uart_rx_echo --variant soc --stage bitstream
```

输出只写入 `build/pds_soc/`。脚本读取 `soc_board_top.v`，仅在生成的综合副本中将模块名改为 `board_top` 并将固件路径改为绝对路径，以复用现有引脚约束和仅检查IO的综合网表测试。原板级源码和旧构建目录不变。`do run_soc_netlist.do` 使用本机PDS官方模型检查这份回显固件的综合网表功能，不含SDF时序回标。构建脚本只生成工程、报告和位流，不执行下载或Flash烧写。第一次实物验收仍按原冻结版本的验收文档进行。

SoC两种固件都使用 `build/pds_soc/`，切换 `--firmware` 前需归档其报告和位流；下列构建证据只对应 `uart_rx_echo` 固件。

本次新SoC验证记录（2026-10-02）：

| 检查 | 结果 |
| --- | --- |
| 独立存储端点4组 | 零/固定等待、随机发起间隔与响应背压、连续IF消费/重发、非法访问隔离及三阶段复位通过；11470 ns |
| 新SoC集成4组 | C零/固定等待、字节/半字/字、前递、分支/JAL/JALR、31次精确退休、15次RAM事务及错路MMIO抑制通过；12276 ns |
| 固定C镜像 | 零额外等待216周期、155条退休，数学CPI约1.394（原性能脚本截断显示1.393）；等待配置1217周期、155条退休，结果一致 |
| 新板级顶层2组 | 50 MHz/115200串口回显16字节与KEY1帧中复位；原Hello固件、LED心跳、KEY2和KEY1重启通过；2517050 ns |
| 新SoC故障3组 | 实际RAM越界LOAD/STORE抑制写回/退休；ROM越界错误等待旧STORE完成；粘滞故障与共同复位恢复通过；820 ns |
| 综合网表功能 | 实际回显固件8字节及KEY1重启通过；3096190 ns；无SDF |
| 实际布局布线资源 | 1667 LUT、550 FF、8 DRM、72分布式RAM、19 IO、0 APM |
| 50 MHz最终STA slow setup / hold | 3.034 ns / 0.058 ns，0失败端点 |
| 50 MHz最终STA fast setup / hold | 8.103 ns / 0.022 ns，0失败端点 |
| recovery / removal / pulse width | 两个corner全部通过，0失败端点 |
| 候选位流 | `build/pds_soc/generate_bitstream/board_top.sbit`；未实物验收 |

所有新ModelSim测试的编译/仿真为0错误、0警告。补充IMEM非法响应必须返回0的断言后，只重跑受影响的两个指令端点配置；其余已通过测试不重复运行。CPU、旧存储器/adapter/外设及固件的源码均未改变，未重跑旧CPU回归或CoreMark。

资源取路由后实际使用汇总（模块归属汇总为1663 LUT）。新数据RAM的8个DRM归属于 `u_soc.u_dmem.u_data_mem`；CPU内部旧RAM没有物理RAM资源，少量范围译码逻辑仍被保留。小回显指令镜像在 `u_soc.u_imem` 优化为LUT ROM。仿真仍会初始化CPU原内部存储器实例，但测试确认其读取/写入使能始终关闭。容量参数不能直接等同于这份小固件优化后的物理资源用量。

最终STA取 `report_timing/board_top.rtr`，不混用路由器摘要。PDS复用引脚、忽略通用 `ASYNC_REG` 属性和异步IO约束相关告警仍存在，边界与前述板级版本相同；工具通过不代替实物验收。候选位流SHA-256：`5ddde8bf748446fa71c07d91dadc6465b30b7ea77bda13add472b053edd8c994`。这些检查全部在本机完成。

## 队友快速上手：下载后先看这里

当前仓库包含 **CPU RTL、软件示例、仿真测试和板级工程生成脚本**。下面快速上手使用原 `board_demo` 最小配置；新增SoC、AXI控制和同步异常版本须选择各自章节的固件/variant。板级引脚仅面向MES50HP的PGL50H-6IFBG484，CNN、LCD、振动模块和外部存储器尚未接入；不能把别的开发板直接套用本仓库的引脚约束。仓库已包含预生成HEX，第一次运行不需要先编译C，也不需要复制本机ModelSim工作库或波形。

### 1. 获取完整仓库

推荐使用 Git 克隆，便于后续同步更新。在 Git Bash 中执行：

```bash
mkdir -p /d/FPGA
cd /d/FPGA
git clone https://github.com/a-learner-1/riscv_3stage.git
cd riscv_3stage
git log -1 --oneline
```

上述命令用于第一次下载，目标目录应尚不存在。没有 D 盘时，换成自己的纯英文路径即可；后面的 ModelSim 路径也要对应修改。

也可以在 GitHub 使用 Code → Download ZIP，解压后将目录命名为 `riscv_3stage`。无论采用哪种方式，都应下载整个仓库，不能只下载 `cpu_top.v`，否则会缺少它依赖的 RTL 模块、测试平台和程序镜像。

### 2. 按需要安装工具

| 使用方式 | 所需工具 |
| --- | --- |
| 用 Git 下载和同步代码 | Git |
| 直接运行仓库已有程序的仿真 | ModelSim；不需要 GCC、Python 或 GNU Make |
| 修改 C/汇编并重新生成 HEX | RISC-V GCC 工具链、Python 3；运行验证时还需要 ModelSim |
| 使用 Makefile 构建 C 示例 | 在前述构建工具之外，还需要 GNU Make；不是首次仿真的必需工具 |
| 生成最小板级 FPGA 工程 | Python 3、PDS；已有 HEX 时不需要先安装 GCC |

当前已验证环境为 Windows、ModelSim SE-64 10.6e、RISC-V GCC 15.2.0 和 GNU binutils 2.45。其他工具版本和操作系统尚未完成同等验证；根目录的 `.bat` 构建脚本用于 Windows。

ModelSim 10.6e 对中文工程路径支持不稳定，请使用纯英文目录，例如 `D:\FPGA\riscv_3stage`。不需要另建或下载 `.mpf` 工程文件：根目录的 `.do` 脚本会编译所需模块并启动测试。

### 3. 首次只运行 UART 集成测试

在 ModelSim 的 Transcript 中执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart.do
```

预期输出：

```text
UART received: Hello RISC-V
UART: baud=115200 clocks_per_bit=868 bytes=13
PASS: CPU UART transmit test
```

这个测试运行仓库中的裸机 C 程序，经 CPU 和 MMIO 将字符送入 UART TX，再由独立的仿真接收器从串行线上解码。13字节包含12个可见字符和一个换行。

最后出现 `$stop` 和 `Break in Module` 表示测试平台主动结束，不是错误。波形中的 `received=13`、`uart_busy=0`、`uart_tx=1` 和 `tohost=1` 表示字符全部接收、发送器回到空闲、程序正常结束。

已有 HEX 镜像直接由仓库提供；首次测试不需要执行任何构建脚本，也不必把完整回归逐项重跑一遍。

### 4. 可选：检查 CPU 性能基线

UART 测试通过后，如需核对 CPU 运行和退休计数，再执行：

```tcl
do run_performance.do
```

仓库当前固定 C 镜像的预期结果：

```text
PERF: tohost=1
PERF: cycles=216
PERF: retired instructions=155
PERF: CPI=1.393
```

CoreMark 使用 `do run_coremark.do`，它是单次算法功能校验，不是正式有效跑分。首次上手不要求运行 CoreMark；有关 CRC、计时区间和十秒规则的说明见下文。

### 5. 修改 C 程序后重新构建

先将自己电脑上 RISC-V 工具链的 `bin` 目录加入 Windows 的 `PATH`，并确认以下命令可用：

```bash
riscv-none-elf-gcc --version
python --version
```

部分构建脚本保留了原作者电脑的 `D:\Tools\...` 工具链后备路径。该路径不是项目要求，也不需要在其他电脑上复刻；队友应优先配置自己的 `PATH`。ModelSim 的路径和许可证配置同样由各自电脑管理，不随仓库分发。

在工程根目录的 Git Bash 中，按修改的程序选择一条构建命令：

| 程序源码 | 构建命令 | 对应 ModelSim 测试 |
| --- | --- | --- |
| `software/uart_demo.c` | `cmd.exe //c build_uart.bat` | `do run_uart.do` |
| `software/gpio_test.c` | `cmd.exe //c build_gpio.bat` | `do run_gpio.do` |
| `software/main.c` | `cmd.exe //c build_program.bat` | `do run_c_program.do` |
| CoreMark 算法或裸机适配层 | `cmd.exe //c build_coremark.bat` | `do run_coremark.do` |
| `software/board_demo.c` | `cmd.exe //c build_board.bat` | `do run_board.do` |

Git Bash 中使用 `//c`，避免 MSYS 将 `/c` 转成路径。在 Windows CMD 中，直接执行相应 `.bat` 文件即可。

构建脚本会生成对应的指令 HEX 和数据 HEX，不会自动启动 ModelSim；编译成功后再运行对应测试。保持当前 `-march=rv32i`、`-mabi=ilp32` 等参数，不要改成包含乘除法或压缩指令的 ISA 配置；当前硬件没有这些扩展。

注意测试平台与程序之间的对应关系：

- UART 测试预期固定字符串 `Hello RISC-V\n`。如果改变输出内容，应同步调整 `tb/uart_cpu_tb.v` 的预期字节和长度。
- 性能测试检查当前 C 示例的155条退休指令。修改程序或更换编译配置后，动态指令数量可能变化；应先确认程序执行正确，再重新建立该程序的性能基线。
- 启动文件、链接脚本和数据镜像也属于程序运行依赖，不要只替换指令 HEX 而漏掉配套数据 HEX。

### 6. 后续同步更新

对于通过 Git 克隆且没有本地未提交修改的工程，在 Git Bash 中执行：

```bash
cd /d/FPGA/riscv_3stage
git status -sb
git pull --ff-only
```

如果已有自己的修改或提交，应先保存并处理分支差异，再同步团队代码；不要使用强制覆盖或删除工程的方式更新。通过 ZIP 下载的目录没有 Git 历史，需要重新下载新版本，或改用 Git 克隆。

### 7. 工程文件如何使用

| 位置 | 用途 |
| --- | --- |
| `rtl/` | CPU、存储器、UART 等硬件源码，是后续硬件集成的基础 |
| `tb/` | 仿真测试平台，用于验证，不作为 FPGA 电路参与综合 |
| `software/` | 裸机 C/汇编、启动文件、链接脚本与 MMIO 辅助函数 |
| `programs/` | 与测试配套的预生成指令/数据 HEX，便于下载后直接验证 |
| `benchmarks/coremark/` | CoreMark 原始算法源码、许可证和来源记录 |
| `tools/` | 二进制转 HEX 等辅助工具 |
| `pds/board_top.fdc` | MES50HP 的 50 MHz 时钟、UART、LED 和按键约束 |
| 根目录 `run_*.do` / `build_*.bat` | 仿真和软件构建入口；目前保持在根目录，避免破坏已有使用方式 |

需要保留并提交源码、测试平台、构建脚本、配套 HEX 和许可证。不需要提交 `build/`、`work/`、`uart_work/`、`uart_unit_work/`、`gpio_work/`、`gpio_unit_work/`、`modelsim.ini`、`transcript`、`*.wlf` 或本机 `.mpf` 工程；这些文件由工具在各自电脑上生成，已由 `.gitignore` 排除。

## CPU 与 CNN 协作边界

CPU 与平台部分负责处理器、存储器、外设和后续加速器接入；CNN 模型与部署由队友负责。双方可以分别开发与验证自己的模块，但当前仓库已有独立32位AXI4-Lite主桥验证入口，尚未接入CNN加速器控制/数据接口，不能把现有 UART TX 或计数器 MMIO 当作已完成的 CNN 接口。

当前 C 示例与 CoreMark 配置使用32 KiB指令区、16 KiB数据区。它们是现阶段的软件运行资源，不代表完整 CNN 权重、音频特征和中间结果都能容纳，也不代表后续最终系统的存储容量。

**CPU 与 CNN 的详细联调约定后续再写，依据实际搭建的 CPU 与系统接口确定，并由双方确认。** 本阶段不预先指定加速器寄存器地址、AXI 类型、数据缓冲区地址或中断号，也不发布一份可能与后续实现不一致的固定接口协议。

待 CPU 总线和加速器接入方式确定后，再文档化实际的控制/状态寄存器、输入输出数据格式、数据传输路径、握手时序、时钟复位和联调测试。后续文档应与 RTL、C 驱动和测试平台一起维护，并明确哪些能力已验证、哪些仍待实现。

## 当前状态

更新时间：2026-10-01。

| 项目 | 状态 |
| --- | --- |
| RV32I 常用整数指令 | 已完成37种 |
| IF/EX/WB 三级流水线 | 已完成 |
| WB → EX 数据前递 | 已完成 |
| 六种条件分支 | 已完成 |
| JAL/JALR | 已完成 |
| 分支与跳转冲刷 | 已完成 |
| LB/LBU/LH/LHU/LW | 已完成 |
| SB/SH/SW | 已完成 |
| 外部 HEX 程序加载 | 已完成 |
| RISC-V GCC 裸机 C 程序 | 已完成 |
| `tohost` 结束协议 | 已完成 |
| 周期、退休指令和 CPI 统计 | 已完成 |
| 指令/数据存储器参数化与扩容 | 已完成 |
| 独立指令/数据 HEX 镜像 | 已完成 |
| `.data`/`.rodata` 预初始化 | 已完成 |
| 同步指令/数据 RAM 与 load-use stall | RTL/仿真已完成；存储映射取决于顶层和镜像，trap_board独立ROM/RAM为15/8个DRM18K |
| 数据侧请求/响应握手 | 单笔在途、请求背压、响应等待、外部RAM端口及错误停机；可变延迟/复位/MMIO唯一性测试通过 |
| 取指侧请求/响应握手 | 单笔在途、默认每拍吞吐、可变延迟、跳转旧响应丢弃、错误停机与故障PC；7组新增检查通过 |
| 最小SoC与独立片上ROM/RAM端点 | 新SoC软件/板级RTL、实际错误响应、PDS 50 MHz最终STA及综合网表功能通过 |
| 性能计数器 MMIO | 已完成 |
| 最小M模式同步异常/CSR | ENABLE_TRAPS=1时开启；基础异常、FENCE/Zicsr/MRET定向验证通过 |
| 最小M模式定时器中断 | ENABLE_TRAPS=1且ENABLE_TIMER_IRQ=1时开启；当前新增范围见首节 |
| CoreMark v1.01 | 单次算法/CRC 校验已通过；不是正式跑分 |
| UART TX | 已完成 RTL 与串行线仿真验证 |
| 8位 GPIO MMIO | 输出、输入同步、输出使能及 SET/CLEAR/TOGGLE；模块和 CPU/C 仿真已通过 |
| UART RX＋16字节FIFO | 模块/MMIO、CPU软件回显、50 MHz板级RTL及硬件镜像综合网表通过；无RX中断 |
| AXI4-Lite主桥 | 独立协议/CPU/AXI RAM验证通过，并已接入新增板级自检/PDS入口；实物和CNN待验证 |
| AXI4-Lite地址分发与控制设备 | 1主2从、新C程序/协议及新增板级自检/PDS 50 MHz验证通过；实物和CNN待验证 |
| Cache、BTB、AXI4 DDR/DMA | 尚未完成 |
| MES50HP 最小板级顶层 | UART TX、LED、按键及上电/KEY1 复位仿真通过 |
| MES50HP 同步异常板级版本 | 开启ENABLE_TRAPS=1；4次异常/MRET、CSR/FENCE、PASS/FAIL、心跳与KEY1通过新RTL及硬件镜像网表检查 |
| PDS 综合、布局布线与 50 MHz 时序 | PDS 2022.2-SP6.4 验证通过，存在复用引脚等告警，见板级章节 |
| 盘古 50 实物验证 | 尚未完成；工具通过不等于实物通过 |

## CPU 架构

```text
外部 HEX
   │
   ▼
指令存储器 → IF → EX → WB → 寄存器堆
                  │      ▲
                  │      │
                  ├──────┘ WB→EX 前递
                  │
                  └→ 数据存储器 / tohost
```

主要参数：

| 参数 | 当前配置 |
| --- | --- |
| ISA | 默认兼容37种；ENABLE_TRAPS=1增加FENCE/ECALL/EBREAK、Zicsr/MRET与同步异常 |
| 数据宽度 | 32位 |
| 流水级 | IF、EX、WB |
| 指令存储器 | 32 KiB，8192×32位，可参数化 |
| 数据存储器 | 16 KiB，4096×32位，可参数化基址 |
| 字节序 | 小端 |
| 通用寄存器 | `x0`–`x31`，其中 `x0` 固定为0 |
| 分支解析 | EX级 |
| 当前存储器模型 | 同步读取；数据 RAM 同步写入 |

### 流水线控制

- 使用 `valid_x` 区分有效指令和流水线气泡。
- ALU、分支、跳转、加载和存储均可使用 WB → EX 前递结果。
- 立即数指令不会把立即数字段误判为 `rs2` 数据相关。
- 分支或跳转在 EX 级确定目标地址，错误路径指令会被冲刷。
- `JALR` 目标地址最低位强制清零。
- 写入 `x0` 的操作被抑制。
- 数据侧使用单笔请求/响应握手，LOAD和STORE均等待完成；等待期间IF/EX停顿。LOAD响应写回后进入WB前递路径，MMIO副作用仅在请求接受时执行一次。

## 已实现指令

| 类别 | 指令 |
| --- | --- |
| 加减 | `ADDI`、`ADD`、`SUB` |
| 逻辑 | `AND`、`OR`、`XOR`、`ANDI`、`ORI`、`XORI` |
| 移位 | `SLL`、`SRL`、`SRA`、`SLLI`、`SRLI`、`SRAI` |
| 比较 | `SLT`、`SLTU`、`SLTI`、`SLTIU` |
| U型 | `LUI`、`AUIPC` |
| 条件分支 | `BEQ`、`BNE`、`BLT`、`BGE`、`BLTU`、`BGEU` |
| 跳转 | `JAL`、`JALR` |
| 加载 | `LB`、`LBU`、`LH`、`LHU`、`LW` |
| 存储 | `SB`、`SH`、`SW` |

`ENABLE_TRAPS=1` 新增 `FENCE`、`ECALL`、`EBREAK`、6种Zicsr与MRET及最小同步异常；默认兼容模式不启用。另可选择ENABLE_TIMER_IRQ开启机器定时器中断；仍无外部中断、乘除法和压缩指令，具体CSR及限制见首节。

## 性能计数器

`cpu_top` 提供三个性能观测端口：

| 信号 | 宽度 | 含义 |
| --- | --- | --- |
| `cycle_count` | 64位 | 从第一条受支持的有效指令进入 EX 后开始累计周期 |
| `instret_count` | 64位 | 已退休的有效指令数量 |
| `retire_valid` | 1位 | 当前 WB/退休点存在一条有效指令 |

退休计数规则：

- 算术、加载、分支、跳转和存储都属于退休指令。
- 分支和存储即使不写通用寄存器，也必须计入 `instret_count`。
- 复位气泡、分支冲刷产生的错误路径指令、越界取指和不支持的指令不计入。
- 性能测试在写入 `tohost` 的存储指令退休后停止。

CPI 由测试平台计算：

```text
CPI = cycle_count / instret_count
```

当前固定的 `c_demo.hex` 与 `c_demo_data.hex` 测试结果：

```text
PASS: performance counters and C program completed
PERF: tohost=1
PERF: cycles=216
PERF: retired instructions=155
PERF: CPI=1.393
```

`performance_tb.v` 会检查精确的155条退休指令，用于发现错误计入气泡或错误路径指令的问题。如果修改并重新编译 `software/main.c`，动态指令数量可能变化，此时需要同步调整测试平台中的 `EXPECTED_INSTRET`。

## 工程目录

```text
rtl/
  instr_mem.v           外部 HEX 指令存储器
  instr_bus_adapter.v   内部同步ROM的请求/响应端点与可选等待
  if_stage.v            取指握手、PC元数据、IF/EX寄存器和重定向冲刷
  decoder.v             指令译码和立即数生成
  regfile.v             两读一写寄存器堆
  alu.v                 算术、逻辑、移位和比较
  data_mem.v            参数化小端数据 RAM、基址和初始化镜像
  cpu_top.v             顶层数据通路、前递、访存和性能计数
  uart_tx.v             UART 8N1 发送器、波特率分频和 busy/done
  uart_rx.v             两级同步、中心采样、假起始过滤和帧错误检测
  uart_rx_fifo.v        可参数化接收队列，默认16字节
  uart_rx_mmio.v        接收数据、状态、占用数及W1C错误寄存器
  gpio_mmio.v           8位 GPIO 寄存器、输入同步及输出使能
  board_reset.v         KEY1 异步置复位、同步延迟释放及上电初值
  board_top.v           MES50HP 50 MHz 板级封装，不改变三级 CPU

tb/
  cpu_top_tb.v          ALU、比较及U型指令集成回归
  branch_tb.v           BEQ/BNE测试
  compare_branch_tb.v   BLT/BGE/BLTU/BGEU测试
  jump_tb.v             JAL/JALR测试
  load_store_tb.v       LW/SW测试
  subword_mem_tb.v      子字加载和存储测试
  program_load_tb.v     外部HEX程序测试
  toolchain_program_tb.v 预生成独立程序测试
  c_program_tb.v        GCC生成的C程序测试
  performance_tb.v      周期、退休指令和CPI测试
  mmio_tb.v             性能计数器 MMIO 和字符写入测试
  coremark_tb.v         CoreMark 单次功能校验
  uart_tx_tb.v          UART 位时序、字节模式、忙状态及复位测试
  uart_cpu_tb.v         C 程序经 CPU/MMIO/TX 串行线的端到端测试
  gpio_unit_tb.v        GPIO 寄存器译码、同步延迟及复位测试
  gpio_cpu_tb.v         C 程序经 CPU/MMIO 访问 GPIO 的集成测试
  board_top_tb.v        50 MHz UART、LED 闪烁、按键和复位重启测试
  board_netlist_tb.v    可选：TX/GPIO演示的综合后功能网表检查
  uart_rx*_tb.v         RX/FIFO/MMIO、CPU回显、板级回显及综合网表测试

software/
  start.S               初始化栈、清零.bss、调用main并写tohost
  main.c                裸机C测试程序
  link.ld               链接脚本和内存布局
  prebuilt_demo.S       预生成程序的汇编源文件
  mmio.h                计数器读取、UART 忙状态轮询和字符输出
  uart_demo.c           发送 Hello RISC-V 并等待最后一帧结束
  uart_rx.h             接收数据、状态、队列占用及清错辅助函数
  uart_rx_echo.c        轮询回显：硬件无限模式、仿真有限32字节模式
  gpio.h                GPIO MMIO 地址及读写辅助函数
  gpio_test.c           有限 GPIO 功能自测，不是板级 LED 闪烁程序
  board_demo.c          持续运行的 UART 启动消息、LED 心跳及按键程序
  coremark_port/        RV32I 裸机计时、格式化输出和结束适配层

benchmarks/coremark/    CoreMark v1.01 原始算法源码与许可证

programs/
  rv32i_regression.hex  指令回归程序
  program_load_test.hex 外部程序加载测试
  toolchain_demo.hex    无需GCC即可运行的预生成程序
  c_demo.hex            由当前C程序生成的指令镜像
  c_demo_data.hex       由当前C程序生成的数据初始化镜像
  data_mem_init_test.hex 数据RAM初始化回归镜像
  uart_demo.hex         UART C 程序指令镜像
  uart_demo_data.hex    UART 字符串初始化镜像
  gpio_test.hex         GPIO C 自测指令镜像
  gpio_test_data.hex    GPIO C 自测初始化数据镜像
  coremark.hex          已接入 UART 忙状态轮询的 CoreMark 指令镜像
  coremark_data.hex     CoreMark 初始化数据镜像
  board_demo.hex        满深度8192字的板级指令镜像，余下填充 NOP
  board_demo_data.hex   满深度4096字的板级数据镜像，0.5秒闪烁间隔
  board_demo_sim_data.hex 同一程序的加速仿真数据镜像，仅缩短闪烁间隔
  uart_rx_echo*.hex     独立的无限回显与有限32字节测试的指令/数据镜像

tools/
  bin_to_hex.py         BIN转32位小端HEX
  build_board_images.py 构建配套板级/仿真镜像并检查指令镜像相同
  build_pds_board.py    按固件生成独立PDS工程，核对路由/最终STA后生成候选位流
  build_uart_rx_images.py 构建RX回显的硬件和有限测试镜像

pds/
  board_top.fdc         PGL50H-6FBG484 的 MES50HP 引脚及时序约束
```

根目录中的 `run_*.do` 是各组 ModelSim 一键测试脚本。

## 环境要求

- 当前验证平台为 Windows，仿真使用 ModelSim SE-64 10.6e。
- 直接使用仓库已有 HEX 运行仿真时，不需要 Python 或 RISC-V GCC。
- 修改软件并重新生成 HEX 时，需要 Python 3 和 xPack GNU RISC-V Embedded GCC，命令前缀为 `riscv-none-elf-`。
- 构建时先配置自己电脑的工具链 `PATH`，不要把文档中的示例路径当作固定安装要求。

已验证的工具链版本：

```text
riscv-none-elf-gcc 15.2.0
GNU binutils 2.45
```

构建参数固定为：

```text
-march=rv32i
-mabi=ilp32
-mno-relax
-msmall-data-limit=0
-nostdlib
-nostartfiles
```

这些参数避免生成乘除法、压缩指令、操作系统调用以及依赖未初始化 `gp` 的小数据区访问。

## 快速运行性能测试

ModelSim 10.6e 对中文工程路径支持不稳定，请将工程放在纯英文路径，例如：

```text
D:\FPGA\riscv_3stage
```

在 ModelSim Transcript 中运行：

```tcl
quit -sim
cd D:/FPGA/riscv_3stage
do run_performance.do
```

测试成功时应看到：

```text
Errors: 0, Warnings: 0
PASS: performance counters and C program completed
PERF: tohost=1
PERF: cycles=216
PERF: retired instructions=155
PERF: CPI=1.393
```

最后出现的 `$stop` 和 `Break in Module performance_tb` 表示测试平台主动停止，不是错误。

## 构建并运行 C 程序

### Windows CMD

先将自己安装的 RISC-V 工具链 `bin` 目录加入 `PATH`，然后从工程根目录执行：

```bat
cd /d D:\FPGA\riscv_3stage
build_program.bat
```

### Git Bash

如果已经安装 GNU Make，并且工具链位于 `PATH`：

```bash
cd /d/FPGA/riscv_3stage
make CROSS=riscv-none-elf-
```

生成文件：

```text
build/c_demo.elf     带符号的可执行文件
build/c_demo_text.bin       指令段小端二进制
build/c_demo_data.bin       初始化数据段小端二进制
build/c_demo.dump           反汇编文件
build/c_demo.map            链接内存映射
programs/c_demo.hex         ModelSim指令镜像
programs/c_demo_data.hex    ModelSim数据初始化镜像
```

随后在 ModelSim 中运行：

```tcl
do run_c_program.do
do run_performance.do
```

## tohost 程序结束协议

GCC C 程序配置的数据 RAM 最后一个字被保留为 `tohost`：

```text
数据RAM基址：0x00010000
字节地址：0x00013FFC
RAM字下标：4095
测试平台路径：dut.u_data_mem.mem[4095]
```

| 写入值 | 含义 |
| --- | --- |
| `1` | 程序成功 |
| `2`、`3`、`4`…… | 程序失败码 |

CPU程序把结果写入 `tohost` 后，测试平台会判断成功或失败并自动停止。该协议后续可以继续用于 CoreMark 和其他裸机基准程序。

旧的预生成汇编回归仍使用低地址兼容配置，其 `tohost` 保持在 `0x000003FC`（字下标255），因此旧测试无需重写。

## UART TX：发送接口

TX保持单帧发送、软件轮询，没有发送FIFO。新增接收器和RX FIFO见后面的接收章节；串口接收中断尚未实现。发送格式为 8N1：一个低电平起始位、八个数据位、一个高电平停止位，低位先发送，空闲电平为高。

| MMIO 地址 | 访问 | 含义 |
| --- | --- | --- |
| `0x20000000` | 对齐 LW 读取 | 周期计数器低32位 |
| `0x20000004` | 对齐 LW 读取 | 退休指令计数器低32位 |
| `0x20000010` | SB/SH/SW 写入 | 低8位作为一个发送字符 |
| `0x20000014` | 对齐 LW 读取 | bit0=1 表示 UART 正在发送，0 表示可以写下一字符 |

软件必须先轮询 busy，再写字符。硬件没有发送 FIFO：忙时写入会被忽略；仿真会报错提醒错误用法。`software/mmio.h` 中的 `mmio_putchar()` 已封装轮询，`mmio_uart_flush()` 等待最后一个停止位发完，程序结束前应调用。

`cpu_top` 新增 `uart_tx` 输出端口，以及 `UART_CLOCK_HZ`、`UART_BAUD` 参数，默认分别为100 MHz、115200。分频按最接近的整数取值，这组参数对应每位868个时钟。这里100 MHz是本次仿真的时钟，不是已确认的开发板输入频率；上板时必须按实际 CPU 时钟修改，并添加引脚约束。

### 直接运行一次集成测试

仓库已经包含 HEX 镜像，第一次验证不需要重新编译 C。将完整仓库下载到英文工程目录后，在 ModelSim Transcript 中执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart.do
```

脚本会编译新增 UART 模块，启动 C 程序并自动检查 TX 串行线。预期输出：

```text
UART received: Hello RISC-V
UART: baud=115200 clocks_per_bit=868 bytes=13
PASS: CPU UART transmit test
```

这个测试从 TX 引脚的实际位流采样解码，不依赖 CPU 中的 `$write` 调试打印。测试同时检查 busy/idle 读取、字符顺序、停止位、MMIO 不访问普通 RAM、`tohost=1` 和最后一帧发送完成。

可选的独立模块测试为 `do run_uart_unit.do`。本次交付前两项 UART 测试和旧 CPU 回归均已在 ModelSim SE-64 10.6e 中验证；日常验证不必每次重复全套测试。

### 修改 C 程序后重新构建

在 Git Bash 中执行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_uart.bat
```

在 Windows CMD 中则直接执行 `build_uart.bat`。Git Bash 中使用 `//c` 是为了避免 MSYS 把 `/c` 转成路径。编译脚本优先使用 PATH 中的 RISC-V GCC，否则尝试本机已安装的 xPack 路径；其他电脑请调整 `UART_CROSS`。

本次还更新了所有使用 CPU 的仿真脚本，加入 `rtl/uart_tx.v` 编译依赖，以及旧测试平台的新增端口连接。不能只替换 `cpu_top.v` 而漏掉 UART 模块和脚本。

## CoreMark 功能校验说明

本节数据来自数据握手改动前的版本（`621d935`及其历史）。本次没有重复运行CoreMark算法；新增STORE响应等待改变周期数，以下性能值不代表当前握手版本。

原始 CoreMark 算法源码与许可证保存在 `benchmarks/coremark/`，本次未修改算法源码。适配层改用 UART 忙状态轮询，并在写入 `tohost` 前等待最后一个字符发完。仓库的 CoreMark HEX 已按新适配层重新构建，旧的不轮询镜像不能继续用于新 UART。

`run_coremark.do` 配套的测试平台使用100 MHz时钟、5 Mbaud的加速仿真 UART，缩短打印等待时间；UART 集成测试仍按115200 baud执行。加速仿真波特率不代表上板配置。

本次单次测试的算法计时为936687周期，CRC分别为：

```text
seedcrc    = 0xe9f5
crclist    = 0xe714
crcmatrix  = 0x1fd7
crcstate   = 0x8e3a
crcfinal   = 0xe714
PASS: CoreMark official algorithms validated
```

从启动到打印结束的整程序统计为1081207周期、826143条退休指令、CPI 1.308；它包含 UART 轮询和格式化输出，不能与仅算法计时混用，也不能作为正式 CoreMark 分数。`ITERATIONS=1` 是功能冒烟测试，未满足官方至少10秒的计时要求，因此原始输出仍会提示十秒规则不满足。正式分数与上板频率、迭代次数、编译参数及完整运行规则需要后续单独验证。

## 当前存储器布局

| 地址范围 | 用途 |
| --- | --- |
| `0x00000000–0x00007FFF` | 指令 RAM中的 `.text`，32 KiB |
| `0x00010000–0x00013FDF` | 数据 RAM中的 `.rodata`、`.data`、`.bss` 和运行时数据 |
| `0x00013FE0` | 初始栈顶，栈向低地址增长 |
| `0x00013FFC` | `tohost` |

程序构建时会把 ELF 分成独立的指令 HEX 和数据 HEX。数据 RAM 启动时先清零，再用 `c_demo_data.hex` 覆盖初始化数据，因此普通 C 全局初始化变量和只读数据不再依赖未实现的数据复制流程。

## 完整回归测试

可以在 ModelSim Transcript 中分别运行：

```tcl
do run_cpu.do
do run_branch.do
do run_compare_branch.do
do run_jump.do
do run_load_store.do
do run_memory_expansion.do
do run_subword_mem.do
do run_program.do
do run_toolchain.do
do run_c_program.do
do run_performance.do
do run_mmio.do
do run_uart_unit.do
do run_uart.do
do run_coremark.do
```

以下是此前阶段在 ModelSim SE-64 10.6e 中通过的回归记录。RX增量只重测受MMIO/顶层改动影响的TX、GPIO、MMIO和板级演示；其它算法未重复运行，见接收章节：

- 77条基础 CPU 集成测试通过。
- 六种条件分支以及有符号、无符号比较通过。
- JAL/JALR链接地址、前递、最低位清零和冲刷通过。
- LW/SW及load-use、存储地址/数据前递通过。
- LB/LBU/LH/LHU/SB/SH符号扩展、小端字节通道和边界测试通过。
- 非零数据 RAM 基址、参数化容量和外部数据 HEX 初始化通过。
- 外部HEX、预生成程序和GCC C程序通过。
- 性能测试结果为192周期、155条退休指令、CPI 1.238。
- UART 位时序、模式字节、复位和 CPU C 程序串行输出通过。
- CoreMark 单次算法 CRC 校验通过；尚无正式有效分数。

## 波形观察

`run_performance.do` 已加入以下关键信号：

```text
clk、rst_n、pc_x、instr_x、valid_x
wb_pc、retire_valid、cycle_count、instret_count
mem_addr_x、mem_wdata_x、mem_we_x、mem[4095]
```

查看程序结束过程时，可以在 Transcript 输入：

```tcl
wave zoom range 1850ns 2000ns
```

最后一次有效存储应满足：

```text
mem_we_x    = 1
mem_addr_x  = 0x00013FFC
mem_wdata_x = 0x00000001
mem[4095]   = 1
```

## GPIO MMIO：三级 CPU 的本次增量

本次保持 IF → EX → WB 架构、原 UART 地址和计数器地址不变。新增独立外设 `rtl/gpio_mmio.v`；GPIO 读取沿用已有的一拍 load-pending 路径，GPIO 存储在有效 EX 存储事务上接受，不访问普通数据 RAM。

| 地址 | 权限 | 低8位含义 |
| --- | --- | --- |
| `0x20000020` | LW/SW | 输出锁存值 OUT |
| `0x20000024` | LW | 两级同步后的外部输入 IN |
| `0x20000028` | LW/SW | 输出使能 OE，1=允许对应引脚输出 |
| `0x2000002C` | SW | SET，掩码为1的输出位置1 |
| `0x20000030` | SW | CLEAR，掩码为1的输出位清0 |
| `0x20000034` | SW | TOGGLE，掩码为1的输出位翻转 |

GPIO 仅接受对齐的32位 LW/SW，高24位写入忽略、读取为0。SET/CLEAR/TOGGLE 为只写，不支持读取；IN 为只读。兼容模式保留原仿真 `$fatal` 检查；ENABLE_TRAPS=1时非法访问进入同步异常，错位访问在请求前阻止。

CPU 新增 `gpio_in[7:0]`、`gpio_out[7:0]`、`gpio_oe[7:0]` 端口。复位后 OUT=0、OE=0；OUT 锁存器可以在 OE=0 时写入，IN 始终采样外部输入。OE 只是单独输出的掩码，尚不是实际 FPGA 引脚方向控制：板级顶层需要实现 I/O 三态或使用掩码门控专用 LED 引脚。不要将裸电机等负载直接接 GPIO。

输入采用两级同步，适用于低速独立输入，没有按键消抖功能，也不能作为高速多位数据总线的完整跨时钟处理。自定义旧测试平台可连接 `.gpio_in(8'd0), .gpio_out(), .gpio_oe()`；所有实例化 CPU 的编译脚本必须加入 `rtl/gpio_mmio.v`。包内已同步更新原脚本和原测试平台。

在仓库根目录的 ModelSim Transcript 中首次只运行一次：

```tcl
do run_gpio.do
```

已包含预生成 HEX，不需要先编译 C。预期输出：

```text
GPIO: tohost=1 writes=14 reads=17 input=A5->3C
GPIO: output=AA direction=00 before reset; reset output=00 direction=00
PASS: CPU GPIO C program, readback, SET/CLEAR/TOGGLE, squash and RAM isolation
```

测试平台会模拟输入从 A5 变为 3C，检查输出回读、OE、SET/CLEAR/TOGGLE、高位掩码、错误路径存储冲刷、x0 读取、普通 RAM 隔离和复位清零。最终 `$stop` 和 `Break` 是正常结束；结束时测试平台重新拉低复位，所以波形末尾 OUT/OE 为0，复位前最后一个输出锁存值是 AA。

可选模块测试为 `do run_gpio_unit.do`，不要求首次重复运行。修改 C 后，在 Git Bash 中用 `cmd.exe //c build_gpio.bat` 重新生成两份 HEX。构建优先使用 PATH 中的 RISC-V GCC，也可通过 `GPIO_CROSS` 指定工具链前缀。保留 `-march=rv32i -mabi=ilp32`。

2026-10-01 验证：GPIO 模块、GPIO CPU/C、原性能、UART CPU、CPU 指令集、分支、比较分支、跳转、LW/SW、子字访存、MMIO 和独立程序共12项测试通过；所有现有测试平台编译为0错误、0警告。固定 C 基线仍为192周期、155条退休指令、CPI 1.238。CoreMark 本次仅编译测试平台，没有重跑算法；GPIO 实物接线及 PDS 上板尚未验证。

## 取指侧请求与响应握手（2026-10-02）

本增量从已提交的数据握手版本 `9ddda14` 开始，保持 IF → EX → WB。取指返回延迟可变时，必须把指令与接受请求时的PC配对；正常EX执行后无新响应时插入气泡，只有数据访存等待才保持EX。这避免重复执行、重复退休或把旧响应当作跳转目标。

### 参数与外部接口

`cpu_top` 新增参数 `EXTERNAL_IMEM`、`IMEM_REQ_WAIT_CYCLES`、`IMEM_RSP_WAIT_CYCLES`，默认均为0。默认由 `instr_bus_adapter.v` 包装内部同步ROM，请求接受后最早在下一个上升沿消费响应；可在消费响应的同一边缘接受下一笔，保持连续非访存指令每拍取指。两个WAIT参数只给内部端点增加等待。

将 `EXTERNAL_IMEM=1` 后，由外部端点响应以下总线；内部ROM不再读取，外部地址范围不受 `IMEM_WORDS` 限制。地址仍从复位PC 0开始，外部端点负责地址映射、四字节对齐、存储器读取及错误响应。CPU和端点使用同一时钟。

| 端口 | 相对CPU方向 | 含义 |
| --- | --- | --- |
| `imem_req_valid` / `imem_req_ready` | 输出 / 输入 | 上升沿同时为1时接受一个取指请求 |
| `imem_req_addr[31:0]` | 输出 | 该请求对应的指令字节地址 |
| `imem_rsp_valid` / `imem_rsp_ready` | 输入 / 输出 | 上升沿同时为1时消费一个响应 |
| `imem_rsp_rdata[31:0]` | 输入 | 与接受地址对应的32位指令 |
| `imem_rsp_error` | 输入 | 该请求失败；与响应数据一起保持 |
| `imem_fault` / `imem_fault_pc[31:0]` | 输出 | 当前路径取指失败后的粘滞停止状态及故障PC |

一次最多一笔已接受请求在途，响应必须按请求顺序返回，没有事务ID。响应最早在请求接受后的周期有效，不能用未经接受的响应或组合零延迟响应。端点必须保持 `rsp_valid/rdata/error`，直到响应握手；请求受阻时CPU保持 `req_valid/addr`，直到请求握手。

默认内部模式中，外部请求与响应ready输出为0、外部输入完全忽略。自定义旧测试平台可用以下连接避免工具的缺失端口告警：

```verilog
.imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
.imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
.imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc()
```

### 跳转、等待、错误与复位

- branch/JAL/JALR重定向丢弃旧路径响应。已经呈现但未接受的请求不会因跳转撤销，会保持到接受、随后接收并丢弃响应，之后继续目标PC；已接受的旧请求同样必须完成。若外部端点永不返回该响应，取指会等待，不包含超时机制。
- 旧响应中的error也被丢弃，包括redirect与error响应同拍。正常消费旧响应与接受新请求同拍时，使用旧PC输出指令，再保存新PC元数据。
- 数据等待期间当前路径指令响应由端点保持，不进入EX；错误响应也等较老LOAD/STORE完成后才设置取指fault。较老事务可正常写回和退休。
- ENABLE_TRAPS=0时，当前路径error使 `imem_fault` 粘滞置位，准确保存故障PC并停止新取指；出错指令不写回、不退休。内部模式未对齐或越界取指使用此机制，只有复位解除。新增ENABLE_TRAPS=1时的CSR/trap/MRET见首节；已经退休的指令、寄存器写入及外设副作用不回滚。
- 复位取消未接受请求、已接受响应等待及未消费响应。**外部端点必须同时复位并丢弃复位前事务**，接口没有跨复位的事务识别机制。复位也不清数据RAM或回滚已接受写入。

### 新增验证与运行入口

在ModelSim Transcript执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_fetch_handshake.do
```

脚本编译依赖、运行测试并检查 `test_pass=1`，不需要重新编译C镜像。最终 `done=7'h7f`，2156 ns停止，输出 `PASS: fetch handshake`。七组覆盖默认吞吐、内部固定请求/响应等待、外部确定种子随机等待、受阻旧请求跨跳转、已接受旧错误响应跨跳转、复位/当前路径错误，以及未对齐/越界地址和redirect与旧error同拍。程序场景精确核对18条退休PC、JAL/JALR链接、load-use、正确RAM结果及错误路径RAM/GPIO/UART副作用。

18项受影响检查通过：原IF、基础CPU、分支、比较分支、跳转、LW/SW、子字访存、MMIO、GPIO、UART TX、UART RX、C程序、退休计数、外部HEX程序、工具链程序、原板级演示、RX板级回显及原数据握手。旧外部HEX测试的STORE监测已改为接受的RAM写事务计数，避免将EX等待拍重复计数；旧测试平台连接新增未使用端口。最终各项ModelSim编译/仿真均0错误、0警告。未重跑未改变的RX/FIFO/MMIO模块单测、旧数据适配器单测、存储器模块单测或CoreMark算法；CoreMark平台仅编译检查。固定C示例仍为216周期、155条退休指令、CPI 1.393。

### 本增量板级构建记录

```bash
cmd.exe //c build_pds_board.bat --firmware uart_rx_echo --variant fetch_handshake --stage bitstream
```

本次输出为 `build/pds_fetch_handshake/`，综合后功能检查入口 `do run_fetch_handshake_netlist.do`。`data_handshake` / `fetch_handshake` variant只区分输出目录，不选择旧源码；新增的 `soc` variant选择SoC顶层。恢复旧构建应先检出对应Git提交。该取指握手阶段的板级继续使用内部指令/数据端点，未连接实际外部存储器或CNN。以前的位流和报告不能作为新RTL版本的证据。

| 本版检查 | 结果 |
| --- | --- |
| 目标与固件 | PGL50H / -6 / FBG484，50 MHz；无限UART回显 |
| 布局布线实际使用 | 1631 LUT、547 FF、8 DRM18K、72分布式RAM、19 IO、0 APM |
| 最终Slow setup/hold | +4.467 ns / +0.034 ns，0失败端点 |
| 最终Fast setup/hold | +8.987 ns / +0.027 ns，0失败端点 |
| 最终recovery/removal/pulse width | 两个corner全部通过 |
| 综合后功能网表 | 实际硬件镜像8字节回显及KEY1重启通过；无SDF |
| 候选位流 | `build/pds_fetch_handshake/generate_bitstream/board_top.sbit`；未实物验收 |

资源取实际使用汇总（模块归属汇总为1630 LUT）；最终STA取 `report_timing/board_top.rtr`，不混用路由器摘要。配置复用引脚、忽略 `ASYNC_REG` 属性和异步外部IO等告警边界保留，见下文。所有工具检查均在本机完成，未下载FPGA、烧写Flash或使用远程平台。

## 数据侧请求与响应握手（9ddda14阶段记录）

本增量从已提交的UART RX版本 `621d935` 开始，仍为 IF → EX → WB，取指仍使用同步指令存储器。数据侧一次最多有一笔在途事务，LOAD和STORE都在完成响应后退休。首次遇到访存指令时锁存地址、字节使能、写入数据及写回信息；请求等待与响应等待期间保持这些信息稳定。

默认继续使用内部RAM和既有MMIO。`data_bus_adapter.v` 接受请求后产生响应；参数 `DMEM_REQ_WAIT_CYCLES` / `DMEM_RSP_WAIT_CYCLES` 分别增加请求接受前与响应可用前的等待周期，默认均为0。默认情况下，请求在一个上升沿接受，响应在接下来一个周期可用，并在下一个上升沿完成。STORE比此前直接在EX完成的版本增加等待周期，旧版CPI不可直接作为当前版本的成绩。

### 外部RAM接口

`cpu_top` 设置 `EXTERNAL_DMEM=1` 时，非MMIO的数据请求交给以下端口；地址位于 `0x2000xxxx` 的MMIO仍由本地外设处理。该接口是单笔事务的项目内部接口；新增主桥可把它转换成AXI4-Lite，外部DDR控制器尚未接入。

| 端口 | CPU方向 | 含义 |
| --- | --- | --- |
| `dmem_req_valid` / `dmem_req_ready` | 输出 / 输入 | 两者同时为1的上升沿接受一次请求 |
| `dmem_req_write` | 输出 | 1为写，0为读 |
| `dmem_req_addr[31:0]` | 输出 | 字节地址 |
| `dmem_req_size[1:0]` | 输出 | 0/1/2分别为字节、半字、字 |
| `dmem_req_wdata[31:0]` / `dmem_req_wstrb[3:0]` | 输出 | 数据已移至对应字节通道；使能位选择实际写入通道 |
| `dmem_rsp_valid` / `dmem_rsp_ready` | 输入 / 输出 | 两者同时为1的上升沿完成请求 |
| `dmem_rsp_rdata[31:0]` | 输入 | 返回包含目标字节的整个32位字；CPU按地址取位并扩展 |
| `dmem_rsp_error` | 输入 | 本次事务出错；与响应同时有效 |
| `dmem_fault` | 输出 | 错误响应锁存后置1，CPU停止推进直到复位 |

请求被接受前必须保持valid及描述符；响应被消费前必须保持valid、数据及error。写请求也需要完成响应。外部设备可以在接受请求后立即准备响应，但CPU从下一周期开始接收它；设备必须保持到握手完成。外部RAM的合法地址范围由响应设备决定，不沿用内部RAM的容量检查。

CPU与响应设备必须使用同一复位，并同时丢弃旧在途事务；接口没有事务ID，不能隔离一个不参与复位的设备在重启后送来的陈旧响应。复位不会清空RAM，也不会撤销已经接受的写操作或MMIO副作用。兼容模式的 `dmem_fault` 是停止机制；新增ENABLE_TRAPS=1将数据错误转为同步异常，见首节。

### 外设副作用与调试

RAM写、GPIO写、UART发送、RX状态W1C和RX FIFO弹出均由一次 `mem_req_fire` 接受事件触发。MMIO读取在接受沿保存快照，RX保存弹出前的队首；多拍等待期间不会重复弹出。`mem_rsp_fire` 为完成响应事件，LOAD仅此时写回，LOAD/STORE仅此时退休。

波形中优先观察 `mem_active`、`req_sent`、`mem_req_valid`、`mem_req_ready`、`mem_req_fire`、`mem_rsp_valid`、`mem_rsp_ready`、`mem_rsp_fire`、`stall_x` 和 `dmem_fault`。历史监视名 `load_issue_x` 现在表示已接受的LOAD请求，`load_pending` 表示已接受且尚未完成的LOAD。

新测试入口（ModelSim Transcript）：

```tcl
cd D:/FPGA/riscv_3stage
do run_data_handshake.do
```

本次修改CPU控制及退休逻辑，因此需运行新握手测试和受影响的CPU/访存/MMIO/外设检查；RX/FIFO等未修改模块的已通过单测不重复运行。历史CoreMark算法不作为本次增量回归；其数据只能引用为旧版本记录。

新的板级构建使用独立目录，避免覆盖已保存的验收版本：

```bash
cmd.exe //c build_pds_board.bat --firmware uart_rx_echo --variant data_handshake --stage bitstream
```

输出位于 `build/pds_data_handshake/`。综合后功能检查入口为 `do run_data_handshake_netlist.do`。板级仍为50 MHz、115200、8N1，默认等待参数为0；外部RAM端口在此最小板级工程中未接入。新版本需要自己的PDS报告和实物验收证据，不能沿用下节RX版本的资源及STA数值。

### 本次验证记录（2026-10-02）

新增适配器单测检查响应背压下的MMIO快照与错误保持，以及请求未接受、已接受待响应、响应有效未消费时的复位。CPU握手测试包括零额外等待、固定等待和确定种子随机等待三种外部RAM场景，每种15次请求/响应、26次唯一退休；并检查字节通道、扩展、前递、LW x0、分支/JAL冲刷、描述符稳定及外部地址范围独立性。另检查本地MMIO请求等待3拍、响应等待7拍时GPIO TOGGLE、TX帧、RX弹出及W1C唯一性；外部LOAD/STORE错误不写回、不退休，复位后恢复。

13项受影响的集成检查通过：基础CPU、分支、跳转、LW/SW、子字访存、MMIO、GPIO、UART TX、UART RX回显、C程序、退休计数、原板级演示和RX板级回显。新增两个测试入口及这13项均通过；旧RX/FIFO/MMIO模块单测和CoreMark算法未重跑。当前固定C示例为216周期、155条退休指令、CPI 1.393，较旧版本的192周期增加24个周期；这仅是同一小程序的控制逻辑基线，不是CNN性能或正式CoreMark分数。

| 握手版本板级检查 | 结果 |
| --- | --- |
| PDS目标与固件 | PGL50H / -6 / FBG484，50 MHz；无限UART回显 |
| 布局布线使用资源 | 1537 LUT、509 FF、8 DRM18K、72分布式RAM、19 IO |
| 最终Slow setup/hold | +5.050 ns / +0.169 ns，0失败端点 |
| 最终Fast setup/hold | +9.427 ns / +0.117 ns，0失败端点 |
| 最终recovery/removal/pulse width | 两个corner全部通过 |
| 综合后功能网表 | 实际硬件镜像8字节回显及KEY1重启通过；无SDF |
| 位流 | `build/pds_data_handshake/generate_bitstream/board_top.sbit`；实物尚未验收 |

资源取布局布线实际使用汇总；同一报告的模块归属汇总为1535 LUT。最终STA取独立 `report_timing/board_top.rtr`，不混用路由器摘要。配置复用引脚及通用 `ASYNC_REG` 属性相关告警仍存在，外部异步IO路径的限制与RX版本相同；工具检查不代替实物验证。已提交的RX版本 `621d935` 和首次板级基线 `6f97477` 可单独恢复；本次未执行下载、Flash烧写或远程平台操作。

## UART RX、FIFO与CPU软件回显

此增量以 `6f97477` 为基线，保留三级流水线、TX地址及旧程序镜像。新增接收模块接入CPU的MMIO，电脑发送的字节经FIFO暂存，CPU执行C程序读取并交给原TX发送器。UART用于命令和调试，不替代音频I2S采集或CNN接口。

### 接收寄存器与副作用

| 地址 | 访问 | 行为 |
| --- | --- | --- |
| `0x20000018` RX_DATA | 对齐LW | 返回队首低8位并弹出一次；空队列返回0且不弹出 |
| `0x2000001C` RX_STATUS | 对齐LW | bit0非空、bit1满、bit2溢出、bit3帧错、bits15:8占用数 |
| `0x2000001C` RX_STATUS | 对齐SW | 写bit2/3为1清除对应粘滞错误，其余位忽略；新错误优先 |

两个错误标志保持到软件W1C或复位；清错不清队列。队列满时丢弃新字节并报溢出；若同一时钟沿有效弹出旧队首，则新字节可以入队。空队列同时读和新数据入队时，读返回0，新字节保留供下一次读取。合法字节0x00与空读均返回0，软件必须先检查非空位。

RX_DATA读取沿用 `load_issue_x` 的MMIO快照：发起沿保存弹出前的数据，后续 `load_pending` 停顿沿不再弹出。兼容模式非法子字/错位访问保留原仿真检查；ENABLE_TRAPS=1时进入同步异常。RX中断仍未实现。

`uart_rx.v` 使用两级同步、8N1中心单点采样、假起始过滤和停止位检查；坏停止位不入队，持续低电平break只报一次帧错并等待高电平再接收。时钟/波特率参数至少要求4时钟/位，队列支持非二次幂深度，CPU默认16字节，MMIO占用字段允许深度1至255。无16倍过采样、自适应波特率、接收中断或硬件流控。TX也仍无FIFO，连续长突发可能超过回显处理速度，应检查溢出位。

### 软件与入口

`software/uart_rx.h` 包含状态、接收和清错函数；主程序的硬件模式为：

```c
#include "uart_rx.h"
int main(void)
{
    for (;;)
        mmio_putchar((char)uart_rx_getchar());
}
```

`build_uart_rx.bat` 生成独立的 `uart_rx_echo.hex` / `_data.hex`（无限回显）和 `uart_rx_echo_test.hex` / `_data.hex`（32字节后写tohost）。指令镜像满深度8192字，数据镜像4096字；硬件代码136字节，有限测试188字节，均没有初始化数据负载，数据镜像填0。旧 `board_demo`、TX、GPIO和CoreMark镜像没有重建或覆盖。

需要修改C并重建时，在Git Bash运行：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_uart_rx.bat
```

工具链支持 `UART_RX_CROSS` 或 `BOARD_CROSS`，保持 `-march=rv32i -mabi=ilp32`。已有随源码提供的HEX时无需先安装GCC。

本次下面的测试均已运行通过，代码不变时无需再跑。修改相关逻辑后的ModelSim入口为：

```tcl
cd D:/FPGA/riscv_3stage
do run_uart_rx.do
```

该入口检查32字节真实串行输入/输出，包含00/FF/55/AA/CR/LF、复位期间输入忽略、32次DATA读取、pending禁止二次读取、RAM隔离和最终tohost=1。`run_uart_rx_unit.do` 检查RX/FIFO/MMIO边界；`run_uart_rx_board.do` 用无限硬件固件检查50 MHz/115200回显16字节及KEY1帧中复位。所有使用CPU的旧脚本已增加RX模块依赖，旧测试将RX明确接空闲高电平。

### 独立板级构建与历史证据（621d935）

RX接MES50HP R8，TX接R9，LVCMOS33/3.3 V；依据硬件手册V1.1 PDF第27页表3-5。CPU输入为 `uart_rx`，新增参数 `UART_RX_FIFO_DEPTH`；板级顶层也有 `uart_rx` 输入。默认 `board_top` 仍加载原LED演示；选回显固件需运行：

```bash
cmd.exe //c build_pds_board.bat --firmware uart_rx_echo --stage bitstream
```

输出在 `build/pds_uart_rx/`，原 `build/pds_board/` 与备份的基线位流保留。脚本分别检查路由器摘要及最终 `report_timing/board_top.rtr`，清单记录二者，全部通过才生成候选位流。

2026-10-01已完成：三个模块单测、CPU回显、板级RTL回显，以及受MMIO/顶层改动影响的旧TX、GPIO、MMIO、板级演示，共9项RTL测试。全部30个测试平台编译为0错误/0警告；回归流程曾遇到已有work库锁定提示，但四项关联测试均完成PASS。没有重跑CoreMark算法、固定性能或其它无关指令回归。

| 新回显工程检查 | 结果 |
| --- | --- |
| PDS目标 | Logos / PGL50H / -6 / FBG484，50 MHz |
| 当前资源 | 1439 LUT、426寄存器、8 DRM18K；RX FIFO使用分布式RAM |
| 最终STA Slow setup/hold | +4.625 ns / +0.142 ns，0失败端点 |
| 最终STA Fast setup/hold | +9.237 ns / +0.101 ns，0失败端点 |
| 最终recovery/removal及pulse width | 两个corner均通过 |
| 综合后功能网表 | 实际无限硬件镜像回显8字节、KEY1重启通过；无SDF |
| 候选位流 | `build/pds_uart_rx/generate_bitstream/board_top.sbit`；实物待验证 |

资源仅对应这份136字节回显固件，不能作为完整CNN系统资源或新CoreMark性能。综合网表检查入口 `do run_uart_rx_netlist.do` 引用安装目录的官方仿真模型，不复制模型源码。

配置复用引脚仍有3条critical warning，Persist Pin保持None。异步RX与按键pad路径设为false path；RX同步级间及CPU内部仍计时。PDS忽略通用 `ASYNC_REG` 属性并发告警，综合网表已核对RX两级触发器及串接关系存在；该属性不能当作PDS已完成同步器布局/MTBF验证的依据。外部IO无同步delay模型，工具通过不等于电气与实物通过。

首次实物仍先验收已保存的 `6f97477` TX/GPIO位流，再单独验收此RX候选版本。回显固件不输出Hello，也不执行LED心跳；发送少量字符才有串口回显。未执行下载、Flash烧写或远程平台操作。

## MES50HP 首次上板：最小 CPU + UART + LED 工程

本节保留首次实物验收基线 `6f97477`（其父提交是GPIO版本 `8fc6459`）的程序行为及构建证据。当前RX分支仍采用 IF → EX → WB，并增加了接收器；其独立工程见上一章。本节的资源、时序及旧综合网表记录均属于已保存的TX/GPIO基线。若要重建原基线，使用 `6f97477` 源码快照；在当前分支运行本节构建命令会使用新增RX后的RTL，不等于原候选位流。

### 1. 目标硬件和引脚

约束依据《MES50HP开发板硬件使用手册_1V1》，PDF 第10、27、33、34页。目标芯片为 **PGL50H-6IFBG484**，PDS 中选 Logos / PGL50H / -6 / FBG484。下载前必须核对自己开发板的型号、版本、芯片丝印及原理图；不同板卡不要沿用这些引脚。

| 板上资源 | 顶层端口 | FPGA 引脚 | 电平/用途 |
| --- | --- | --- | --- |
| 50 MHz 晶振 | `clk_50m` | P20 | 20 ns 主时钟，不使用 PLL |
| KEY1 | `key1_n` | K18 | 低有效；本工程作为 CPU 复位 |
| KEY2–KEY8 | `keys_n[0]`–`keys_n[6]` | L15、J17、K16、J16、J19、H20、H17 | 低有效；依次对应 LED2–LED8 |
| LED1–LED8 | `led[0]`–`led[7]` | B2、A2、B3、A3、C5、A5、F7、F8 | 高电平点亮 |
| 板载 USB-UART TX | `uart_tx` | R9 | 115200、8N1、无流控 |

这些 IO 使用 LVCMOS33、3.3 V。基线 `6f97477` 未使用R8；当前RX分支已增加 `uart_rx` 输入和R8约束。使用板载 CP2102 的 UART Type-C 接口，不要将 UART 接口与 JTAG 配置接口混淆。

**REPROGRAM 按钮用于重新加载 FPGA 配置，不是 CPU 复位。** 按 KEY1 才会重新启动本 CPU 程序。KEY1 复位异步拉低，经过两级同步和50000个50 MHz时钟（约1 ms）后释放；配置时采用寄存器初值保证首次启动也先保持复位。按键回跳会重新延长释放等待。KEY2–KEY8 只有两级同步，没有完整机械消抖，本演示仅显示按下状态，不用于按键事件计数。

LED 输出是 `gpio_out & gpio_oe` 的专用输出门控，不是外部 GPIO 的双向三态。本工程不需要杜邦线或焊接外部模块，也不会驱动电机、屏幕或其他大电流负载。

### 2. 本程序在板上做什么

配置启动后，CPU 执行 `software/board_demo.c`：

- UART 发送一次 `Hello RISC-V\r\n`，共14字节，随后等待最后一帧发完。
- LED1 每约0.5秒翻转一次（完整亮灭周期约1秒）；延时由 CPU 读取周期计数器决定，不是独立硬件 LED 闪烁器。
- 按住 KEY2–KEY8 时，相应 LED2–LED8 点亮，松开熄灭。
- 按 KEY1 时 LED 熄灭、CPU 复位；松开后重新发启动消息并恢复运行。

这个程序一直运行，不返回 `main`，不会写 `tohost=1` 自动结束。这个 `board_demo` 固件只发送启动消息，不读取新增RX寄存器；回显功能由独立的 `uart_rx_echo` 固件提供。CPU仍使用原来的32 KiB指令地址空间、16 KiB数据RAM和MMIO地址；这个旧板级顶层未启用新增同步异常/CSR，没有操作系统或中断。

### 3. 首次只运行新增板级仿真

已有旧测试通过后，不要求重跑全部回归。在 ModelSim Transcript 执行：

```tcl
cd D:/FPGA/riscv_3stage
do run_board.do
```

预期：

```text
BOARD: boot=1 UART received Hello RISC-V (CR LF)
BOARD: boot=2 UART received Hello RISC-V (CR LF)
PASS: board power-on reset, 50MHz UART, CPU-driven LED blink, KEY2 and KEY1 restart
NOTE: short blink/reset delays used in simulation; physical board not tested
```

测试用实际 UART 引脚的位流解码，时钟为50 MHz、每位434个时钟，波特率约115207。与旧100 MHz UART 测试的868时钟/位不同，这不是旧串口测试结果发生错误。

为缩短测试，复位等待改为16周期，数据初始化镜像中的闪烁间隔改为2000周期；**指令 HEX 与硬件完全相同**。PDS 使用默认50000周期复位等待和 `board_demo_data.hex` 的25000000周期间隔，绝不使用 `board_demo_sim_data.hex`。测试内有一次有意的 KEY1 复位，因此收到两次启动消息，并非脚本无限重复仿真。最终 `$stop`/`Break` 为正常结束。

### 4. 修改板级 C 程序时才重新编译

在 Git Bash 的工程根目录执行：

```bash
cmd.exe //c build_board.bat
```

需要 Python 3 和 RV32I GCC；优先用 PATH 中的 `riscv-none-elf-gcc`，也可设置 `BOARD_CROSS` 工具链前缀。Windows CMD 直接执行 `build_board.bat`。脚本生成三份满深度 HEX，并检查硬件与仿真的指令二进制逐字节一致。

本次固件有效载荷为264字节指令、20字节初始化数据，其余指令填 NOP、数据填0。满深度填充用于明确 FPGA 初始化值，不代表固件已经占满存储器。改程序或编译参数后，指令镜像不一致时脚本会报错，不能继续沿用旧镜像。

### 5. 生成自己的 PDS 工程

将仓库放在纯英文目录。安装 PDS、配置有效许可证和 Python 3；优先使用 PATH 中的 `pds_shell`，也可把环境变量 `PDS_SHELL` 设为安装目录中 `pds_shell.exe` 的完整路径。脚本保留本机 `D:/pango/PDS_2022.2-SP6.4` 后备路径，不要求队友复制该安装路径。

首次可直接执行以下一条命令，完成编译、综合、映射、布局布线和时序分析：

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_pds_board.bat --stage timing
```

如果先只检查综合，使用 `cmd.exe //c build_pds_board.bat`。所有产物生成在 `build/pds_board/`，核心文件为：

```text
build/pds_board/board_demo.pds
build/pds_board/board_generated.tcl
build/pds_board/board_top_init_paths.v
build/pds_board/compile/board_top_rtl.adf
build/pds_board/synthesize/board_top_syn.adf
build/pds_board/synthesize/board_top_syn.vm
build/pds_board/place_route/board_top.prr
build/pds_board/place_route/board_top_timing_summary_after_hold_fix.txt
build/pds_board/build_manifest.json
```

PDS 2022.2-SP6.4 使用 `compile -top_module board_top -loop_limit 10000` 后再执行 ADS 综合。不要将 `tb/` 文件加入硬件综合。

脚本生成一份仅用于综合的顶层副本，把两份硬件 HEX 默认值改为本机绝对路径，避免 PDS 切换工作目录后加载错文件；仓库中的 `rtl/board_top.v` 仍保持相对路径。**移动工程目录或修改 HEX 后必须重新运行生成脚本，不能复用别人电脑上的 PDS 输出工程或位流。**

生成完成后可以在 PDS 打开 `build/pds_board/board_demo.pds`，检查 Report Summary、管脚表、资源和时序。时钟约束为20 ns；仅异步按键输入和非源同步 LED/UART 输出被设为 false path，CPU、存储器和内部复位释放路径仍进行50 MHz时序检查。外部 IO 没有同步的 input/output delay 模型，工具会给出相关告警，不能宣称“零告警”或所有外部接口时序已验证。

如果助手沙箱运行 PDS 报 `Flow-0189`，应先用一个最小工程区分工具环境/权限问题与 RTL 错误。本次同样错误在最小单寄存器工程中出现；获准在沙箱外运行后最小工程与本工程均编译成功。普通用户本机运行不需要复制任何沙箱配置，不要据此关闭电脑安全设置。

### 6. 本次工具验证结果与告警边界

2026-10-01，PDS 2022.2-SP6.4、PGL50H-6FBG484、50 MHz、当前板级演示固件：

| 检查项 | 结果 |
| --- | --- |
| 板级 RTL 仿真 | 0编译错误、0编译警告；UART、LED闪烁、KEY2和KEY1重启通过 |
| ADS 综合资源 | 1417 LUT、377寄存器、8个 DRM18K；0锁存器、0 APM |
| 实际存储器映射 | 数据 RAM 为8个 DRM18K；264字节小指令程序优化为 LUT ROM，未强制占用32 KiB BRAM |
| 布局布线引脚检查 | 18个顶层端口均落在上述指定引脚 |
| Slow corner setup / hold | WNS +4.840 ns / WHS +0.155 ns，0失败端点 |
| Fast corner setup / hold | WNS +9.523 ns / WHS +0.111 ns，0失败端点 |
| 内部 recovery / removal | 两个 corner 均通过；外部异步按键路径不在此保证范围内 |
| 综合后功能网表 | 用实际硬件镜像检查上电、UART消息、KEY2及KEY1重启，通过 |
| 候选位流生成 | `board_top.sbit` 和 `board_top.bin` 已生成；未下载或烧写硬件 |
| 实物串口、LED、按键 | 尚未验证 |

上述裕量来自 `report_timing/board_top.rtr` 的最终独立静态时序分析。`place_route/board_top_timing_summary_after_hold_fix.txt` 与 `build_manifest.json` 中的 +5.092/+0.144 ns、+9.720/+0.099 ns 是路由器摘要；两份报告均通过，报告数值不能混用。

资源仅属于当前小程序和顶层，换 CoreMark/CNN 程序会改变 ROM 推断及资源，必须重新综合；不能把这一结果当作整个 CNN 系统已综合。

约束检查还有3个 `ConstraintEditor-2002` critical warning：K18、J19、H20属于配置复用引脚。布局布线管脚表已确认相应端口仍放在指定位置；PDS 手册说明配置中的 Persist Pin 默认释放这些端口给用户使用。生成位流时必须保持释放设置，不能启用保留配置复用引脚。此告警不是未经核对便可忽略的普通换行提醒。

综合日志还有 fanout 等告警，不能把综合成功理解为告警为0。当前有限演示的判断依据为映射结果、综合网表功能及约束下的布局布线时序；真实上板电气行为仍待检查。综合后网表检查不含 SDF 路由延迟，不能替代静态时序分析和实物验证。

可选的可重复网表检查入口为 `do run_board_netlist.do`，需要先生成 PDS 综合网表，并通过 `PDS_HOME`（安装根目录）或 `PDS_SHELL` 指向本机 PDS 安装。脚本引用安装目录的官方仿真模型，不复制或分发它们。此项已经在交付前检查，不是要求首次再次运行所有测试。

### 7. 生成候选位流与首次实物验收

确认上面的器件、引脚、复用引脚设置及时序后，在 Git Bash 执行：

```bash
cmd.exe //c build_pds_board.bat --stage bitstream
```

脚本先重新生成并检查布局布线时序，通过后才生成候选位流；**只生成文件，不自动连接、下载或烧写 FPGA**。配置使用 TCK 启动，适用于首次 JTAG 临时配置验证。本阶段不要改成 Flash 固化、加密或 efuse 操作。

候选文件路径为 `build/pds_board/generate_bitstream/board_top.sbit`（JTAG验收使用）及同目录的 `board_top.bin`。本次已验证生成流程，但代码包不分发本机生成的位流；在自己的英文工程目录重新生成，避免把旧程序或错误器件的文件下载到板上。

首次上板按以下顺序验收：

1. 核对实物确为 MES50HP / PGL50H-6IFBG484，使用开发板规定电源和下载线，先不连接 LCD、振动模块或其他外部负载。
2. 在 PDS Configuration 中选择本次生成的候选位流，通过 JTAG **仅下载到 FPGA SRAM**；不要选择烧写 Flash。成功仅表示配置完成，不等于程序功能通过。
3. 打开板载 USB-UART 对应 COM 口，设置115200、8数据位、无校验、1停止位、无流控；先打开终端再按 KEY1，预期收到 `Hello RISC-V`。
4. 松开 KEY1 后观察 LED1 大约每0.5秒翻转；按住 KEY2–KEY8，相应 LED 点亮；再按 KEY1，应熄灯、重新输出启动消息。
5. 保存串口截图、LED/按键现象和 PDS 时序报告，再把实物结果写回 README。没收到文字时依次检查 COM口、板载 UART接口、50 MHz时钟、复位、程序镜像和 TX引脚，不要直接跳到 CNN 联调。

当前尚未执行上述实物验收，README 不把“位流生成”写成“上板通过”。程序和硬件采用 JTAG 临时配置，断电后不会保留本次下载的设计。

新增源码、脚本、FDC、三份 HEX 和 README 应提交；`build/`、`board_work/`、综合网表、PDS本机工程、波形、许可证和候选位流不应提交。

## 已知问题

- 必须尽量在纯英文路径运行 ModelSim，否则可能出现数据库路径乱码或 `vlog-9`。
- 如果出现 `Failed to open readmem file`，应检查 ModelSim 当前目录以及 `programs/*.hex` 是否存在。
- 如果出现 `Unable to remove locked optimized design` 或 WLF 文件被占用，请关闭其他 ModelSim 仿真实例后重试。
- Git 的 LF/CRLF 提示只是 Windows 换行格式提醒，不是编译错误。
- 不要提交 `build/`、`work/`、`uart_work/`、`uart_unit_work/`、`gpio_work/`、`gpio_unit_work/`、`modelsim.ini`、`transcript` 和 `wlf*` 等本地产物。

## 当前限制

- 已有可选最小M模式同步异常、定时器中断和有限CSR；完整特权架构、外部中断和操作系统支持尚未实现。
- 尚未实现Cache、BTB和AXI4 DDR/DMA；AXI4-Lite已有板级自检/PDS入口，尚未接CNN或完成实物验收。UART TX无FIFO，RX有16字节FIFO，但仍无接收中断、奇偶校验或硬件流控。GPIO已有RTL/MMIO和仿真，实际引脚三态及按键消抖仍需板级实现。
- 板级数据RAM映射为DRM18K，初始化已在对应综合网表中验证；旧小指令程序可优化为LUT ROM，trap_board指令镜像映射为15块DRM18K。其他镜像须单独检查映射，实物初始化尚待验收。
- 取指与数据侧均已有单笔请求/响应握手及外部端口；AXI4-Lite已有RAM与控制演示设备的1主2从分发，实际DDR等外部存储器控制器尚未接入。兼容模式取指故障粘滞停止，新模式进入同步异常处理；仍无总线超时机制。
- 32 KiB指令区和16 KiB数据区已运行本阶段的 CoreMark 单次程序，但不代表可以容纳后续完整音频特征提取和 CNN 输入数据。
- 最小板级工程已完成 PDS 综合、资源统计和50 MHz静态时序分析；尚未完成盘古50实物验收，不代表 CNN 或完整 SoC 已上板。

## 后续路线

1. 按板级章节完成 JTAG 临时下载、串口启动消息、LED心跳和按键复位的首次实物验收。
2. 保存对应 PDS 报告和实物证据，依据真实问题修复并建立板级稳定基线；再接外部屏幕或其他外设。
3. 验收新增RX回显：115200、8N1发送少量字符并逐字节核对，单独记录RX版本的实物结果。
4. 完成新增AXI板级自检的实物验收，与队友确定CNN控制、状态、缓冲区和数据格式，依据已验证的AXI4-Lite流程接入正式设备，并更新对应板级/PDS验证。
5. 完善基础指令与同步异常的标准一致性覆盖，扩展完整异常/中断；建立正式CoreMark基线后实现二路组相联Cache与BTB并比较性能。
6. 完成CNN及系统端到端验证，评估资源、推理延迟和准确率，再依据关键路径评估五级流水线。

## 当前性能基线

本阶段的 C 示例主要用于验证工具链、访存、分支、流水线冲刷和性能计数器，并不代表最终 CPU 或 CNN 性能。当前基线的价值在于：后续加入同步存储器、Cache、BTB 或 CNN 加速器后，可以使用相同的计数方法进行可重复比较。

## CoreMark 测评准备（2026-10-03）

新增独立的 smoke、smoke-validation、formal-short、performance 和 validation 构建；移植层使用 64 位 mtime 与小数秒，正式模式严格校验时长、种子和 CRC。专用顶层接通 timer，官方算法文件保持原样。详见 [CoreMark 配置、命令与验证边界](docs/coremark.md)。本轮只做测评准备与新增短程验证，正式分数和对应 PDS/实物验收尚未完成。
