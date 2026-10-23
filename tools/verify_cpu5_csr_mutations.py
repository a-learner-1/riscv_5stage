"""Reject real CPU5 CSR/MRET RTL mutants after independent clean compilation.

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
OUT = ROOT / 'build/cpu5_s7_csr_mutations'
PIPE = 'rtl/cpu5_alu_pipeline.v'
BANK = 'rtl/cpu5_csr_unit.v'
TB = 'tb/cpu5_csr_control_tb.v'
TOP = 'cpu5_csr_control_tb'
LIB = 'cpu5_csr_mutation_work'
RTL = [
    'rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v',
    'rtl/cpu5_branch_unit.v', 'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v',
    'rtl/cpu5_ram_owner.v', BANK, PIPE,
]
SOURCES = RTL + ['rtl/cpu5_pipeline_types.vh', TB,
                 'run_cpu5_csr_control.do', 'tools/verify_cpu5_csr_mutations.py']
DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILE_MARKER = 'CPU5 CSR MUTATION CLEAN COMPILE PASS'
SIM_MARKER = 'CPU5 CSR MUTATION REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutant(name, rel, old, new, expected_assertion):
    return dict(name=name, kind='rtl_semantic', changed_file=rel, old=old,
                new=new, expected_assertion=expected_assertion)


def specimens():
    """Each edit changes synthesizable behavior; no test assertion is edited."""
    return [
        mutant('csr_write_before_retirement', PIPE,
               'assign csr_commit_fire=ENABLE_CSR && retire_fire && exmem_q.is_csr;',
               'assign csr_commit_fire=ENABLE_CSR && rst_n && exmem_valid_q && exmem_q.is_csr;',
               'CPU5 CSR/MRET lacks normal oldest MEM retirement'),
        mutant('mstatus_warl_unmasked', BANK,
               "12'h300:csr_mstatus<=32'h00001800|(write_value&32'h88);",
               "12'h300:csr_mstatus<=32'h00001800|write_value;",
               'CSR committed state'),
        mutant('mtvec_warl_mode_retained', BANK,
               "12'h305:csr_mtvec<={write_value[31:2],2'b00};",
               "12'h305:csr_mtvec<=write_value;",
               'CSR committed state'),
        mutant('mepc_warl_unaligned', BANK,
               "12'h341:csr_mepc<={write_value[31:2],2'b00};",
               "12'h341:csr_mepc<=write_value;",
               'CSR committed state'),
        mutant('register_zero_suppresses_write_intent', PIPE,
               'exmem_next.csr_write_intent=idex_q.csr_write_intent;',
               'exmem_next.csr_write_intent=idex_q.funct3[2]?idex_q.csr_write_intent:'
               "((idex_q.instr[13:12]==2'b01)||(ex_rs1_value!=0));",
               'CSR killed/fault token retired'),
        mutant('csr_return_uses_stale_wb', PIPE,
               'assign mem_result_value=ENABLE_CSR && exmem_q.is_csr?csr_read_value:',
               'assign mem_result_value=ENABLE_CSR && exmem_q.is_csr?memwb_q.result:',
               'CSR retirement payload'),
        mutant('trap_ignores_committed_mtvec', PIPE,
               'wire [31:0] trap_target=ENABLE_CSR?csr_mtvec_value:TRAP_VECTOR;',
               'wire [31:0] trap_target=TRAP_VECTOR;',
               'CSR precise trap/priority'),
        mutant('mret_does_not_restore_mstatus', BANK,
               "csr_mstatus<=32'h00001880|(csr_mstatus[7]?32'h8:32'd0);",
               'csr_mstatus<=csr_mstatus;',
               'CSR committed state'),
        mutant('mret_redirects_to_fallthrough', PIPE,
               'mret_fire?csr_mepc_value:ex_redirect?',
               "mret_fire?(exmem_q.pc+32'd4):ex_redirect?",
               'CSR MRET MEM authorization/priority'),
        mutant('mret_allows_younger_ex', PIPE,
               '&& !trap_fire && !mret_fire && ex_enable && mem_can_load',
               '&& !trap_fire && ex_enable && mem_can_load',
               'CPU5 MRET leaked younger action or BP commit'),
        mutant('trap_drops_retired_old_wb', PIPE,
               'assign wb_we=wb_fire && memwb_q.writes_rd && memwb_q.rd!=0;',
               'assign wb_we=wb_fire && memwb_q.writes_rd && memwb_q.rd!=0 && !trap_fire;',
               'CSR WB stream'),
        mutant('unknown_csr_reads_as_zero', BANK,
               "default:known=1'b0;", "default:known=1'b1;",
               'CSR killed/fault token retired'),
        mutant('readonly_csr_accepts_write_intent', BANK,
               'assign access_illegal=!known || (read_only && access_write_intent);',
               'assign access_illegal=!known;',
               'CSR killed/fault token retired'),
        mutant('csr_decode_overrides_fetch_error', PIPE,
               'exmem_q.is_csr && !exmem_q.exception_valid && csr_access_illegal;',
               'exmem_q.is_csr && csr_access_illegal;',
               'CSR precise trap/priority'),
    ]


def parameter_specimens():
    return [dict(name=name, kind='parameter_guard', changed_file=TB,
                 old=old, new=new,
                 expected_assertion='CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode')
            for name, old, new in [
                ('invalid_csr_boolean', '.ENABLE_CSR(1)', '.ENABLE_CSR(2)'),
                ('csr_without_sync_traps', '.ENABLE_SYNC_TRAPS(1)', '.ENABLE_SYNC_TRAPS(0)'),
                ('csr_without_control_flow', '.ENABLE_CONTROL_FLOW(1)', '.ENABLE_CONTROL_FLOW(0)'),
                ('unaligned_reset_vector', '.TRAP_VECTOR(VECTOR)', ".TRAP_VECTOR(32'h00000101)"),
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
    (directory / 'build/cpu5_s7_csr_control').mkdir(parents=True)
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
