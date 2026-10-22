# CPU5 RAM fixture

This is a freestanding C workload for the partial CPU5 integer and RAM stages.
It is not CoreMark and produces no board-performance claim.

Build both seed images and independent retirement/memory gold from the repository
root:

```text
python -B tools/generate_cpu5_ram_vectors.py
python -B tools/analyze_cpu5_ram.py --vectors-only
```

The builder finds `riscv-none-elf-gcc` on PATH, uses the existing xPack GCC
15.2.0 installation, or accepts `CPU5_RAM_CROSS` as a toolchain prefix.
The compiler uses RV32I, ILP32, `-O2`, freestanding/static linking, and disabled
link relaxation. Each seed directory records its complete flags, compiler
version, ELF, map, disassembly, code/data binary, and SHA256 manifest.

ROM occupies `0x00000000..0x00007fff`; RAM occupies
`0x00010000..0x00013fff`. The fixture initializes all 31 nonzero GPRs before
setting SP to `0x14000`. RAM initialization includes `.data` and zero-filled
`.bss`; the endpoint testbench supplies this initial image. Calls and volatile
stack locals exercise save/restore, stack traffic, and return dependencies.

The C program uses volatile words, halfwords, bytes, an address loaded from RAM,
array loops, immediate load consumers, write/read dependencies, signed boundary
values, and two input seeds. A few inline assembly statements force actual
`LB`, `LH`, and `LW x0` instructions: GCC can otherwise emit unsigned volatile
loads followed by explicit sign extension. All other workload instructions are
selected by GCC. The fixture uses neither M, CSR, nor FENCE instructions.

`cpu5_ram_stop` contains EBREAK (`0x00100073`). EBREAK is an unimplemented
stop in this partial core; it does not retire and this fixture does not claim
Trap or debug support. The interpreter verifies the entire program finishes at
that symbol. It rejects unsupported instructions, misaligned RAM accesses, and
addresses outside the RAM whitelist.

The generator executes actual machine words and compares final arrays and
eight result words against a separate high-level algorithm. A second interpreter
in the analyzer imports neither the generator nor RTL and checks every golden
retirement field, D-access field, and complete final RAM/GPR image. Golden
records use architectural retirement order; actual fetch sequence IDs must be
bound to real accepted packets in simulation.

Expected result[0] checksums are `0x1f91678c` (seed `0x13579bdf`) and
`0xecda0199` (seed `0x2468ace0`). The signed boundary outputs include
`0xffffff80` and `0xffff8000`. These are functional test signatures.

The D gold uses original byte addresses, size codes 0/1/2 for byte/half/word,
lane-shifted store bytes, and byte strobes. Unselected store-data lanes and
write-response data are not architectural outputs. Read response data is the
aligned 32-bit RAM word, before load extraction and sign extension.
