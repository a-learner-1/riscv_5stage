"""Streaming, independent architectural/timing audit for CPU5 CoreMark raw CSV.

No PASS label, summary counter, or firmware timing value substitutes for the
edge/native/retire ledgers. Arithmetic follows RV32IM; stores reconstruct RAM.
"""
import csv
import gzip
import hashlib
import json
import math
from pathlib import Path
import re

CLASSES=("work_other","ifetch_wait","data_read_wait","data_write_wait","local_mmio_wait",
         "redirect_wait","mul_wait","div_wait","load_use_wait","id_hazard_wait")
SCHEMAS={
 "edges":"cycle,count,instret,events,retire,wb",
 "retire":"event,cycle,seq,pc,instr,rd,value,writes",
 "terminal":"event,cycle,seq,pc,instr,addr,value,error",
 "stats":"event,cycle,offset,data,response",
 "triggers":"kind,cycle,count,instret,d_valid,d_seq,d_addr,d_write,d_killed,d_state,m_valid,m_seq,m_killed,m_gen,m_op,m_state,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,i_access,i_hit,i_miss,i_refill,i_error,d_access,d_hit,d_miss,d_refill,d_error,d_write_count,d_bypass,bp_lookup,bp_hit,bp_taken,bp_resolved,bp_mispredict,bp_direction,bp_target",
 "timer":"cycle,seq,offset,data,mtime,error",
 "native":"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error",
}
HEX={"seq","pc","instr","addr","wdata","wstrb","rdata","value","offset","data","mtime","events","d_seq","d_addr","m_seq","m_gen"}
TEXT={"event","kind"}
IC=("i_access","i_hit","i_miss","i_refill","i_error")
DC=("d_access","d_hit","d_miss","d_refill","d_error","d_write_count","d_bypass")
BP=("bp_lookup","bp_hit","bp_taken","bp_resolved","bp_mispredict","bp_direction","bp_target")
MASK=(1<<32)-1


def check(condition,code,detail=""):
    if not condition:raise ValueError(code+(": "+str(detail) if detail else ""))


def unique(pairs):
    result={}
    for key,value in pairs:
        check(key not in result,"JSON_DUPLICATE",key);result[key]=value
    return result


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"),object_pairs_hook=unique,
                      parse_constant=lambda value:(_ for _ in ()).throw(ValueError("JSON_NONFINITE")))


def rows(directory,name):
    normal=directory/(name+".csv"); zipped=directory/(name+".csv.gz")
    check(normal.is_file()!=zipped.is_file(),"CSV_CLOSURE",name)
    opener=gzip.open if zipped.is_file() else open
    with opener(zipped if zipped.is_file() else normal,"rt",encoding="ascii",newline="") as stream:
        reader=csv.reader(stream);header=next(reader,None)
        check(header==SCHEMAS[name].split(","),"CSV_HEADER",name)
        for fields in reader:
            check(len(fields)==len(header),"CSV_COLUMNS",name)
            row={}
            for key,value in zip(header,fields):
                if key in TEXT:row[key]=value;continue
                check(re.fullmatch("[0-9a-fA-F]+" if key in HEX else "[0-9]+",value) is not None,
                      "CSV_NUMBER",name+"."+key)
                row[key]=int(value,16 if key in HEX else 10)
            yield row


class Cursor:
    def __init__(self,iterator):
        self.iterator=iter(iterator);self.row=next(self.iterator,None);self.previous=0
    def at(self,cycle):
        check(self.row is None or self.row["cycle"]>=cycle,"CSV_ORDER")
        while self.row is not None and self.row["cycle"]==cycle:
            row=self.row;self.row=next(self.iterator,None);yield row
    def exhausted(self):check(self.row is None,"CSV_TRAILING")


def signed(value,bits=32):
    value&=(1<<bits)-1
    return value-(1<<bits) if value&(1<<(bits-1)) else value


