`timescale 1ns/1ps
// Hand-authored instruction streams and an independent, retire-edge machine
// model. No force, deposit, or reference to RTL decode/RMW helper functions.
module cpu5_m_control_case #(parameter integer MODE=0)(output reg done=0);
    localparam [31:0] VECTOR=32'h100;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,in_fetch_error=0,in_pred_taken=0,in_pred_hit=0;
    reg [31:0] in_pc=0,in_instr=0,in_pred_next_pc=0,in_fetch_tval=0;
    reg [63:0] in_seq=0,flush_cut_seq=0;reg [7:0] in_epoch=0;
    reg id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    wire in_ready,ex_valid,wb_we,retire_valid,retire_writes_rd;
    wire [31:0] ex_pc,ex_instr,wb_pc,wb_data,retire_pc,retire_instr,retire_value,arch_next_pc_q;
    wire [4:0] wb_rd,retire_rd;wire [63:0] retire_seq,cycle_count,instret_count;
    wire halted,halt_fetch_error,id_raw_wait,retire_fire,wb_fire,flush_ready,flush_fire;
    wire [31:0] halt_pc,halt_instr,halt_cause,halt_tval;wire [63:0] halt_seq;
    wire redirect_valid,redirect_kill_ifid;wire [31:0] redirect_pc;wire [63:0] redirect_seq;
    wire bp_commit_valid,bp_commit_taken,bp_commit_is_branch,bp_commit_is_jal;
    wire [63:0] bp_commit_seq;wire [31:0] bp_commit_pc,bp_commit_target;
    wire [31:0] bp_resolved_count,bp_mispredict_count,bp_direction_error_count,bp_target_error_count;
    wire trap_fire,trap_valid;wire [31:0] trap_pc,trap_cause,trap_tval;wire [63:0] trap_seq;
    wire dmem_req_valid,dmem_req_write,dmem_rsp_ready,dmem_fault;
    reg dmem_req_ready=1,dmem_rsp_valid=0,dmem_rsp_error=0;reg [31:0] dmem_rsp_rdata=0;
    wire [31:0] dmem_req_addr,dmem_req_wdata;wire [1:0] dmem_req_size;wire [3:0] dmem_req_wstrb;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),
        .BRANCH_RESOLVE_IN_ID(MODE),.ENABLE_BRANCH_PRED(1),.ENABLE_RAM(1),
        .DMEM_WORDS(8),.ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.TRAP_VECTOR(VECTOR)) dut(.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),.perf_cycle_events(),.*);
    reg [63:0] eseq[0:255],tseq[0:15],qseq[0:15];
    reg [31:0] epc[0:255],eins[0:255],eval[0:255],enext[0:255];reg [4:0] erd[0:255];
    reg [31:0] tpc[0:15],tcause[0:15],ttval[0:15],tvector[0:15],qa[0:15];
    reg [31:0] model_gpr[0:31];reg [31:0] model_known=1;
    reg [31:0] model_status=32'h1800,model_vector=VECTOR,model_scratch=0,model_epc=0,model_cause=0,model_tval=0;
    reg [31:0] saved_pc=0,saved_cause=0,saved_tval=0;reg [63:0] saved_seq=0;
    integer expected=0,retired=0,wb_count=0,traps_expected=0,traps=0,requests_expected=0,requests=0,responses=0;
    integer case_no=0,passed=0,cycles=0,timeout=0,i,j,k,stage,ri,wi,ti;
    integer trace_fd,summary_fd,total_retired=0,total_wb=0,total_traps=0,total_requests=0,total_responses=0;
    integer total_csr=0,total_mret=0,total_stall=0,total_held_wb=0,total_old_wb=0,total_killed=0,total_drain=0;
    integer total_status_checks=0,total_raw_wait=0,total_held_d=0;
    integer total_mret_old_wb=0,total_pending_csr_branch=0;
    reg [63:0] mseq[0:255];reg [31:0] mpc[0:255],mins[0:255],mval[0:255];reg mkill[0:255];
    integer m_expected=0,m_issued=0,m_completed=0,m_drained=0,m_active=-1;
    integer total_m_issued=0,total_m_completed=0,total_m_drained=0,total_m_busy=0,total_m_fast=0,total_m_held=0;
    integer total_old_load_block=0,total_handler_drain=0,total_m_wb_hold=0;
    reg m_held=0,m_just_started=0;reg [95:0] m_held_fields;
    reg [31:0] lhs_vec,rhs_vec,math_value;
    integer op_no,pair_no;
    reg last_accept=0,last_rsp=0,last_trap=0,last_mret=0;reg [63:0] last_accept_seq=0;
    reg pre_trap,pre_retire,pre_wb,pre_we,pre_wb_hold,bus_pending=0,held=0;
    reg [63:0] pre_wb_seq,bus_seq=0;reg [31:0] pre_wb_pc,pre_wb_value;reg [4:0] pre_wb_rd;
    reg [134:0] held_fields=0;reg [31:0] arch_expected=0,oldcsr,newcsr,operand,word;
    reg [11:0] addr,model_addr;reg [2:0] funct;reg write_intent;reg [31:0] model_word;
    reg [63:0] s;reg [31:0] p;
    function [31:0] addi(input [4:0] d,input [4:0] a,input integer v);
        begin addi={v[11:0],a,3'b000,d,7'h13};end
    endfunction
    function [31:0] csr(input [2:0] f,input [4:0] d,input [11:0] a,input [4:0] z);
        begin csr={a,z,f,d,7'h73};end
    endfunction
    function [31:0] load(input [4:0] d,input [4:0] a,input integer v);
        begin load={v[11:0],a,3'b010,d,7'h03};end
    endfunction
    function [31:0] jal(input [4:0] d,input integer v);
        begin jal={v[20],v[10:1],v[11],v[19:12],d,7'h6f};end
    endfunction
    function [31:0] beq(input [4:0] a,input [4:0] b,input integer v);
        begin beq={v[12],v[10:5],b,a,3'b000,v[4:1],v[11],7'h63};end
    endfunction
    function [31:0] mop(input [2:0] f,input [4:0] d,input [4:0] a,input [4:0] b);
        begin mop={7'b0000001,b,a,f,d,7'h33};end
    endfunction
    // Mathematical ISA oracle. This uses the simulator's arithmetic operators,
    // independently of the unchanged iterative/multiply implementation.
    function [31:0] m_math(input [2:0] f,input [31:0] a,input [31:0] b);
        reg signed [63:0] sa,sb,sp;reg [63:0] ua,ub,up;
        begin
            sa={{32{a[31]}},a};sb={{32{b[31]}},b};ua={32'd0,a};ub={32'd0,b};
            case(f)
                0:begin up=ua*ub;m_math=up[31:0];end
                1:begin sp=sa*sb;m_math=sp[63:32];end
                2:begin sp=sa*$signed(ub);m_math=sp[63:32];end
                3:begin up=ua*ub;m_math=up[63:32];end
                4:if(b==0)m_math=32'hffffffff;else if(a==32'h80000000&&b==32'hffffffff)m_math=32'h80000000;else m_math=sa/sb;
                5:if(b==0)m_math=32'hffffffff;else m_math=ua/ub;
                6:if(b==0)m_math=a;else if(a==32'h80000000&&b==32'hffffffff)m_math=0;else m_math=sa%sb;
                7:if(b==0)m_math=a;else m_math=ua%ub;
            endcase
        end
    endfunction
    function [31:0] read_model(input [11:0] a);
        begin case(a)
            12'h300:read_model=model_status;12'h301:read_model=32'h40001100;
            12'h305:read_model=model_vector;12'h340:read_model=model_scratch;
            12'h341:read_model=model_epc;12'h342:read_model=model_cause;12'h343:read_model=model_tval;
            12'hf11,12'hf12,12'hf13,12'hf14,12'hf15:read_model=0;
            default:begin read_model=32'hxxxxxxxx;$fatal(1,"CSR model unsupported retired address=%h",a);end
        endcase end
    endfunction
    task tick;
        begin @(posedge clk);#2;
            if((last_accept&&last_accept_seq==in_seq)||last_trap||last_mret)in_valid=0;
        end
    endtask
    task reset_case(input integer n);
        begin @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            dmem_req_ready=1;dmem_rsp_valid=0;dmem_rsp_error=0;
            case_no=n;expected=0;traps_expected=0;requests_expected=0;m_expected=0;s=1;p='h200;
            tick;tick;@(negedge clk);rst_n=1;
        end
    endtask
    task expect_packet(input [63:0] age,input [31:0] pc,input [31:0] ins,input [4:0] d,input [31:0] v,input [31:0] nextpc);
        begin eseq[expected]=age;epc[expected]=pc;eins[expected]=ins;erd[expected]=d;
            eval[expected]=v;enext[expected]=nextpc;expected=expected+1;end
    endtask
    task expect_trap(input [63:0] age,input [31:0] pc,input [31:0] cause,input [31:0] val,input [31:0] vec);
        begin tseq[traps_expected]=age;tpc[traps_expected]=pc;tcause[traps_expected]=cause;
            ttval[traps_expected]=val;tvector[traps_expected]=vec;traps_expected=traps_expected+1;end
    endtask
    task expect_request(input [63:0] age,input [31:0] a);
        begin qseq[requests_expected]=age;qa[requests_expected]=a;requests_expected=requests_expected+1;end
    endtask
    task offer(input [63:0] age,input [31:0] pc,input [31:0] ins);
        begin @(negedge clk);in_valid=1;in_seq=age;in_pc=pc;in_instr=ins;in_epoch=in_epoch+1;
            in_pred_next_pc=pc+4;in_pred_taken=0;in_pred_hit=0;end
    endtask
    task send(input [63:0] age,input [31:0] pc,input [31:0] ins);
        begin offer(age,pc,ins);timeout=0;tick;
            while(!(last_accept&&last_accept_seq==age))begin tick;timeout=timeout+1;
                if(timeout>100)$fatal(1,"CSR ID timeout mode=%0d case=%0d seq=%0d",MODE,case_no,age);end
        end
    endtask
    task emit(input [31:0] ins,input [4:0] d,input [31:0] val);
        begin expect_packet(s,p,ins,d,val,p+4);send(s,p,ins);s=s+1;p=p+4;end
    endtask
    task emit_csr(input [2:0] f,input [4:0] d,input [11:0] a,input [4:0] z,input [31:0] oldval);
        begin emit(csr(f,d,a,z),d,oldval);end
    endtask
    task const32(input [4:0] d,input [31:0] value);
        reg [31:0] upper;reg signed [31:0] low;
        begin
            upper=(value+32'h800)&32'hfffff000;low=$signed(value-upper);
            emit({upper[31:12],d,7'h37},d,upper);emit(addi(d,d,low),d,value);
        end
    endtask
    task expect_m(input [63:0] age,input [31:0] pc,input [31:0] ins,input [31:0] value,input killed);
        begin mseq[m_expected]=age;mpc[m_expected]=pc;mins[m_expected]=ins;mval[m_expected]=value;
            mkill[m_expected]=killed;m_expected=m_expected+1;end
    endtask
    task emit_m(input [2:0] f,input [4:0] d,input [4:0] a,input [4:0] b,input [31:0] value);
        begin expect_m(s,p,mop(f,d,a,b),value,0);emit(mop(f,d,a,b),d,value);end
    endtask
    task wait_m_started(input integer n);
        begin timeout=0;while(m_issued<n)begin tick;timeout=timeout+1;if(timeout>120)$fatal(1,"M start timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_m_done;
        begin timeout=0;while(!dut.m_completion_valid)begin tick;timeout=timeout+1;if(timeout>120)$fatal(1,"M completion timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_retired(input integer n);
        begin timeout=0;while(retired<n)begin tick;timeout=timeout+1;
            if(timeout>100)$fatal(1,"CSR retire timeout mode=%0d case=%0d have=%0d want=%0d",MODE,case_no,retired,n);end end
    endtask
    task wait_traps(input integer n);
        begin timeout=0;while(traps<n)begin tick;timeout=timeout+1;
            if(timeout>100)$fatal(1,"CSR trap timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_requests(input integer n);
        begin timeout=0;while(requests<n)begin tick;timeout=timeout+1;
            if(timeout>100)$fatal(1,"CSR D request timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task respond(input [31:0] data,input error);
        begin @(negedge clk);dmem_rsp_valid=1;dmem_rsp_rdata=data;dmem_rsp_error=error;timeout=0;tick;
            while(!last_rsp)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"CSR response timeout");end
            @(negedge clk);dmem_rsp_valid=0;dmem_rsp_error=0;
        end
    endtask
    task flush_at(input [63:0] cut);
        begin @(negedge clk);flush_valid=1;flush_cut_seq=cut;in_valid=0;#1;
            if(!flush_ready||!flush_fire)$fatal(1,"CSR cancelable flush rejected");
            tick;@(negedge clk);flush_valid=0;end
    endtask
    task finish_case;
        begin in_valid=0;timeout=0;
            while(retired!=expected || wb_count!=expected || traps!=traps_expected || dut.idex_valid_q ||
                dut.exmem_valid_q || dut.memwb_valid_q || dut.ram_owner_valid || dut.m_owner_valid || bus_pending)begin
                tick;timeout=timeout+1;if(timeout>120)$fatal(1,"CSR drain mode=%0d case=%0d retire=%0d/%0d wb=%0d traps=%0d/%0d",MODE,case_no,retired,expected,wb_count,traps,traps_expected);
            end
            repeat(4)tick;
            if(requests!=requests_expected||responses!=requests)$fatal(1,"M D ledger not closed");
            if(m_issued!=m_expected||m_completed+m_drained!=m_issued)$fatal(1,"M issue/completion ledger not closed mode=%0d case=%0d starts=%0d/%0d complete=%0d drain=%0d",MODE,case_no,m_issued,m_expected,m_completed,m_drained);
            for(j=1;j<32;j=j+1)if(model_known[j]&&dut.u_regfile.regs[j]!==model_gpr[j])
                $fatal(1,"CSR physical GPR mismatch mode=%0d case=%0d reg=%0d",MODE,case_no,j);
            passed=passed+1;$display("CPU5_M_CONTROL_CASE_PASS mode=%0d case=%0d retire=%0d traps=%0d req=%0d",MODE,case_no,retired,traps,requests);
        end
    endtask
    task check_state;
        begin
            if(dut.g_csr.u_csr.csr_mstatus!==model_status||dut.g_csr.u_csr.csr_mtvec!==model_vector||
                dut.g_csr.u_csr.csr_mscratch!==model_scratch||dut.g_csr.u_csr.csr_mepc!==model_epc||
                dut.g_csr.u_csr.csr_mcause!==model_cause||dut.g_csr.u_csr.csr_mtval!==model_tval)
                $fatal(1,"CSR committed state mode=%0d case=%0d status=%h/%h vector=%h/%h scratch=%h/%h epc=%h/%h cause=%h/%h tval=%h/%h",MODE,case_no,
                    dut.g_csr.u_csr.csr_mstatus,model_status,dut.g_csr.u_csr.csr_mtvec,model_vector,
                    dut.g_csr.u_csr.csr_mscratch,model_scratch,dut.g_csr.u_csr.csr_mepc,model_epc,
                    dut.g_csr.u_csr.csr_mcause,model_cause,dut.g_csr.u_csr.csr_mtval,model_tval);
            total_status_checks=total_status_checks+1;
        end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst_n)begin
            retired=0;wb_count=0;traps=0;requests=0;responses=0;bus_pending=0;held=0;
            last_accept=0;last_rsp=0;last_trap=0;last_mret=0;m_issued=0;m_completed=0;m_drained=0;m_active=-1;m_held=0;m_just_started=0;model_known=1;model_gpr[0]=0;
            arch_expected=0;saved_seq=0;saved_pc=0;saved_cause=0;saved_tval=0;
            model_status='h1800;model_vector=VECTOR;model_scratch=0;model_epc=0;model_cause=0;model_tval=0;
            if(wb_we||retire_fire||trap_fire||redirect_valid||dmem_req_valid||dmem_rsp_ready)$fatal(1,"CSR reset side effect");
            #1;check_state;
            if(trap_valid||retire_valid||trap_pc!==0||trap_cause!==0||trap_tval!==0||trap_seq!==0||instret_count!==0||arch_next_pc_q!==0)
                $fatal(1,"CSR reset descriptor state");
        end else begin
            check_state;
            last_accept=in_valid&&in_ready;last_accept_seq=in_seq;last_rsp=dmem_rsp_valid&&dmem_rsp_ready;
            pre_trap=trap_fire;last_trap=trap_fire;pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;
            last_mret=pre_retire&&dut.exmem_q.instr==32'h30200073;
            pre_wb_hold=dut.memwb_valid_q&&!wb_ready;pre_wb_seq=dut.memwb_q.seq;
            pre_wb_pc=wb_pc;pre_wb_value=wb_data;pre_wb_rd=wb_rd;ri=retired;wi=wb_count;ti=traps;
            if(last_accept&&in_instr[6:0]==7'h63&&dut.exmem_valid_q&&dut.exmem_q.is_csr&&
                !pre_retire&&pre_wb_hold)total_pending_csr_branch=total_pending_csr_branch+1;
            if(dut.m_unit_start!==dut.m_issue_fire)$fatal(1,"M start pulse lacks exactly one owner allocation");
            if(dut.m_unit_busy)total_m_busy=total_m_busy+1;
            if(m_just_started&&dut.m_unit_done&&!dut.m_unit_busy)total_m_fast=total_m_fast+1;
            m_just_started=dut.m_issue_fire;
            if(m_held&&(!dut.m_completion_valid||{dut.m_completion_seq,dut.m_completion_result}!==m_held_fields))
                $fatal(1,"M held completion identity/result changed");
            m_held=dut.m_completion_valid&&!dut.m_completion_ready&&!dut.m_drain_fire;
            m_held_fields={dut.m_completion_seq,dut.m_completion_result};
            if(m_held)total_m_held=total_m_held+1;
            if(dut.idex_valid_q&&dut.idex_q.is_m&&dut.exmem_valid_q&&(dut.exmem_q.is_load||dut.exmem_q.is_store))begin
                total_old_load_block=total_old_load_block+1;if(dut.m_issue_fire)$fatal(1,"M started before older memory fault risk retired");end
            if(dut.m_issue_fire)begin
                if(m_issued>=m_expected||dut.idex_q.seq!==mseq[m_issued]||dut.idex_q.pc!==mpc[m_issued]||dut.idex_q.instr!==mins[m_issued]||dut.m_owner_valid||m_active!=-1)
                    $fatal(1,"M start owner/order mode=%0d case=%0d start=%0d seq=%0d",MODE,case_no,m_issued,dut.idex_q.seq);
                m_active=m_issued;m_issued=m_issued+1;total_m_issued=total_m_issued+1;
            end
            if(dut.m_completion_valid&&(dut.m_completion_ready||dut.m_drain_fire))begin
                if(m_active<0||dut.m_completion_seq!==mseq[m_active]||dut.m_completion_result!==mval[m_active]||dut.m_completion_killed!==mkill[m_active])
                    $fatal(1,"M completion generation/owner/value mode=%0d case=%0d index=%0d seq=%0d result=%h",MODE,case_no,m_active,dut.m_completion_seq,dut.m_completion_result);
                if(dut.m_drain_fire)begin
                    if(!dut.m_completion_killed)$fatal(1,"M live completion drained without consume");
                    m_drained=m_drained+1;total_m_drained=total_m_drained+1;
                end else begin
                    if(dut.m_completion_killed)$fatal(1,"M killed completion consumed");
                    m_completed=m_completed+1;total_m_completed=total_m_completed+1;
                end
                m_active=-1;
            end
            if(in_valid&&id_raw_wait)total_raw_wait=total_raw_wait+1;
            if(!mem_enable&&dut.exmem_valid_q)begin total_stall=total_stall+1;
                if(trap_fire||retire_fire||dut.csr_commit_fire||dut.mret_fire)$fatal(1,"CSR MEM enable ignored");end
            if(pre_wb_hold)total_held_wb=total_held_wb+1;
            if(pre_wb_hold&&dut.exmem_valid_q&&dut.exmem_q.is_m)total_m_wb_hold=total_m_wb_hold+1;
            if(held&&(!dmem_req_valid||{dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq}!==held_fields))
                $fatal(1,"CSR changed held D request");
            held=dmem_req_valid&&!dmem_req_ready;
            held_fields={dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq};
            if(held)total_held_d=total_held_d+1;
            if(dmem_req_valid&&(requests>=requests_expected||dut.ram_req_seq!==qseq[requests]||
                dmem_req_addr!==qa[requests]||dmem_req_write||dmem_req_size!==2||dmem_req_wstrb!==0))
                $fatal(1,"CSR unexpected/younger D request mode=%0d case=%0d seq=%0d",MODE,case_no,dut.ram_req_seq);
            if(last_rsp)begin
                if(!bus_pending||dut.ram_rsp_seq!==bus_seq)$fatal(1,"CSR D response owner mismatch");
                if(dut.ram_owner_killed)begin total_killed=total_killed+1;if(pre_trap)$fatal(1,"CSR killed D error trapped");end
                bus_pending=0;responses=responses+1;total_responses=total_responses+1;
            end
            if(dmem_req_valid&&dmem_req_ready)begin
                if(bus_pending)$fatal(1,"CSR multiple D owners");
                bus_pending=1;bus_seq=dut.ram_req_seq;requests=requests+1;total_requests=total_requests+1;
            end
            if(pre_wb)begin
                if(wi>=retired||dut.memwb_q.seq!==eseq[wi]||wb_pc!==epc[wi]||wb_rd!==erd[wi]||wb_data!==eval[wi]||pre_we!==(erd[wi]!=0))
                    $fatal(1,"CSR WB stream mode=%0d case=%0d index=%0d seq=%0d value=%h/%h",MODE,case_no,wi,dut.memwb_q.seq,wb_data,eval[wi]);
                wb_count=wb_count+1;total_wb=total_wb+1;
            end
            if(bp_commit_valid!==(retire_fire&&dut.exmem_q.instr!=32'h30200073&&!(dut.exmem_q.instr[6:0]==7'h73&&dut.exmem_q.instr[14:12]!=0)))$fatal(1,"CSR BP authorization mismatch");
            if(pre_trap)begin
                if(ti>=traps_expected||dut.exmem_q.seq!==tseq[ti]||dut.exmem_q.pc!==tpc[ti]||halt_cause!==tcause[ti]||halt_tval!==ttval[ti]||
                    pre_retire||bp_commit_valid||last_accept||!redirect_valid||!redirect_kill_ifid||redirect_pc!==tvector[ti]||redirect_seq!==tseq[ti])
                    $fatal(1,"CSR precise trap/priority mode=%0d case=%0d event=%0d seq=%0d pc=%h cause=%0d tval=%h redirect=%h",MODE,case_no,ti,dut.exmem_q.seq,dut.exmem_q.pc,halt_cause,halt_tval,redirect_pc);
                if(pre_wb&&pre_we)total_old_wb=total_old_wb+1;
                model_status={19'd0,2'b11,3'd0,model_status[3],3'd0,1'b0,3'd0};
                model_epc=tpc[ti]&32'hfffffffc;model_cause=tcause[ti];model_tval=ttval[ti];
                saved_seq=tseq[ti];saved_pc=tpc[ti];saved_cause=tcause[ti];saved_tval=ttval[ti];
                arch_expected=tvector[ti];traps=traps+1;total_traps=total_traps+1;
                $fdisplay(trace_fd,"trap,%0d,%0d,%h,%h,%h,%h",case_no,cycles,tseq[ti],tpc[ti],tcause[ti],ttval[ti]);
            end else if(redirect_valid&&!last_mret)$fatal(1,"CSR unexpected younger redirect mode=%0d case=%0d seq=%0d",MODE,case_no,redirect_seq);
            if(pre_retire)begin
                if(ri>=expected||dut.exmem_q.seq!==eseq[ri]||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri])
                    $fatal(1,"CSR killed/fault token retired mode=%0d case=%0d index=%0d seq=%0d",MODE,case_no,ri,dut.exmem_q.seq);
                if(dut.ram_owner_valid&&dut.ram_owner_killed)total_drain=total_drain+1;
                if(dut.m_owner_valid&&dut.m_owner_killed)total_handler_drain=total_handler_drain+1;
                model_word=eins[ri];
                if(model_word==32'h30200073)begin
                    if(!redirect_valid||!redirect_kill_ifid||redirect_pc!==model_epc||redirect_seq!==eseq[ri]||last_accept||dut.ram_issue_fire)
                        $fatal(1,"CSR MRET MEM authorization/priority mode=%0d case=%0d",MODE,case_no);
                    model_status=(model_status&32'hffffff77)|32'h80|(model_status[7]?32'h8:32'h0)|32'h1800;
                    if(enext[ri]!==model_epc)$fatal(1,"CSR test MRET oracle mismatch");total_mret=total_mret+1;
                    if(pre_wb&&pre_we)total_mret_old_wb=total_mret_old_wb+1;
                end else if(model_word[6:0]==7'h33&&model_word[31:25]==1)begin
                    if(!model_known[model_word[19:15]]||!model_known[model_word[24:20]])$fatal(1,"M oracle uninitialized source");
                    math_value=m_math(model_word[14:12],model_gpr[model_word[19:15]],model_gpr[model_word[24:20]]);
                    if(math_value!==eval[ri])$fatal(1,"M mathematical oracle differs from directed expected value");
                end else if(model_word[6:0]==7'h73&&model_word[14:12]!=0)begin
                    model_addr=model_word[31:20];funct=model_word[14:12];oldcsr=read_model(model_addr);
                    if(eval[ri]!==oldcsr)$fatal(1,"CSR read/RMW old value mode=%0d case=%0d csr=%h got=%h expected=%h",MODE,case_no,model_addr,eval[ri],oldcsr);
                    if(!funct[2]&&!model_known[model_word[19:15]])$fatal(1,"CSR oracle uninitialized source");
                    operand=funct[2]?{27'd0,model_word[19:15]}:model_gpr[model_word[19:15]];
                    write_intent=funct[1:0]==1||model_word[19:15]!=0;
                    case(funct[1:0])1:newcsr=operand;2:newcsr=oldcsr|operand;3:newcsr=oldcsr&~operand;default:$fatal(1,"CSR oracle funct");endcase
                    if(write_intent)case(model_addr)
                        12'h300:model_status=(newcsr&32'h88)|32'h1800;
                        12'h305:model_vector=newcsr&32'hfffffffc;
                        12'h340:model_scratch=newcsr;12'h341:model_epc=newcsr&32'hfffffffc;
                        12'h342:model_cause=newcsr;12'h343:model_tval=newcsr;
                        12'h301:begin end
                        default:$fatal(1,"CSR read-only ID write retired");
                    endcase
                    total_csr=total_csr+1;
                end
                if(erd[ri]!=0)begin model_gpr[erd[ri]]=eval[ri];model_known[erd[ri]]=1;end
                arch_expected=enext[ri];
            end
            #1;check_state;
            if(trap_valid!==pre_trap||retire_valid!==pre_retire)$fatal(1,"CSR registered event mismatch");
            if(pre_trap&&pre_wb_hold&&(!dut.memwb_valid_q||dut.memwb_q.seq!==pre_wb_seq||wb_pc!==pre_wb_pc||wb_data!==pre_wb_value||wb_rd!==pre_wb_rd))
                $fatal(1,"CSR trap destroyed held old WB");
            if(trap_seq!==saved_seq||trap_pc!==saved_pc||trap_cause!==saved_cause||trap_tval!==saved_tval)
                $fatal(1,"CSR software CSR write changed persistent trap descriptor");
            if(pre_retire)begin
                if(retire_seq!==eseq[ri]||retire_pc!==epc[ri]||retire_instr!==eins[ri]||retire_rd!==erd[ri]||retire_value!==eval[ri]||retire_writes_rd!==(erd[ri]!=0))
                    $fatal(1,"CSR retirement payload mode=%0d case=%0d index=%0d seq=%0d value=%h/%h rd=%0d/%0d",MODE,case_no,ri,retire_seq,retire_value,eval[ri],retire_rd,erd[ri]);
                retired=retired+1;total_retired=total_retired+1;
                $fdisplay(trace_fd,"retire,%0d,%0d,%h,%h,%h,%h",case_no,cycles,retire_seq,retire_pc,retire_instr,retire_value);
            end
            if(instret_count!==retired||arch_next_pc_q!==arch_expected)$fatal(1,"CSR instret/arch-next-PC mode=%0d case=%0d pc=%h/%h",MODE,case_no,arch_next_pc_q,arch_expected);
        end
    end
    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s8_m_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc,instruction_or_cause,value_or_tval");
        // Fixed hand-computed arithmetic anchors guard the mathematical oracle.
        if(m_math(0,32'hffffffff,2)!==32'hfffffffe||m_math(1,32'hffffffff,2)!==32'hffffffff||
            m_math(2,32'h80000000,32'hffffffff)!==32'h80000000||
            m_math(3,32'hffffffff,32'hffffffff)!==32'hfffffffe||
            m_math(4,32'hfffffff9,3)!==32'hfffffffe||m_math(6,32'hfffffff9,3)!==32'hffffffff||
            m_math(5,32'hffffffff,2)!==32'h7fffffff||m_math(7,32'hffffffff,2)!==1)
            $fatal(1,"M fixed arithmetic oracle anchors");
        for(op_no=0;op_no<8;op_no=op_no+1)begin
            reset_case(op_no+1);
            for(pair_no=0;pair_no<15;pair_no=pair_no+1)begin
                case(pair_no)
                    0:begin lhs_vec=0;rhs_vec=0;end
                    1:begin lhs_vec=1;rhs_vec=0;end
                    2:begin lhs_vec=32'hffffffff;rhs_vec=0;end
                    3:begin lhs_vec=32'h80000000;rhs_vec=32'hffffffff;end
                    4:begin lhs_vec=32'h80000000;rhs_vec=1;end
                    5:begin lhs_vec=32'hffffffff;rhs_vec=1;end
                    6:begin lhs_vec=32'hfffffff9;rhs_vec=3;end
                    7:begin lhs_vec=7;rhs_vec=32'hfffffffd;end
                    8:begin lhs_vec=32'hfffffff9;rhs_vec=32'hfffffffd;end
                    9:begin lhs_vec=32'h7fffffff;rhs_vec=32'h80000000;end
                    10:begin lhs_vec=32'h80000001;rhs_vec=32'h7fffffff;end
                    11:begin lhs_vec=32'hffffffff;rhs_vec=32'hffffffff;end
                    12:begin lhs_vec=32'hffffffff;rhs_vec=2;end
                    13:begin lhs_vec=32'h12345678;rhs_vec=32'h10001;end
                    14:begin lhs_vec=32'hf0f0f0f0;rhs_vec=32'hf0f;end
                endcase
                const32(1,lhs_vec);const32(2,rhs_vec);
                emit_m(op_no,3,1,2,m_math(op_no,lhs_vec,rhs_vec));
                emit(addi(4,3,1),4,m_math(op_no,lhs_vec,rhs_vec)+1);
            end
            emit_csr(2,10,'h301,0,'h40001100);finish_case;
        end

        reset_case(9);emit(addi(1,0,4),1,4);emit(addi(2,0,3),2,3);
        emit_m(0,5,1,2,12);emit_m(0,6,5,2,36);emit(addi(7,6,1),7,37);
        emit_csr(1,8,'h340,6,0);emit_csr(2,9,'h340,0,36);finish_case;

        // Consecutive old sticky done, zero/overflow fastpaths and ordinary
        // iterative/multiply paths must each produce a new generation.
        reset_case(10);const32(1,32'h80000000);const32(2,32'hffffffff);
        emit_m(4,5,1,0,32'hffffffff);emit_m(0,6,2,2,1);
        emit_m(4,7,1,2,32'h80000000);emit_m(6,8,1,2,0);
        emit_m(6,9,1,0,32'h80000000);emit_m(7,10,2,0,32'hffffffff);
        emit_m(5,11,2,2,1);emit_m(2,12,1,2,32'h80000000);finish_case;

        reset_case(11);emit(addi(1,0,123),1,123);emit(addi(2,0,7),2,7);wait_retired(2);repeat(2)tick;
        @(negedge clk);wb_ready=0;emit(addi(5,0,91),5,91);wait_retired(3);
        emit_m(4,6,1,2,17);repeat(45)tick;
        if(retired!=3||wb_count!=2||!dut.exmem_valid_q||!dut.exmem_q.is_m)$fatal(1,"M held WB fixture lost result");
        @(negedge clk);wb_ready=1;emit(addi(7,6,1),7,18);finish_case;

        reset_case(12);emit(addi(1,0,123),1,123);emit(addi(2,0,7),2,7);wait_retired(2);repeat(2)tick;
        @(negedge clk);mem_enable=0;emit_m(0,5,1,2,861);repeat(15)tick;
        if(retired!=2)$fatal(1,"M retired while MEM disabled");
        @(negedge clk);mem_enable=1;emit(addi(6,5,1),6,862);finish_case;

        reset_case(13);emit(addi(1,0,123),1,123);emit(addi(2,0,7),2,7);wait_retired(2);repeat(2)tick;
        emit_m(4,5,1,2,17);wait_m_started(1);@(negedge clk);ex_enable=0;wait_m_done;repeat(10)tick;
        if(!dut.m_owner_valid||dut.m_completion_result!==17||m_completed!=0)$fatal(1,"M completion not retained across EX hold");
        @(negedge clk);ex_enable=1;finish_case;

        reset_case(14);emit(addi(1,0,1000),1,1000);emit(addi(2,0,7),2,7);wait_retired(2);repeat(2)tick;
        expect_m(3,'h208,mop(4,5,1,2),142,1);send(3,'h208,mop(4,5,1,2));wait_m_started(1);flush_at(3);
        if(!dut.m_owner_valid||!dut.m_owner_killed||!dut.m_unit_busy)$fatal(1,"M running DIV did not persist for killed drain");
        s=6;p=VECTOR;emit(addi(6,0,19),6,19);emit_csr(2,7,'h301,0,'h40001100);
        emit_m(0,8,2,2,49);finish_case;

        reset_case(15);emit(addi(1,0,123),1,123);wait_retired(1);repeat(2)tick;
        expect_m(2,'h204,mop(4,5,1,0),32'hffffffff,1);send(2,'h204,mop(4,5,1,0));wait_m_started(1);flush_at(2);
        s=5;p=VECTOR;emit_m(0,6,1,1,15129);finish_case;

        // An older LOAD can still fault, so a younger M must not start yet.
        reset_case(16);emit(32'h000100b7,1,'h10000);emit(addi(2,0,7),2,7);emit(addi(3,0,3),3,3);wait_retired(3);
        expect_request(4,'h10000);expect_trap(4,'h20c,5,'h10000,VECTOR);send(4,'h20c,load(4,1,0));wait_requests(1);
        send(5,'h210,mop(0,5,2,3));repeat(8)tick;
        if(m_issued!=0)$fatal(1,"M younger op started before older LOAD error");
        respond(0,1);wait_traps(1);s=8;p=VECTOR;emit_csr(2,6,'h301,0,'h40001100);finish_case;

        reset_case(17);emit(32'h000100b7,1,'h10000);emit(addi(3,0,3),3,3);wait_retired(2);
        expect_request(s,'h10000);expect_packet(s,p,load(4,1,0),4,100,p+4);send(s,p,load(4,1,0));s=s+1;p=p+4;wait_requests(1);
        expect_m(s,p,mop(4,5,4,3),33,0);expect_packet(s,p,mop(4,5,4,3),5,33,p+4);send(s,p,mop(4,5,4,3));s=s+1;p=p+4;repeat(7)tick;
        if(m_issued!=0)$fatal(1,"M ignored older unresolved LOAD");respond(100,0);emit(addi(6,5,1),6,34);finish_case;

        reset_case(18);emit(addi(1,0,1000),1,1000);emit(addi(2,0,7),2,7);emit(addi(5,0,0),5,0);wait_retired(3);
        emit_m(4,5,1,2,142);wait_m_started(1);@(negedge clk);in_epoch=8'hfe;
        expect_packet(s,p,beq(5,0,8),0,0,p+4);send(s,p,beq(5,0,8));s=s+1;p=p+4;
        emit(addi(6,5,1),6,143);finish_case;

        reset_case(19);s=64'hffffffff;emit(addi(1,0,12),1,12);emit(addi(2,0,3),2,3);
        emit_m(0,5,1,2,36);emit_m(4,6,5,2,12);emit(addi(7,6,1),7,13);finish_case;

        reset_case(20);s=64'hffffffff;emit(addi(1,0,1000),1,1000);emit(addi(2,0,7),2,7);wait_retired(2);repeat(2)tick;
        expect_m(s,p,mop(4,5,1,2),142,1);send(s,p,mop(4,5,1,2));wait_m_started(1);flush_at(s);
        s=s+4;p=VECTOR;emit(addi(6,0,21),6,21);emit_m(0,7,2,2,49);finish_case;

        // Fetch error is already an exception packet, even if its data bits
        // decode an M instruction. It must reach MEM without allocating M.
        reset_case(21);word=mop(0,5,1,2);in_fetch_error=1;in_fetch_tval='hdead0000;
        expect_trap(1,'h200,1,'hdead0000,VECTOR);send(1,'h200,word);@(negedge clk);in_fetch_error=0;
        for(i=0;i<8&&traps==0;i=i+1)tick;
        if(traps!=1||m_issued!=0)$fatal(1,"M fault packet waited for nonexistent arithmetic completion");
        s=4;p=VECTOR;emit(addi(1,0,9),1,9);emit_m(0,5,1,1,81);finish_case;

        // The same fault must also pass an unrelated older killed DIV owner.
        reset_case(22);emit(addi(1,0,1000),1,1000);emit(addi(2,0,7),2,7);wait_retired(2);repeat(2)tick;
        expect_m(3,'h208,mop(4,5,1,2),142,1);send(3,'h208,mop(4,5,1,2));wait_m_started(1);flush_at(3);
        in_fetch_error=1;in_fetch_tval='hdead0004;expect_trap(6,'h300,1,'hdead0004,VECTOR);send(6,'h300,mop(0,6,1,2));
        @(negedge clk);in_fetch_error=0;
        for(i=0;i<8&&traps==0;i=i+1)tick;
        if(traps!=1||m_issued!=1||!dut.m_owner_valid||!dut.m_owner_killed)
            $fatal(1,"M fetch fault blocked or started during older killed drain");
        s=9;p=VECTOR;emit(addi(6,0,21),6,21);emit_csr(2,7,'h301,0,'h40001100);emit_m(0,8,2,2,49);finish_case;

        if(passed!=22||total_m_issued<140||total_m_completed<130||total_m_drained!=4||
            total_m_fast<15||total_m_busy<1000||total_m_held<5||total_old_load_block<10||
            total_handler_drain<3||total_m_wb_hold<3||total_status_checks<1000)
            $fatal(1,"M control coverage mode=%0d cases=%0d issued=%0d complete=%0d drained=%0d fast=%0d busy=%0d held=%0d loadblock=%0d handler=%0d wbhold=%0d",MODE,passed,total_m_issued,total_m_completed,total_m_drained,total_m_fast,total_m_busy,total_m_held,total_old_load_block,total_handler_drain,total_m_wb_hold);
        summary_fd=$fopen($sformatf("build/cpu5_s8_m_control/mode%0d_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"mode\":%0d,\"cases\":%0d,\"retired\":%0d,\"wb\":%0d,\"traps\":%0d,\"requests\":%0d,\"responses\":%0d,\"m_issued\":%0d,\"m_completed\":%0d,\"m_drained\":%0d,\"fast_results\":%0d,\"busy_edges\":%0d,\"held_completion_edges\":%0d,\"older_memory_block_edges\":%0d,\"handler_retire_during_m_drain\":%0d,\"m_mem_with_held_wb_edges\":%0d,\"committed_state_checks\":%0d}",
            MODE,passed,total_retired,total_wb,total_traps,total_requests,total_responses,total_m_issued,total_m_completed,total_m_drained,total_m_fast,total_m_busy,total_m_held,total_old_load_block,total_handler_drain,total_m_wb_hold,total_status_checks);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule
module cpu5_m_control_tb;
    wire [1:0] done;reg test_pass=0;
    cpu5_m_control_case #(.MODE(0)) ex_mode(done[0]);
    cpu5_m_control_case #(.MODE(1)) id_mode(done[1]);
    initial begin wait(&done);test_pass=1;$display("CPU5 M CONTROL TEST PASS");$stop;end
    initial begin #500000;$fatal(1,"CPU5 M control timeout");end
endmodule
