from pathlib import Path
import json,subprocess
P=Path(__file__).resolve().parent
W=P/'work'
ROOT=P/'ram_unit_parameters'
results=[]
for name,base,words in [('zero_words','00010000',0),('negative_words','00010000',-1),('unaligned_base','00010001',4096),('end_above_2p32','fffffff0',5)]:
    d=ROOT/name
    (d/'rtl').mkdir(parents=True,exist_ok=True)
    (d/'tb').mkdir(exist_ok=True)
    (d/'build/cpu5_s5_ram_unit').mkdir(parents=True,exist_ok=True)
    (d/'rtl/cpu5_ram_unit.v').write_bytes((W/'rtl/cpu5_ram_unit.v').read_bytes())
    (d/'run_cpu5_ram_unit.do').write_bytes((W/'run_cpu5_ram_unit.do').read_bytes())
    (d/'tb/cpu5_ram_unit_tb.v').write_text(f'''`timescale 1ns/1ps
module cpu5_ram_unit_tb;
reg test_pass=0;
cpu5_ram_unit #(.DMEM_BASE_ADDR(32'h{base}),.DMEM_WORDS({words})) dut(
.instr(32'd0),.rs1_value(32'd0),.rs2_value(32'd0),.response_word(32'd0));
initial begin #1;test_pass=1;$stop;end
endmodule
''',encoding='utf-8',newline='\n')
    p=subprocess.run([r'D:\modeltech64_10.6e\win64\vsim.exe','-c','-do','run_cpu5_ram_unit.do','-l','build/cpu5_s5_ram_unit/process.log'],cwd=d,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    (d/'console.log').write_text(p.stdout,encoding='utf-8')
    fatals=[line for line in p.stdout.splitlines() if 'Fatal:' in line]
    result={'name':name,'exit_code':p.returncode,'rejected':p.returncode!=0 and any('nonempty aligned RAM range' in line for line in fatals),'fatal':fatals[:1]}
    results.append(result);print(json.dumps(result))
summary={'parameters':results,'all_rejected':all(x['rejected'] for x in results)}
(ROOT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8')
if not summary['all_rejected']:raise SystemExit(1)
