import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'mutations'
FILES = ['rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
         'rtl/cpu5_alu_pipeline.v', 'rtl/cpu5_pipeline_types.vh',
         'tb/cpu5_alu_control_tb.v', 'run_cpu5_alu_control.do']
GOOD_EVIDENCE = ['build/cpu5_s2_control/transcript.log',
                 'build/cpu5_s2_control/control_trace.csv',
                 'build/cpu5_s2_control/control.wlf',
                 'build/cpu5_s2_control/verification.json']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise AssertionError(f'expected one mutation site: {old!r}')
    return text.replace(old, new, 1)

def stale_wb(text):
    text = replace_once(text, ' || (wb_writer&&memwb_q.rd==rs1)', '')
    return replace_once(text, ' || (wb_writer&&memwb_q.rd==rs2)', '')

def delayed_instret(text):
    text = replace_once(text, '                instret_count<=instret_count+64\'d1;\n', '')
    return replace_once(text, '            retire_valid<=retire_fire;\n',
        '            retire_valid<=retire_fire;\n'
        '            if(retire_valid)instret_count<=instret_count+64\'d1;\n')

def blocked_wb(text):
    return replace_once(text,
        'assign wb_fire=rst_n && memwb_valid_q && wb_ready;',
        'assign wb_fire=rst_n && memwb_valid_q && wb_ready && mem_enable;')

def flush_drops_wb(text):
    text = replace_once(text,
        'assign wb_fire=rst_n && memwb_valid_q && wb_ready;',
        'assign wb_fire=rst_n && memwb_valid_q && wb_ready && !flush_valid;')
    return replace_once(text,
        'wire wb_can_load=!memwb_valid_q || wb_fire;',
        'wire wb_can_load=!memwb_valid_q || wb_fire || flush_valid;')

MUTATIONS = [
    ('stale_wb_raw', stale_wb,
     'Omit the WB producer from both conservative source-dependency checks.',
     'dependent ID accepted at producer WB write edge'),
    ('delayed_instret', delayed_instret,
     'Increment instret from registered retire_valid one edge after MEM fire.',
     'registered retire/counter edge mismatch'),
    ('wb_blocked_by_mem_enable', blocked_wb,
     'Incorrectly require MEM enable before draining already retired WB.',
     'MEM hold failed to drain older WB exactly once'),
    ('flush_drops_retired_wb', flush_drops_wb,
     'Apply a global flush to the already retired WB slot: suppress its write and clear it.',
     'flush failed to kill MEM/EX/input while preserving old WB'),
]

OUT.mkdir(exist_ok=True)
before = {p: sha(ROOT / p) for p in FILES + GOOD_EVIDENCE}
core_bytes = (ROOT / 'rtl/cpu5_alu_pipeline.v').read_bytes()
core_text = core_bytes.decode('utf-8')
results = []
for name, mutate, description, expected_message in MUTATIONS:
    run_dir = OUT / name
    if run_dir.exists():
        raise RuntimeError(f'do not overwrite prior mutation evidence: {run_dir}')
    for relative in FILES:
        destination = run_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)
    mutated_text = mutate(core_text)
    mutated_file = run_dir / 'rtl/cpu5_alu_pipeline.v'
    mutated_file.write_bytes(mutated_text.encode('utf-8'))
    result = subprocess.run(
        ['D:/modeltech64_10.6e/win64/vsim.exe', '-c', '-do', 'run_cpu5_alu_control.do'],
        cwd=run_dir, capture_output=True, text=True, timeout=45)
    log = result.stdout + result.stderr
    (run_dir / 'process.log').write_text(log, encoding='utf-8', newline='')
    record = {
        'id': name, 'description': description, 'isolated_workdir': str(run_dir),
        'good_core_sha256': before['rtl/cpu5_alu_pipeline.v'],
        'mutated_core_sha256': sha(mutated_file),
        'exit_code': result.returncode,
        'expected_assertion_message': expected_message,
        'expected_assertion_seen': expected_message in log,
        'compile_errors_zero': 'Errors: 0, Warnings: 0' in log,
        'success_marker_absent': 'CPU5_ALU_CONTROL_PASS' not in log,
        'process_log_sha256': sha(run_dir / 'process.log'),
    }
    record['rejected_as_expected'] = (
        result.returncode != 0 and record['expected_assertion_seen']
        and record['compile_errors_zero'] and record['success_marker_absent'])
    results.append(record)
    (run_dir / 'result.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')

after = {p: sha(ROOT / p) for p in FILES + GOOD_EVIDENCE}
output = {
    'schema': 1, 'date': '2026-10-21',
    'scope': 'Four real CPU5 ALU control RTL defects; production/main-work sources unchanged.',
    'good_inputs_and_evidence_before': before,
    'good_inputs_and_evidence_after': after,
    'original_good_run_and_source_hashes_preserved': before == after,
    'results': results,
    'all_four_rejected': len(results) == 4 and all(r['rejected_as_expected'] for r in results),
}
output['pass'] = output['original_good_run_and_source_hashes_preserved'] and output['all_four_rejected']
(OUT / 'mutation_results.json').write_text(json.dumps(output, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'pass': output['pass'], 'results': [
    {'id': r['id'], 'exit_code': r['exit_code'],
     'expected_assertion_seen': r['expected_assertion_seen'],
     'rejected_as_expected': r['rejected_as_expected']} for r in results]}, indent=2))
if not output['pass']:
    raise SystemExit(1)
