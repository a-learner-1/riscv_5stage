# CPU5 CoreMark S18 evidence (2026-10-26)

Four fresh real RV32IM CoreMark smoke cases; performance seeds, one iteration. Raw edge/native/retire/Stats/timer traces and exact images are in raw_evidence.zip. The independent interpreter replays every retired instruction and rebuilds final RAM.

43 receipt/semantic negative cases were rejected, including coherent metadata forgery. Short drain/timer probes are separate fixtures; the 8 backend init cases execute actual production C on Windows and do not claim RV32 wrong-image hardware execution. No formal CoreMark score, P&R/STA, bitstream or board performance is claimed.

Replay: extract the ZIP at a clean checkout of source_commit, run tools/verify_cpu5_coremark.py with --source-commit set to that commit. The recorded runtime D: junction may be replaced by ordinary extracted build directories.
