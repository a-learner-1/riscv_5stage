"""Independent machine-word, per-edge cycle classification and Stats window gold.

The ISA/cache/native/physical-RAM oracle remains the immutable S15 reference.
The new classification model derives producer dependencies from machine words;
observed perf bits never supply expected classifications or snapshot values.
"""
from __future__ import annotations
import csv
import hashlib
import json
from pathlib import Path
import shutil
import cpu5_d0_reference as architectural

require=architectural.require
selftest_decoder=architectural.selftest_decoder
NAMES=('work_other','ifetch_wait','data_read_wait','data_write_wait','local_mmio_wait',
       'redirect_wait','mul_wait','div_wait','load_use_wait','id_hazard_wait')
HEX={'count_pre','count_post','events_pre','events_post','id_instr','ex_instr','mem_instr','wb_instr',
     'id_seq','ex_seq','mem_seq','wb_seq','mem_addr','d_seq','d_addr','d_complete_seq','d_complete_addr',
     'm_seq','m_complete_seq','ex_addr','araddr','rdata'}


def rows(path):
    with path.open(newline='',encoding='ascii') as stream:
        reader=csv.DictReader(stream)
        require(reader.fieldnames is not None and len(reader.fieldnames)==len(set(reader.fieldnames)),path.name+': unique header')
        result=[]
        for r in reader:
            require(None not in r and all(v is not None and v==v.strip() and v for v in r.values()),path.name+': exact fields')
            try:r={k:int(v,16 if k in HEX else 10) for k,v in r.items()}
            except ValueError as error:raise ValueError(path.name+': unknown or malformed raw signal') from error
            require(all(v>=0 for v in r.values()),path.name+': negative raw signal')
            result.append(r)
    return result


def decode(word):
    """Only machine-word ISA fields; no hardware decode/helper flags."""
    op=word&127;f3=(word>>12)&7;rd=(word>>7)&31;a=(word>>15)&31;b=(word>>20)&31
    load=op==3 and f3 in (0,1,2,4,5);store=op==35 and f3 in (0,1,2)
    branch=op==99 and f3 in (0,1,4,5,6,7);jalr=op==103 and f3==0
    csr=op==115 and f3 in (1,2,3,5,6,7);mret=word==0x30200073
    fence=op==15 and f3==0;m=op==51 and word>>25==1
    alu=op in (19,51,55,23);jal=op==111
    use1=load or store or branch or jalr or (alu and op in (19,51)) or (csr and not(f3&4)) or m
    use2=store or branch or op==51
    writes=(load or jalr or jal or alu or csr or m) and rd!=0
    return dict(op=op,f3=f3,rd=rd,rs1=a,rs2=b,use1=use1,use2=use2,writes=writes,
                load=load,store=store,branch=branch,jalr=jalr,csr=csr,mret=mret,fence=fence,m=m,
                supported=load or store or branch or jalr or csr or mret or fence or alu or jal or word in (0x73,0x100073))