class Architecture:
    """Consume committed instructions, not pipeline decode or expected-result pins."""
    def __init__(self,rom):
        self.rom=rom;self.reg=[0]*32;self.pc=0;self.instructions=0
    def retire(self,row,memory):
        pc=row["pc"];ins=row["instr"];op=ins&127;rd=(ins>>7)&31
        f=(ins>>12)&7;a=self.reg[(ins>>15)&31];b=self.reg[(ins>>20)&31];top=ins>>25
        check(pc==self.pc and pc%4==0 and pc//4<len(self.rom) and self.rom[pc//4]==ins,"ISA_PC_INSTRUCTION",hex(pc))
        if op not in (0x03,0x23):check(memory is None,"ISA_UNEXPECTED_MEMORY")
        next_pc=(pc+4)&MASK;result=0;writes=True
        imm=signed(ins>>20,12)
        if op==0x37: result=ins&0xfffff000
        elif op==0x17: result=pc+(ins&0xfffff000)
        elif op==0x6f:
            displacement=((ins>>31)<<20)|(((ins>>12)&255)<<12)|(((ins>>20)&1)<<11)|(((ins>>21)&1023)<<1)
            result=pc+4;next_pc=(pc+signed(displacement,21))&MASK
        elif op==0x67:
            check(f==0,"ISA_JALR");result=pc+4;next_pc=(a+imm)&MASK&~1
        elif op==0x63:
            displacement=((ins>>31)<<12)|(((ins>>7)&1)<<11)|(((ins>>25)&63)<<5)|(((ins>>8)&15)<<1)
            take={0:a==b,1:a!=b,4:signed(a)<signed(b),5:signed(a)>=signed(b),6:a<b,7:a>=b}
            check(f in take,"ISA_BRANCH");writes=False
            if take[f]:next_pc=(pc+signed(displacement,13))&MASK
        elif op==0x13:
            if f==0:result=a+imm
            elif f==2:result=int(signed(a)<imm)
            elif f==3:result=int(a<(imm&MASK))
            elif f==4:result=a^(imm&MASK)
            elif f==6:result=a|(imm&MASK)
            elif f==7:result=a&(imm&MASK)
            elif f==1:check(top==0,"ISA_SHIFT");result=a<<((ins>>20)&31)
            elif f==5:
                check(top in (0,32),"ISA_SHIFT");result=(signed(a) if top==32 else a)>>((ins>>20)&31)
            else:raise ValueError("ISA_IMMEDIATE")
        elif op==0x33:
            if top==1:
                if f==0:result=a*b
                elif f==1:result=(signed(a)*signed(b))>>32
                elif f==2:result=(signed(a)*b)>>32
                elif f==3:result=(a*b)>>32
                elif f in (4,6):
                    x,y=signed(a),signed(b)
                    quotient=-1 if y==0 else abs(x)//abs(y)*(-1 if (x<0)!=(y<0) else 1)
                    result=quotient if f==4 else x if y==0 else x-quotient*y
                elif f==5:result=MASK if b==0 else a//b
                else:result=a if b==0 else a%b
            elif top in (0,32):
                check(top==0 or f in (0,5),"ISA_ALU_ENCODING")
                if f==0:result=a-b if top==32 else a+b
                elif f==1:result=a<<(b&31)
                elif f==2:result=int(signed(a)<signed(b))
                elif f==3:result=int(a<b)
                elif f==4:result=a^b
                elif f==5:result=(signed(a) if top==32 else a)>>(b&31)
                elif f==6:result=a|b
                else:result=a&b
            else:raise ValueError("ISA_REGISTER")
        elif op in (0x03,0x23):
            check(memory is not None,"ISA_MEMORY_MISSING",row["seq"])
            check(memory["seq"]==row["seq"] and memory["pc"]==pc,"ISA_MEMORY_OWNER")
            store=op==0x23
            if store:imm=signed(((ins>>25)<<5)|((ins>>7)&31),12)
            address=(a+imm)&MASK;size={0:0,1:1,2:2,4:0,5:1}.get(f)
            check(size is not None and (not store or f<3),"ISA_MEMORY_ENCODING")
            check(address% (1<<size)==0,"ISA_MEMORY_ALIGNMENT")
            check(memory["addr"]==address and memory["size"]==size and memory["is_write"]==int(store),"ISA_MEMORY_DESCRIPTOR")
            if store:
                strobe=((1<<(1<<size))-1)<<(address&3)
                check(memory["wstrb"]==strobe and memory["wdata"]==((b<<((address&3)*8))&MASK),"ISA_STORE_DATA")
                writes=False
            else:
                check(memory["wstrb"]==0 and memory["wdata"]==0,"ISA_LOAD_SHAPE")
                value=(memory["rdata"]>>((address&3)*8))&((1<<(8*(1<<size)))-1)
                result=signed(value,8*(1<<size)) if f in (0,1) else value
        elif op==0x0f:
            check(f==0,"ISA_FENCE");writes=False
        else:raise ValueError("ISA_UNSUPPORTED: "+hex(ins))
        check(row["rd"]==(rd if writes else 0) and row["writes"]==int(writes and rd!=0),"ISA_DESTINATION",f"pc={pc:08x} instr={ins:08x} rd={row['rd']} writes={row['writes']} expected_rd={rd if writes else 0}")
        if writes and rd:
            check(row["value"]==(result&MASK),"ISA_RESULT",f"pc={pc:08x} actual={row['value']:08x} expected={result&MASK:08x}")
            self.reg[rd]=result&MASK
        self.pc=next_pc;self.instructions+=1


def parse_console(text):
    result={}
    for line in text.splitlines():
        if not line.startswith("COREMARK "):continue
        if line=="COREMARK RESULT: SMOKE PASS":continue
        match=re.fullmatch(r"COREMARK ([a-z][a-z0-9_]*)=(.*)",line)
        check(match is not None,"CONSOLE_SYNTAX",line)
        key,value=match.groups();check(key not in result,"CONSOLE_DUPLICATE",key);result[key]=value
    check(text.splitlines().count("COREMARK RESULT: SMOKE PASS")==1,"CONSOLE_RESULT")
    for token in ("COREMARK RESULT: FORMAL","SMOKE FAIL","Cannot validate operation","ERROR:","ERROR! list","ERROR! matrix","ERROR! state"):
        check(token not in text,"CONSOLE_ERROR",token)
    return result


def stats_word(offset,start,stop,case):
    fixed={0:0x434d4158,4:0x434d4158,8:case["cache"],12:0x02040010,16:0x02040010,
           20:0x00100001,24:4,28:case["d0"]}
    if offset in fixed:return fixed[offset]
    for base,trigger in ((0x40,start),(0x80,stop)):
        if base<=offset<base+64 and offset%4==0:
            check(trigger is not None,"STATS_EARLY_BANK")
            values=[trigger["count"]&MASK,trigger["count"]>>32,trigger["instret"]&MASK,trigger["instret"]>>32]
            values += [trigger[x] for x in IC+DC]
            return values[(offset-base)//4]
    for base,trigger in ((0xc0,start),(0xe0,stop)):
        if base<=offset<base+28 and offset%4==0:
            check(trigger is not None,"STATS_EARLY_BP");return trigger[BP[(offset-base)//4]]
    for bank,trigger,index,count in ((0x100,start,0,6),(0x140,stop,0,6),(0x180,start,6,4),(0x1c0,stop,6,4)):
        if bank<=offset<bank+count*8 and offset%4==0:
            check(trigger is not None,"STATS_EARLY_PROFILE");value=trigger["p"+str(index+(offset-bank)//8)]
            return (value>>(32*((offset-bank)%8//4)))&MASK
    raise ValueError("STATS_UNEXPECTED_OFFSET: "+hex(offset))


def precheck(directory,number,run_id,allow_probe=False):
    """Small raw ledgers reject forged summaries before scanning large traces."""
    s=read_json(directory/"summary.json")
    check(s["status"]=="PASS" and s["case"]==number and s["run_id"]==run_id,"CASE_RUN_ID")
    check(s["quick_probe"]==int(allow_probe),"QUICK_PROBE_SCOPE")
    triggers=list(rows(directory,"triggers"))
    check([r["kind"] for r in triggers]==["start","start","stop"],"TRIGGER_ORDER")
    begin,end=triggers[1:]
    expected=dict(start_cycle=begin["count"],stop_cycle=end["count"],start_instret=begin["instret"],stop_instret=end["instret"],
                  snapshot_cycle_delta=end["count"]-begin["count"],snapshot_instret_delta=end["instret"]-begin["instret"])
    check(s["window"]==expected,"RAW_WINDOW_SUMMARY")
    first=[begin["p"+str(i)] for i in range(10)];last=[end["p"+str(i)] for i in range(10)]
    delta=[b-a for a,b in zip(first,last)]
    check(s["profile"]==dict(start=first,stop=last,delta=delta) and all(x>=0 for x in delta) and sum(delta)==expected["snapshot_cycle_delta"],"RAW_PROFILE_SUMMARY")
    timer=list(rows(directory,"timer"));sample=[];ticks=[]
    for row in timer:
        check(row["error"]==0 and row["mtime"]==row["cycle"]-1,"TIMER_INDEPENDENT_CLOCK")
        check(row["offset"] in (0x40,0x44) and row["data"]==((row["mtime"]>>(32 if row["offset"]==0x44 else 0))&MASK),"TIMER_DATA")
        sample.append(row)
        check([x["offset"] for x in sample]==[0x44,0x40,0x44][:len(sample)],"TIMER_HLH_ORDER")
        if len(sample)==3:
            if sample[0]["data"]==sample[2]["data"]:ticks.append(sample[1]["mtime"])
            sample=[]
    check(not sample and len(ticks)==2,"TIMER_PAIRS")
    check(s["timer"]==dict(reads=len(timer),pairs=2,start_ticks=ticks[0],stop_ticks=ticks[1],raw_ticks=ticks[1]-ticks[0]),"RAW_TIMER_SUMMARY")
    if not allow_probe:
        values=parse_console((directory/"console.txt").read_text(encoding="ascii"))
        required={"counter_cycles":str(expected["snapshot_cycle_delta"]),"counter_retired":str(expected["snapshot_instret_delta"]),
                  "raw_ticks":str(ticks[1]-ticks[0]),"window_tick_gap":str(expected["snapshot_cycle_delta"]-(ticks[1]-ticks[0])),
                  "cycle_profile_sum":str(sum(delta))}
        required.update({"cycle_"+name:str(value) for name,value in zip(CLASSES,delta)})
        for key,value in required.items():check(values.get(key)==value,"RAW_CONSOLE_VALUE",key)
        expected_floats={"counter_cpi":expected["snapshot_cycle_delta"]/expected["snapshot_instret_delta"],
                         "seconds":(ticks[1]-ticks[0])/50000000,
                         "iterations_per_second":50000000/(ticks[1]-ticks[0]),
                         "coremark_per_mhz":1000000/(ticks[1]-ticks[0])}
        for key,wanted in expected_floats.items():
            text=values.get(key,"")
            check(re.fullmatch(r"[0-9]+\.[0-9]{9}",text) is not None,"CONSOLE_FLOAT_SYNTAX",key)
            actual=float(text)
            check(math.isfinite(actual) and abs(actual-wanted)<=2e-8*max(1,abs(wanted)),"CONSOLE_FLOAT_VALUE",key)
    return s


def audit_case(directory,number,firmware,run_id,allow_probe=False):
    precheck(directory,number,run_id,allow_probe)
    s=read_json(directory/"summary.json")
    check(s["status"]=="PASS" and s["case"]==number and s["d0"]==number//2 and s["cache"]==(3 if number%2 else 0),"CASE_IDENTITY")
    check(s["run_id"]==run_id,"CASE_RUN_ID")
    check(s["quick_probe"]==int(allow_probe),"QUICK_PROBE_SCOPE")
    initial=[int(line,16) for line in (firmware/"program_data.hex").read_text().splitlines()]
    rom=[int(line,16) for line in (firmware/"program.hex").read_text().splitlines()]
    check(len(initial)==4096 and len(rom)==8192,"FIRMWARE_IMAGE_SIZE")
    memory=initial[:];architecture=Architecture(rom)
    triggers=list(rows(directory,"triggers"));check([r["kind"] for r in triggers]==["start","start","stop"],"TRIGGER_ORDER")
    trigger_map={r["cycle"]:r for r in triggers};check(len(trigger_map)==3,"TRIGGER_UNIQUE")
    terminals=list(rows(directory,"terminal"));check([r["event"] for r in terminals]==["req","rsp","completion","retire","wb"],"TERMINAL_ORDER")
    term={r["event"]:r for r in terminals};seq=term["req"]["seq"];pc=term["req"]["pc"];ins=term["req"]["instr"]
    for row in terminals:
        check((row["seq"],row["pc"],row["instr"],row["addr"],row["error"])==(seq,pc,ins,0x13ffc,0),"TERMINAL_DESCRIPTOR")
        check(row["value"]==(1 if row["event"]=="req" else 0),"TERMINAL_VALUE")
    check(term["req"]["cycle"]<=term["rsp"]["cycle"]<=term["completion"]["cycle"]<=term["retire"]["cycle"]<term["wb"]["cycle"],"TERMINAL_TIMING")
    cursors={name:Cursor(rows(directory,name)) for name in ("native","retire","timer","stats")}
    gold=[0]*10;nret=nwb=last_seq=0;seen_retire=False;expected_wb=None;pending=None;completed={}
    stats_pending=None;stats_values={};timer_values={};coherent=[];sample=[];timer_rows=stats_responses=native_responses=ram_writes=0
    start=stop=None;uart=bytearray();offsets=set();last_cycle=0;terminal_retire_index=None
    terminal_seen=set();native_last_seq=-1
    for e in rows(directory,"edges"):
        cycle=e["cycle"];check(cycle==last_cycle+1 and e["count"]==cycle-1 and e["instret"]==nret,"EDGE_COUNTER")
        event=e["events"];check(event==0 if cycle==1 else 0<event<1024 and event&(event-1)==0,"EVENT_ONE_HOT")
        if event:gold[event.bit_length()-1]+=1
        check(sum(gold)==e["count"],"EVENT_SUM")
        trigger=trigger_map.get(cycle)
        if trigger:
            check([trigger["p"+str(i)] for i in range(10)]==gold and trigger["count"]==e["count"] and trigger["instret"]==nret,"TRIGGER_GOLD")
            check(trigger["d_valid"]==1 and trigger["d_killed"]==trigger["d_write"]==0 and trigger["d_state"]==2,"TRIGGER_D_OWNER")
            check(pending is not None and trigger["d_seq"]==pending["seq"] and trigger["d_addr"]==pending["addr"],"TRIGGER_NATIVE_OWNER")
            check(trigger["m_valid"] in (0,1) and trigger["m_killed"] in (0,1),"TRIGGER_M_CONTEXT")
            if trigger["kind"]=="start":start=trigger
            else:stop=trigger
        # Timer executions happen before the corresponding native response.
        for row in cursors["timer"].at(cycle):
            check(pending is not None and row["seq"]==pending["seq"] and pending["addr"]==0x20000000+row["offset"] and not pending["is_write"],"TIMER_OWNER")
            check(row["error"]==0 and row["mtime"]==cycle-1,"TIMER_INDEPENDENT_CLOCK")
            check(row["offset"] in (0x40,0x44) and row["data"]==((cycle-1)>>(32 if row["offset"]==0x44 else 0))&MASK,"TIMER_DATA")
            check(row["seq"] not in timer_values,"TIMER_DUPLICATE")
            timer_values[row["seq"]]=row["data"];timer_rows+=1;sample.append(row)
            check([r["offset"] for r in sample]==[0x44,0x40,0x44][:len(sample)],"TIMER_HLH_ORDER")
            if len(sample)==3:
                if sample[0]["data"]==sample[2]["data"]:
                    assembled=(sample[0]["data"]<<32)|sample[1]["data"]
                    check(assembled==sample[1]["mtime"],"TIMER_HLH_VALUE");coherent.append((assembled,sample[1]["cycle"]))
                sample=[]
        for row in cursors["stats"].at(cycle):
            check(row["response"]==0,"STATS_RESPONSE_ERROR")
            if row["event"]=="req":
                check(stats_pending is None and pending is not None and not pending["is_write"] and pending["addr"]==0x30000000+row["offset"],"STATS_OWNER")
                stats_pending=(row,pending["seq"],stats_word(row["offset"],start,stop,s));offsets.add(row["offset"])
            else:
                check(row["event"]=="rsp" and stats_pending is not None,"STATS_UNOWNED_RESPONSE")
                request,owner,value=stats_pending
                check(row["offset"]==request["offset"] and cycle>request["cycle"] and row["data"]==value,"STATS_BANK_DATA",hex(row["offset"]))
                stats_values[owner]=value;stats_pending=None;stats_responses+=1
        for row in cursors["native"].at(cycle):
            check(row["error"]==0,"NATIVE_ERROR")
            if row["event"]=="req":
                check(pending is None and row["seq"]>native_last_seq and row["rdata"]==0,"NATIVE_REQUEST")
                check(row["size"] in (0,1,2) and row["is_write"] in (0,1),"NATIVE_SHAPE")
                pending=dict(row);native_last_seq=row["seq"];address=row["addr"]
                if 0x10000<=address<0x14000:
                    index=(address-0x10000)//4
                    if row["is_write"]:
                        check(row["wstrb"]>0 and row["wstrb"]<16,"RAM_WRITE_STROBE")
                        for lane in range(4):
                            if row["wstrb"]&(1<<lane):memory[index]=(memory[index]&~(255<<(lane*8)))|(row["wdata"]&(255<<(lane*8)))
                        ram_writes+=1
                    pending["expected_read"]=0 if row["is_write"] else memory[index]
                elif address in (0x20000040,0x20000044):
                    check(not row["is_write"],"TIMER_WRITE_FORBIDDEN")
                elif address==0x20000010:
                    check(row["is_write"]==1 and row["size"]==2 and row["wstrb"]==15,"UART_STORE_SHAPE")
                    uart.append(row["wdata"]&255);pending["expected_read"]=0
                elif address==0x20000014:
                    check(not row["is_write"],"UART_STATUS_WRITE")
                elif 0x30000000<=address<0x30000200:
                    check(not row["is_write"] and row["size"]==2,"STATS_NATIVE_SHAPE")
                else:raise ValueError("NATIVE_UNEXPECTED_ADDRESS: "+hex(address))
                if address==0x13ffc and row["is_write"] and row["wdata"]!=0:
                    check(row["seq"]==seq and row["pc"]==pc and row["wdata"]==1 and cycle==term["req"]["cycle"],"TOHOST_NATIVE_REQUEST")
                    terminal_seen.add("req")
            else:
                check(row["event"]=="rsp" and pending is not None,"NATIVE_UNOWNED_RESPONSE")
                check(all(row[k]==pending[k] for k in ("seq","pc","addr","wdata","wstrb","size","is_write")),"NATIVE_DESCRIPTOR")
                address=row["addr"]
                if address in (0x20000040,0x20000044):
                    check(row["seq"] in timer_values and row["rdata"]==timer_values.pop(row["seq"]),"TIMER_RESPONSE_FREEZE")
                elif 0x30000000<=address<0x30000200:
                    check(row["seq"] in stats_values and row["rdata"]==stats_values.pop(row["seq"]),"STATS_NATIVE_DATA")
                elif address==0x20000014:check(row["rdata"] in (0,1),"UART_STATUS")
                else:check(row["rdata"]==pending["expected_read"],"RAM_NATIVE_DATA",hex(address))
                check(row["seq"] not in completed,"NATIVE_REPEATED_COMPLETION")
                completed[row["seq"]]=dict(row);pending=None;native_responses+=1
                if row["seq"]==seq:
                    check(cycle==term["rsp"]["cycle"] and row["pc"]==pc,"TOHOST_NATIVE_RESPONSE");terminal_seen.add("rsp")
        flags={"retire":0,"wb":0}
        for row in cursors["retire"].at(cycle):
            check(row["event"] in flags,"RETIRE_EVENT");flags[row["event"]]+=1
            if row["event"]=="wb":
                check(expected_wb is not None,"WB_UNOWNED")
                check(cycle>expected_wb["cycle"] and all(row[k]==expected_wb[k] for k in ("seq","pc","instr","rd","value","writes")),"WB_PACKET")
                expected_wb=None;nwb+=1
                if row["seq"]==seq:
                    check(cycle==term["wb"]["cycle"] and not row["writes"],"TOHOST_WB");terminal_seen.add("wb")
            else:
                check(expected_wb is None and (not seen_retire or row["seq"]>last_seq),"RETIRE_SEQUENCE")
                packet=completed.pop(row["seq"],None)
                architecture.retire(row,packet)
                expected_wb=dict(row);last_seq=row["seq"];seen_retire=True
                if row["seq"]==seq:
                    check(cycle==term["retire"]["cycle"] and row["pc"]==pc and row["instr"]==ins and not row["writes"],"TOHOST_RETIRE")
                    terminal_retire_index=nret;terminal_seen.add("retire")
                nret+=1
        check(flags["retire"]==e["retire"] and flags["wb"]==e["wb"] and e["retire"] in (0,1) and e["wb"] in (0,1),"EDGE_PACKET_FLAGS")
        check(len(completed)<8,"NATIVE_COMPLETION_LEAK")
        last_cycle=cycle
    for cursor in cursors.values():cursor.exhausted()
    check(pending is None and not completed and expected_wb is None and stats_pending is None and not stats_values and not timer_values,"DRAIN_LEDGER")
    check(nret==nwb==s["retired"]==s["writebacks"] and last_cycle==s["compute_cycles"] and nret<=last_cycle,"TOTAL_RETIRE_WB")
    check(terminal_seen=={"req","rsp","retire","wb"},"TOHOST_CLOSURE")
    check(ram_writes==s["native_ram_writes"]==s["ram_physical_writes"],"RAM_WRITE_COUNT")
    actual=[int(line,16) for line in (directory/"actual_ram.hex").read_text().splitlines()]
    check(actual==memory and len(actual)==4096 and memory[-1]==1,"RAM_FINAL_IMAGE")
    check(start==triggers[1] and stop==triggers[2],"SNAPSHOT_SELECTION")
    window=s["window"];profiles=s["profile"]
    check(window==dict(start_cycle=start["count"],stop_cycle=stop["count"],start_instret=start["instret"],stop_instret=stop["instret"],
          snapshot_cycle_delta=stop["count"]-start["count"],snapshot_instret_delta=stop["instret"]-start["instret"]),"SUMMARY_WINDOW")
    pstart=[start["p"+str(i)] for i in range(10)];pstop=[stop["p"+str(i)] for i in range(10)]
    delta=[b-a for a,b in zip(pstart,pstop)]
    check(profiles==dict(start=pstart,stop=pstop,delta=delta) and sum(delta)==window["snapshot_cycle_delta"],"SUMMARY_PROFILE")
    for name,fields in (("icache",IC),("dcache",DC),("bp",BP)):
        check(s[name]==dict(start=[start[k] for k in fields],stop=[stop[k] for k in fields]),"SUMMARY_LIVE_COUNTER",name)
    check(s["raw_starts"]==2 and s["stops"]==1,"SUMMARY_TRIGGERS")
    check(len(coherent)==2 and not sample and timer_rows==s["timer"]["reads"] and s["timer"]["pairs"]==2,"TIMER_PAIRS")
    ticks=coherent[1][0]-coherent[0][0]
    check(0<ticks<=window["snapshot_cycle_delta"] and window["snapshot_cycle_delta"]-ticks<=256,"TIMER_WINDOW")
    check(s["timer"]==dict(reads=timer_rows,pairs=2,start_ticks=coherent[0][0],stop_ticks=coherent[1][0],raw_ticks=ticks),"SUMMARY_TIMER")
    check(start["cycle"]<coherent[0][1]<coherent[1][1]<stop["cycle"],"TIMER_BOUNDARIES")
    drain=s["drain"]
    check(drain["gate_cycle"]==term["req"]["cycle"] and drain["tail_cycles"]==last_cycle-drain["gate_cycle"] and 0<drain["tail_cycles"]<2000,"DRAIN_TAIL")
    check(drain["pipeline_empty"]==1 and drain["expected_wb_valid"]==drain["memwb_valid_at_stop"]==0 and drain["if_accepted"]==drain["if_returned"]>0 and drain["shared_reset_after_snapshot"]==1,"DRAIN_STRUCTURE")
    host=s["tohost"]
    check(all(host[k]==1 for k in ("requests","responses","completions","retired","value","wb_matched")) and host["writes_we"]==0,"SUMMARY_TOHOST_COUNTS")
    check((int(host["seq"],16),int(host["pc"],16),int(host["instr"],16),int(host["addr"],16))==(seq,pc,ins,0x13ffc),"SUMMARY_TOHOST_IDENTITY")
    check(host["retire_index"]==terminal_retire_index and host["writebacks"]==nwb,"SUMMARY_TOHOST_INDEX")
    for name,event in (("request","req"),("response","rsp"),("completion","completion"),("retire","retire"),("wb","wb")):
        check(host[name+"_cycle"]==term[event]["cycle"],"SUMMARY_TOHOST_CYCLE")
    console_file=(directory/"console.txt").read_bytes();serial=(directory/"uart_serial.txt").read_bytes()
    console=bytes(uart)
    # Windows ModelSim text-mode $fwrite expands each LF to CRLF. Accept only
    # that exact serialization, or the identical bytes used by non-Windows runs.
    check(console_file==serial and console_file in (console,console.replace(b'\n',b'\r\n')) and len(console)==s["console_bytes"]==s["uart_frames"] and s["uart_data_mismatch"]==s["uart_stop_errors"]==0,"UART_PIN_NATIVE_MATCH")
    if not allow_probe:
        values=parse_console(console.decode("ascii"))
        expected={"platform":"cpu5","isa":"rv32im","data_backend":"bram" if number//2 else "axi","backend_id":str(number//2),
                  "cache_enable":str(s["cache"]),"cache_geometry":str(0x02040010),"branch_pred_enable":"1","btb_entries":"16","btb_config":str(0x00100001),
                  "stats_schema":"4","cycle_profile_schema":"2","counter_window":"START-before-mtime;STOP-after-mtime;includes-boundary-overhead",
                  "counter_valid":"1","counter_cycles":str(window["snapshot_cycle_delta"]),"counter_retired":str(window["snapshot_instret_delta"]),
                  "cycle_profile_valid":"1","cycle_profile_sum":str(sum(delta)),"window_tick_gap":str(window["snapshot_cycle_delta"]-ticks),
                  "profile":"cpu5-smoke","mode":"smoke","run":"performance","cpu_hz":"50000000","uart_baud":"5000000","iterations_requested":"1","iterations":"1",
                  "raw_ticks":str(ticks),"seed1":"0x0000","seed2":"0x0000","seed3":"0x0066","seedcrc":"0xe9f5","crclist":"0xe714","crcmatrix":"0x1fd7","crcstate":"0x8e3a",
                  "cache_state":"fixed-iterations;no-explicit-flush","predictor_state":"fixed-iterations;no-explicit-reset"}
        expected.update({"cycle_"+name:str(value) for name,value in zip(CLASSES,delta)})
        for name,fields,names in (("icache",IC,("access","hit","miss","refill_words","errors")),
                                   ("dcache",DC,("access","hit","miss","refill_words","errors","write","bypass")),
                                   ("bp",BP,("lookup","hit","predicted_taken","resolved","next_pc_mismatch","direction_error","target_error"))):
            expected.update({name+"_"+key:str((stop[field]-start[field])&MASK) for field,key in zip(fields,names)})
        extra={"counter_cpi","seconds","iterations_per_second","coremark_per_mhz","compiler","flags","memory"}
        check(set(values)==set(expected)|extra,"CONSOLE_KEY_SET",sorted(set(values)^ (set(expected)|extra)))
        for key,value in expected.items():check(values.get(key)==value,"CONSOLE_VALUE",key)
        check("ERROR! Must execute for at least 10 secs" in console.decode() and
              "NOTE: smoke timing is a functional observation; it is not a formal score." in console.decode(),"SMOKE_SCOPE")
        for line in ("seedcrc          : 0xe9f5","[0]crclist       : 0xe714","[0]crcmatrix     : 0x1fd7","[0]crcstate      : 0x8e3a"):
            check(line in console.decode(),"UPSTREAM_CRC",line)
        required=set(range(0,32,4))|set(range(0x40,0xc0,4))|set(range(0xc0,0xdc,4))|set(range(0xe0,0xfc,4))
        for base,count in ((0x100,6),(0x140,6),(0x180,4),(0x1c0,4)):required|=set(range(base,base+count*8,4))
        check(required<=offsets,"STATS_BANK_COVERAGE")
        check(0<window["snapshot_instret_delta"]<=window["snapshot_cycle_delta"]<2**32,"WINDOW_POSSIBLE")
        if not s["cache"]:check(not any(start[k] or stop[k] for k in IC+DC),"CACHE_DISABLED_BANK")
        check(stop["i_error"]==start["i_error"]==stop["d_error"]==start["d_error"]==0,"CACHE_ERRORS")
    return dict(case=number,d0=s["d0"],cache=s["cache"],cycles=last_cycle,retired=nret,writebacks=nwb,
                window_cycles=window["snapshot_cycle_delta"],window_retired=window["snapshot_instret_delta"],raw_ticks=ticks,
                window_tick_gap=window["snapshot_cycle_delta"]-ticks,cycle_classes=dict(zip(CLASSES,delta)),
                icache_delta=[(stop[k]-start[k])&MASK for k in IC],dcache_delta=[(stop[k]-start[k])&MASK for k in DC],
                bp_delta=[(stop[k]-start[k])&MASK for k in BP],native_transactions=native_responses,ram_writes=ram_writes,
                stats_responses=stats_responses,timer_reads=timer_rows,console_bytes=len(console),terminal_seq=seq,
                drained=True,architectural_instructions=architecture.instructions,quick_probe=allow_probe,
                uart_file_lf_expanded_to_crlf=console_file!=console)

