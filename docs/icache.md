# Two-way instruction cache, first implementation

This step implements the **instruction** half of the two-way cache requirement.
The data cache and dynamic branch predictor remain future work. It preserves the
RV32I instruction set and the IF/EX/WB pipeline. Existing SoC instantiations have
`ENABLE_ICACHE=0` by default; `icache_board_top` explicitly enables it.

## Organization and interface

| Item | Board configuration |
| --- | --- |
| Capacity | 2 KiB of instruction data, plus tags/valid/LRU metadata |
| Associativity | 2 ways |
| Sets | 64 |
| Line size | 16 bytes, four 32-bit instructions |
| Replacement | Invalid way first, then least recently used way |
| Hit | Registered one-cycle response; response consumption and next request overlap |
| Miss | Blocking, four sequential ready/valid ROM reads, full-line refill |
| ROM | 32 KiB at `0x00000000`, fixed read-only initialization image |
| RAM | 16 KiB at `0x00010000`, accessed through the existing AXI4-Lite bridge |
| Clock / serial | 50 MHz / 115200 baud, 8N1 |

`instr_cache` goes between the SoC's existing instruction request/response wires
and `soc_instr_mem`. The CPU pipeline and decoder do not change. The ROM instance
stays at `soc_axi_lite_top.u_imem`, preserving existing testbench hierarchy.
Both ways' data arrays use synchronous reads and are not reset; only valid/LRU
bits, protocol state and counters reset. Tags store only the useful ROM address
bits; the complete 32-bit address is checked before any lookup result is used.

The cache accepts one outstanding CPU request. Request addresses and CPU
responses stay stable under backpressure. Reset must be shared with the ROM
responder; it cancels the transaction and invalidates both ways. A refill error
leaves the selected victim invalid, returns an error for the originally requested
PC, and preserves the other way. Redirects do not cancel a refill: the existing
IF stage drains and discards stale responses, including stale errors.

This version serves immutable instruction ROM. It does not implement self
modifying code, cache coherence, `FENCE.I`, AXI bursts, nonblocking misses, or a
data cache. Replacing the ROM image requires a shared reset. The optional cache
has not been added to `coremark_board_top`: the old 52.574739 CoreMark result
remains the no-cache baseline, and this step establishes no new performance score.

## Counter snapshot device

`soc_icache_stats_top` routes the data master to AXI RAM and a read-only statistics
device at `0x30000000`. This address belongs to the diagnostic board version;
it does not define the CNN teammate's register map.

| Offset | Value |
| --- | --- |
| `0x00` | ID `0x49433241` (`IC2A`); an accepted read snapshots all five counters |
| `0x04` | Geometry: ways `[31:24]`, sets `[23:16]`, line bytes `[15:0]`; `0x02400010` |
| `0x08` | Snapshot of accepted instruction requests |
| `0x0C` | Snapshot of hits |
| `0x10` | Snapshot of misses |
| `0x14` | Snapshot of successful refill words |
| `0x18` | Snapshot of invalid requests / failed refills |

Read ID before sampling the other registers. Reads stay frozen until another
ID read, regardless of instructions executed by the sampling routine. Counters
wrap modulo 2^32 and reset with the cache. Statistics events have a uniform
one-clock delay to keep counter carry chains off the redirect/lookup path.
Invalid/misaligned requests increment
access/error only; valid requests increment access and exactly one of hit/miss.
The requested address must be within ROM and four-byte aligned.

At a snapshot, a refill may still be in progress: without errors, successful
refill words can trail `misses * 4` by zero through four words. A read of an
unimplemented/misaligned offset returns SLVERR. Every write returns SLVERR; AW
and W are accepted independently, and R/B responses remain stable until accepted.

## Firmware and validation

`software/icache_board.c` reuses the existing timer handler's ABI and verifies:

1. Globally masked and locally masked timer interrupt behavior.
2. Three precise timer IRQ/MRET returns while a 2048-step checksum runs.
3. Calls A/B/A/C/A/B, repeated 64 times, produce the expected result 704.
4. Functions A/B/C are each aligned to 1024 bytes, share cache set indices, and
   have distinct tags. The builder checks this in the linked ELF symbols.
5. The hardware cache ID/geometry, nonzero hits/misses, zero errors and coherent
   counter snapshot. PASS is printed only after all checks succeed.

Hardware and simulation use identical instruction bytes. Their initialized RAM
differs only in the heartbeat period: 25,000,000 cycles for the board and 2,000
cycles for RTL simulation. ELF, disassembly, map, symbols, build log, source/image
hashes and build report are saved under `build/icache_board_firmware/`.

`run_icache.do` runs these self-checking tests:

- Fast and delayed ROM models, independent two-way LRU reference model, all line
  offsets, conflicts, 160 repeatable random accesses, every refill error beat,
  invalid requests, backpressure, shared reset during requests/refills/responses,
  and sustained one warm hit per clock.
- Atomic AXI counter snapshots, invalid reads/writes, AW-first/W-first/simultaneous
  writes, held R/B responses and reset of partially accepted transactions.
- Real IF stage plus cache: same-edge redirect/error, blocked miss redirects,
  stale error discard, current-path precise faults and EX-stall recovery.
- Real linked firmware at 50 MHz / physical UART rate, including delayed ROM,
  exact foreground checksum writes, x1..x31 preservation across three MRETs,
  reset inside an ISR, actual software FAIL recovery, heartbeat and two boots.

The PDS builder rejects wrong variants, stale firmware images or sources and
does not generate a bitstream if either router timing or final independent STA
fails. The netlist test uses only board pins, hardware ROM/RAM initialization,
50 MHz and the physical UART rate; it checks two PASS messages and KEY1 restart.
Functional netlist simulation does not use SDF.

## Commands and physical board check

In Git Bash:

```bash
cd /d/FPGA/riscv_3stage
cmd.exe //c build_icache_board.bat
cmd.exe //c build_pds_board.bat --variant icache_board --firmware icache_board --stage bitstream
```

Optional ModelSim GUI checks from the project directory:

```tcl
do run_icache.do
do run_icache_board_netlist.do
```

Open `build/pds_icache_board/board_demo.pds` in PDS and select
`build/pds_icache_board/generate_bitstream/board_top.sbit` for JTAG SRAM download.
Keep the existing USB/UART connection and SSCOM at 115200, 8N1, text receive.
After boot, expect exactly `ICACHE PASS`, then LED2 on and LED1 toggling roughly
every 0.5 seconds. Press and release KEY1: LEDs clear during reset, then another
PASS appears and the heartbeat resumes. No serial command needs to be sent.
`ICACHE FAIL XXXXXXXX` / LED3 indicates a failed software assertion; preserve
the complete received line and build log to diagnose it.

Physical board verification passed on 2026-10-04: the user supplied a COM8
115200/8N1 screenshot with one complete 13-byte `ICACHE PASS` and confirmed
normal status LEDs, heartbeat and KEY1 restart. Next, implement a two-way data
cache with a defined RAM/MMIO policy, then run a controlled CoreMark comparison
and add dynamic branch prediction.

The implemented step has passed RTL/baseline regressions, 50 MHz final STA and
two-boot functional netlist simulation. See
[the verification record](icache_verification_20261003.md) for measured timing,
artifact hashes and the vendor RAM-model warning explanation.
