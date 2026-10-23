import hashlib, json, re, shutil, subprocess, sys
from pathlib import Path

P = Path(__file__).resolve().parent
SRC = P / 'control_work'
OUT = P / 'control_mutants'
SIM = r'D:\modeltech64_10.6e\win64\vsim.exe'
RTL = 'rtl/cpu5_alu_pipeline.v'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

# Every mutation changes synthesizable implementation, not assertions or TB.
# A compile failure, warning, unrelated failure or successful mutant is rejected.
MUTANTS = [
 ('ecall_cause', 'id_ecall?32\'d11:id_ebreak?', 'id_ecall?32\'d8:id_ebreak?',
  'TRAP registered/persistent descriptor'),
 ('ebreak_tval', 'id_ebreak?in_pc:id_illegal?', 'id_ebreak?32\'d0:id_illegal?',
  'TRAP registered/persistent descriptor'),
 ('source_pc', 'trap_pc<=exmem_q.pc;', 'trap_pc<=exmem_q.pc+32\'d4;',
  'TRAP registered/persistent descriptor'),
 ('source_seq32', 'trap_seq<=exmem_q.seq;', 'trap_seq<={32\'d0,exmem_q.seq[31:0]};',
  'TRAP registered/persistent descriptor'),
 ('illegal_tval', 'id_illegal?in_instr:32\'d0;', 'id_illegal?32\'d0:32\'d0;',
  'TRAP registered/persistent descriptor'),
 ('mem_enable', 'mem_fault && mem_enable && trap_safe;', 'mem_fault && trap_safe;',
  'TRAP MEM enable ignored|CPU5 trap lacks live oldest MEM fault'),
 ('wb_space_dependency', 'mem_fault && mem_enable && trap_safe;', 'mem_fault && mem_enable && trap_safe && wb_can_load;',
  'TRAP event timeout mode=0 case=12'),
 ('consume_error', 'ram_mem_matches && (retire_fire || trap_fire);', 'ram_mem_matches && retire_fire;',
  'TRAP fault source completion not acknowledged'),
 ('vector', 'redirect_pc=trap_fire?TRAP_VECTOR:', 'redirect_pc=trap_fire?(TRAP_VECTOR+32\'d4):',
  'TRAP pre-edge owner/priority'),
 ('trap_instret', 'instret_count<=instret_count+64\'d1;', 'instret_count<=instret_count+64\'d1;',
  'TRAP instret/arch-next-PC mismatch'),
 ('descriptor_pulse', 'trap_valid<=trap_fire;', 'trap_valid<=trap_fire || trap_valid;',
  'TRAP registered event mismatch'),
 ('held_wb_kill', 'if(wb_can_load)begin\n                memwb_valid_q<=retire_fire;',
  'if(wb_can_load || trap_fire)begin\n                memwb_valid_q<=retire_fire;',
  'TRAP destroyed held retired WB token'),
 ('kill_young_ex', 'wire ex_can_load=!idex_valid_q || kill_ex || ex_move || trap_fire;',
  'wire ex_can_load=!idex_valid_q || kill_ex || ex_move;',
  'TRAP unexpected D request mode=1 case=10 seq=3 addr=00010004 wr=1'),
 ('trap_retire', "assign retire_fire=rst_n && exmem_valid_q && !kill_mem && !mem_fault &&\n        mem_result_ready && mem_enable && wb_can_load;",
  "assign retire_fire=trap_fire || (rst_n && exmem_valid_q && !kill_mem && !mem_fault &&\n        mem_result_ready && mem_enable && wb_can_load);",
  'CPU5 invalid retirement authorization|CPU5 synchronous trap leaked younger or fault-source action|TRAP pre-edge owner/priority'),
 ('handler_drain_block', 'wire ex_base_move=rst_n && idex_valid_q && !kill_ex && !trap_fire && ex_enable && mem_can_load &&',
  'wire ex_base_move=rst_n && idex_valid_q && !kill_ex && !trap_fire && ex_enable && mem_can_load && !(ram_owner_valid && ram_owner_killed && !idex_q.exception_valid) &&',
  'TRAP handler ALU could not progress during killed D drain'),
]

OUT.mkdir(exist_ok=True)
identity = {str(p.relative_to(SRC)).replace('\\','/'):sha(p) for p in
            sorted([*SRC.glob('rtl/*'), *SRC.glob('tb/*'), SRC/'run_cpu5_trap_control.do']) if p.is_file()}
selected=set(sys.argv[1:])
results=[]
if selected:
    prior=json.loads((OUT/'results.json').read_text(encoding='utf-8'))
    assert prior['source_sha256']==identity
    results=[r for r in prior['mutants'] if r['name'] not in selected]
for name, old, new, target in MUTANTS:
    if selected and name not in selected: continue
    dst = OUT/name
    dst.mkdir(exist_ok=True)
    for rel in identity:
        q=dst/rel;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(SRC/rel,q)
    p=dst/RTL; s=p.read_text(encoding='utf-8')
    if name=='trap_instret':
        old='trap_seq<=exmem_q.seq;arch_next_pc_q<=TRAP_VECTOR;'
        new='trap_seq<=exmem_q.seq;arch_next_pc_q<=TRAP_VECTOR;instret_count<=instret_count+64\'d1;'
    assert s.count(old)==1,(name,s.count(old))
    s=s.replace(old,new);p.write_text(s,encoding='utf-8',newline='\n')
    proc=subprocess.run([SIM,'-c','-do','run_cpu5_trap_control.do'],cwd=dst,
                        capture_output=True,text=True,timeout=60)
    log=proc.stdout+proc.stderr;(dst/'process.log').write_text(log,encoding='utf-8',newline='\n')
    failure=re.search(r'# \*\* Fatal: ([^\n\r]*)',log)
    target_ok=bool(failure and re.search(target,failure.group(1)))
    compiles=bool(re.search(r'Errors: 0, Warnings: 0',log))
    warnings=bool(re.search(r'\*\* Warning:',log))
    row=dict(name=name,expected_failure=target,exit_code=proc.returncode,
             rejected=proc.returncode!=0 and compiles and not warnings and target_ok,
             compile_pass=compiles,warnings=warnings,failure=failure.group(1) if failure else None,
             original_sha256=identity[RTL],mutant_sha256=sha(p),old=old,new=new)
    results.append(row)
    (OUT/'results.json').write_text(json.dumps(dict(source_sha256=identity,mutants=results),indent=2),encoding='utf-8')
    print(json.dumps(row),flush=True)
assert all(r['rejected'] for r in results), 'One or more semantic mutants survived or failed off target'
print('CPU5_TRAP_CONTROL_MUTANTS_PASS',len(results))
