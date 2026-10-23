import hashlib,json,re,shutil,subprocess
from pathlib import Path
P=Path(__file__).resolve().parent; S=P/'control_work'; O=P/'trap_parameters'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
identity=json.loads((P/'control_result.json').read_text())['source_sha256']
checks=[('invalid_enable','.ENABLE_SYNC_TRAPS(1)','.ENABLE_SYNC_TRAPS(2)'),
        ('misaligned_vector','.TRAP_VECTOR(VECTOR)',".TRAP_VECTOR(32'h102)")]
rows=[]
for name,old,new in checks:
    d=O/name;d.mkdir(parents=True,exist_ok=True)
    for rel,h in identity.items():
        assert sha(S/rel)==h
        q=d/rel;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(S/rel,q)
    p=d/'tb/cpu5_trap_control_tb.v';t=p.read_text();assert t.count(old)==1
    p.write_text(t.replace(old,new),encoding='utf-8',newline='\n')
    r=subprocess.run([r'D:\modeltech64_10.6e\win64\vsim.exe','-c','-do','run_cpu5_trap_control.do'],cwd=d,capture_output=True,text=True,timeout=60)
    log=r.stdout+r.stderr;(d/'process.log').write_text(log,encoding='utf-8',newline='\n')
    target='CPU5 ALU requires 64-bit age, positive epoch and supported forwarding mode'
    fatal=re.search(r'# \*\* Fatal: ([^\r\n]+)',log)
    rejected=r.returncode!=0 and 'Errors: 0, Warnings: 0' in log and '** Warning:' not in log and fatal is not None and fatal.group(1)==target and re.search(r'Time: 0 ps',log) is not None
    rows.append(dict(name=name,rejected=rejected,exit_code=r.returncode,
        source_sha256={rel:sha(d/rel) for rel in identity},bad_tb_sha256=sha(p),
        original_tb_sha256=identity['tb/cpu5_trap_control_tb.v'],old=old,new=new,
        failure=fatal.group(1) if fatal else None,time_zero=bool(re.search(r'Time: 0 ps',log)),process_sha256=sha(d/'process.log')))
result=dict(pass_=all(x['rejected'] for x in rows),parameter_rejections=len(rows),
            functional_mutants_included=False,checks=rows)
(O/'summary.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2));assert result['pass_']
