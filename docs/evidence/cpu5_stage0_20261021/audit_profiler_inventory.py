"""Read-only CPU5 stage-0 profiler audit; writes only beside this script."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess

ROOT = Path(r'D:\FPGA\riscv_3stage')
OUT = Path(__file__).resolve().parent
SPEC = Path(r'C:\Users\23123\Downloads\cpu5_arch_spec_v0_3.md')
ENV = dict(os.environ, GIT_OPTIONAL_LOCKS='0')


def git(*args, allow_failure=False):
    result = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, env=ENV)
    if result.returncode and not allow_failure:
        raise RuntimeError(result.stderr.decode('utf-8', 'replace'))
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(data):
    return data.replace(b'\r\n', b'\n')


GROUPS = {
    'd1_m1_m2': ['run_coremark_d1_measure.do', 'tb/coremark_d1_measure_tb.v', 'tools/analyze_d1_measure.py'],
    'synthetic_axi_write': ['run_axi_write_profile.do', 'tb/axi_write_profile_tb.v', 'tools/analyze_axi_write_profile.py', 'docs/axi_write_profile.md'],
    'real_coremark_axi_write': ['run_coremark_axi_write_profile.do', 'tb/coremark_axi_write_profile_tb.v', 'tools/analyze_coremark_axi_write_profile.py', 'docs/coremark_axi_write_profile.md'],
    'd0_native_write': ['run_coremark_d0_measure.do', 'tb/coremark_d0_measure_tb.v', 'tools/analyze_coremark_d0_measure.py'],
    'cycle_profile': ['run_cpu_cycle_profile.do', 'tb/cpu_cycle_profile_tb.v', 'docs/cycle_profile.md'],
    'workload': ['run_coremark_m.do', 'tb/coremark_axi_tb.v', 'tb/coremark_d0_workload_tb.v', 'tools/coremark_axi_contract.py', 'tools/regression_suites.json'],
    'semantic_sources': ['rtl/cpu_top.v', 'rtl/if_stage.v', 'rtl/branch_predictor.v', 'rtl/soc_axi_lite_top.v', 'rtl/soc_coremark_axi_top.v', 'rtl/axi_lite_coremark_stats.v', 'rtl/machine_timer.v', 'rtl/rv32m_unit.v', 'rtl/data_cache.v', 'rtl/dmem_region_router.v', 'rtl/soc_data_mem.v', 'software/coremark_port/core_portme.c', 'software/coremark_port/core_portme_axi.c', 'software/coremark_port/coremark_axi_stats.h', 'software/timer.h'],
    'cpu5_planned_only': ['rtl/cpu5_top.v', 'rtl/cpu5_cycle_profile.v', 'rtl/axi_lite_coremark_stats5.v', 'rtl/cpu5_m_owner.v'],
}

ANCHOR = re.compile(r'`define\s+(D1_|D0_|CMW_)|always @\(posedge|\$fwrite\([^,]+,\s*"(?:key,|profile,|case_id,)|selected_start_triggers|start_triggers|selected_epoch|starts<1|starts<|starts\+|epoch==|epoch.*starts|mem_start_x|m2_pred|m2_direrr|bp_resolve_valid|bp_predictable_x|bp_next_mismatch_x|retire_to_wb|retire_valid\s*<=|if \(retire_valid\)|perf_cycle_events\s*<=|profile_next\[|start_snapshot\[0\]|stop_snapshot\[0\]|mmio_endpoint_fire|load_mmio_data_q\s*<=|timer_read_time|void start_time|void stop_time|ENABLE_D0_BRAM\(|coremark_axi_read\([04]u\)|#1;|schema_version|raw START=2|latest-START lifecycle')


def entry(rel):
    path = ROOT / rel
    tracked = git('ls-files', '--error-unmatch', '--', rel, allow_failure=True).returncode == 0
    obj = {'path': rel, 'absolute_path': str(path), 'exists': path.is_file(), 'tracked': tracked}
    if not path.is_file():
        obj['status'] = 'NOT IMPLEMENTED' if rel.startswith('rtl/cpu5') or rel.endswith('coremark_stats5.v') else 'NOT FOUND'
        return obj
    data = path.read_bytes()
    text = data.decode('utf-8-sig')
    obj.update(bytes=len(data), sha256=sha(data), canonical_lf_sha256=sha(canonical(data)), line_count=len(text.splitlines()))
    obj['git_status_porcelain'] = git('status', '--porcelain=v1', '--untracked-files=all', '--', rel).stdout.decode('utf-8').strip()
    if tracked:
        blob = git('show', 'HEAD:' + rel).stdout
        obj['head_blob_sha1'] = git('rev-parse', 'HEAD:' + rel).stdout.decode().strip()
        obj['head_blob_sha256'] = sha(blob)
        obj['head_blob_canonical_lf_sha256'] = sha(canonical(blob))
        obj['worktree_matches_head_canonical_lf'] = canonical(data) == canonical(blob)
        obj['last_commit'] = git('log', '-1', '--format=%H', '--', rel).stdout.decode().strip()
        obj['origin'] = 'tracked Git file; worktree identity above controls this audit'
    else:
        obj['origin'] = 'pre-existing untracked workspace file; no committed provenance; inventoried, not installed or validated'
    obj['anchors'] = [{'line': n, 'text': line.strip()} for n, line in enumerate(text.splitlines(), 1) if ANCHOR.search(line)]
    obj['macro_bindings'] = [{'line': n, 'macro': m[1], 'expansion': m[2]} for n, line in enumerate(text.splitlines(), 1) if (m := re.match(r'\s*`define\s+((?:D1_|D0_|CMW_)\w+)\s+(.+)', line))]
    # Literal first-line CSV headers as implemented; no newly invented version number.
    obj['csv_literal_headers'] = []
    for match in re.finditer(r'\$fwrite\(\s*(\w+)\s*,\s*"([^"\n]*)"', text):
        literal = match[2].split(r'\n', 1)[0]
        if literal.startswith(('key,value', 'key,count', 'profile,transaction,', 'profile,group,', 'case_id,cache,')):
            obj['csv_literal_headers'].append({'line': text.count('\n', 0, match.start()) + 1, 'stream': match[1], 'columns': literal.split(',')})
    return obj


SIGNALS = [
    {'id': 'S01', 'old': 'D1_CPU.mem_start_x && D1_CPU.is_store_x && !D1_CPU.mem_req_mmio', 'binding': 'workload.dut.u_core.u_cpu', 'source': 'tb/coremark_d1_measure_tb.v:68-70; rtl/cpu_top.v:1249-1259', 'age': 'current valid EX instruction, before its transaction is latched; not a D request handshake', 'sample': 'posedge PRE-NBA', 'window': 'last START inclusive, STOP exclusive [S,T); D1 fixed raw=2, selected=1, epoch=2', 'output': 'M1 gap buckets, next non-local EX memory launch', 'cpu5_planned': 'cpu5_mem_launch_valid/pc/seq/is_store plus a separately defined launch stage; or cpu5_d_req_fire+owner_is_store with a NEW metric/schema', 'reuse': 'ADAPT REQUIRED; CPU5 MEM STORE cannot be paired with EX is_store; moving launch to handshake changes measured S'},
    {'id': 'S02', 'old': 'D1_CPU.bp_resolve_valid && D1_CPU.bp_predictable_x', 'binding': 'workload.dut.u_core.u_cpu', 'source': 'tb/coremark_d1_measure_tb.v:70-71,225-245; rtl/cpu_top.v:794-805,884-889', 'age': 'completed architectural instruction; predictable set is conditional branch OR JAL, excludes JALR', 'sample': 'posedge PRE-NBA, same combinational event as counter update; counter values before increment', 'window': '[S,T), endpoint pre-counter differences must reconcile', 'output': 'e_resolved / direction error decomposition / hit and relearn / separate JALR count', 'cpu5_planned': 'cpu5_bp_resolve_commit, owner seq/PC/op, prediction metadata, direction/target/mismatch and eligible-set flags', 'reuse': 'ADAPT REQUIRED; retain eligible set and retirement ownership; no speculative younger training'},
    {'id': 'S03', 'old': 'D1_IF.prediction_hit_x/prediction_taken_x; D1_BP.update_match', 'binding': 'workload.dut.u_core.u_cpu.u_if_stage[.g_branch_predictor.u_branch_predictor]', 'source': 'tb/coremark_d1_measure_tb.v:19-21,228-241; rtl/if_stage.v:81-96; rtl/branch_predictor.v:83', 'age': 'IF-latched prediction metadata transported with the same EX instruction; update_match is current predictor table match at update', 'sample': 'posedge PRE-NBA', 'window': '[S,T), gated by S02', 'output': 'M2 miss/hit-wrong-direction/relearn buckets', 'cpu5_planned': 'retired owner prediction_hit/taken and commit update_match metadata', 'reuse': 'ADAPT REQUIRED; IF/ID live metadata must not be combined with MEM control instruction'},
    {'id': 'S04', 'old': 'bp_resolve_valid && bp_next_mismatch_x / bp_mispredict_count', 'binding': 'workload.dut.u_core.u_cpu', 'source': 'rtl/cpu_top.v:794-807,884-889', 'age': 'all completed supported instructions with actual next PC, not just predictable branch/JAL; JALR mismatch can count', 'sample': 'event PRE-NBA; counter increment visible POST-NBA', 'window': 'event [S,T) agrees pre-counter STOP-START; post-NBA registered trace must align owner', 'output': 'redirect events distinct from redirect_wait cycle count', 'cpu5_planned': 'cpu5_bp_mispredict_commit with opcode/PC/seq; optional speculative redirect issue separate', 'reuse': 'ADAPT REQUIRED; preserve all-instruction mismatch vs control-only R denominator distinction'},
    {'id': 'S05', 'old': 'retire_valid + wb_pc (+wb_rd/wb_data/wb_we)', 'binding': 'workload.{retire_valid,wb_pc} / workload.dut.u_core.u_cpu', 'source': 'rtl/cpu_top.v:1543-1575,1628-1660; tb/coremark_d0_measure_tb.v:103-117; tb/coremark_axi_write_profile_tb.v:392-435', 'age': 'instruction completed at this edge; registered retire_valid and WB metadata correspond after NBA', 'sample': 'POST-NBA #1 in existing STORE observers; PRE-NBA sampling observes previous edge completed instruction, valid if deliberately aligned; instret_count increments from PRE-NBA retire_valid', 'window': 'do not mix physical completion [S,T) with delayed observation without explicit edge/owner alignment', 'output': 'STORE retirement timestamp; new RAW trace must PC-decode same ROM and must not substitute live instr_x', 'cpu5_planned': 'cpu5_mem_commit_valid plus commit PC/instr/seq/rd/value, and separately WB-stage write; explicit output latency', 'reuse': 'ADAPT REQUIRED; MEM retirement may precede WB GPR write, retire_valid is not wb_we'},
    {'id': 'S06', 'old': 'dmem_req_valid&&ready / bridge_req_valid&&ready / dmem_rsp_valid&&ready', 'binding': 'workload.dut.u_core.*', 'source': 'tb/coremark_d0_measure_tb.v:79-101; tb/coremark_axi_write_profile_tb.v:330-369; rtl/soc_axi_lite_top.v:167-220', 'age': 'current one-outstanding transaction owner, descriptor frozen from EX launch', 'sample': 'posedge PRE-NBA', 'window': 'transaction epoch/launch membership; boundary-crossing checks; response/retire timestamp separate', 'output': 'cpu_accept/backend_accept/cpu_response; AXI timestamp chain only when AXI backend selected', 'cpu5_planned': 'cpu5_d_req_fire, cpu5_d_rsp_fire, separate old rsp_owner/new req_owner seq/PC/op/class; killed/drain flag', 'reuse': 'ADAPT REQUIRED; same-cycle A response/B request must not use one live owner or EX PC'},
    {'id': 'S07', 'old': 'actual BRAM mem_we / AXI RAM u_data_mem.we; AW/W/B handshake and first VALID', 'binding': 'D0_RAM=workload.dut.u_core.g_d0_bram.u_ram; CMW_RAM=workload.dut.u_ram; synthetic case.ram', 'source': 'tb/coremark_d0_measure_tb.v:89-105; tb/coremark_axi_write_profile_tb.v:342-403; tb/axi_write_profile_tb.v:390-426', 'age': 'irreversible write belongs to accepted transaction descriptor; AW/W pairs timestamp=max(AW,W)', 'sample': 'WE and handshake PRE-NBA; RAM readback and first VALID POST-NBA #1', 'window': 'native D0 forbids ordinary RAM leak to AXI; synthetic epochs are reset epochs, not START banks', 'output': 'one physical effect per store, byte-mask verification, additive vs diagnostic stages', 'cpu5_planned': 'backend effect probe plus owner identity/class; younger requests require MEM oldest authorization', 'reuse': 'backend physical probes conditionally reusable if backend unchanged; timing equality/CPU owner adapters must change'},
    {'id': 'S08', 'old': 'stats_arvalid&&stats_arready at 0x30000000 / 0x30000004', 'binding': 'workload.dut.* and workload.dut.u_stats', 'source': 'rtl/axi_lite_coremark_stats.v:122-180; software/coremark_port/core_portme_axi.c:28-41,66; tb/coremark_d0_measure_tb.v:54-65', 'age': 'device read has snapshot side effect; AR acceptance edge, not R response or retirement', 'sample': 'posedge PRE-NBA at AR; snapshot registers written NBA', 'window': 'portable_init ID read is a real START; later START re-arms and supersedes bank; last START selected; STOP exactly once', 'output': 'frozen cycle/instret/cache/BP and cycle-profile banks', 'cpu5_planned': 'MEM-authorized STATS transaction acceptance + snapshot event IDs and aligned counters; independent stats5/schema', 'reuse': 'address/effect contract may survive; CPU5 timing/counter ABI must be revalidated; never EX speculative stats read'},
    {'id': 'S09', 'old': 'perf_cycle_events[5:0] and profile_next[0:5]', 'binding': 'workload.dut.u_core.u_cpu / workload.dut.u_stats', 'source': 'rtl/cpu_top.v:1587-1624; rtl/axi_lite_coremark_stats.v:65-76,151-152,179-180; tb/coremark_axi_write_profile_tb.v:280-284,392-429', 'age': 'one registered attribution per counted physical CPU edge; six-class one-hot, includes M waits in work_other', 'sample': 'CPU computes pre-edge predicate -> event POST-NBA; stats consumes old registered event with profile_next at same snapshot edge', 'window': 'physical attribution edges [S,T) correspond to PRE-NBA registered-event samples (S,T]; POST-NBA observer samples [S,T)', 'output': 'six counters sum to cycle_count delta; event counter NOT additive with nonexclusive BP/M/retire events', 'cpu5_planned': 'cpu5 ten-bit registered main attribution, hardware schema4/profile schema2 (planned), explicit count enable and snapshot alignment', 'reuse': 'NOT BINARY COMPATIBLE; dedicated stats/firmware/guard/analyzer; do not silently truncate high bits or require other==instret'},
    {'id': 'S10', 'old': 'timer_mtime / mem_req_fire && timer_read_hit_x / load_mmio_data_q', 'binding': 'workload.dut.u_core.u_cpu.g_machine_timer.u_timer (enabled generate branch) and MMIO endpoint descriptor', 'source': 'software/timer.h:15-24; software/coremark_port/core_portme.c:383-391; software/coremark_port/core_portme_axi.c:28-41; rtl/cpu_top.v:1175-1193,1210-1216,1272-1294,1414-1418; rtl/machine_timer.v:24-43', 'age': 'actual LOCAL MMIO endpoint request owner; hi/lo/hi are separate accepted reads, low captures PRE-increment mtime and retry on high rollover', 'sample': 'endpoint fire/read data PRE-NBA; load_mmio_data_q captures same edge NBA; mtime increments NBA', 'window': 'START before mtime sample and STOP after mtime sample; counter_cycles can exceed raw_ticks by boundary overhead, do not equate them', 'output': 'raw_ticks/seconds vs frozen counter window; workload checks actual high-low-high samples', 'cpu5_planned': 'MEM-authorized local endpoint fire + read/write descriptor, pre-pop UART head/data capture; mtime and stats remain separate devices', 'reuse': 'timer helper/endpoint behavior reusable if contract unchanged; five-stage timing and UART pop require new tests'},
    {'id': 'S11', 'old': 'm_start_x/m_complete_x/m_wait_x + instr_x[14:12]', 'binding': 'workload.dut.u_core.u_cpu[.g_m.u_muldiv]', 'source': 'rtl/cpu_top.v:996-1016; rtl/rv32m_unit.v', 'age': 'held EX M owner in three-stage CPU; start/complete events distinct from actual wait cycles; sticky unit done', 'sample': 'posedge PRE-NBA for control event; done/result POST-NBA from unit then CPU completion at later edge', 'window': 'count start/complete/wait separately and record boundary-spanning owner; not equal to all work_other-retired by assumption', 'output': 'current profiler set has no complete standalone MUL/DIV measurement export; planned observation', 'cpu5_planned': 'm owner valid/seq/pc/op/killed/start accepted/result consumed and independent mul/div wait/complete', 'reuse': 'ADAPT REQUIRED; killed owner drains, unit resource busy and architectural blocking are different'},
]
for signal in SIGNALS:
    signal['cpu5_implementation_status'] = 'NOT IMPLEMENTED'
    signal['cpu5_execution_status'] = 'NOT RUN'

CONTRACT_TESTS = [
    'Three raw START triggers -> final epoch selected; one raw START accepted; STOP=1; active STORE crossing START/STOP rejected; no combined reset epochs.',
    'At S/T inject distinct pre-edge and post-edge BP/retire/profile events; prove physical [S,T) and delayed registered events (S,T] with integer endpoint ledgers.',
    'MEM older STORE with EX younger ALU or STORE: launch/op/PC/seq stay same owner; never combine MEM mem_start alias and EX is_store.',
    'RSP(A)+REQ(B) same edge, A error/kill and B ready/backpressure: old response and new request carry distinct owners, each completes once.',
    'EX older RAM LOAD + ID younger redirect: D owner survives fetch-epoch change; older LOAD error still traps; wrong-path younger LOAD drains without Trap/WB.',
    'Retire instructions with rd=x0, STORE, CSR and M; one retire pulse independent of wb_we; MEM retirement vs later WB observed with explicit latency.',
    'MUL vs DIV/REM including divide-by-zero, INT_MIN/-1, sticky done, killed DIV then ISR MUL: per-owner start/complete/wait and drain partition.',
    'BP branch/JAL/JALR/non-control stale prediction cases: eligible-set counters, mismatch events and redirect wait cycles separately reconciled; no killed younger training.',
    'UART RX pop/head capture and every MMIO write enable at one authorized endpoint edge; local timer high-low-high rollover; STATS read never speculative.',
    'Ten-class one-hot/count-enable, reserved-address collision negatives, schema4/2 rejection by old guards and old six-class firmware unchanged.',
    'Native D0 RAM write effect readback vs AXI write effect readback: no invented AXI phases on BRAM traffic; latency equality constraints versioned for CPU5.',
    'Dynamic RAW shadowed writer, both-source overlap, x0 and unused operands: distance2 is exact closest-writer distance only, never producer-unready inference.',
]


def main():
    head_before = git('rev-parse', 'HEAD').stdout.decode().strip()
    status_before = git('status', '--porcelain=v1', '--untracked-files=all').stdout
    files = [entry(rel) for rel in dict.fromkeys(path for paths in GROUPS.values() for path in paths)]
    # Do not infer declaration or implementation from a specification probe name.
    cpu5_sources = list((ROOT / 'rtl').glob('*cpu5*')) + list((ROOT / 'rtl').glob('*stats5*'))
    record = {
        'audit_schema': 1, 'date': '2026-10-21', 'scope': 'v0.3 sections 8.5/8.6 E and 10.0; source inspection only',
        'audit_status': 'SOURCE_INVENTORY_AND_SEMANTIC_MAPPING_COMPLETE',
        'design_freeze_status': 'NOT CLAIMED', 'cpu5_rtl_status': 'NOT IMPLEMENTED', 'cpu5_simulation_status': 'NOT RUN',
        'legacy_simulations_in_this_audit': 'NOT RUN', 'main_repository': str(ROOT), 'head': head_before,
        'specification': {'path': str(SPEC), 'sha256': sha(SPEC.read_bytes())},
        'groups': GROUPS, 'files': files, 'signal_mapping': SIGNALS,
        'cpu5_source_matches': [str(p) for p in cpu5_sources],
        'migration_status': 'PROPOSED MAPPING ONLY; no prefix-only substitution authorized; CPU5 timing/schema must be tested',
        'known_legacy_restrictions': {
            'd1_fixed_two_raw_starts': {'tb': 'tb/coremark_d1_measure_tb.v:133-156,299-301', 'analyzer': 'tools/analyze_d1_measure.py:73-79', 'formula': 'raw==2 && selected==1 && epoch==2 && stop==1 && crossings==0', 'generalization': 'NOT IMPLEMENTED in this audit'},
            'd0_generic_latest_start': {'tb': 'tb/coremark_d0_measure_tb.v:31,54-65', 'analyzer': 'tools/analyze_coremark_d0_measure.py:28', 'formula': 'raw>=1 && selected==1 && epoch==raw && stop==1 && crossings==0'},
            'real_axi_write_generic_latest_start': {'tb': 'tb/coremark_axi_write_profile_tb.v:295-311', 'analyzer': 'tools/analyze_coremark_axi_write_profile.py:122-127', 'formula': 'raw>=1 && selected_epoch==raw && stop==1; rejects boundary crossings'},
            'synthetic_axi_python_analyzer': 'tools/analyze_axi_write_profile.py NOT FOUND; checks, metrics and summaries are implemented inside TB; do not conflate with real-CoreMark analyzer',
            'd0_fixed_store_latency': 'D0 native observer/analyzer currently require latency==write_wait==2 and response edge==retirement edge; CPU5 may change this, so logic cannot be copied unchanged',
            'old_axi_workload_not_d0': 'tb/coremark_axi_tb.v does not pass ENABLE_D0_BRAM; use tb/coremark_d0_workload_tb.v for M/D0 configuration',
            'csv_versioning': 'existing CSV text has no explicit schema column; header/hash identify format. Analyzer JSON schema_version=1 is not hardware stats schema3 or profile schema1',
        },
        'future_contract_tests': [{'id': f'E-T{i+1:02}', 'description': desc, 'status': 'NOT IMPLEMENTED / NOT RUN for CPU5'} for i, desc in enumerate(CONTRACT_TESTS)],
    }
    assert git('rev-parse', 'HEAD').stdout.decode().strip() == head_before
    assert git('status', '--porcelain=v1', '--untracked-files=all').stdout == status_before
    record['main_head_and_git_status_unchanged_during_audit'] = True
    record['audited_files_unchanged_at_end'] = all(not f['exists'] or sha(Path(f['absolute_path']).read_bytes()) == f['sha256'] for f in files)
    assert record['audited_files_unchanged_at_end']
    (OUT / 'profiler_inventory.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    md = ['# CPU5 阶段 0：profiler 存量与语义映射', '',
          f'日期：2026-10-21。只读核对主工程 `{ROOT}`，HEAD `{head_before}`。规格 v0.3 SHA256 `{record["specification"]["sha256"]}`。', '',
          '**本报告只完成 E 的源文件清点与迁移设计草案。CPU5 RTL／probe 均 NOT IMPLEMENTED，CPU5 测试均 NOT RUN；不宣称 SPEC FROZEN、PARTIAL VERIFIED 或 IMPLEMENTATION PASS。没有启动 ModelSim、构建、综合、P&R、下载或 Git 写操作。**', '',
          '## 文件身份与来源', '',
          '完整原始 SHA256、Git HEAD blob、最近提交、工作区状态、行号锚点和宏展开见同目录 `profiler_inventory.json`。raw SHA 和 LF 规范化 SHA 分列，避免把 EOL 差异误认为逻辑差异。untracked 文件仅是本机证据，不自动拥有可复现的 Git 来源。', '',
          '| 组 | 实际文件 | 来源／状态 | SHA256 |', '|---|---|---|---|']
    for group, paths in GROUPS.items():
        for rel in paths:
            file = next(f for f in files if f['path'] == rel)
            state = ('tracked; ' + (file['git_status_porcelain'] or 'clean')) if file['tracked'] else ('untracked' if file['exists'] else file['status'])
            md.append(f'| {group} | `{rel}` | {state} | `{file.get("sha256", "—")}` |')
    md += ['', '## 生命周期与现有 CSV 合同', '',
           '- **D1：仍固定两次 START。** TB `133–156,299–301` 和 analyzer `73–79` 都硬性要求 `raw=2, selected=1, epoch=2, STOP=1, crossings=0`。当前并未泛化。本轮不修改历史 D1。`M1_CAP=40, M1_SAVE=7, M1_LIMIT=14` 是旧写等待投射参数，不适用于把 D0／CPU5 净收益直接读作写缓冲收益。',
           '- **D0：通用最后 START。** analyzer 第 28 行要求 `raw>=1 && selected==1 && epoch==raw && stop==1`，第 29 行拒绝 boundary/error/cancel；TB 第 31、54–65 行相应实现。D0 固定时序验收还要求 STORE 两拍、CPU response 与 retirement 同边沿（TB 108–117；analyzer 40–42），这些是旧实现特性，不能迁为五级安全不变量。',
           '- **真实 CoreMark AXI 写通路：通用最后 START。** TB 295–311、analyzer 122–127 实现最后代次选择；CSV 保留每笔 `window_epoch`，只汇总选中 epoch。该组四个文件（runner/TB/analyzer/docs）当前均为 untracked，已记录 raw SHA；原 ZIP 缺它们与当前工作区存在并不矛盾。',
           '- **独立十场景 AXI 写通路：没有找到独立 Python analyzer。** 场景/事务/27 个指标/错误取消与加总检查内建于 TB，runner 只检查 TB 完成标志。其 `epoch` 是 reset 启动代次，不是 CoreMark START 银行代次。不能把真实 CoreMark analyzer 套上其 CSV。',
           '- D1 输出 `build/d1_measure_<profile>_window.csv`（key,value）和 buckets（key,count，gap 0..40 加六个 M2 桶）；D0 输出 transactions/window；真实 CoreMark 写通路输出 transactions/summary/window；独立 AXI 场景输出 transactions/summary。实际列头逐一自动摘录于 JSON 的 `csv_literal_headers`。',
           '- D1 key/value 及桶 CSV 没有显式 schema 列；D0/真实写通路 analyzer 的 JSON `schema_version=1` 不是硬件 schema3 或周期 profile schema1。迁移必须分开命名三个层面的版本。不能仅改 prefix 后保留不同语义的旧列名。', '',
           '## 边沿与窗口：避免一拍错账', '',
           '设 E 是物理 posedge 编号。PRE-NBA 是该边沿之前的稳定组合／寄存值；POST-NBA 为现有 TB 用 `#1` 观察更新后的状态。', '',
           '1. `mem_start_x`、总线 req/rsp fire、真实 RAM WE、BP resolve：PRE-NBA 采样。这些分别是发起、握手、副作用和完成事件，不能互相替代。',
           '2. `perf_cycle_events`：CPU 在该边沿根据 PRE-NBA 条件注册新事件，POST-NBA 才看见归属 E 的值。原 stats 在 E 使用旧事件形成 `profile_next`，START/STOP 锁它以对齐 PRE-NBA `cycle_count`。',
           '3. 所以 S=START、T=STOP 的计数差，物理阻塞边沿是 `[S,T)`；在 POST-NBA 采新事件同样取 `[S,T)`；若 PRE-NBA 直接采旧注册事件，必须取 `(S,T]`。两种不能混用。D1 BP 是当前 PRE-NBA resolve，硬件锁 BP pre-counter，因此 BP 事件取 `[S,T)`；不存在把所有注册字段统一移一拍的万能规则。',
           '4. `retire_valid` 与 `wb_pc` 同一边沿注册。现有写观察器 POST-NBA 看见 E 完成的指令；新 RAW 观察器若 PRE-NBA 采它们，看见的是 E-1 完成的指令，必须显式标注 completion edge／观察延迟并绑定 PC，不能用实时 `instr_x`。`instret_count` 再根据 PRE-NBA `retire_valid` 增加，端点对账须保持此合同。',
           '5. mtime 每拍 NBA 增加；端点接受读时取 pre-increment 值，固件 high/low/high 在三个不同被接受的读边沿取数，溢出则重试。START 在计时读取前，STOP 在计时读取后，故 `counter_cycles` 与 `raw_ticks` 允许有边界开销，不能强制相等。', '',
           '## 旧层次到 CPU5 的字段合同草案', '',
           '下列新名字全部是**规划**；首次实现 patch 还需锁定具体端口、宽度、owner 字段、边沿、寄存延迟与 schema。']
    for s in SIGNALS:
        md += ['', f'### {s["id"]}：`{s["old"]}`', '',
               f'- 实际层次：`{s["binding"]}`；来源：`{s["source"]}`。',
               f'- 指令年龄：{s["age"]}。', f'- 采样：{s["sample"]}。窗口：{s["window"]}。',
               f'- 输出意义：{s["output"]}。', f'- CPU5 拟探针：`{s["cpu5_planned"]}`。',
               f'- 兼容结论：{s["reuse"]}。**CPU5 NOT IMPLEMENTED / NOT RUN。**']
    md += ['', '## Workload 变体与可复用边界', '',
           '- `tb/coremark_axi_tb.v:59–65` 是 AXI workload，没有传 `ENABLE_D0_BRAM`，只换配置宏不等于 D0。M/D0 应使用 `tb/coremark_d0_workload_tb.v:62–69`，该处明确连接 backend 和 ENABLE_M，`run_coremark_m.do` 也使用它。D0 observer 第 12 行实例化的正是 D0 workload。',
           '- D1/真实 AXI 写观察器的 `workload.dut.u_ram` 是 AXI RAM；D0 的 RAM 是 `workload.dut.u_core.g_d0_bram.u_ram`。原生 BRAM流量无 AW/W/B，不得编造 12 段 AXI 时间戳。',
           '- 独立 AXI 案例使用 `axi_write_profile_tb.<case>.cpu`、`.ram` 及本地 cq/bq/AXI wire；不采用 D1 宏。现有端点协议断言可在后端不变的条件下复用，但 CPU retirement/launch 固定延迟必须变更。',
           '- 建议保留旧 TB 与 analyzer 文件，CPU5 用新 adapter+新 schema。M1 若从 EX launch 改为 MEM req acceptance，是新指标而非原始 gap S 的直接延续；比较前需两种采样同时记录以证明定义。BP 预测元数据必须跟随退休控制指令，不能读取当拍 IF/ID 的预测作为 MEM 指令属性。', '',
           '## CPU5 后续必须执行的合同测试（本轮均 NOT IMPLEMENTED / NOT RUN）', '']
    md += [f'- **E-T{i+1:02}** {test}' for i, test in enumerate(CONTRACT_TESTS)]
    md += ['', '## 本轮边界与验收', '',
           '本轮只读扫描及证据生成脚本成功执行，audited_files_unchanged_at_end=true，Git HEAD 与 status 在本脚本前后相同。该检查证明本次清点过程未改变被审文件，并不替代父任务对整个工作区的冻结核验。所有历史文档中的 PASS 都是原记录，本次没有重新运行它们。CPU5 的 probe、hazard CSV、十分类实测、A01–A16、PLL、ILA、STA 均未在本子任务实现或运行。', '']
    (OUT / 'profiler_signal_map.md').write_text('\n'.join(md), encoding='utf-8')
    print(json.dumps({'files': len(files), 'existing': sum(f['exists'] for f in files), 'untracked': [f['path'] for f in files if f['exists'] and not f['tracked']], 'missing': [f['path'] for f in files if not f['exists']], 'signal_mappings': len(SIGNALS), 'cpu5_status': record['cpu5_rtl_status'], 'outputs': ['profiler_inventory.json', 'profiler_signal_map.md']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
