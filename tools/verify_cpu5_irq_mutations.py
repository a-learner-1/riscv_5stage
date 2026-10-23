"""Reject real CPU5 machine IRQ RTL mutants after independent clean compilation.

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
OUT = ROOT / 'build/cpu5_s9_irq_mutations'
PIPE = 'rtl/cpu5_alu_pipeline.v'
BANK = 'rtl/cpu5_csr_unit.v'
CTRL = 'rtl/cpu5_irq_ctrl.v'
TB = 'tb/cpu5_irq_control_tb.v'
TOP = 'cpu5_irq_control_tb'
LIB = 'cpu5_irq_mutation_work'
RTL = [
    'rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
    'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
    'rtl/cpu5_ram_owner.v', BANK, 'rtl/rv32m_unit.v', 'rtl/cpu5_m_owner.v', CTRL, PIPE,
]
SOURCES = RTL + ['rtl/cpu5_pipeline_types.vh', TB,
                 'run_cpu5_irq_control.do', 'tools/verify_cpu5_irq_mutations.py']
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILE_MARKER = 'CPU5 IRQ MUTATION CLEAN COMPILE PASS'
SIM_MARKER = 'CPU5 IRQ MUTATION REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutant(name, rel, old, new, expected_assertion):
    return dict(name=name, kind='rtl_semantic', changed_file=rel, old=old,
                new=new, expected_assertion=expected_assertion)


def specimens():
    """Architectural IRQ errors, each rejected by a designated semantic check."""
    return [
        mutant('irq_uses_one_sync_flop', CTRL,
               'external_sync_q<=external_meta_q;', 'external_sync_q<=irq_external;',
               'IRQ post-commit arm/synchronizer model'),
        mutant('irq_bypasses_old_arm', CTRL,
               'irq_arm_q && irq_eligible_now && safe_boundary',
               'irq_eligible_now && safe_boundary',
               ['IRQ independent arbitration model', 'CPU5 IRQ lacks pre-edge safe armed eligibility']),
        mutant('irq_ignores_current_eligibility', CTRL,
               'irq_arm_q && irq_eligible_now && safe_boundary',
               'irq_arm_q && safe_boundary',
               ['IRQ independent arbitration model', 'CPU5 IRQ lacks pre-edge safe armed eligibility']),
        mutant('irq_arm_uses_old_global_enable', CTRL,
               'wire next_global=retire_fire?post_commit_global_enable:global_enable;',
               'wire next_global=global_enable;',
               'IRQ post-commit arm/synchronizer model'),
        mutant('irq_arm_uses_old_mie', CTRL,
               'wire [31:0] next_mie=retire_fire?post_commit_mie:mie_value;',
               'wire [31:0] next_mie=mie_value;',
               'IRQ post-commit arm/synchronizer model'),
        mutant('irq_mret_arm_uses_old_mie_status', BANK,
               'assign post_commit_global_enable=mret_fire?csr_mstatus[7]:',
               'assign post_commit_global_enable=mret_fire?csr_mstatus[3]:',
               'IRQ post-commit arm/synchronizer model'),
        mutant('irq_uncommitted_disable_shields_entry', PIPE,
               '.global_enable(csr_mstatus_value[3]),.mie_value(csr_mie_value),',
               ".global_enable(csr_mstatus_value[3] && !(exmem_valid_q && exmem_q.is_csr && (exmem_q.csr_addr==12'h300 || exmem_q.csr_addr==12'h304) && exmem_q.csr_write_intent && exmem_q.csr_operand==0)),.mie_value(csr_mie_value),",
               'IRQ independent arbitration model'),
        mutant('irq_waits_for_wb_space', PIPE,
               'assign irq_safe_boundary=!ram_store_lock &&',
               'assign irq_safe_boundary=wb_can_load && !ram_store_lock &&',
               'IRQ independent arbitration model'),
        mutant('irq_starves_at_empty_boundary', PIPE,
               'assign irq_safe_boundary=!ram_store_lock &&',
               'assign irq_safe_boundary=exmem_valid_q && !ram_store_lock &&',
               'IRQ independent arbitration model'),
        mutant('irq_steals_store_completion_edge', PIPE,
               'assign irq_safe_boundary=!ram_store_lock &&',
               'assign irq_safe_boundary=(!ram_store_lock || (ram_mem_matches && !ram_completion_error)) &&',
               ['IRQ independent arbitration model', 'CPU5 IRQ crossed unsafe or paused boundary']),
        mutant('irq_preempts_live_load', PIPE,
               '!(exmem_valid_q && !kill_mem && exmem_q.is_load);', "1'b1;",
               ['IRQ independent arbitration model', 'CPU5 IRQ crossed unsafe or paused boundary']),
        mutant('irq_waits_for_cancelable_m', PIPE,
               'assign irq_safe_boundary=!ram_store_lock &&',
               'assign irq_safe_boundary=!m_owner_valid && !ram_store_lock &&',
               'IRQ independent arbitration model'),
        mutant('irq_waits_for_killed_d_drain', PIPE,
               'assign irq_safe_boundary=!ram_store_lock &&',
               'assign irq_safe_boundary=!ram_owner_valid && !ram_store_lock &&',
               'IRQ independent arbitration model'),
        mutant('irq_does_not_kill_running_m', PIPE,
               'assign owner_kill_valid=flush_fire || trap_fire || mret_fire || irq_take;',
               'assign owner_kill_valid=flush_fire || trap_fire || mret_fire;',
               'IRQ did not cancel running M owner'),
        mutant('irq_saves_mem_pc_instead_of_committed_next_pc', PIPE,
               '.fault_pc(irq_take?arch_next_pc_q:exmem_q.pc),',
               '.fault_pc(exmem_q.pc),',
               'CSR committed state'),
        mutant('irq_overlaps_retirement', PIPE,
               '!kill_mem && !mem_fault && !irq_take &&',
               '!kill_mem && !mem_fault &&',
               ['IRQ entry priority/diagnostic owner', 'CPU5 IRQ leaked retirement or younger action', 'CPU5 IRQ and retirement overlap']),
        mutant('irq_drops_already_retired_wb', PIPE,
               'assign wb_we=wb_fire && memwb_q.writes_rd && memwb_q.rd!=0;',
               'assign wb_we=wb_fire && memwb_q.writes_rd && memwb_q.rd!=0 && !irq_take;',
               'CSR WB stream'),
        mutant('irq_timer_wrongly_beats_external', CTRL,
               "assign irq_cause=enabled_pending[11]?32'h8000000b:\n        enabled_pending[3]?32'h80000003:enabled_pending[7]?32'h80000007:32'd0;",
               "assign irq_cause=enabled_pending[7]?32'h80000007:\n        enabled_pending[11]?32'h8000000b:enabled_pending[3]?32'h80000003:32'd0;",
               'CSR committed state'),
        mutant('irq_ignores_sync_fault_priority', CTRL,
               'mem_enable && !flush_active && !sync_fault;',
               'mem_enable && !flush_active;',
               ['IRQ independent arbitration model', 'CPU5 IRQ lacks pre-edge safe armed eligibility', 'CPU5 IRQ leaked retirement or younger action']),
        mutant('irq_mip_reads_mie_instead_of_pending', BANK,
               "12'h344:begin known=IRQ_ENABLED;read_value=irq_pending & IRQ_MASK;end",
               "12'h344:begin known=IRQ_ENABLED;read_value=csr_mie;end",
               'CSR retirement payload'),
        mutant('irq_volatile_mip_forwarded_before_retirement', PIPE,
               "wire csr_read_stable=exmem_q.csr_addr!=12'h344 || (mem_enable && wb_can_load);",
               "wire csr_read_stable=1'b1;",
               ['IRQ volatile MIP branch captured before CSR retirement',
                'CSR unexpected younger redirect mode=1 case=26']),
        mutant('irq_mie_warl_not_masked', BANK,
               "12'h304:csr_mie<=write_value & IRQ_MASK;",
               "12'h304:csr_mie<=write_value;",
               'CSR committed state'),
    ]


def parameter_specimens():
    tokens=['CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode',
            'CPU5 IRQ source parameters must be boolean',
            'CPU5 CSR IRQ source parameters must be boolean']
    return [dict(name='invalid_' + source + '_boolean', kind='parameter_guard', changed_file=TB,
                 old=f'.ENABLE_{source.upper()}_IRQ(1)', new=f'.ENABLE_{source.upper()}_IRQ(2)',
                 expected_assertion=tokens) for source in ('external','software','timer')]


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
    (directory / 'build/cpu5_s9_irq_control').mkdir(parents=True)
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
        tokens=spec['expected_assertion'] if isinstance(spec['expected_assertion'], list) else [spec['expected_assertion']]
        assert code != 0 and '** Fatal:' in output and any(token in output for token in tokens), \
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
    results, failures = [], []
    for spec in specs:
        try:
            results.append(verify_one(args.vsim, run_dir / spec['name'], spec, originals, args.timeout))
        except AssertionError as error:
            failures.append(dict(name=spec['name'], error=str(error)))
            print(spec['name'], 'FAILED CHECK', flush=True)
    if failures:
        (run_dir / 'failures.json').write_text(json.dumps(failures, indent=2) + '\n', encoding='utf-8')
    assert not failures, failures
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
