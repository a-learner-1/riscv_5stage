from pathlib import Path
import hashlib
import json
import subprocess

root = Path.cwd()
files = [
    'rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_alu_decode.v',
    'rtl/cpu5_branch_unit.v', 'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_pipeline_types.vh',
    'tb/cpu5_branch_control_tb.v', 'run_cpu5_branch_control.do',
]
out = root / 'build/cpu5_s4_branch_control'
hashes = {
    p: {
        'sha256': hashlib.sha256((root / p).read_bytes()).hexdigest(),
        'canonical_lf_sha256': hashlib.sha256((root / p).read_bytes().replace(b'\r\n', b'\n')).hexdigest(),
    } for p in files
}
(out / 'source_hashes.json').write_text(json.dumps(hashes, indent=2) + '\n', encoding='utf-8')
rtl = (root / 'rtl/cpu5_alu_pipeline.v').read_text()
changes = {
    'flush_consumes_surviving_source': [
        (' && !(ENABLE_CONTROL_FLOW && flush_valid)', ''),
    ],
    'ex_redirect_admits_younger': [
        ('!ex_redirect && !(ENABLE_CONTROL_FLOW && flush_valid)', '!(ENABLE_CONTROL_FLOW && flush_valid)'),
    ],
    'id_redirect_kills_source': [
        ('assign redirect_kill_ifid=ex_redirect;', 'assign redirect_kill_ifid=redirect_valid;'),
    ],
    'known_ex_fault_loses_priority': [
        ('wire known_ex_fault=idex_valid_q && !kill_ex &&\n        (!idex_supported_q || idex_q.exception_valid || ex_target_fault);', "wire known_ex_fault=1'b0;"),
    ],
    'prediction_trains_before_retire': [
        ('assign bp_commit_valid=ENABLE_CONTROL_FLOW && retire_fire;', 'assign bp_commit_valid=ENABLE_CONTROL_FLOW && idex_valid_q;'),
    ],
    'flush_blocks_retired_wb': [
        ('assign wb_fire=rst_n && memwb_valid_q && wb_ready;', 'assign wb_fire=rst_n && memwb_valid_q && wb_ready && !flush_valid;'),
    ],
    'newest_mem_unready_ignored': [
        ('exmem_supported_q && !exmem_q.exception_valid && exmem_q.result_ready', 'exmem_supported_q && !exmem_q.exception_valid'),
    ],
    'age_truncated_32bit': [
        ('in_seq>=flush_cut_seq', 'in_seq[31:0]>=flush_cut_seq[31:0]'),
        ('idex_q.seq>=flush_cut_seq', 'idex_q.seq[31:0]>=flush_cut_seq[31:0]'),
        ('exmem_q.seq>=flush_cut_seq', 'exmem_q.seq[31:0]>=flush_cut_seq[31:0]'),
    ],
    'ordinary_alu_wrong_prediction_not_corrected': [
        ('ex_move && idex_supported_q && !idex_q.exception_valid', 'ex_move && ex_is_cf && idex_supported_q && !idex_q.exception_valid'),
        ('id_move && supported && !in_fetch_error', 'id_move && cf_supported && !in_fetch_error'),
    ],
    'jal_link_writes_target': [
        ("exmem_next.alu_result=ex_is_cf?(idex_q.is_branch?32'd0:idex_q.pc+32'd4):alu_result;", "exmem_next.alu_result=ex_is_cf?(idex_q.is_branch?32'd0:ex_branch_target):alu_result;"),
    ],
}
results = []
for name, replacements in changes.items():
    mutated = rtl
    for old, new in replacements:
        assert old in mutated, (name, old)
        mutated = mutated.replace(old, new)
    dest = root / 'build/mutations' / name
    for p in files:
        target = dest / p
        target.parent.mkdir(parents=True, exist_ok=True)
        if p == 'rtl/cpu5_alu_pipeline.v':
            target.write_text(mutated, encoding='utf-8')
        else:
            target.write_bytes((root / p).read_bytes())
    (dest / 'build/cpu5_s4_branch_control').mkdir(parents=True, exist_ok=True)
    proc = subprocess.run([
        r'D:\modeltech64_10.6e\win64\vsim.exe', '-c', '-do',
        'run_cpu5_branch_control.do', '-l', 'build/cpu5_s4_branch_control/process.log',
    ], cwd=dest, capture_output=True, text=True)
    log = proc.stdout + proc.stderr
    (dest / 'stdout.log').write_text(log, encoding='utf-8')
    rejected = proc.returncode != 0 and '** Fatal:' in log and 'Errors: 0, Warnings: 0' in log
    fatal = next((line for line in log.splitlines() if '** Fatal:' in line), '')
    result = {
        'name': name, 'exit_code': proc.returncode, 'rejected': rejected, 'fatal': fatal,
        'source_sha256': hashlib.sha256((dest / 'rtl/cpu5_alu_pipeline.v').read_bytes()).hexdigest(),
        'tb_sha256': hashes['tb/cpu5_branch_control_tb.v']['sha256'],
        'log': str((dest / 'stdout.log').relative_to(root)),
    }
    results.append(result)
    print(json.dumps(result), flush=True)
    assert rejected, name
(out / 'mutation_results.json').write_text(json.dumps(results, indent=2) + '\n', encoding='utf-8')