def classify(row,forwarding,id_mode,recovery):
    instructions={s:decode(row[s+'_instr']) for s in ('id','ex','mem','wb')}
    i,x,m,w=(instructions[s] for s in ('id','ex','mem','wb'))
    live={s:bool(row[s+'_valid'] and (s=='wb' or not row['kill_'+s])) for s in ('id','ex','mem','wb')}
    writer={s:live[s] and instructions[s]['writes'] for s in ('ex','mem','wb')}
    if row['ex_error']:writer['ex']=False
    sources=lambda ins:[ins['rs1']] * bool(ins['use1']) + [ins['rs2']] * bool(ins['use2'])
    def nearest(source,stages):
        return next((s for s in stages if source!=0 and writer[s] and instructions[s]['rd']==source),None)
    mem_available=bool(row['mem_ready'] and not row['mem_error'])
    ex_stall=bool(forwarding and live['ex'] and x['supported'] and not row['ex_error'] and
                  any(nearest(a,('mem','wb'))=='mem' and not mem_available for a in sources(x)))
    branch_stall=bool(live['id'] and not row['id_error'] and id_mode and (i['branch'] or i['jalr'] or i['op']==111) and
                      any((nearest(a,('ex','mem','wb'))=='ex') or
                          (nearest(a,('ex','mem','wb'))=='mem' and not mem_available) for a in sources(i)))
    serial=bool(row['id_valid'] and (i['csr'] or i['mret']) and
                any(live[s] and (instructions[s]['csr'] or instructions[s]['mret']) for s in ('ex','mem')))
    no_forward_raw=bool(not forwarding and row['id_valid'] and not row['id_error'] and i['supported'] and
                        any(nearest(a,('ex','mem','wb')) is not None for a in sources(i)))
    id_raw=no_forward_raw or branch_stall or serial
    # These raw path signals are cross-checks, never expected category inputs.
    if not row['mem_fault'] and not row['ex_error'] and not row['known_ex_fault']:
        require(row['ex_stall']==int(ex_stall),'independent EX producer readiness')
        require(row['branch_stall']==int(branch_stall),'independent ID branch dependency')
        require(row['csr_serial']==int(serial),'independent CSR serial dependency')
        require(row['id_raw']==int(id_raw),'independent ID source dependency')
    hard=bool(row['trap'] or row['mret'] or row['irq'] or row['mem_fault'])
    wb_open=not row['wb_valid'] or row['wb_ready']
    mem_open=bool(row['mem_enable'] and wb_open and not row['kill_mem'] and not hard)
    d_complete=bool(row['d_state']==3 or (row['d_state']==2 and row['d_rsp_valid']))
    require(row['d_complete']==int(d_complete),'independent D completion availability')
    matching=bool(row['mem_valid'] and d_complete and row['d_complete_seq']==row['mem_seq'] and not row['d_complete_killed'])
    owned=bool(row['d_valid'] and row['d_seq']==row['mem_seq'])
    nonram=not 0x10000<=row['mem_addr']<0x10100
    mem_request=bool(live['mem'] and (m['store'] or (m['load'] and nonram)) and row['mem_enable'] and
                     not row['mem_error'] and not row['flush'] and not row['mem_fault'] and not row['irq'] and not owned)
    mem_data=bool(row['mem_valid'] and mem_open and (m['load'] or m['store']) and not matching and (owned or mem_request))
    fence=bool(live['mem'] and m['fence'])
    fence_data=bool(fence and mem_open and row['d_valid'])
    mem_can=not row['mem_valid'] or row['kill_mem'] or row['retire'] or row['trap'] or row['irq']
    m_complete=bool(row['m_valid'] and (row['m_state']==2 or (row['m_state']==1 and row['m_done'])))
    require(row['m_complete']==int(m_complete),'independent M completion availability')
    m_match=bool(m_complete and row['ex_valid'] and row['m_complete_seq']==row['ex_seq'] and not row['m_complete_killed'])
    ex_base=bool(live['ex'] and not row['trap'] and not row['mret'] and row['ex_enable'] and mem_can and
                 not row['irq'] and not fence and (not x['m'] or row['ex_error'] or m_match) and
                 (not forwarding or not ex_stall) and not row['flush'])
    ex_load=bool(x['load'] and not row['ex_error'] and not row['ex_ram_fault'] and ex_base and not row['ex_ram_out'])
    completion_ack=matching and (row['retire'] or row['trap'])
    old_ram=0x10000<=row['d_addr']<0x10100
    turnover=bool(row['d_valid'] and not row['d_store'] and d_complete and old_ram and
                  not row['d_complete_error'] and not row['d_killed'] and completion_ack)
    ex_data=bool(ex_load and not (not row['d_valid'] or turnover))
    if mem_data or fence_data or ex_data:
        if mem_data:address=row['mem_addr'];write=m['store']
        elif fence_data or (ex_data and row['d_valid']):address=row['d_addr'];write=row['d_store']
        else:address=row['ex_addr'];write=False
        return 4 if address>>8==0x200000 else 3 if write else 2
    older_risk=bool(live['mem'] and (row['mem_fault'] or m['load'] or m['store'] or m['csr'] or m['mret']))
    m_wait=bool(live['ex'] and x['supported'] and x['m'] and not row['ex_error'] and row['ex_enable'] and
                mem_can and not fence and not older_risk and (not forwarding or not ex_stall) and
                not m_match and not row['flush'] and not hard)
    if m_wait:return 7 if x['f3']&4 else 6
    ex_can=not row['ex_valid'] or row['kill_ex'] or row['ex_move'] or row['trap'] or row['mret'] or row['irq']
    id_wait=bool(live['id'] and row['id_enable'] and i['supported'] and not row['id_error'] and not hard and
                 mem_can and ex_can and not row['redirect'] and not row['flush'] and not(id_mode and row['known_ex_fault']) and id_raw)
    if id_wait:
        for a in sources(i):
            producer=nearest(a,('ex','mem','wb'))
            if producer is None:continue
            unavailable=not forwarding or (id_mode and (i['branch'] or i['jalr'] or i['op']==111) and
                                           (producer=='ex' or (producer=='mem' and not row['mem_ready'])))
            if unavailable and instructions[producer]['load']:return 8
        return 9
    if mem_can and not row['id_valid'] and row['id_ready']:return 5 if recovery else 1
    return 0


