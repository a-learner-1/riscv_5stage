"""Independent RV32 machine-word, device-event and owner-ledger oracle.

Dynamic counter gold is calculated from a complete edge/retirement history.
Neither retirement values nor observed device read data supply expected values.
"""
from __future__ import annotations
import csv
import hashlib
import json
from pathlib import Path
import shutil
from cpu5_csr_reference import Machine as CSRMachine
from cpu5_m_reference import m_result

MASK=0xffffffff
CSRS=('mstatus','mtvec','mscratch','mepc','mcause','mtval','mie')
FIELDS=('kind','pc','instr','rd','value','writes','nextpc','cause','tval')+CSRS
EVENT_HEADER=('kind','cycle','index','seq')+FIELDS[1:]+('instret',)
WB_HEADER=('cycle','index','seq','pc','instr','rd','value','writes','nextpc')
ACCEPT_HEADER=('cycle','seq','pc','instr')
D_HEADER=('event','cycle','seq','pc','addr','wdata','wstrb','size','is_write','rdata','error')
LOCAL_HEADER=('cycle','seq','pc','addr','wdata','wstrb','size','is_write','rdata','error','tx','pop','gpio')
IF_HEADER=('event','cycle','addr')
CYCLE_HEADER=('cycle','raw','pending','arm','eligible','take','mstatus','mie')
HEX={'seq','pc','instr','value','nextpc','cause','tval','addr','wdata','wstrb','rdata','pending',*CSRS}


def require(ok,message):
    if not ok: raise ValueError(message)


def read_hex(path):
    lines=path.read_text(encoding='ascii').splitlines()
    require(lines and all(len(x)==8 and all(c in '0123456789abcdefABCDEF' for c in x) for x in lines),f'{path.name}: exact hex required')
    return [int(x,16) for x in lines]


def read_csv(path,header):
    result=[]
    with path.open(newline='',encoding='ascii') as stream:
        reader=csv.DictReader(stream);require(tuple(reader.fieldnames or ())==header,f'{path.name}: header mismatch')
        for number,record in enumerate(reader):
            require(None not in record and all(v and v==v.strip() for v in record.values()),f'{path.name}: malformed row{number}')
            row={}
            for k,v in record.items():
                if k in ('event','kind'): row[k]=v
                else:
                    try: row[k]=int(v,16 if k in HEX else 10)
                    except ValueError as e: raise ValueError(f'{path.name}: invalid {k}') from e
                    require(row[k]>=0 and (k not in HEX or row[k]<=(0xffffffffffffffff if k=='seq' else MASK)),f'{path.name}: invalid range {k}')
            result.append(row)
    return result


