import csv, hashlib, json, pathlib, re, shutil, subprocess

BASE = pathlib.Path(__file__).resolve().parent
GOOD = BASE / 'owner_work'
SIM = pathlib.Path(r'D:\modeltech64_10.6e\win64\vsim.exe')
OUT = GOOD / 'build/cpu5_s5_ram_owner'
FILES = ('rtl/cpu5_ram_owner.v', 'tb/cpu5_ram_owner_tb.v', 'run_cpu5_ram_owner.do')
MUTANTS = [
    ('bind_requires_req_ready',
     'assign issue_fire=issue_valid && issue_ready;',
     'assign issue_fire=issue_valid && issue_ready && dmem_req_ready;',
     'offer binds independently of req ready'),
    ('killed_request_cancels',
     'assign dmem_req_valid=rst_n && ((state_q==PRESENTED) || new_request);',
     'assign dmem_req_valid=rst_n && !effective_killed && ((state_q==PRESENTED) || new_request);',
     'held request remains valid'),
    ('store_is_killable',
     'wire kill_owner=kill_valid && !is_store_q && seq_q>=kill_cut_seq;',
     'wire kill_owner=kill_valid && seq_q>=kill_cut_seq;',
     'STORE cannot be killed'),
    ('response_claims_new_owner',
     'assign rsp_owner_seq=seq_q;',
     'assign rsp_owner_seq=new_request?issue_seq:seq_q;',
     'A response and B request have distinct descriptors'),
    ('load_to_store_handoff',
     '(load_turnover && !issue_is_store));',
     '(load_turnover));',
     'new STORE cannot handoff from load'),
    ('fault_handoff',
     '!result_error && !effective_killed && completion_ready;',
     '!effective_killed && completion_ready;',
     'fault ack does not handoff'),
    ('kill_truncates_seq',
     'wire kill_owner=kill_valid && !is_store_q && seq_q>=kill_cut_seq;',
     'wire kill_owner=kill_valid && !is_store_q && seq_q[31:0]>=kill_cut_seq[31:0];',
     '64 bit age and epoch independence'),
    ('completion_bypasses_cache',
     'assign completion_rdata=state_q==COMPLETE?rdata_q:dmem_rsp_rdata;',
     'assign completion_rdata=dmem_rsp_rdata;',
     'blocked completion stable'),
    ('killed_response_waits_ready',
     'rdata_q<=dmem_rsp_rdata; error_q<=dmem_rsp_error;\n                    if(effective_killed || completion_ready)',
     'rdata_q<=dmem_rsp_rdata; error_q<=dmem_rsp_error;\n                    if(completion_ready)',
     'killed response drops without completion ready'),
]

rows = []
for name, old, new, expected in MUTANTS:
    directory = GOOD / 'build/mutations' / name
    for relative in FILES:
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(GOOD / relative, target)
    source = directory / FILES[0]
    original = source.read_text()
    assert original.count(old) == 1, (name, original.count(old))
    source.write_text(original.replace(old, new), newline='\n')
    (directory / 'build/cpu5_s5_ram_owner').mkdir(parents=True, exist_ok=True)
    result = subprocess.run([str(SIM), '-c', '-do', 'run_cpu5_ram_owner.do', '-l',
                             'build/cpu5_s5_ram_owner/process.log'],
                            cwd=directory, capture_output=True, text=True, timeout=60)
    (directory / 'output.log').write_text(result.stdout + result.stderr)
    output = result.stdout + result.stderr
    rejected = result.returncode != 0 and expected in output and 'Errors: 0, Warnings: 0' in output
    rows.append(dict(name=name, exit_code=result.returncode, expected_failure=expected,
                     rejected=rejected, source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
    print(name, result.returncode, rejected, flush=True)
    assert rejected, (name, output)

manifest = {}
for relative in FILES:
    raw = (GOOD / relative).read_bytes()
    assert raw == (BASE / 'work' / relative).read_bytes(), relative
    manifest[relative] = dict(sha256=hashlib.sha256(raw).hexdigest(),
        canonical_lf_sha256=hashlib.sha256(raw.replace(b'\r\n',b'\n')).hexdigest())
summary = json.loads((OUT / 'summary.json').read_text())
transcript = (OUT / 'modelsim_transcript.log').read_text()
assert 'CPU5 RAM OWNER DIRECTED TEST PASS' in transcript
assert not re.search(r'Warnings: [1-9]|Errors: [1-9]', transcript)
trace = list(csv.DictReader((OUT / 'trace.csv').open()))
# This fixed ledger describes the stimulus, without importing RTL logic.
expected_requests = [
    (0x100000001,0x10003,0), (10,0x10010,0), (20,0x10020,0), (21,0x10074,0),
    (30,0x10030,0), (31,0x10031,0), (40,0x10040,0), (41,0x10044,0),
    (50,0x10050,0), (51,0x10054,1), (55,0x10057,1), (60,0x10060,0),
    (70,0x10070,0), (80,0x10080,0), (0xffffffff,0x10090,0), (100,0x10100,1),
    (202,0x10208,0), (203,0x1020c,0),
]
expected_responses = [
    (0x100000001,0xbad00001,1,1), (10,0x12345678,0,0), (20,0x11223344,0,0),
    (21,0x55667788,0,0), (30,0x31323334,0,0), (31,0x35363738,0,0),
    (40,0x41424344,0,0), (41,0x45464748,0,0), (50,0x51525354,0,0),
    (51,0,0,0), (55,0,0,0), (60,0xbad00060,1,0), (70,0x71727374,0,1),
    (80,0,1,0), (0xffffffff,0x91929394,0,0), (100,0,1,0), (203,0,0,0),
]
actual_requests = [(int(r['req_seq'],16),int(r['req_addr'],16),int(r['req_write']))
                   for r in trace if r['req_fire']=='1']
actual_responses = [(int(r['rsp_seq'],16),int(r['rsp_rdata'],16),int(r['error']),int(r['killed']))
                    for r in trace if r['rsp_fire']=='1']
assert actual_requests == expected_requests
assert actual_responses == expected_responses
trace_checks = dict(rows=len(trace), requests_checked=len(actual_requests),
                    responses_checked=len(actual_responses), fixed_stimulus_ledger=True,
                    reset_cancelled_accepted_seq=202)
verification = dict(pass_all=True, summary=summary, compile_warnings=0, source_manifest=manifest,
                    mutations=rows, mutations_rejected=len(rows), trace_checks=trace_checks)
(OUT / 'verification.json').write_text(json.dumps(verification, indent=2)+'\n')
print(json.dumps(verification, indent=2))
