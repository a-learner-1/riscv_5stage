import hashlib,json,re
from pathlib import Path
P=Path(__file__).resolve().parent
C=P/'control_work'; M=P/'control_mutants'; W=P/'work'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((M/'results.json').read_text())
assert len(r['mutants'])==15 and all(x['rejected'] for x in r['mutants'])
for rel,h in r['source_sha256'].items():
    assert sha(C/rel)==h,(rel,'positive source changed')
    assert sha(W/rel)==h,(rel,'W differs from positive tested source')
for row in r['mutants']:
    for rel,h in r['source_sha256'].items():
        expected=row['mutant_sha256'] if rel=='rtl/cpu5_alu_pipeline.v' else h
        assert sha(M/row['name']/rel)==expected,(row['name'],rel)
    log=(M/row['name']/'process.log').read_text()
    assert 'Errors: 0, Warnings: 0' in log and not re.search(r'\*\* Warning:',log)
    assert re.search(row['expected_failure'],row['failure'])
summaries=[json.loads((C/f'build/cpu5_s6_trap_control/mode{i}_summary.json').read_text()) for i in range(2)]
log=C/'build/cpu5_s6_trap_control/modelsim_transcript.log'
text=log.read_text();assert 'Errors: 0, Warnings: 0' in text and '** Warning:' not in text
assert 'CPU5 TRAP CONTROL DIRECTED TEST PASS' in text
e=dict(pass_=True,source_sha256=r['source_sha256'],modes=summaries,
       totals={k:sum(x[k] for x in summaries) for k in summaries[0] if k not in ('pass','mode')},
       rtl_mutants=len(r['mutants']),rejected_mutants=len(r['mutants']),
       positive_transcript_sha256=sha(log),mutants_result_sha256=sha(M/'results.json'),
       reproduction_script_sha256=sha(P/'run_control_mutants.py'),
       scope='Ordinary RAM; fixed-vector synchronous Trap; no CSR/MRET/IRQ or SoC integration')
(P/'control_result.json').write_text(json.dumps(e,indent=2),encoding='utf-8')
print(json.dumps(e,indent=2))
