"""Reject real CPU5 RV32M/core-owner RTL mutants after independent clean compilation.

Every specimen retains its actual bad source, compile/run scripts and console
logs in a fresh directory. A compile/elaboration failure is never accepted as a
semantic rejection. Parameter guards are reported separately from RTL mutants.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s8_m_mutations'
PIPE = 'rtl/cpu5_alu_pipeline.v'
BANK = 'rtl/cpu5_csr_unit.v'
TB = 'tb/cpu5_m_control_tb.v'
TOP = 'cpu5_m_control_tb'
LIB = 'cpu5_m_mutation_work'
RTL = [
    'rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
    'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
    'rtl/cpu5_ram_owner.v', BANK, 'rtl/rv32m_unit.v', 'rtl/cpu5_m_owner.v', PIPE,
]
SOURCES = RTL + ['rtl/cpu5_pipeline_types.vh', TB,
                 'run_cpu5_m_control.do', 'tools/verify_cpu5_m_mutations.py']
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILE_MARKER = 'CPU5 M MUTATION CLEAN COMPILE PASS'
SIM_MARKER = 'CPU5 M MUTATION REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutant(name, rel, old, new, expected_assertion):
    return dict(name=name, kind='rtl_semantic', changed_file=rel, old=old,
                new=new, expected_assertion=expected_assertion)


def specimens():
    """Synthesizable core integration edits; neither assertions nor TB change."""
    return [
        mutant('m_advances_without_result', PIPE,
               '(!idex_q.is_m || idex_q.exception_valid || m_ex_matches) &&', "1'b1 &&",
               'CPU5 M result lacks matching live EX identity'),
        mutant('m_fetch_fault_waits_for_m_result', PIPE,
               '(!idex_q.is_m || idex_q.exception_valid || m_ex_matches) &&',
               '(!idex_q.is_m || m_ex_matches) &&',
               'M fault packet waited for nonexistent arithmetic completion'),
        mutant('m_writes_zero_instead_of_result', PIPE,
               'exmem_next.alu_result=idex_q.is_m?m_completion_result:',
               "exmem_next.alu_result=idex_q.is_m?32'd0:",
               'CSR retirement payload'),
        mutant('m_start_ignores_old_memory_risk', PIPE,
               'ex_enable && !m_older_risk && (!ENABLE_FORWARDING || !ex_source_stall);',
               'ex_enable && (!ENABLE_FORWARDING || !ex_source_stall);',
               'CPU5 M start lacks safe live EX owner'),
        mutant('m_completion_consumed_during_ex_hold', PIPE,
               'assign m_completion_ready=m_ex_matches && ex_move;',
               'assign m_completion_ready=m_ex_matches;',
               'M completion not retained across EX hold'),
        mutant('m_owner_kill_disconnected', PIPE,
               '.issue_op(idex_q.funct3),.issue_lhs(ex_rs1_value),.issue_rhs(ex_rs2_value),\n'
               '            .kill_valid(owner_kill_valid),',
               '.issue_op(idex_q.funct3),.issue_lhs(ex_rs1_value),.issue_rhs(ex_rs2_value),\n'
               "            .kill_valid(1'b0),",
               'M running DIV did not persist for killed drain'),
        mutant('misa_does_not_advertise_integrated_m', BANK,
               "12'h301:read_value=ENABLE_RV32M?32'h40001100:32'h40000100;",
               "12'h301:read_value=32'h40000100;",
               'CSR retirement payload'),
        mutant('m_mem_forward_uses_zero', PIPE,
               '        .mem_result_value(mem_result_value),',
               "        .mem_result_value(exmem_q.is_m?32'd0:mem_result_value),",
               'CSR retirement payload'),
        mutant('m_only_decodes_mul', PIPE,
               "wire id_m=ENABLE_RV32M && in_instr[6:0]==7'h33 && in_instr[31:25]==7'h01;",
               "wire id_m=ENABLE_RV32M && in_instr[6:0]==7'h33 && in_instr[31:25]==7'h01 && in_instr[14:12]==0;",
               'CSR precise trap/priority'),
    ]


def parameter_specimens():
    return [dict(name='invalid_rv32m_boolean', kind='parameter_guard', changed_file=TB,
                 old='.ENABLE_RV32M(1)', new='.ENABLE_RV32M(2)',
                 expected_assertion='CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode')]


def run_process(command, cwd, name, timeout):
    p = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=timeout)
    output = p.stdout + p.stderr
    log = cwd / (name + '_console.log')
    log.write_text(output, encoding='utf-8', newline='')
    return p.returncode, output, log


def prepare(directory, spec, originals):
    directory.mkdir(parents=True, exist_ok=False)
    for rel, content in originals.items():
        if rel.startswith('tools/') or rel.endswith('.do'):
            continue
        target = directory / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    changed = None
    if spec:
        path = directory / spec['changed_file']
        content = path.read_text(encoding='utf-8')
        count = content.count(spec['old'])
        assert count == 1, (spec['name'], 'mutation anchor must be unique', count)
        path.write_text(content.replace(spec['old'], spec['new']),
                        encoding='utf-8', newline='')
        assert sha(path) != hashlib.sha256(originals[spec['changed_file']]).hexdigest()
        changed = dict(path=spec['changed_file'], good_sha256=hashlib.sha256(
            originals[spec['changed_file']]).hexdigest(), bad_sha256=sha(path),
            old=spec['old'], new=spec['new'])
    # The unmodified control TB owns its output layout. Its copies write only
    # inside this specimen; the good run's evidence is never shared or changed.
    (directory / 'build/cpu5_s8_m_control').mkdir(parents=True)
    compile_do = '\n'.join([
        'onerror {quit -code 1 -f}',
        'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', f'vmap {LIB} work',
        f'vlog -sv +incdir+. -work {LIB} ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILE_MARKER}"', 'quit -code 0 -f', '',
    ])
    simulate_do = '\n'.join([
        'onerror {quit -code 1 -f}',
        'transcript file simulation_transcript.log',
        f'vmap {LIB} work',
        f'vsim -voptargs="+acc" -onfinish stop -wlf specimen.wlf {LIB}.{TOP}',
        'run -all',
        f'if {{[examine -radix unsigned sim:/{TOP}/test_pass] != 1}} '
        '{quit -code 1 -f}',
        f'echo "{SIM_MARKER}"', 'quit -code 0 -f', '',
    ])
    (directory / 'compile.do').write_text(compile_do, encoding='utf-8', newline='')
    (directory / 'simulate.do').write_text(simulate_do, encoding='utf-8', newline='')
    return changed


def verify_one(vsim, directory, spec, originals, timeout):
    changed = prepare(directory, spec, originals)
    code, output, compile_log = run_process(
        [str(vsim), '-c', '-do', 'compile.do'], directory, 'compile', timeout)
    assert code == 0 and COMPILE_MARKER in output and not DIAGNOSTIC.search(output), \
        ('specimen must compile with zero warnings/errors', directory.name, code, output[-6000:])
    compile_record = dict(status='PASS', exit_code=code, warnings=0, errors=0,
                          console_sha256=sha(compile_log))
    code, output, simulation_log = run_process(
        [str(vsim), '-c', '-do', 'simulate.do'], directory, 'simulation', timeout)
    assert not DIAGNOSTIC.search(output), \
        ('simulation warning/elaboration error is not semantic evidence', directory.name, output[-6000:])
    if spec:
        assert code != 0 and '** Fatal:' in output and spec['expected_assertion'] in output, \
            ('designated semantic assertion did not reject specimen', directory.name,
             code, spec['expected_assertion'], output[-6000:])
        status = 'REJECTED'
    else:
        assert code == 0 and SIM_MARKER in output, \
            ('good control reference failed', code, output[-6000:])
        status = 'PASS'
    result = dict(name=directory.name, kind=spec['kind'] if spec else 'good_reference',
                  status=status, directory=str(directory.relative_to(ROOT)),
                  compile=compile_record, simulation_exit_code=code,
                  expected_assertion=spec['expected_assertion'] if spec else None,
                  simulation_console_sha256=sha(simulation_log),
                  actual_assertion=next((line.strip() for line in output.splitlines()
                                         if '** Fatal:' in line), None),
                  changed_source=changed,
                  specimen_source_sha256={rel: sha(directory / rel)
                                          for rel in RTL + ['rtl/cpu5_pipeline_types.vh', TB]},
                  retained_artifact_sha256={p.name: sha(p) for p in directory.iterdir()
                                           if p.is_file() and p.suffix in ('.do', '.log', '.wlf')})
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(directory.name, status, flush=True)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--timeout', type=int, default=240)
    ap.add_argument('--only', action='append', help='debug selected specimens; result is PARTIAL')
    ap.add_argument('--list', action='store_true', help='list specimen names without simulation')
    args = ap.parse_args()
    all_specs = specimens() + parameter_specimens()
    if args.list:
        print('\n'.join(s['name'] for s in all_specs))
        return
    names = {s['name'] for s in all_specs}
    assert not args.only or set(args.only) <= names, 'unknown specimen name'
    specs = [s for s in all_specs if not args.only or s['name'] in args.only]
    before = {rel: sha(ROOT / rel) for rel in SOURCES}
    originals = {rel: (ROOT / rel).read_bytes() for rel in SOURCES}
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_') + uuid.uuid4().hex[:8]
    run_dir = OUT / 'runs' / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    # A failed rerun must never leave a previous PASS as the current result.
    (OUT / 'verification.json').write_text(json.dumps(dict(
        status='RUNNING', run_id=run_id, source_sha256=before), indent=2) + '\n',
        encoding='utf-8')
    reference = verify_one(args.vsim, run_dir / 'good_reference', None, originals, args.timeout)
    results = [verify_one(args.vsim, run_dir / s['name'], s, originals, args.timeout) for s in specs]
    assert before == {rel: sha(ROOT / rel) for rel in SOURCES}, 'mutation tests changed good input'
    result = dict(status='PARTIAL' if args.only else 'PASS', run_id=run_id,
                  source_sha256=before, good_sources_unchanged=True,
                  good_reference=reference, specimens=results,
                  rtl_semantic_rejected=sum(s['kind'] == 'rtl_semantic' for s in results),
                  parameter_guards_rejected=sum(s['kind'] == 'parameter_guard' for s in results),
                  compile_zero_warning_error=True,
                  semantic_rejection_requires='clean compile, nonzero simulation exit, Fatal and designated assertion token',
                  performance_claim='NONE')
    rendered = json.dumps(result, indent=2) + '\n'
    (run_dir / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps({k: result[k] for k in ('status', 'rtl_semantic_rejected',
                                            'parameter_guards_rejected', 'good_sources_unchanged')}))


if __name__ == '__main__':
    main()