class Machine(CSRMachine):
    def __init__(self,initial,local_rows,events):
        super().__init__();self.mie=0
        self.memory=bytearray(b''.join(x.to_bytes(4,'little') for x in initial))
        self.local_rows=local_rows;self.history=events;self.local_index=0
        self.gpio=0;self.oe=0;self.rx=[0xa6,0x3c];self.tx=[]
        self.accesses=[];self.effects=[]

    def finish(self,pc,word,rd,value,nextpc=None,access=None):
        value &= MASK
        if rd: self.gpr[rd]=value
        self.pc=(pc+4)&MASK if nextpc is None else nextpc
        self.instret+=1
        return dict(kind='retire',pc=pc,instr=word,rd=rd,value=value,writes=int(rd!=0),nextpc=self.pc,cause=0,tval=0,**self.csr,mie=self.mie,access=access)

    def fault(self,pc,word,cause,tval,access):
        old=self.csr['mstatus']
        self.csr.update(mstatus=0x1800|((old&8)<<4),mepc=pc,mcause=cause,mtval=tval)
        self.pc=self.csr['mtvec']
        return dict(kind='trap',pc=pc,instr=word,rd=0,value=0,writes=0,nextpc=self.pc,cause=cause,tval=tval,**self.csr,mie=self.mie,access=access)

    def interrupt(self):
        pc=self.pc;old=self.csr['mstatus'];require(old&8,'gold IRQ committed MIE')
        self.csr.update(mstatus=0x1800|((old&8)<<4),mepc=pc,mcause=0x8000000b,mtval=0)
        self.pc=self.csr['mtvec']
        return dict(kind='irq',pc=pc,instr=0,rd=0,value=0,writes=0,nextpc=self.pc,cause=0x8000000b,tval=0,**self.csr,mie=self.mie,access=None)

    def step(self,word):
        pc=self.pc;op=word&127;f=(word>>12)&7;rd=(word>>7)&31;a=(word>>15)&31;b=(word>>20)&31
        if op in (3,0x23):
            write=op==0x23;imm=(((word>>25)<<5)|((word>>7)&31)) if write else word>>20
            if imm&2048: imm-=4096
            addr=(self.operand(a)+imm)&MASK;size=0 if f in (0,4) else 1 if f in (1,5) else 2
            raw=self.operand(b) if write else 0
            data=(raw<<(8*(addr&3)))&MASK;strobe=((1<<(1<<size))-1)<<(addr&3) if write else 0
            result=0;error=0;local=0x20000000<=addr<0x20000100
            access=dict(pc=pc,instr=word,addr=addr,wdata=data,wstrb=strobe,size=size,is_write=int(write),rdata=0,error=0)
            if 0x10000<=addr<=0x10000+len(self.memory)-(1<<size):
                offset=addr-0x10000;aligned=offset&~3
                result=int.from_bytes(self.memory[aligned:aligned+4],'little')
                if write:self.memory[offset:offset+(1<<size)]=(raw&((1<<(8*(1<<size)))-1)).to_bytes(1<<size,'little')
            elif local:
                require(self.local_index<len(self.local_rows),'local execution missing')
                row=self.local_rows[self.local_index];self.local_index+=1
                require(row['pc']==pc and row['addr']==addr,'local execution machine-word owner')
                tx=pop=gpio=0
                if write and addr==0x20000010 and size in (0,1,2):
                    self.tx.append(raw&255);tx=1
                elif size!=2 or addr&3:error=1
                elif write:
                    if addr in (0x20000020,0x20000028,0x2000002c,0x20000030,0x20000034):
                        gpio=1
                        if addr==0x20000020:self.gpio=raw&255
                        elif addr==0x20000028:self.oe=raw&255
                        elif addr==0x2000002c:self.gpio|=raw&255
                        elif addr==0x20000030:self.gpio&=~raw&255
                        else:self.gpio^=raw&255
                    elif addr==0x2000001c:pass
                    else:error=1
                else:
                    if addr==0x20000000:result=row['cycle']-1
                    elif addr==0x20000004:result=sum(e['kind']=='retire' and e['cycle']<row['cycle'] for e in self.history)
                    elif addr==0x20000018:result=self.rx.pop(0) if self.rx else 0;pop=1
                    elif addr==0x20000020:result=self.gpio
                    elif addr==0x20000024:result=0xa5
                    elif addr==0x20000028:result=self.oe
                    else:error=1
                self.effects.append(dict(**access,cycle=row['cycle'],tx=tx,pop=pop,gpio=gpio,expected_rdata=result,expected_error=error))
            elif not write and addr==0x30000000:result=0x13579bdf
            elif not write and addr==0x90000000:result=0x2468ace0
            else:raise ValueError(f'gold unsupported external access {addr:08x}')
            access.update(rdata=result,error=error);self.accesses.append(access)
            if error:return self.fault(pc,word,7 if write else 5,addr,access)
            if write:return self.finish(pc,word,0,0,access=access)
            shifted=result>>(8*(addr&3));bits=8*(1<<size);value=shifted&((1<<bits)-1)
            if f in (0,1) and value&(1<<(bits-1)):value-=1<<bits
            return self.finish(pc,word,rd,value,access=access)
        if op==0x33 and word>>25==1:return self.finish(pc,word,rd,m_result(f,self.operand(a),self.operand(b)))
        if op==0x63:
            imm=((word>>31)<<12)|(((word>>7)&1)<<11)|(((word>>25)&63)<<5)|(((word>>8)&15)<<1)
            if imm&4096:imm-=8192
            av,bv=self.operand(a),self.operand(b)
            taken=av==bv if f==0 else av!=bv if f==1 else (av^0x80000000)<(bv^0x80000000) if f==4 else None
            require(taken is not None,'gold branch subset')
            return self.finish(pc,word,0,0,(pc+(imm if taken else 4))&MASK)
        if op==0x73 and f in (1,2,3,5,6,7) and word>>20==0x304:
            old=self.mie;source=a if f&4 else self.operand(a)
            if f in (1,5) or a:self.mie=(source if f&3==1 else old|source if f&3==2 else old&~source)&0x800
            return self.finish(pc,word,rd,old)
        event=super().step(word)
        return dict(**event,mie=self.mie,access=None)


