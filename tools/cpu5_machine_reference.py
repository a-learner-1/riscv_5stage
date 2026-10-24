"""Independent RV32 machine-word, machine-device and owner-ledger oracle.

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
LOCAL_HEADER=('target','cycle','seq','pc','addr','wdata','wstrb','size','is_write','rdata','error','timer_write','software_write','gpio')
IF_HEADER=('event','cycle','addr')
CYCLE_HEADER=('cycle','raw','device_timer','device_software','pending','arm','eligible','take','mstatus','mie','mtime_lo','mtime_hi','cmp_lo','cmp_hi','msip')
HEX={'seq','pc','instr','value','nextpc','cause','tval','addr','wdata','wstrb','rdata','pending','mtime_lo','mtime_hi','cmp_lo','cmp_hi',*CSRS}


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
                if k in ('event','kind','target'): row[k]=v
                else:
                    try: row[k]=int(v,16 if k in HEX else 10)
                    except ValueError as e: raise ValueError(f'{path.name}: invalid {k}') from e
                    require(row[k]>=0 and (k not in HEX or row[k]<=(0xffffffffffffffff if k=='seq' else MASK)),f'{path.name}: invalid range {k}')
            result.append(row)
    return result


MASK64=(1<<64)-1
TIMER_ADDRS=(0x20000040,0x20000044,0x20000048,0x2000004c)


def advance_devices(mtime,compare,msip,event):
    tick=(mtime+1)&MASK64
    if event and event['is_write'] and event['size']==2 and event['addr']%4==0 and event['wstrb']==15:
        a,v=event['addr'],event['wdata']
        if a==0x20000040:tick=(mtime&0xffffffff00000000)|v
        elif a==0x20000044:tick=(v<<32)|(mtime&MASK)
        elif a==0x20000048:compare=(compare&0xffffffff00000000)|v
        elif a==0x2000004c:compare=(v<<32)|(compare&MASK)
        elif a==0x20000050:msip=v&1
    return tick,compare,msip


def device_timeline(cycles,local,events,fixture):
    irq=[r for r in events if r['kind']=='irq'];require(len(irq)==4,'four device IRQ events required')
    writes={r['cycle']:r for r in local if r['target']=='machine'}
    require(len(writes)==sum(r['target']=='machine' for r in local),'one machine execution per edge')
    enabled=next(r['cycle'] for r in local if r['pc']==fixture['priority_set_pc'])
    mtime=0;compare=MASK64;msip=p1=p2=0;states={}
    for index,row in enumerate(cycles):
        cycle=index+1;require(row['cycle']==cycle,'contiguous cycles')
        require(((row['mtime_hi']<<32)|row['mtime_lo'])==mtime,'timer pre-edge mtime mismatch')
        require(((row['cmp_hi']<<32)|row['cmp_lo'])==compare,'timer pre-edge comparator mismatch')
        require(row['msip']==msip and row['device_software']==msip,'software device level mismatch')
        timer=int(mtime>=compare);require(row['device_timer']==timer,'timer unsigned level mismatch')
        raw=int(enabled<cycle<=irq[1]['cycle']);require(row['raw']==raw,'external raw source schedule')
        require(row['pending']==p2,'two-flop pending mismatch')
        states[cycle]=dict(mtime=mtime,compare=compare,msip=msip,pending=p2,raw=raw,timer=timer)
        mtime,compare,msip=advance_devices(mtime,compare,msip,writes.get(cycle))
        p2,p1=p1,(0x800 if raw else 0)|(0x80 if timer else 0)|(8 if states[cycle]['msip'] else 0)
    return states


class Machine(CSRMachine):
    def __init__(self,initial,local_rows,timeline):
        super().__init__();self.mie=0
        self.memory=bytearray(b''.join(x.to_bytes(4,'little') for x in initial))
        self.local_rows=local_rows;self.timeline=timeline;self.local_index=0;self.cycle=0
        self.gpio=0;self.accesses=[];self.effects=[]

    def finish(self,pc,word,rd,value,nextpc=None,access=None):
        value &= MASK
        if rd:self.gpr[rd]=value
        self.pc=(pc+4)&MASK if nextpc is None else nextpc;self.instret+=1
        return dict(kind='retire',pc=pc,instr=word,rd=rd,value=value,writes=int(rd!=0),nextpc=self.pc,cause=0,tval=0,**self.csr,mie=self.mie,access=access)

    def fault(self,pc,word,cause,tval,access):
        old=self.csr['mstatus'];self.csr.update(mstatus=0x1800|((old&8)<<4),mepc=pc,mcause=cause,mtval=tval)
        self.pc=self.csr['mtvec']
        return dict(kind='trap',pc=pc,instr=word,rd=0,value=0,writes=0,nextpc=self.pc,cause=cause,tval=tval,**self.csr,mie=self.mie,access=access)

    def interrupt(self,cause):
        pc=self.pc;old=self.csr['mstatus'];require(old&8,'gold IRQ committed MIE')
        self.csr.update(mstatus=0x1800|((old&8)<<4),mepc=pc,mcause=cause,mtval=0);self.pc=self.csr['mtvec']
        return dict(kind='irq',pc=pc,instr=0,rd=0,value=0,writes=0,nextpc=self.pc,cause=cause,tval=0,**self.csr,mie=self.mie,access=None)

    def step(self,word):
        pc=self.pc;op=word&127;f=(word>>12)&7;rd=(word>>7)&31;a=(word>>15)&31;b=(word>>20)&31
        if op in (3,0x23):
            write=op==0x23;imm=(((word>>25)<<5)|((word>>7)&31)) if write else word>>20
            if imm&2048:imm-=4096
            addr=(self.operand(a)+imm)&MASK;size=0 if f in (0,4) else 1 if f in (1,5) else 2
            raw=self.operand(b) if write else 0;data=(raw<<(8*(addr&3)))&MASK;strobe=((1<<(1<<size))-1)<<(addr&3) if write else 0
            result=0;error=0;access=dict(pc=pc,instr=word,addr=addr,wdata=data,wstrb=strobe,size=size,is_write=int(write),rdata=0,error=0)
            if 0x10000<=addr<=0x10000+len(self.memory)-(1<<size):
                offset=addr-0x10000;aligned=offset&~3;result=int.from_bytes(self.memory[aligned:aligned+4],'little')
                if write:self.memory[offset:offset+(1<<size)]=(raw&((1<<(8*(1<<size)))-1)).to_bytes(1<<size,'little')
            elif 0x20000000<=addr<0x20000100:
                require(self.local_index<len(self.local_rows),'local execution missing')
                row=self.local_rows[self.local_index];self.local_index+=1
                require(row['pc']==pc and row['addr']==addr,'local execution machine-word owner')
                timer_write=software_write=gpio=0;target='machine' if 0x20000040<=addr<0x20000054 else 'normal'
                legal=(size==2 and addr%4==0)
                if target=='machine':
                    state=self.timeline[row['cycle']]
                    legal=legal and addr in (*TIMER_ADDRS,0x20000050)
                    if legal:
                        if write:timer_write=int(addr in TIMER_ADDRS);software_write=int(addr==0x20000050)
                        elif addr==0x20000050:result=state['msip']
                        elif addr in (0x20000040,0x20000044):result=(state['mtime']>>(32 if addr&4 else 0))&MASK
                        else:result=(state['compare']>>(32 if addr&4 else 0))&MASK
                else:
                    legal=legal and addr==0x20000020
                    if legal:
                        if write:self.gpio=raw&255;gpio=1
                        else:result=self.gpio
                error=int(not legal)
                self.effects.append(dict(**access,target=target,cycle=row['cycle'],timer_write=timer_write,software_write=software_write,gpio=gpio,expected_rdata=result,expected_error=error))
            else:raise ValueError(f'gold unsupported access {addr:08x}')
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
            require(taken is not None,'gold branch subset');return self.finish(pc,word,0,0,(pc+(imm if taken else 4))&MASK)
        if op==0x73 and f in (1,2,3,5,6,7):
            addr=word>>20
            if addr in (0x304,0x344,0x301):
                old=self.mie if addr==0x304 else self.timeline[self.cycle]['pending'] if addr==0x344 else 0x40001100
                source=a if f&4 else self.operand(a)
                if addr==0x304 and (f in (1,5) or a):self.mie=(source if f&3==1 else old|source if f&3==2 else old&~source)&0x888
                return self.finish(pc,word,rd,old)
        event=super().step(word);return dict(**event,mie=self.mie,access=None)


def selftest_decoder():
    m=Machine([0]*64,[],{0:dict(pending=0x888)});checks=0
    for word,value in ((0x000100b7,0x10000),(0x20000137,0x20000000),(0x800002b7,0x80000000)):
        require(m.step(word)['value']==value,'fixed LUI');checks+=1
    m.gpr[5]=0x888;require(m.step(0x30429073)['mie']==0x888,'fixed mie');checks+=1
    require(m.step(0x344023f3)['value']==0x888,'fixed mip read');checks+=1
    require(m.step(0x34401073)['value']==0x888,'fixed mip write ignored');checks+=1
    m.gpr[3]=49;require(m.step(0x0030a023)['writes']==0,'fixed RAM store');checks+=1
    require(m.step(0x0000a203)['value']==49,'fixed RAM load');checks+=1
    require(m.step(0x30102f73)['value']==0x40001100,'fixed integrated M misa');checks+=1
    m.csr['mstatus']=0x1808;pc=m.pc;e=m.interrupt(0x80000003);require(e['mepc']==pc and e['mstatus']==0x1880,'fixed software IRQ');checks+=1
    require(m.step(0x30200073)['nextpc']==pc,'fixed MRET');checks+=1
    require(advance_devices(0xffffffff, MASK64,0,None)[0]==0x100000000,'fixed mtime carry');checks+=1
    require(advance_devices(MASK64,MASK64,0,None)[0]==0,'fixed mtime wrap');checks+=1
    event=dict(is_write=1,size=2,addr=0x20000040,wstrb=15,wdata=7)
    require(advance_devices(0x1ffffffff,0,0,event)[0]==0x100000007,'fixed mtime write replaces increment');checks+=1
    event.update(addr=0x20000050,wdata=0xfffffffe)
    require(advance_devices(5,10,1,event)==(6,10,0),'fixed software low-bit write');checks+=1
    local=[dict(pc=0,addr=0x20000050,cycle=10),dict(pc=4,addr=0x20000050,cycle=14),
           dict(pc=8,addr=0x20000040,cycle=18),dict(pc=12,addr=0x20000048,cycle=22),dict(pc=16,addr=0x20000040,cycle=26)]
    state={c:dict(mtime=0x100000007,compare=0x100000010,msip=1,pending=8) for c in (10,14,18,22,26)}
    io=Machine([0]*64,local,state);io.gpr[2]=0x20000000;io.gpr[3]=1
    require(io.step(0x04312823)['writes']==0 and io.effects[-1]['software_write']==1,'fixed software SW');checks+=1
    require(io.step(0x05012303)['value']==1,'fixed software LW');checks+=1
    require(io.step(0x04012483)['value']==7,'fixed pre-edge mtime LW');checks+=1
    require(io.step(0x04812583)['value']==16,'fixed comparator LW');checks+=1
    fault=io.step(0x04010983)
    require(fault['kind']=='trap' and fault['cause']==5 and fault['tval']==0x20000040 and fault['mepc']==16,'fixed illegal machine LB');checks+=1
    return dict(status='PASS',fixed_word_checks=checks-5,device_state_checks=5,total_checks=checks)


def audit_case(directory,program,initial,fixture):
    events=read_csv(directory/'events.csv',EVENT_HEADER);accepts=read_csv(directory/'accept.csv',ACCEPT_HEADER)
    wb=read_csv(directory/'wb.csv',WB_HEADER);drows=read_csv(directory/'d.csv',D_HEADER)
    external=read_csv(directory/'external.csv',D_HEADER);local=read_csv(directory/'local.csv',LOCAL_HEADER)
    ifrows=read_csv(directory/'if.csv',IF_HEADER);cycles=read_csv(directory/'cycles.csv',CYCLE_HEADER)
    metrics=json.loads((directory/'metrics.json').read_text());timeline=device_timeline(cycles,local,events,fixture);m=Machine(initial,local,timeline)
    owners={};previous=-1
    for row in accepts:
        require(row['seq']>previous and row['seq'] not in owners,'accepted age/identity');previous=row['seq'];owners[row['seq']]=row
    retired=[];traps=[];irqs=[];gold_events=[];previous=-1;lastcycle=0;irq_index=0
    for index,row in enumerate(events):
        require(row['index']==index and row['cycle']>lastcycle,'event index/cycle');lastcycle=row['cycle']
        require(m.pc%4==0 and m.pc<len(program)*4,'gold PC range')
        m.cycle=row['cycle']
        if (irq_index==0 and m.pc==fixture['first_mepc']) or (1<=irq_index<=3 and m.pc==fixture['priority_mepc']):
            gold=m.interrupt(fixture['irq_causes'][irq_index]);irq_index+=1
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
    require([r['cause'] for r in irqs]==fixture['irq_causes'] and [r['pc'] for r in irqs]==[fixture['first_mepc']]+[fixture['priority_mepc']]*3,'IRQ fixture boundary/count')
    require([e['pc'] for e in traps]==fixture['sync_pcs'] and [e['cause'] for e in traps]==[5],'local precise synchronous trap count')
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
        for field in ('target','pc','addr','wdata','wstrb','size','is_write','timer_write','software_write','gpio'):require(row[field]==gold[field],f'local {field} mismatch')
        require(row['rdata']==gold['expected_rdata'] and row['error']==gold['expected_error'],'local read/error mismatch')
        require(row['seq'] in requests and requests[row['seq']]['cycle']<row['cycle']<responses[row['seq']]['cycle'],'local captured descriptor lifetime')
    require(m.gpio==0x77,'device GPIO final state')
    irq_enable=[next(r for r in retired if r['pc']==pc-4) for pc in (fixture['first_mepc'],fixture['priority_mepc'])]
    require(irqs[0]['cycle']==irq_enable[0]['cycle']+1 and irqs[1]['cycle']==irq_enable[1]['cycle']+1,'IRQ next edge after committed CSR enable')
    gold_bycycle={row['cycle']:gold for row,gold in zip(events,gold_events)}
    arm=0;status=0x1800;mie=0
    for row in cycles:
        cycle=row['cycle'];pending=timeline[cycle]['pending']
        require(row['mstatus']==status and row['mie']==mie,'pre-edge committed CSR')
        eligible=int(bool(status&8 and mie&pending));take=int(bool(arm and eligible))
        require(row['arm']==arm and row['eligible']==eligible,'old arm/current eligible mismatch')
        require(row['take']==take,'IRQ independently calculated safe edge')
        gold=gold_bycycle.get(cycle)
        require((gold is not None and gold['kind']=='irq')==bool(take),'IRQ expected architectural edge')
        if gold:status=gold['mstatus'];mie=gold['mie']
        arm=0 if gold and gold['kind'] in ('irq','trap') else int(bool(status&8 and mie&pending))
    bycycle={r['cycle']:r for r in retired}
    for irq in irqs[2:]:
        previous=bycycle.get(irq['cycle']-1)
        require(previous and previous['instr']==0x30200073,'remaining pending must take immediately after MRET')
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
                d_requests=len(requests),d_responses=len(responses),requests=iq,responses=ir,
                device_effects=sum(r['target']=='machine' for r in local),timer_writes=sum(r['timer_write'] for r in local),
                software_writes=sum(r['software_write'] for r in local),normal_effects=sum(r['target']=='normal' for r in local),gpio_writes=sum(r['gpio'] for r in local))
    for key,value in counts.items():require(type(metrics.get(key)) is int and metrics[key]==value,f'metric {key} mismatch')
    require(metrics['cycles']==len(cycles),'complete cycle metrics')
    require(timeline[len(cycles)]['msip']==0 and timeline[len(cycles)]['timer']==0,'machine sources not cleared')
    return dict(status='PASS',**counts,cycles=len(cycles),defined_gpr=sum(x is not None for x in m.gpr),unchanged_unknown_gpr=sum(x is None for x in m.gpr),cycle_checks=len(cycles),immediate_post_mret_irqs=2)


def analyze(directory):
    program=read_hex(directory/'program.hex');initial=read_hex(directory/'ram_initial.hex');fixture=json.loads((directory/'fixture.json').read_text())
    paths=sorted((directory/'cases').glob('case*'),key=lambda p:int(p.name[4:]))
    require([p.name for p in paths]==[f'case{i}' for i in range(16)],'sixteen matrix cases required')
    cases=[dict(case=i,id_mode=i%2,predict=(i//2)%2,wait=(i//4)%2,forwarding=i//8,**audit_case(path,program,initial,fixture)) for i,path in enumerate(paths)]
    sums={f'total_{key}':sum(c[key] for c in cases) for key in ('retired','wb_packets','irqs','sync_traps','d_requests','d_responses','device_effects','requests','responses','timer_writes','software_writes','normal_effects','gpio_writes','cycle_checks')}
    return dict(status='PASS',scope='CPU5 machine timer/software devices and prioritized IRQ real IF program',case_count=len(cases),cases=cases,decoder_selftest=selftest_decoder(),**sums)


def selftest_evidence(directory):
    source=directory/'cases/case0';scratch=directory.parent/(directory.name+'_negative_evidence');scratch.mkdir(exist_ok=True)
    program=read_hex(directory/'program.hex');initial=read_hex(directory/'ram_initial.hex');fixture=json.loads((directory/'fixture.json').read_text())
    protected=[p for p in directory.rglob('*') if p.is_file() and p.name not in ('verification.json','analysis.json')]
    def hashes():return {p.relative_to(directory).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
    before=hashes();rejected=[]
    tests=[('irq_mepc','events.csv','event pc mismatch'),('irq_cause','events.csv','event cause mismatch'),('mret_pc','events.csv','event nextpc mismatch'),
           ('mip_value','events.csv','event value mismatch'),('wb_data','wb.csv','WB value mismatch'),('d_response','d.csv','D response data/error'),
           ('route','external.csv','external route ledger mismatch'),('timer_effect','local.csv','local timer_write mismatch'),
           ('timer_state','cycles.csv','timer pre-edge mtime mismatch'),('software_level','cycles.csv','software device level mismatch'),
           ('pending','cycles.csv','two-flop pending mismatch'),('take','cycles.csv','IRQ independently calculated safe edge'),
           ('ram','actual_ram_final.hex','complete RAM mismatch'),('gpr','actual_gpr_final.hex','final GPR x18 mismatch')]
    for name,filename,reason in tests:
        target=scratch/name;shutil.copytree(source,target,dirs_exist_ok=True);changed=target/filename
        if filename.endswith('.csv'):
            with changed.open(newline='',encoding='ascii') as stream:reader=csv.DictReader(stream);header=reader.fieldnames;rows=list(reader)
            if name=='irq_mepc':row=next(r for r in rows if r['kind']=='irq');field='pc'
            elif name=='irq_cause':row=next(r for r in rows if r['kind']=='irq');field='cause'
            elif name=='mret_pc':row=next(r for r in rows if r['kind']=='retire' and r['instr']=='30200073');field='nextpc'
            elif name=='mip_value':row=next(r for r in rows if r['kind']=='retire' and r['instr']=='344023f3');field='value'
            elif name=='wb_data':row=rows[0];field='value'
            elif name=='d_response':row=next(r for r in rows if r['event']=='rsp');field='rdata'
            elif name=='route':row=rows[0];field='addr'
            elif name=='timer_effect':row=next(r for r in rows if r['timer_write']=='1');field='timer_write'
            elif name=='timer_state':row=rows[0];field='mtime_lo'
            elif name=='software_level':row=next(r for r in rows if r['device_software']=='1');field='device_software'
            elif name=='pending':row=next(r for r in rows if r['pending']!='00000000');field='pending'
            else:row=next(r for r in rows if r['take']=='1');field='take'
            row[field]=f'{int(row[field],16)^1:08x}' if field in HEX else str(int(row[field])^1)
            with changed.open('w',newline='',encoding='ascii') as stream:writer=csv.DictWriter(stream,fieldnames=header,lineterminator='\n');writer.writeheader();writer.writerows(rows)
        else:
            rows=changed.read_text().splitlines();i=18 if name=='gpr' else 0;rows[i]=f'{int(rows[i],16)^1:08x}';changed.write_text('\n'.join(rows)+'\n',encoding='ascii')
        try:audit_case(target,program,initial,fixture)
        except ValueError as e:require(reason in str(e),f'negative {name} unintended rejection: {e}');message=str(e)
        else:raise ValueError(f'negative {name} accepted')
        rejected.append(dict(name=name,status='REJECTED',reason=message,good_sha256=hashlib.sha256((source/filename).read_bytes()).hexdigest(),bad_sha256=hashlib.sha256(changed.read_bytes()).hexdigest()))
    require(before==hashes(),'negative copies modified good inputs')
    result=dict(status='PASS',rejected_count=len(rejected),rejected=rejected,good_inputs_unchanged=True)
    (scratch/'summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8');return result
