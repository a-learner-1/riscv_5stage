"""Exercise actual mutated RAM pipeline RTL in isolated ModelSim projects.

No RTL/test file in work is changed. Each simulation compiles source afresh;
a mutant counts only after zero-warning compilation and a designated runtime
failure. Baseline RTL/test digests bind the resulting evidence.
"""
import hashlib,json,pathlib,re,shutil,subprocess,sys

BASE=pathlib.Path(__file__).resolve().parent
WORK=BASE/'work'
ROOT=BASE/'ram_core_mutants'
SIM=r'D:\modeltech64_10.6e\win64\vsim.exe'
PIPE='rtl/cpu5_alu_pipeline.v'
FILES=[*map(lambda p:p.as_posix(),[p.relative_to(WORK) for p in (WORK/'rtl').glob('*') if p.is_file()]),
       'tb/cpu5_ram_control_tb.v','tb/cpu5_ram_top_tb.v',
       'run_cpu5_ram_control.do','run_cpu5_ram_top.do',
       'tools/generate_cpu5_ram_vectors.py','software/cpu5_ram/start.S',
       'software/cpu5_ram/main.c','software/cpu5_ram/link.ld','programs/data_handshake_blank.hex']

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def clone(target):
    for name in FILES:
        dst=target/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(WORK/name,dst)
    for name in ['build/cpu5_s5_ram','build/cpu5_s5_ram_control']:(target/name).mkdir(parents=True,exist_ok=True)
def simulate(target,suite):
    process=subprocess.run([SIM,'-c','-do',f'run_cpu5_ram_{suite}.do','-l','process.log'],
                           cwd=target,capture_output=True,text=True,timeout=90)
    out=process.stdout+process.stderr
    (target/'output.log').write_text(out,newline='\n')
    first_fatal=re.search(r'# \*\* Fatal: ([^\n]+)',out)
    return process.returncode,out,first_fatal.group(1) if first_fatal else None

MUTANTS=[
 dict(name='load_value_is_address',suite='control',replacements=[
      (PIPE,'assign mem_result_value=exmem_q.is_load?ram_load_value:',
            'assign mem_result_value=exmem_q.is_load?exmem_q.mem_addr:')],
      expect='RAM retirement stream'),
 dict(name='load_forward_uses_zero',suite='control',replacements=[
      (PIPE,'.mem_result_value(mem_result_value),','.mem_result_value(exmem_q.is_load?32\'d0:mem_result_value),')],
      expect='RAM retirement stream',count=2),
 dict(name='store_lane_data_unshifted',suite='top',replacements=[
      (PIPE,'.issue_wdata(mem_store_request?exmem_q.mem_wdata:ram_ex_wdata),',
            '.issue_wdata(mem_store_request?exmem_q.store_raw:ram_ex_wdata),')],
      expect='D store byte mismatch'),
 dict(name='load_format_uses_new_ex_addr',suite='top',replacements=[
      (PIPE,'.rs1_value(exmem_q.mem_addr),.rs2_value(32\'d0),.response_word(ram_completion_data),',
            '.rs1_value(ram_ex_addr),.rs2_value(32\'d0),.response_word(ram_completion_data),')],
      expect='Pre-MEM golden mismatch'),
 dict(name='store_flush_lock_removed',suite='control',replacements=[
      (PIPE,'assign flush_ready=!ENABLE_RAM || !flush_valid ||\n        !(ram_store_lock && flush_cut_seq<=ram_owner_seq);',
            'assign flush_ready=1\'b1;')],
      expect='irrevocable STORE flush accepted early'),
 dict(name='error_response_retires',suite='control',replacements=[
      (PIPE,'wire ram_mem_error=ram_mem_matches && (exmem_q.is_load||exmem_q.is_store) && ram_completion_error;',
            'wire ram_mem_error=1\'b0;'),
      (PIPE,'(ram_mem_matches && !ram_completion_error):exmem_q.result_ready;',
            '(ram_mem_matches):exmem_q.result_ready;')],
      expect='older LOAD error lost same-edge priority'),
 dict(name='load_owner_not_killed_by_flush',suite='control',replacements=[
      (PIPE,'.kill_valid(flush_fire),.kill_cut_seq(flush_cut_seq),',
            '.kill_valid(1\'b0),.kill_cut_seq(flush_cut_seq),')],
      expect='RAM drain'),
 dict(name='fetch_epoch_kills_data_owner',suite='control',replacements=[
      (PIPE,'.kill_valid(flush_fire),.kill_cut_seq(flush_cut_seq),',
            '.kill_valid(flush_fire || (ram_owner_valid && !ram_owner_store && cf_supported && in_epoch==8\'hff && in_epoch!=ram_completion_epoch)),\n            .kill_cut_seq(flush_fire?flush_cut_seq:ram_owner_seq),')],
      expect='fetch epoch killed older LOAD owner'),
 dict(name='load_fault_gate_removed',suite='control',replacements=[
      (PIPE,'wire ex_load_request=ENABLE_RAM && idex_q.is_load && !idex_q.exception_valid && !ex_ram_fault && ex_base_move;',
            'wire ex_load_request=ENABLE_RAM && idex_q.is_load && !idex_q.exception_valid && ex_base_move;')],
      expect='CPU5 LOAD issue lacks live advancing EX owner'),
 dict(name='store_issue_ignores_mem_enable',suite='control',replacements=[
      (PIPE,'mem_enable && !flush_valid && !halted && !ram_mem_owned;',
            '!flush_valid && !halted && !ram_mem_owned;')],
      expect='STORE presented before MEM authorization'),
]

