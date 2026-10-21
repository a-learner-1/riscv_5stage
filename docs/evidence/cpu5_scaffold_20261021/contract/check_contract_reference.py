"""Design-reference sanity only: no CPU5 IRQ RTL is simulated here."""
import json
import argparse
from pathlib import Path
P=Path(__file__).resolve().parent
ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--contract',type=Path,default=P/'contracts/cpu5_design_contract_20261021.json')
ap.add_argument('--output',type=Path,default=P/'contract_reference_check.json')
args=ap.parse_args()
c=json.loads(args.contract.read_text(encoding='utf-8'))
assert [x['id'] for x in c['assertions']]==[f'A{i:02}' for i in range(1,17)]
assert all(x['implementation']=='NOT IMPLEMENTED' and x['run']=='NOT RUN' for x in c['assertions'])
assert c['age']['seq_bits']==64 and not c['age']['wrap_allowed']
assert 'post_commit_CSR' in c['irq']['arm_next']

def boundary(arm,pending,enabled,safe,complete,fault,post_enabled):
    take=bool(arm and pending and enabled and safe and not fault)
    retire=bool(complete and not fault and not take)
    next_arm=False if fault or take else bool(pending and (post_enabled if retire else enabled))
    assert not(take and retire)
    return dict(sync_trap=bool(fault),retire=retire,irq_take=take,arm_next=next_arm)

cases=[
 ('new_irq_can_retire',(0,1,1,1,1,0,1),(0,1,0,1)),
 ('armed_alu_must_take',(1,1,1,1,1,0,1),(0,0,1,0)),
 ('csr_enable_T0',(0,1,0,1,1,0,1),(0,1,0,1)),
 ('csr_enable_T1',(1,1,1,1,1,0,1),(0,0,1,0)),
 ('csr_disable_T0_unarmed',(0,1,1,1,1,0,0),(0,1,0,0)),
 ('csr_disabled_T1',(0,1,0,1,1,0,0),(0,1,0,0)),
 ('armed_irq_beats_unretired_disable',(1,1,1,1,1,0,0),(0,0,1,0)),
 ('mret_enable_T0',(0,1,0,1,1,0,1),(0,1,0,1)),
 ('mret_pending_T1',(1,1,1,1,1,0,1),(0,0,1,0)),
 ('held_store',(1,1,1,0,0,0,1),(0,0,0,1)),
 ('store_completes_before_IRQ',(1,1,1,0,1,0,1),(0,1,0,1)),
 ('after_store_safe_boundary',(1,1,1,1,1,0,1),(0,0,1,0)),
 ('sync_fault_preempts_IRQ',(1,1,1,1,1,1,1),(1,0,0,0)),
 ('source_disappears',(1,0,1,1,1,0,1),(0,1,0,0)),
 ('disabled_candidate',(1,1,0,1,1,0,0),(0,1,0,0)),
]
out=[]
for name,inputs,expected in cases:
    result=boundary(*inputs)
    assert tuple(map(int,result.values()))==expected,(name,result)
    out.append({'case':name,'inputs':inputs,'expected':expected,'reference':result})
result={'status':'PASS (design-reference consistency only)','assertion_IDs':16,
        'IRQ_reference_cases':out,'CPU5_IRQ_RTL':'NOT IMPLEMENTED / NOT RUN',
        'CPU5_A01_A16_complete_implementation':'NOT IMPLEMENTED / NOT RUN'}
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':'PASS (design only)','IRQ_cases':len(out),'A01_A16_all_not_implemented':True}))