def audit_profile(directory,forwarding,id_mode):
    trace=rows(directory/'profile.csv');bus=rows(directory/'stats.csv')
    require(len(trace)==len(bus)>0,'complete CPU/Stats edge traces')
    retired=architectural.read_csv(directory/'events.csv',architectural.EVENT_HEADER)
    retired={r['cycle']:r for r in retired if r['kind']=='retire'}
    accepted={r['seq']:r for r in architectural.read_csv(directory/'accept.csv',architectural.ACCEPT_HEADER)}
    descriptors={r['seq']:r for r in architectural.read_csv(directory/'d.csv',architectural.D_HEADER) if r['event']=='present'}
    totals=[0]*10;previous=0;recovery=False;categories=[];pending=None;starts=[];stops=[]
    start=stop=None;reads=responses=holds=0;words=set();instret=0
    for edge,(row,axi) in enumerate(zip(trace,bus),1):
        require(row['cycle']==axi['cycle']==edge,'contiguous profile/Stats cycles')
        require(row['count_pre']==edge-1 and row['count_post']==edge,'CPU count/event edge alignment')
        require(row['d_valid']==int(row['d_state']!=0),'CPU D owner state/valid consistency')
        require(row['m_valid']==int(row['m_state']!=0),'CPU M owner state/valid consistency')
        for stage in ('ex','mem','wb'):
            if row[stage+'_valid']:
                token=accepted.get(row[stage+'_seq'])
                require(token is not None and token['instr']==row[stage+'_instr'] and token['cycle']<edge,'profile stage accepted machine-word identity')
        if row['d_valid']:
            descriptor=descriptors.get(row['d_seq'])
            require(descriptor is not None and descriptor['addr']==row['d_addr'] and descriptor['is_write']==row['d_store'],'profile D owner independent descriptor')
        category=classify(row,forwarding,id_mode,recovery);require(0<=category<10,'profile category range')
        expected=1<<category
        require(row['events_pre']==previous,'previous registered event alignment')
        require(row['events_post']==expected,'independent CPU cycle category')
        require(row['events_post']!=0 and row['events_post']&(row['events_post']-1)==0,'one event per counted cycle')
        # Stats consumes the event registered by the previous CPU edge.
        # The trigger captures profile_next, aligned to pre-edge cycle_count.
        if previous:totals[previous.bit_length()-1]+=1
        require(sum(totals)==row['count_pre'],'profile_next sum and CPU counted cycles')
        response_fire=axi['rvalid'] and axi['rready']
        if pending is not None:
            require(axi['rvalid']==1 and axi['rdata']==pending['data'] and axi['rresp']==0,'Stats response data/ownership')
        else:require(axi['rvalid']==0,'Stats response without accepted read')
        if axi['rvalid'] and not axi['rready']:holds+=1
        if response_fire:pending=None;responses+=1
        if axi['arvalid'] and axi['arready']:
            require(pending is None,'Stats observation read overwrite')
            offset=axi['araddr']-0x30000000;require(0<=offset<0x200 and offset%4==0,'Stats observation address')
            if offset in (0,4):
                snapshot=dict(cycle=edge-1,edge=edge,instret=instret,profile=totals.copy(),
                              d_valid=row['d_valid'],d_seq=row['d_seq'],d_state=row['d_state'],m_valid=row['m_valid'],m_seq=row['m_seq'])
                if offset==0:start=snapshot;starts.append(snapshot)
                else:require(start is not None,'STOP before START');stop=snapshot;stops.append(snapshot)
                data=0x434d4158
            elif offset==0x18:data=4
            elif offset in (0x40,0x44,0x48,0x4c,0x80,0x84,0x88,0x8c):
                bank=start if offset<0x80 else stop;require(bank is not None,'counter bank before trigger')
                field=(offset&0x3f)//4;value=bank['cycle' if field<2 else 'instret'];data=(value>>(32*(field%2)))&0xffffffff
            else:
                bank=None;category_index=None;high=None
                for n in range(10):
                    base=(0x100+n*8) if n<6 else (0x180+(n-6)*8)
                    for is_stop,shift in ((False,0),(True,0x40)):
                        if offset in (base+shift,base+shift+4):
                            bank=stop if is_stop else start;category_index=n;high=offset==base+shift+4
                require(bank is not None and category_index is not None,'all profile words use explicit discontiguous map')
                data=(bank['profile'][category_index]>>(32*high))&0xffffffff;words.add(offset)
            pending=dict(data=data,edge=edge,offset=offset);reads+=1
        if edge in retired:instret+=1
        # Independently mirror the documented lifetime of the recovery tag.
        if row['redirect']:recovery=True
        elif row['flush_fire'] or row['id_move']:recovery=False
        previous=expected;categories.append(category)
    require(pending is None and reads==responses==60,'all Stats observation reads drain')
    require(len(starts)==2 and len(stops)==1 and starts[0]['edge']<starts[1]['edge']<stops[0]['edge'],'last START selected exactly once and one STOP')
    require(start==starts[-1] and start['d_valid'] and start['d_state'] in (1,2),'selected START crosses accepted or presented D owner')
    expected_words={base+shift+high for i in range(10) for base in [(0x100+i*8) if i<6 else (0x180+(i-6)*8)] for shift in (0,0x40) for high in (0,4)}
    require(words==expected_words,'all forty discontiguous profile words printed')
    delta=[b-a for a,b in zip(start['profile'],stop['profile'])]
    direct=[sum(x==i for x in categories[start['edge']-1:stop['edge']-1]) for i in range(10)]
    require(delta==direct and sum(delta)==stop['cycle']-start['cycle'],'ten classes sum to selected window cycles')
    require(stop['instret']-start['instret']==sum(start['edge']<=e<stop['edge'] for e in retired),'selected retirement window independent count')
    # Cross-window ownership is explicit, rather than equating a request count
    # to a window's response count without its boundary descriptor.
    d=architectural.read_csv(directory/'d.csv',architectural.D_HEADER)
    crossing=[r for r in d if r['event']=='rsp' and r['seq']==start['d_seq']]
    require(len(crossing)==1 and start['edge']<=crossing[0]['cycle']<stop['edge'],'START D owner drains within selected window')
    counts=[sum(x==i for x in categories) for i in range(10)]
    return dict(profile_edge_checks=len(trace),profile_categories=dict(zip(NAMES,counts)),profile_window=dict(zip(NAMES,delta)),
                profile_window_cycles=sum(delta),profile_window_retired=stop['instret']-start['instret'],
                profile_start_count=len(starts),profile_stop_count=len(stops),profile_selected_epoch=len(starts),
                profile_owner_crossings=1,profile_printed_words=len(words),profile_stats_reads=reads,profile_stats_responses=responses,
                profile_response_hold_edges=holds,profile_scope='Independent AXI observation master with real CPU counters/events; CPU self-read is a separate system suite')


