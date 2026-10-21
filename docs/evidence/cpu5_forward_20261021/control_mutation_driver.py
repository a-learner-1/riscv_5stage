from pathlib import Path
import csv, hashlib, json, shutil, subprocess

BASE=Path(__file__).resolve().parent
GOOD=BASE/'control_work'
W=BASE/'work'
OUT=BASE/'control_mutations'
VSIM=Path(r'D:\modeltech64_10.6e\win64\vsim.exe')
FILES=['rtl/alu.v','rtl/regfile.v','rtl/cpu5_hazard.v','rtl/cpu5_alu_decode.v',
       'rtl/cpu5_alu_pipeline.v','rtl/cpu5_pipeline_types.vh',
       'tb/cpu5_forward_control_tb.v','run_cpu5_forward_control.do']

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def replace_once(text,old,new):
    assert text.count(old)==1, (old,text.count(old))
    return text.replace(old,new)

core=(GOOD/'rtl/cpu5_alu_pipeline.v').read_text()
hazard=(GOOD/'rtl/cpu5_hazard.v').read_text()
mutations=[]
mutations.append(('no_wb_to_id','rtl/cpu5_alu_pipeline.v',replace_once(core,
    'idex_next.rs1_value=id_saved_rs1;idex_next.rs2_value=id_saved_rs2;',
    'idex_next.rs1_value=rf1;idex_next.rs2_value=rf2;'),
    'MEM identity/value mismatch case=1 index=3'))
held='else if(ENABLE_FORWARDING && idex_valid_q && !kill_ex)begin'
mutations.append(('no_held_ex_capture','rtl/cpu5_alu_pipeline.v',replace_once(core,held,
    "else if(1'b0)begin"),'EX held operand was not retained across producer drain'))
mutations.append(('capture_only_if_all_sources_ready','rtl/cpu5_alu_pipeline.v',replace_once(core,held,
    'else if(ENABLE_FORWARDING && idex_valid_q && !kill_ex && !ex_source_stall)begin'),
    "resolved second source vanished during a different source's stall"))
mutations.append(('wb_ready_used_as_data_ready','rtl/cpu5_alu_pipeline.v',replace_once(core,
    ".wb_result_ready(1'b1)",'.wb_result_ready(wb_ready)'),
    'WB backpressure hid valid producer data'))
mem_condition="""else if (mem_is_valid && mem_does_write && mem_destination != 5'd0 &&
                             mem_destination == source) begin"""
mutations.append(('unready_mem_falls_back_to_wb','rtl/cpu5_hazard.v',replace_once(hazard,
    mem_condition,"""else if (mem_is_valid && mem_does_write && mem_destination != 5'd0 &&
                             mem_destination == source && mem_is_ready) begin"""),
    'unready latest MEM was bypassed or retired case=8'))
mem_body="""else if (mem_is_valid && mem_does_write && mem_destination != 5'd0 &&
                             mem_destination == source) begin
                    if (mem_is_ready)
                        select_source = {1'b0, 1'b0, FWD_MEM, mem_value};
                    else
                        select_source = {1'b1, 1'b0, FWD_BLOCK, 32'd0};
                end else if (wb_is_valid && wb_does_write && wb_destination != 5'd0 &&
                             wb_destination == source) begin
                    if (wb_is_ready)
                        select_source = {1'b0, 1'b0, FWD_WB, wb_value};
                    else
                        select_source = {1'b1, 1'b0, FWD_BLOCK, 32'd0};
                end"""
wb_body="""else if (wb_is_valid && wb_does_write && wb_destination != 5'd0 &&
                             wb_destination == source) begin
                    if (wb_is_ready)
                        select_source = {1'b0, 1'b0, FWD_WB, wb_value};
                    else
                        select_source = {1'b1, 1'b0, FWD_BLOCK, 32'd0};
                end else if (mem_is_valid && mem_does_write && mem_destination != 5'd0 &&
                             mem_destination == source) begin
                    if (mem_is_ready)
                        select_source = {1'b0, 1'b0, FWD_MEM, mem_value};
                    else
                        select_source = {1'b1, 1'b0, FWD_BLOCK, 32'd0};
                end"""
mutations.append(('wb_wins_over_newer_mem','rtl/cpu5_hazard.v',replace_once(hazard,mem_body,wb_body),
    'newest MEM did not beat matching old WB'))
mutations.append(('capture_rs1_only_if_all_sources_ready','rtl/cpu5_alu_pipeline.v',replace_once(core,
    'if(idex_q.uses_rs1 && !ex_stall1)idex_q.rs1_value<=ex_rs1_value;',
    'if(idex_q.uses_rs1 && !ex_source_stall)idex_q.rs1_value<=ex_rs1_value;'),
    "resolved first source vanished during a different source's stall"))

results=[]
for name,changed,source,expected in mutations:
    root=OUT/name
    for filename in FILES:
        dst=root/filename;dst.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(GOOD/filename,dst)
    (root/changed).write_text(source,newline='\n')
    (root/'build/cpu5_s3_control').mkdir(parents=True,exist_ok=True)
    run=subprocess.run([str(VSIM),'-c','-do','run_cpu5_forward_control.do','-l','build/cpu5_s3_control/process.log'],
        cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
    (root/'runner.log').write_text(run.stdout,newline='\n')
    passed=(run.returncode==1 and expected in run.stdout and
            'CPU5_FORWARD_CONTROL_PASS cases=' not in run.stdout and
            '# Errors: 0, Warnings: 0' in run.stdout)
    result={'name':name,'changed_file':changed,'changed_sha256':sha(root/changed),
            'exit_code':run.returncode,'expected_assertion':expected,
            'expected_assertion_seen':expected in run.stdout,
            'overall_pass_marker_seen':'CPU5_FORWARD_CONTROL_PASS cases=' in run.stdout,
            'compile_errors_zero':'# Errors: 0, Warnings: 0' in run.stdout,
            'rejected_as_expected':passed,'log':str(root/'runner.log')}
    results.append(result)
    print(name,passed,flush=True)

assert all(r['rejected_as_expected'] for r in results),results

with (GOOD/'build/cpu5_s3_control/coverage.csv').open(newline='') as f:
    rows=list(csv.DictReader(f))
assert len(rows)==1
coverage={k:int(v) for k,v in rows[0].items()}
assert coverage['retire']==44 and coverage['wb_consume']==44 and coverage['physical_writes']==43 and coverage['id_accept']==46
for filename in FILES: assert sha(GOOD/filename)==sha(W/filename), filename
record={'scope':'CPU5 3A-2 directed forwarding controls; forced unready ALU is not LOAD execution',
        'positive':{'exit_code':0,'coverage':coverage,'compile_errors':0,'compile_warnings':0,
            'source_sha256':{f:sha(GOOD/f) for f in FILES},
            'main_isolated_source_sha256':{f:sha(W/f) for f in FILES},
            'source_bytes_match_main':True,'trace_sha256':sha(GOOD/'build/cpu5_s3_control/control_trace.csv'),
            'transcript_sha256':sha(GOOD/'build/cpu5_s3_control/transcript.log'),
            'process_sha256':sha(GOOD/'build/cpu5_s3_control/process.log')},
        'negative_rtl':results,'negative_passed':len(results)}
(GOOD/'build/cpu5_s3_control/verification.json').write_text(json.dumps(record,indent=2,ensure_ascii=False)+'\n',encoding='utf-8',newline='\n')
print(json.dumps({'coverage':coverage,'negative_passed':len(results)}),flush=True)
