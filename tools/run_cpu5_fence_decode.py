"""Real-core FENCE field matrix with separate private compile/simulation evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/cpu5_s12_fence_decode'
CORE = 'rtl/cpu5_alu_pipeline.v'
TB = 'tb/cpu5_fence_decode_tb.v'
RTL = ['rtl/alu.v', 'rtl/regfile.v', 'rtl/cpu5_alu_decode.v', 'rtl/cpu5_branch_unit.v',
       'rtl/cpu5_hazard.v', 'rtl/cpu5_ram_unit.v', 'rtl/cpu5_ram_owner.v',
       'rtl/cpu5_csr_unit.v', 'rtl/cpu5_irq_ctrl.v', 'rtl/rv32m_unit.v',
       'rtl/cpu5_m_owner.v', CORE]
COMPILE_SOURCES = RTL + ['rtl/cpu5_pipeline_types.vh', TB]
SOURCES = COMPILE_SOURCES + ['run_cpu5_fence_decode.do', 'tools/run_cpu5_fence_decode.py']
BAD_DIAGNOSTIC = re.compile(r'\*\*\s+(?:Warning|Error):|^Traceback \(', re.MULTILINE)
COMPILED = 'CPU5 FENCE DECODE CLEAN COMPILE PASS'
PASSED = 'CPU5 FENCE DECODE REFERENCE PASS'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def specimens():
    # Filled with unique exact anchors against the submitted S12 implementation.
    # These modify private RTL, and each must pass a separate clean compile
    # before the independent instruction-stream oracle rejects its semantics.
    def m(name, old, new, token):
        return dict(name=name, old=old, new=new, expected_assertion=token)
    return [
        m('reject_nonzero_fm', "in_instr[14:12]==0;", "in_instr[14:12]==0 && in_instr[31:28]==0;", 'FENCE decode oracle precise exception'),
        m('reject_zero_pred', "in_instr[14:12]==0;", "in_instr[14:12]==0 && in_instr[27:24]!=0;", 'FENCE decode oracle precise exception'),
        m('reject_zero_succ', "in_instr[14:12]==0;", "in_instr[14:12]==0 && in_instr[23:20]!=0;", 'FENCE decode oracle precise exception'),
        m('accept_fence_i', "in_instr[14:12]==0;", "in_instr[14:12]<=1;", ['FENCE decode oracle unsupported instruction retired', 'FENCE decode oracle retirement architectural stream']),
        m('ignore_feature_switch', "wire id_fence=ENABLE_FENCE &&", "wire id_fence=1'b1 &&", 'FENCE decode oracle unsupported instruction retired'),
        m('fence_nonzero_result', '(ex_is_mem||idex_q.is_mret||idex_q.is_fence)?32\'d0:', '(ex_is_mem||idex_q.is_mret)?32\'d0:idex_q.is_fence?32\'d1:', ['CPU5 FENCE retired before data drain or wrote a register', 'FENCE decode oracle retirement architectural stream']),
    ]


def process(vsim, path, script, name):
    p = subprocess.run([str(vsim), '-c', '-do', script], cwd=path, capture_output=True,
                       text=True, encoding='utf-8', errors='replace', timeout=240)
    output = p.stdout + p.stderr
    log = path / (name + '_console.log')
    log.write_text(output, encoding='utf-8', newline='')
    return p.returncode, output, log


def verify(vsim, path, spec, originals):
    path.mkdir(parents=True)
    for rel in COMPILE_SOURCES:
        target = path / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(originals[rel])
    (path / 'build/cpu5_s12_fence_decode').mkdir(parents=True)
    change = None
    if spec:
        target = path / CORE
        source = target.read_text(encoding='utf-8')
        assert source.count(spec['old']) == 1, (spec['name'], source.count(spec['old']))
        target.write_text(source.replace(spec['old'], spec['new']), encoding='utf-8', newline='\n')
        change = dict(path=CORE, good_sha256=hashlib.sha256(originals[CORE]).hexdigest(),
                      bad_sha256=sha(target), old=spec['old'], new=spec['new'])
        assert change['good_sha256'] != change['bad_sha256']
    (path / 'compile.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file compile_transcript.log',
        'vmap -c', 'vlib work', 'vmap fence_decode_work work',
        'vlog -sv +incdir+. -work fence_decode_work ' + ' '.join(RTL + [TB]),
        f'echo "{COMPILED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    (path / 'simulate.do').write_text('\n'.join([
        'onerror {quit -code 1 -f}', 'transcript file simulation_transcript.log',
        'vmap fence_decode_work work',
        'vsim -voptargs="+acc" -onfinish stop -wlf fence_decode.wlf fence_decode_work.cpu5_fence_decode_tb',
        'log -r sim:/*', 'run -all',
        'if {[examine -radix unsigned sim:/cpu5_fence_decode_tb/test_pass] != 1} {quit -code 1 -f}',
        f'echo "{PASSED}"', 'quit -code 0 -f', '',
    ]), encoding='utf-8')
    code, output, compile_log = process(vsim, path, 'compile.do', 'compile')
    assert code == 0 and COMPILED in output and not BAD_DIAGNOSTIC.search(output), (path.name, output[-6000:])
    compile_record = dict(status='PASS', exit_code=code, warnings=0, errors=0,
                          console_sha256=sha(compile_log))
    code, output, simulation_log = process(vsim, path, 'simulate.do', 'simulation')
    assert not BAD_DIAGNOSTIC.search(output), (path.name, output[-6000:])
    actual = next((line.strip() for line in output.splitlines() if '** Fatal:' in line), None)
    if spec:
        tokens = spec['expected_assertion'] if isinstance(spec['expected_assertion'], list) else [spec['expected_assertion']]
        assert code != 0 and actual and any(token in actual for token in tokens), (path.name, code, spec, output[-7000:])
        status = 'REJECTED'
    else:
        assert code == 0 and PASSED in output and not actual, (path.name, code, output[-7000:])
        status = 'PASS'
    artifacts = {p.relative_to(path).as_posix(): sha(p) for p in path.rglob('*')
                 if p.is_file() and p.suffix in ('.do', '.log', '.wlf', '.csv', '.json', '.ini')}
    record = dict(name=path.name, kind='rtl_semantic' if spec else 'good_reference', status=status,
                  directory=path.relative_to(ROOT).as_posix(), compile=compile_record,
                  simulation_exit_code=code, simulation_console_sha256=sha(simulation_log),
                  expected_assertion=spec['expected_assertion'] if spec else None,
                  actual_assertion=actual, changed_source=change,
                  source_sha256={p: sha(path / p) for p in COMPILE_SOURCES},
                  retained_artifact_sha256=artifacts)
    if not spec:
        summaries = [json.loads((path / f'build/cpu5_s12_fence_decode/case{i}_summary.json').read_text()) for i in range(5)]
        for i, summary in enumerate(summaries):
            assert summary['status'] == 'PASS' and summary['case'] == i
            assert summary['wb'] == summary['retired']
            if i < 4:
                assert summary['matrix_fences'] == 4096 and summary['fences'] == 4143
                assert summary['retired'] == 4174 and summary['traps'] == 8 and summary['accepted'] == 4182
                assert summary['unknown_operand_edges'] >= 4096 and summary['producer_alias_edges'] >= 16
            else:
                assert summary['retired'] == 0 and summary['traps'] == summary['accepted'] == 24
        record['summaries'] = summaries
    (path / 'result.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print(path.name, status, flush=True)
    return record


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vsim', type=Path, default=Path(r'D:\modeltech64_10.6e\win64\vsim.exe'))
    ap.add_argument('--reference-only', action='store_true', help='Run only the complete positive field matrix.')
    a = ap.parse_args()
    originals = {p: (ROOT / p).read_bytes() for p in SOURCES}
    before = {p: hashlib.sha256(data).hexdigest() for p, data in originals.items()}
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ_') + uuid.uuid4().hex[:8]
    run = OUT / 'runs' / run_id
    run.mkdir(parents=True)
    (OUT / 'verification.json').write_text(json.dumps(dict(status='RUNNING', run_id=run_id), indent=2) + '\n', encoding='utf-8')
    positive = verify(a.vsim, run / 'good_reference', None, originals)
    records = [] if a.reference_only else [verify(a.vsim, run / s['name'], s, originals) for s in specimens()]
    assert before == {p: sha(ROOT / p) for p in SOURCES}, 'FENCE decode verification changed source'
    result = dict(status='PASS', run_id=run_id, source_sha256=before, sources_unchanged=True,
                  positive=positive, specimens=records, rtl_mutations_rejected=len(records),
                  parameter_guards_rejected=0, compile_zero_warning_error=True)
    rendered = json.dumps(result, indent=2) + '\n'
    (run / 'verification.json').write_text(rendered, encoding='utf-8')
    (OUT / 'verification.json').write_text(rendered, encoding='utf-8')
    print(json.dumps(dict(status='PASS', summaries=positive['summaries'], rtl_mutations_rejected=len(records))))


if __name__ == '__main__':
    main()
