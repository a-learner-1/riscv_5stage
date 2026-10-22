from pathlib import Path
import hashlib,json,subprocess
P=Path(__file__).resolve().parent
W=P/'work'
ROOT=P/'ram_unit_mutants'
BASE=(W/'rtl/cpu5_ram_unit.v').read_text(encoding='utf-8')
MUTATIONS={
    'i_immediate_zero_extend':("is_load?{{20{instr[31]}},instr[31:20]}","is_load?{20'd0,instr[31:20]}"),
    'accept_illegal_load_f3':('load_opcode && (funct3==0 || funct3==1 || funct3==2 || funct3==4 || funct3==5)','load_opcode'),
    'range_end_wrap32':('localparam [63:0] RAM_END=','localparam [31:0] RAM_END='),
    'no_load_byte_shift':('wire [31:0] shifted=response_word>>shift_bits;','wire [31:0] shifted=response_word;'),
    'store_uses_unshifted_data':('assign wdata=is_store?(rs2_value<<shift_bits):32\'d0;',"assign wdata=is_store?rs2_value:32'd0;"),
    'range_checks_first_only':('last_byte>=RAM_END','first_byte>=RAM_END'),
}
results=[]
for name,(old,new) in MUTATIONS.items():
    assert BASE.count(old)==1,(name,BASE.count(old))
    d=ROOT/name
    (d/'rtl').mkdir(parents=True,exist_ok=True)
    (d/'tb').mkdir(exist_ok=True)
    (d/'build/cpu5_s5_ram_unit').mkdir(parents=True,exist_ok=True)
    source=BASE.replace(old,new)
    (d/'rtl/cpu5_ram_unit.v').write_text(source,encoding='utf-8',newline='\n')
    for file in ['tb/cpu5_ram_unit_tb.v','run_cpu5_ram_unit.do']:
        (d/file).write_bytes((W/file).read_bytes())
    p=subprocess.run([r'D:\modeltech64_10.6e\win64\vsim.exe','-c','-do','run_cpu5_ram_unit.do','-l','build/cpu5_s5_ram_unit/process.log'],cwd=d,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    (d/'console.log').write_text(p.stdout,encoding='utf-8')
    fatals=[line for line in p.stdout.splitlines() if 'Fatal:' in line]
    r={'name':name,'exit_code':p.returncode,'rejected':p.returncode!=0 and bool(fatals),'fatal':fatals[:1],'mutant_sha256':hashlib.sha256(source.encode()).hexdigest()}
    results.append(r)
    print(json.dumps(r))
summary={'good_source_sha256':hashlib.sha256((W/'rtl/cpu5_ram_unit.v').read_bytes()).hexdigest(),'mutants':results,'all_rejected':all(x['rejected'] for x in results)}
(ROOT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
if not summary['all_rejected']:raise SystemExit(1)