ROOT.mkdir(parents=True,exist_ok=True)
resume='--resume' in sys.argv
cached=json.loads((ROOT/'summary.json').read_text()) if resume and (ROOT/'summary.json').exists() else {}
baseline=ROOT/'baseline'
manifest={name:digest(WORK/name) for name in FILES}
baseline_cached=resume and cached.get('source_manifest')==manifest and all(
    (baseline/name).exists() and digest(baseline/name)==manifest[name] for name in FILES)
if not baseline_cached:clone(baseline)
(ROOT/'source_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
results=[]
if baseline_cached:
    baseline_output=(baseline/'output.log').read_text()
    baseline_exit=cached.get('baseline_control_exit')
else:baseline_exit,baseline_output,baseline_fatal=simulate(baseline,'control')
assert baseline_exit==0 and 'CPU5 RAM CONTROL DIRECTED TEST PASS' in baseline_output,(baseline_exit,baseline_output)
print('baseline control PASS',flush=True)
for mutant in MUTANTS:
    target=ROOT/mutant['name']
    changed={}
    for name,old,new in mutant['replacements']:
        source=changed.get(name,(WORK/name).read_text())
        count=mutant.get('count',1)
        assert source.count(old)==count,(mutant['name'],source.count(old),count)
        changed[name]=source.replace(old,new)
    changed_hash={name:hashlib.sha256(source.encode()).hexdigest() for name,source in changed.items()}
    candidate=next((r for r in cached.get('mutants',[]) if r.get('name')==mutant['name']),{})
    expected_hash={**manifest,**changed_hash}
    can_resume=resume and cached.get('source_manifest')==manifest and candidate.get('rejected') and \
        candidate.get('expected_failure')==mutant['expect'] and candidate.get('suite')==mutant['suite'] and \
        candidate.get('mutated_source_sha256')==changed_hash and all(
            (target/name).exists() and digest(target/name)==expected_hash[name] for name in FILES)
    if can_resume:
        cached_output=(target/'output.log').read_text()
        can_resume='Errors: 0, Warnings: 0' in cached_output and '# ** Warning:' not in cached_output and \
            candidate['actual_failure'] in cached_output and mutant['expect'].lower() in candidate['actual_failure'].lower()
    if can_resume:
        results.append(candidate)
        print(mutant['name'],'RESUMED verified source/log hashes',flush=True)
        continue
    clone(target)
    for name,source in changed.items():(target/name).write_text(source,newline='\n')
    code,out,fatal=simulate(target,mutant['suite'])
    compiled='Errors: 0, Warnings: 0' in out and '# ** Warning:' not in out
    rejected=code!=0 and fatal is not None and mutant['expect'].lower() in fatal.lower() and compiled
    row=dict(name=mutant['name'],suite=mutant['suite'],exit_code=code,compile_warnings=0 if compiled else None,
             expected_failure=mutant['expect'],actual_failure=fatal,rejected=rejected,
             mutated_source_sha256={n:digest(target/n) for n,_,_ in mutant['replacements']})
    results.append(row)
    (ROOT/'summary.json').write_text(json.dumps(dict(pass_all=all(r['rejected'] for r in results),
       source_manifest=manifest,baseline_control_exit=baseline_exit,mutants=results),indent=2)+'\n')
    print(mutant['name'],code,rejected,fatal,flush=True)
    if not rejected:
        print(out[-6000:]);sys.exit(1)
assert all(digest(WORK/name)==manifest[name] for name in FILES),'work source changed during mutation run'
print('ALL RAM CORE MUTANTS REJECTED',len(results),flush=True)
