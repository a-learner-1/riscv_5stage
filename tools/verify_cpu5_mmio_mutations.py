"""Reject real CPU5 ordered MMIO RTL mutants after independent clean compilation.

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
OUT = ROOT / 'build/cpu5_s10_mmio_mutations'
PIPE = 'rtl/cpu5_alu_pipeline.v'
BANK = 'rtl/cpu5_csr_unit.v'
CTRL = 'rtl/cpu5_irq_ctrl.v'
TB = 'tb/cpu5_mmio_control_tb.v'
TOP = 'cpu5_mmio_control_tb'
LIB = 'cpu5_mmio_mutation_work'
RTL = [
    'rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
    'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
    'rtl/cpu5_ram_owner.v', BANK, 'rtl/rv32m_unit.v', 'rtl/cpu5_m_owner.v', CTRL, PIPE,
]
SOURCES = RTL + ['rtl/cpu5_pipeline_types.vh', TB,
                 'run_cpu5_mmio_control.do', 'tools/verify_cpu5_mmio_mutations.py']
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILE_MARKER = 'CPU5 MMIO MUTATION CLEAN COMPILE PASS'
SIM_MARKER = 'CPU5 MMIO MUTATION REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutant(name, rel, old, new, expected_assertion):
    return dict(name=name, kind='rtl_semantic', changed_file=rel, old=old,
                new=new, expected_assertion=expected_assertion)


def specimens():
    """Each real bad implementation must fail a designated behavioral check."""
    return [
        mutant('nonram_read_speculates_in_ex', PIPE,
               '(!ENABLE_MMIO || !ram_ex_out_of_range);', "1'b1;",
               ['CPU5 non-RAM read speculated in EX', 'MMIO first presentation lacks oldest MEM authorization']),
        mutant('only_local_io_is_ordered', PIPE,
               '(!ENABLE_MMIO || !ram_ex_out_of_range);',
               "(!ENABLE_MMIO || !(ram_ex_addr>=32'h20000000 && ram_ex_addr<32'h20000100));",
               ['CPU5 non-RAM read speculated in EX', 'MMIO first presentation lacks oldest MEM authorization']),
        mutant('mmio_range_still_faults_at_ex', PIPE,
               'ram_ex_misaligned || (!ENABLE_MMIO && ram_ex_out_of_range);',
               'ram_ex_misaligned || ram_ex_out_of_range;', ['MMIO precise trap/priority', 'IRQ independent arbitration model']),
        mutant('mmio_read_never_issues_from_mem', PIPE,
               'wire mem_request=mem_store_request || mem_io_request;',
               'wire mem_request=mem_store_request;', 'MMIO request presentation timeout'),
        mutant('mmio_read_bypasses_mem_enable', PIPE,
               'exmem_q.is_load && exmem_q.mem_order_barrier && exmem_supported_q && !exmem_q.exception_valid &&\n        mem_enable && !flush_valid && !mem_fault && !ram_mem_owned;',
               'exmem_q.is_load && exmem_q.mem_order_barrier && exmem_supported_q && !exmem_q.exception_valid &&\n        !flush_valid && !mem_fault && !ram_mem_owned;',
               ['MMIO first presentation lacks oldest MEM authorization', 'CPU5 ordered I/O read lacks oldest MEM authorization']),
        mutant('mmio_read_mislabeled_as_write', PIPE,
               'assign ram_issue_store=mem_store_request;',
               'assign ram_issue_store=mem_request;', ['MMIO unexpected/younger D request', 'MMIO first presentation lacks oldest MEM authorization', 'CPU5 STORE issue lacks oldest qualified MEM owner']),
        mutant('mmio_seq_mux_uses_ex_owner', PIPE,
               '.issue_seq(mem_request?exmem_q.seq:idex_q.seq),',
               '.issue_seq(mem_store_request?exmem_q.seq:idex_q.seq),',
               ['MMIO first presentation lacks oldest MEM authorization', 'MMIO unexpected/younger D request']),
        mutant('mmio_addr_mux_uses_ex_address', PIPE,
               '.issue_addr(mem_request?exmem_q.mem_addr:ram_ex_addr),',
               '.issue_addr(mem_store_request?exmem_q.mem_addr:ram_ex_addr),', 'MMIO unexpected/younger D request'),
        mutant('mmio_pc_mux_uses_ex_pc', PIPE,
               '.issue_pc(mem_request?exmem_q.pc:idex_q.pc),',
               '.issue_pc(mem_store_request?exmem_q.pc:idex_q.pc),',
               ['CPU5 D completion owner identity mismatch', 'MMIO precise trap/priority']),
        mutant('mmio_barrier_not_saved', PIPE,
               'exmem_next.mem_order_barrier=ENABLE_MMIO && ex_is_mem && ram_ex_out_of_range;',
               "exmem_next.mem_order_barrier=1'b0;", 'MMIO request presentation timeout'),
        mutant('mmio_class_not_saved', PIPE,
               "exmem_next.mem_class=(ENABLE_MMIO && ex_is_mem && ram_ex_out_of_range)?3'd1:3'd0;",
               "exmem_next.mem_class=3'd0;", 'MMIO first presentation lacks oldest MEM authorization'),
        mutant('owner_orders_only_local_io', 'rtl/cpu5_ram_owner.v',
               'wire issue_io=ENABLE_MMIO && (issue_first<RAM_BEGIN || issue_last>=RAM_END);',
               "wire issue_io=ENABLE_MMIO && (issue_addr>=32'h20000000 && issue_addr<32'h20000100);",
               'MMIO owner lost irrevocable lock'),
        mutant('io_read_has_no_irrevocable_lock', 'rtl/cpu5_ram_owner.v',
               'assign store_lock=owner_valid && (is_store_q || is_io_q);',
               'assign store_lock=owner_valid && is_store_q;', ['MMIO owner lost irrevocable lock', 'MMIO irrevocable flush was accepted']),
        mutant('completed_io_unlocks_before_retire', 'rtl/cpu5_ram_owner.v',
               'assign store_lock=owner_valid && (is_store_q || is_io_q);',
               'assign store_lock=owner_valid && (is_store_q || is_io_q) && state_q!=COMPLETE;',
               'MMIO owner lost irrevocable lock'),
        mutant('io_read_reuses_ram_turnover', 'rtl/cpu5_ram_owner.v',
               '!is_io_q && !result_error && !effective_killed && completion_ready;',
               '!result_error && !effective_killed && completion_ready;',
               ['CPU5 ordered I/O used RAM load turnover', 'MMIO IO-to-RAM turnover occurred']),
        mutant('cached_io_response_value_corrupted', 'rtl/cpu5_ram_owner.v',
               'assign completion_rdata=state_q==COMPLETE?rdata_q:dmem_rsp_rdata;',
               "assign completion_rdata=state_q==COMPLETE?(rdata_q ^ (is_io_q?32'd1:32'd0)):dmem_rsp_rdata;",
               'MMIO retirement payload'),
        mutant('completed_io_request_replayed', 'rtl/cpu5_ram_owner.v',
               '((state_q==PRESENTED) || new_request);',
               '((state_q==PRESENTED) || (state_q==COMPLETE && is_io_q) || new_request);',
               ['MMIO unexpected/younger D request', 'MMIO multiple D owners']),
    ]


def parameter_specimens():
    return [dict(name=name, kind='parameter_guard', changed_file=TB, old=old, new=new,
                 expected_assertion=['CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode', 'CPU5 ordered D owner requires boolean MMIO and a valid RAM range'])
            for name, old, new in [
                ('mmio_boolean_guard', '.ENABLE_MMIO(1)', '.ENABLE_MMIO(2)'),
                ('mmio_requires_ram_guard', '.ENABLE_RAM(1)', '.ENABLE_RAM(0)'),
                ('ram_local_page_overlap_guard', '.DMEM_WORDS(8)', ".DMEM_BASE_ADDR(32'h20000000),.DMEM_WORDS(8)"),
            ]]


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
    (directory / 'build/cpu5_s10_mmio_control').mkdir(parents=True)
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