def selftest_decoder():
    m=Machine([0]*64,[],[]);checks=0
    for word,value in ((0x000100b7,0x10000),(0x20000137,0x20000000),(0x800002b7,0x80000000)):
        require(m.step(word)['value']==value,'fixed LUI');checks+=1
    m.gpr[5]=0x800;require(m.step(0x30429073)['mie']==0x800,'fixed mie');checks+=1
    m.gpr[3]=0x13579bdf;require(m.step(0x0030a023)['writes']==0,'fixed RAM store');checks+=1
    require(m.step(0x0000a203)['value']==0x13579bdf,'fixed RAM load');checks+=1
    m.gpr[20]=0x8000000b;pc=m.pc;require(m.step(0x000a4663)['nextpc']==pc+12,'fixed signed BLT IRQ');checks+=1
    m.csr['mstatus']=0x1808;pc=m.pc;e=m.interrupt();require(e['mepc']==pc and e['mstatus']==0x1880,'fixed IRQ');checks+=1
    require(m.step(0x30200073)['nextpc']==pc,'fixed MRET');checks+=1
    io=Machine([0]*64,[dict(pc=0,addr=0x20000020,cycle=10),dict(pc=4,addr=0x20000020,cycle=14),
                           dict(pc=8,addr=0x20000018,cycle=18),dict(pc=12,addr=0x20000018,cycle=22),
                           dict(pc=16,addr=0x20000000,cycle=26),dict(pc=20,addr=0x20000020,cycle=30)],[])
    io.gpr[2]=0x20000000;io.gpr[5]=0x55
    require(io.step(0x02512023)['writes']==0 and io.gpio==0x55,'fixed GPIO SW');checks+=1
    require(io.step(0x02012303)['value']==0x55,'fixed GPIO LW');checks+=1
    require(io.step(0x01812403)['value']==0xa6,'fixed first FIFO head');checks+=1
    require(io.step(0x01812483)['value']==0x3c and not io.rx,'fixed second FIFO head');checks+=1
    require(io.step(0x00012503)['value']==25,'fixed pre-edge cycle sample');checks+=1
    fault=io.step(0x02010703)
    require(fault['kind']=='trap' and fault['cause']==5 and fault['tval']==0x20000020 and fault['mepc']==20,'fixed illegal GPIO LB precise access fault');checks+=1
    return dict(status='PASS',fixed_word_checks=checks)


