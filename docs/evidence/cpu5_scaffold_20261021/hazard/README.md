# CPU5 hazard first-stage verification

Combinational source-selection contract only; this does not claim an implemented CPU5 pipeline or ISA equivalence. No legacy file changed.

Both CHECK_EX_PRODUCER=0 (EX consumers) and =1 (ID branch/JALR consumers) are tested for every vector. ID never accepts an EX result, including a ready ALU result. Producer eligibility requires valid, writes_rd and nonzero matching rd. The newest matching register version owns the source even while unready. Each source has an independent selector/stall; stall is their OR. WB readiness is explicit and defensively enforced. Unused/invalid operands retain the RF input and do not stall; used x0 yields zero.

Test oracle treats WB/EX/MEM as an unordered set of register versions with age tags 10/30/20, finds the highest-age matching writer, then asks whether that version is available at the consumer stage. It does not reproduce the RTL conditional ordering.

Positive ModelSim SE-64 10.6e: exit 0, 442,418 vectors, 1,769,672 source checks, 50 named/GPR cases, 0 compile/sim warnings. 442,368 vectors exhaust producer valid/write/ready flags (512), consumer valid/uses flags (8), producer register equivalence classes (27), and source relationship patterns (4). Additional cases cover 18 explicit contracts plus all 32 architectural GPR numbers. Distinct RF/MEM/WB data values make incorrect selection observable.

Negative validation uses six actual mutated RTL source files, compiled separately through the same test and DO gate. All six are rejected with exit 1:

- newest_not_ready_falls_to_WB: `HAZARD FAIL case=3 named=newest blocks older WB mode=0 flags=x shape=x pattern=x consumer=x rs=5/6`.
- x0_not_constant: `HAZARD FAIL case=11 named=x0 masks every producer mode=0 flags=x shape=x pattern=x consumer=x rs=0/0`.
- unused_source_compared: `HAZARD FAIL case=12 named=unused operands ignore RAW mode=0 flags=x shape=x pattern=x consumer=x rs=5/6`.
- WB_beats_newer_MEM: `HAZARD FAIL case=4 named=newest ready beats older WB mode=0 flags=x shape=x pattern=x consumer=x rs=5/6`.
- ready_EX_forwards_to_ID: `HAZARD FAIL case=5 named=EX blocks ID even ready mode=1 flags=x shape=x pattern=x consumer=x rs=5/6`.
- rs2_incorrectly_reuses_rs1: `HAZARD FAIL case=0 named=RF only mode=0 flags=x shape=x pattern=x consumer=x rs=5/6`.

After mutation validation, the unmodified delivered RTL was recompiled and the positive suite passed again. `verification.json` records source hashes, negative failures and log hashes. `positive_process.log` and `positive_transcript.log` retain the final pass; `mutants/` contains exact faulty RTL and logs.

Rerun: `vsim -c -do run_cpu5_hazard.do`. The optional Tcl variable CPU5_HAZARD_SOURCE selects a separately generated mutation; normal runs default to rtl/cpu5_hazard.v.

Pending integration verification: actual pipeline hold/advance, descriptor/store-data capture, branch redirect age, long-latency ownership, CSR serialization and full program equivalence. Those are outside this combinational module.