def analyze(directory):
    result=architectural.analyze(directory)
    for c in result['cases']:
        c.update(audit_profile(directory/f"cases/case{c['case']}",c['forwarding'],c['id_mode']))
    sums={f'total_{key}':sum(c[key] for c in result['cases']) for key in ('profile_edge_checks','profile_window_cycles','profile_window_retired','profile_start_count','profile_stop_count','profile_owner_crossings','profile_printed_words','profile_stats_reads','profile_stats_responses','profile_response_hold_edges')}
    result.update(sums)
    result['profile_class_totals']={name:sum(c['profile_categories'][name] for c in result['cases']) for name in NAMES}
    result['profile_window_totals']={name:sum(c['profile_window'][name] for c in result['cases']) for name in NAMES}
    result['architectural_scope']=result['scope']
    result['scope']='CPU5 ten-class registered cycle producer with unchanged S15 ISA workload; independent per-edge machine-word dependency and owner gold, real CPU-to-Stats profile_next windows and separate AXI observation master'
    return result


def selftest_evidence(directory):
    legacy=architectural.selftest_evidence(directory)
    source=directory/'cases/case0';scratch=directory.parent/(directory.name+'_negative_evidence')
    protected={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir() if p.is_file()}
    tests=[
        ('profile_post_event','profile.csv','independent CPU cycle category'),
        ('profile_previous_event','profile.csv','previous registered event alignment'),
        ('profile_cycle_alignment','profile.csv','CPU count/event edge alignment'),
        ('profile_stage_word','profile.csv','profile stage accepted machine-word identity'),
        ('profile_owner_address','profile.csv','profile D owner independent descriptor'),
        ('profile_owner_valid','profile.csv','CPU D owner state/valid consistency'),
        ('profile_priority','profile.csv','independent CPU cycle category'),
        ('stats_read_data','stats.csv','Stats response data/ownership'),
        ('stats_missing_accept','stats.csv','Stats response without accepted read'),
        ('stats_extra_bank_low','stats.csv','Stats response data/ownership'),
        ('stats_extra_bank_high','stats.csv','Stats response data/ownership'),
        ('stats_stop_cycle','stats.csv','Stats response data/ownership'),
        ('stats_second_start','stats.csv','Stats response data/ownership'),
        ('stats_print_stability','stats.csv','Stats response data/ownership'),
    ]
    rejected=[]
    for name,filename,reason in tests:
        target=scratch/name;require(not target.resolve().is_relative_to(directory.resolve()),'bad copies stay outside good evidence')
        shutil.copytree(source,target,dirs_exist_ok=True);changed=target/filename
        with changed.open(newline='',encoding='ascii') as stream:
            reader=csv.DictReader(stream);header=reader.fieldnames;records=list(reader)
        if filename=='profile.csv':
            if name=='profile_post_event':row=records[0];field='events_post'
            elif name=='profile_previous_event':row=records[0];field='events_pre'
            elif name=='profile_cycle_alignment':row=records[0];field='count_post'
            elif name=='profile_stage_word':row=next(r for r in records if r['ex_valid']=='1');field='ex_instr'
            elif name=='profile_owner_address':row=next(r for r in records if r['d_valid']=='1');field='d_addr'
            elif name=='profile_owner_valid':row=next(r for r in records if r['d_valid']=='1');field='d_valid'
            else:row=next(r for r in records if int(r['events_post'],16)==16);field='events_post'
        else:
            if name=='stats_read_data':row=next(r for r in records if r['rvalid']=='1');field='rdata'
            elif name=='stats_missing_accept':row=next(r for r in records if r['arvalid']=='1' and r['arready']=='1');field='arvalid'
            elif name=='stats_second_start':
                row=[r for r in records if r['arvalid']=='1' and r['arready']=='1' and int(r['araddr'],16)==0x30000000][1]
                field='araddr';row[field]='30000004'
            else:
                offset={'stats_extra_bank_low':0x180,'stats_extra_bank_high':0x19c,'stats_stop_cycle':0x80,'stats_print_stability':0x40}[name]
                accepts=[k for k,r in enumerate(records) if r['arvalid']=='1' and r['arready']=='1' and int(r['araddr'],16)==0x30000000+offset]
                begin=accepts[-1] if name=='stats_print_stability' else accepts[0]
                row=next(r for r in records[begin+1:] if r['rvalid']=='1');field='rdata'
        if name=='profile_priority':row[field]=format(1<<9,'x')
        elif name!='stats_second_start':row[field]=format(int(row[field],16)^1,'x') if field in HEX else str(int(row[field])^1)
        with changed.open('w',newline='',encoding='ascii') as stream:
            writer=csv.DictWriter(stream,fieldnames=header,lineterminator='\n');writer.writeheader();writer.writerows(records)
        try:audit_profile(target,forwarding=0,id_mode=0)
        except ValueError as error:
            require(reason in str(error),f'profile negative {name} unintended rejection: {error}');actual=str(error)
        else:raise ValueError(f'profile negative {name} accepted')
        rejected.append(dict(name=name,status='REJECTED',reason=actual,
                             good_sha256=hashlib.sha256((source/filename).read_bytes()).hexdigest(),bad_sha256=hashlib.sha256(changed.read_bytes()).hexdigest()))
    require(protected=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir() if p.is_file()},'profile negatives changed good inputs')
    result=dict(status='PASS',rejected_count=legacy['rejected_count']+len(rejected),
                architectural_rejected_count=legacy['rejected_count'],profile_rejected_count=len(rejected),
                rejected=legacy['rejected']+rejected,good_inputs_unchanged=legacy['good_inputs_unchanged'])
    (scratch/'summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result