def audit_case(directory,program,initial,fixture):
    events=read_csv(directory/'events.csv',EVENT_HEADER);accepts=read_csv(directory/'accept.csv',ACCEPT_HEADER)
    wb=read_csv(directory/'wb.csv',WB_HEADER);drows=read_csv(directory/'d.csv',D_HEADER)
    external=read_csv(directory/'external.csv',D_HEADER);local=read_csv(directory/'local.csv',LOCAL_HEADER)
    ifrows=read_csv(directory/'if.csv',IF_HEADER);cycles=read_csv(directory/'cycles.csv',CYCLE_HEADER)
    metrics=json.loads((directory/'metrics.json').read_text());m=Machine(initial,local,events)
    owners={};previous=-1
    for row in accepts:
        require(row['seq']>previous and row['seq'] not in owners,'accepted age/identity');previous=row['seq'];owners[row['seq']]=row
    retired=[];traps=[];irqs=[];gold_events=[];previous=-1;lastcycle=0;irq_done=False
    for index,row in enumerate(events):
        require(row['index']==index and row['cycle']>lastcycle,'event index/cycle');lastcycle=row['cycle']
        require(m.pc%4==0 and m.pc<len(program)*4,'gold PC range')
        if m.pc==fixture['irq_mepc'] and not irq_done:gold=m.interrupt();irq_done=True
        else:gold=m.step(program[m.pc//4])
        gold_events.append(gold)
        for field in FIELDS:require(row[field]==gold[field],f'event {field} mismatch row{index}')
        if row['kind']=='retire':
            require(row['seq']>previous and row['seq'] in owners and all(row[k]==owners[row['seq']][k] for k in ('pc','instr')) and owners[row['seq']]['cycle']<row['cycle'],'retirement accepted owner')
            previous=row['seq'];retired.append(row)
        elif row['kind']=='irq':irqs.append(row)
        else:
            require(row['kind']=='trap' and row['seq'] in owners and owners[row['seq']]['pc']==row['pc'],'synchronous trap accepted owner');traps.append(row)
        require(row['instret']==m.instret,'retirement-only instret')
    require(len(irqs)==1 and irqs[0]['pc']==fixture['irq_mepc'],'IRQ fixture boundary/count')
    require([e['pc'] for e in traps]==fixture['sync_pcs'] and [e['cause'] for e in traps]==[5,7],'local precise synchronous trap count')
    require(any(r['pc']==fixture['terminal_pc'] for r in retired),'terminal retirement missing')
    require(not any(r['pc'] in fixture['wrongpath_pcs'] for r in retired),'wrongpath retirement')
    require(len(wb)==len(retired),'WB closure')
    for index,(row,old) in enumerate(zip(wb,retired)):
        require(row['index']==index and row['cycle']>old['cycle'],'WB cycle/index')
        for field in ('seq','pc','instr','rd','value','writes','nextpc'):require(row[field]==old[field],f'WB {field} mismatch')
    arch={r['seq']:r for r in events if r['kind']!='irq'}
    present={};requests={};responses={};ordinal=0;pending=None
    for row in drows:
        seq=row['seq'];require(seq in arch,'D accepted architectural owner')
        if row['event']=='present':
            require(seq not in present and ordinal<len(m.accesses),'D duplicate presentation')
            gold=m.accesses[ordinal];ordinal+=1;present[seq]=(row,gold)
            require(row['cycle']<=arch[seq]['cycle'],'D presentation lifetime')
        else:
            require(seq in present,'D action lacks first presentation');gold=present[seq][1]
            if row['event']=='req':
                require(seq not in requests and pending is None,'D duplicate request/owner overwrite');requests[seq]=row;pending=seq
                require(row['cycle']>=present[seq][0]['cycle'],'D acceptance before presentation')
            else:
                require(row['event']=='rsp' and seq in requests and pending==seq and seq not in responses,'D response owner');responses[seq]=row;pending=None
                require(row['rdata']==gold['rdata'] and row['error']==gold['error'],'D response data/error')
                require(requests[seq]['cycle']<row['cycle']<=arch[seq]['cycle'],'D response lifetime')
        for field in ('pc','addr','wdata','wstrb','size','is_write'):require(row[field]==gold[field],f'D {field} mismatch')
    require(ordinal==len(m.accesses) and pending is None and set(present)==set(requests)==set(responses),'D ledger closure')
    exp_ext=[r for r in drows if r['event'] in ('req','rsp') and not 0x20000000<=r['addr']<0x20000100]
    require(external==exp_ext,'external route ledger mismatch')
    require(len(local)==len(m.effects)==m.local_index,'local endpoint execution closure')
    for row,gold in zip(local,m.effects):
        for field in ('pc','addr','wdata','wstrb','size','is_write','tx','pop','gpio'):require(row[field]==gold[field],f'local {field} mismatch')
        require(row['rdata']==gold['expected_rdata'] and row['error']==gold['expected_error'],'local read/error mismatch')
        require(row['seq'] in requests and requests[row['seq']]['cycle']<row['cycle']<responses[row['seq']]['cycle'],'local captured descriptor lifetime')
    require(m.rx==[] and m.tx==[0x51] and m.gpio==0x58 and m.oe==0xff,'device effects final state')
    require(sum(r['pop'] for r in local)==2 and sum(r['tx'] for r in local)==1 and sum(r['gpio'] for r in local)==5,'device effect counts')
    stats=next(r for r in retired if r['pc']==fixture['stats_pc'])
    stats_request=next(r for r in requests.values() if r['pc']==fixture['stats_pc'])
    require(irqs[0]['cycle']==stats['cycle']+1,'IRQ first safe edge after IO retirement')
    p1=p2=arm=0;status=0x1800;mie=0;bycycle={r['cycle']:r for r in events}
    for index,row in enumerate(cycles):
        cycle=index+1;require(row['cycle']==cycle,'contiguous cycles')
        raw=int(stats_request['cycle']<cycle<=irqs[0]['cycle'])
        require(row['raw']==raw,'raw source fixture schedule')
        require(row['pending']==p2,'two-flop pending mismatch')
        require(row['mstatus']==status and row['mie']==mie,'pre-edge committed CSR')
        eligible=int(bool(status&8 and mie&p2));take=int(bool(arm and eligible and cycle>stats['cycle']))
        require(row['arm']==arm and row['eligible']==eligible,'old arm/current eligible mismatch')
        require(row['take']==take,'IRQ independently calculated safe edge')
        event=bycycle.get(cycle)
        if event:status=event['mstatus'];mie=event['mie']
        arm=0 if event and event['kind'] in ('irq','trap') else int(bool(status&8 and mie&p2))
        p2,p1=p1,0x800 if raw else 0
    expected_ram=[int.from_bytes(m.memory[i:i+4],'little') for i in range(0,len(m.memory),4)]
    require(read_hex(directory/'actual_ram_final.hex')==expected_ram,'complete RAM mismatch')
    final=(directory/'actual_gpr_final.hex').read_text(encoding='ascii').splitlines();require(len(final)==32,'complete GPR observations')
    for i,value in enumerate(m.gpr):require(final[i].lower()==('xxxxxxxx' if value is None else f'{value:08x}'),f'final GPR x{i} mismatch')
    ipending=None;iq=ir=0
    for row in ifrows:
        if row['event']=='req':require(ipending is None,'IF overwrite');ipending=row['addr'];iq+=1
        else:require(row['event']=='rsp' and ipending==row['addr'],'IF response owner');ipending=None;ir+=1
    require(ipending is None and iq==ir,'IF ledger closure')
    counts=dict(events=len(events),retired=len(retired),wb_packets=len(wb),irqs=len(irqs),sync_traps=len(traps),accepted=len(accepts),
                d_requests=len(requests),d_responses=len(responses),requests=iq,responses=ir,local_effects=len(local),tx_events=1,rx_pops=2,gpio_writes=5)
    for key,value in counts.items():require(type(metrics.get(key)) is int and metrics[key]==value,f'metric {key} mismatch')
    require(metrics['cycles']==len(cycles) and metrics['tx_physical']==0x51 and metrics['tx_frames']==1,'physical TX frame/metrics')
    require(stats['cycle']-stats_request['cycle']>=10,'IO IRQ blocking coverage')
    return dict(status='PASS',**counts,cycles=len(cycles),defined_gpr=sum(x is not None for x in m.gpr),unchanged_unknown_gpr=sum(x is None for x in m.gpr),cycle_checks=len(cycles),irq_after_io_cycle=irqs[0]['cycle'])


def analyze(directory):
    program=read_hex(directory/'program.hex');initial=read_hex(directory/'ram_initial.hex');fixture=json.loads((directory/'fixture.json').read_text())
    paths=sorted((directory/'cases').glob('case*'),key=lambda p:int(p.name[4:]))
    require([p.name for p in paths]==[f'case{i}' for i in range(16)],'sixteen matrix cases required')
    cases=[dict(case=i,id_mode=i%2,predict=(i//2)%2,wait=(i//4)%2,forwarding=i//8,**audit_case(path,program,initial,fixture)) for i,path in enumerate(paths)]
    sums={f'total_{key}':sum(c[key] for c in cases) for key in ('retired','wb_packets','irqs','sync_traps','d_requests','d_responses','local_effects','requests','responses','tx_events','rx_pops','gpio_writes','cycle_checks')}
    return dict(status='PASS',scope='CPU5 ordered devices and physical UART/GPIO real IF program',case_count=len(cases),cases=cases,decoder_selftest=selftest_decoder(),**sums)


def selftest_evidence(directory):
    source=directory/'cases/case0';scratch=directory.parent/(directory.name+'_negative_evidence');scratch.mkdir(exist_ok=True)
    program=read_hex(directory/'program.hex');initial=read_hex(directory/'ram_initial.hex');fixture=json.loads((directory/'fixture.json').read_text())
    protected=[p for p in directory.rglob('*') if p.is_file() and p.name not in ('verification.json','analysis.json')]
    def hashes():return {p.relative_to(directory).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
    before=hashes();rejected=[]
    tests=[('irq_mepc','events.csv','event pc mismatch'),('trap_cause','events.csv','event cause mismatch'),('counter_value','events.csv','event value mismatch'),
           ('wb_data','wb.csv','WB value mismatch'),('d_response','d.csv','D response data/error'),('route','external.csv','external route ledger mismatch'),
           ('pop','local.csv','local pop mismatch'),('gpio','local.csv','local gpio mismatch'),('pending','cycles.csv','two-flop pending mismatch'),
           ('take','cycles.csv','IRQ independently calculated safe edge'),('ram','actual_ram_final.hex','complete RAM mismatch'),('gpr','actual_gpr_final.hex','final GPR x8 mismatch')]
    for name,filename,reason in tests:
        target=scratch/name;shutil.copytree(source,target,dirs_exist_ok=True);changed=target/filename
        if filename.endswith('.csv'):
            with changed.open(newline='',encoding='ascii') as stream:reader=csv.DictReader(stream);header=reader.fieldnames;rows=list(reader)
            if name=='irq_mepc':row=next(r for r in rows if r['kind']=='irq');field='pc'
            elif name=='trap_cause':row=next(r for r in rows if r['kind']=='trap');field='cause'
            elif name=='counter_value':row=next(r for r in rows if r['kind']=='retire' and r['instr']=='00012503');field='value'
            elif name=='wb_data':row=rows[0];field='value'
            elif name=='d_response':row=next(r for r in rows if r['event']=='rsp');field='rdata'
            elif name=='route':row=rows[0];field='addr'
            elif name in ('pop','gpio'):row=next(r for r in rows if r[name]=='1');field=name
            elif name=='pending':row=next(r for r in rows if r['pending']!='00000000');field='pending'
            else:row=next(r for r in rows if r['take']=='1');field='take'
            row[field]=f'{int(row[field],16)^1:08x}' if field in HEX else str(int(row[field])^1)
            with changed.open('w',newline='',encoding='ascii') as stream:writer=csv.DictWriter(stream,fieldnames=header,lineterminator='\n');writer.writeheader();writer.writerows(rows)
        else:
            rows=changed.read_text().splitlines();i=8 if name=='gpr' else 0;rows[i]=f'{int(rows[i],16)^1:08x}';changed.write_text('\n'.join(rows)+'\n',encoding='ascii')
        try:audit_case(target,program,initial,fixture)
        except ValueError as e:require(reason in str(e),f'negative {name} unintended rejection: {e}');message=str(e)
        else:raise ValueError(f'negative {name} accepted')
        rejected.append(dict(name=name,status='REJECTED',reason=message,good_sha256=hashlib.sha256((source/filename).read_bytes()).hexdigest(),bad_sha256=hashlib.sha256(changed.read_bytes()).hexdigest()))
    require(before==hashes(),'negative copies modified good inputs')
    result=dict(status='PASS',rejected_count=len(rejected),rejected=rejected,good_inputs_unchanged=True)
    (scratch/'summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');return result
