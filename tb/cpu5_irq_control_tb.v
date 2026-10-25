`timescale 1ns/1ps
// Hand-authored instruction streams and an independent, retire-edge machine
// model. No force, deposit, or reference to RTL decode/RMW helper functions.
module cpu5_irq_control_case #(parameter integer MODE=0)(output reg done=0);
    localparam [31:0] VECTOR=32'h100;
    reg clk=0;always #5 clk=~clk;
    reg irq_external=0,irq_software=0,irq_timer=0;
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
        .DMEM_WORDS(8),.ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.ENABLE_EXTERNAL_IRQ(1),.ENABLE_SOFTWARE_IRQ(1),.ENABLE_TIMER_IRQ(1),.TRAP_VECTOR(VECTOR)) dut(.perf_cycle_events(),.*);
    reg [63:0] eseq[0:255],tseq[0:15],qseq[0:15];
    reg [31:0] epc[0:255],eins[0:255],eval[0:255],enext[0:255];reg [4:0] erd[0:255];
    reg qw[0:15];reg [31:0] qdata[0:15];reg [3:0] qstrb[0:15];
    reg [31:0] tpc[0:15],tcause[0:15],ttval[0:15],tvector[0:15],qa[0:15];
    reg [31:0] model_gpr[0:31];reg [31:0] model_known=1;
    reg [31:0] model_status=32'h1800,model_vector=VECTOR,model_scratch=0,model_epc=0,model_cause=0,model_tval=0;
    reg [31:0] model_mie=0,model_meta=0,model_sync=0,model_pending_pre=0;
    reg model_arm=0,model_eligible=0,model_irq=0,model_safe=1,sync_expected_now=0;
    reg [31:0] model_irq_cause,model_irq_pc;reg [63:0] model_irq_seq;
    reg [63:0] live_seq[0:511];reg live_valid[0:511];integer live_count=0,li;
    integer irqs=0,irqs_expected=0,total_irqs=0,total_irq_with_old_wb=0,total_irq_with_held_wb=0;
    integer total_arm_edges=0,total_revoke_edges=0,total_irq_safe_edges=0,total_irq_while_m_drain=0,total_irq_while_d_drain=0;
    reg pre_irq=0,last_irq=0;
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
            12'h300:read_model=model_status;12'h304:read_model=model_mie;12'h344:read_model=model_sync;12'h301:read_model=32'h40001100;
            12'h305:read_model=model_vector;12'h340:read_model=model_scratch;
            12'h341:read_model=model_epc;12'h342:read_model=model_cause;12'h343:read_model=model_tval;
            12'hf11,12'hf12,12'hf13,12'hf14,12'hf15:read_model=0;
            default:begin read_model=32'hxxxxxxxx;$fatal(1,"CSR model unsupported retired address=%h",a);end
        endcase end
    endfunction
    task tick;
        begin @(posedge clk);#2;
            if((last_accept&&last_accept_seq==in_seq)||last_trap||last_mret||last_irq)in_valid=0;
        end
    endtask
    task reset_case(input integer n);
        begin @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            dmem_req_ready=1;dmem_rsp_valid=0;dmem_rsp_error=0;irq_external=0;irq_software=0;irq_timer=0;model_safe=1;sync_expected_now=0;
            case_no=n;expected=0;traps_expected=0;requests_expected=0;m_expected=0;irqs_expected=0;s=1;p='h200;
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
        begin qseq[requests_expected]=age;qa[requests_expected]=a;qw[requests_expected]=0;qdata[requests_expected]=0;qstrb[requests_expected]=0;requests_expected=requests_expected+1;end
    endtask
    task expect_store(input [63:0] age,input [31:0] a,input [31:0] data);
        begin qseq[requests_expected]=age;qa[requests_expected]=a;qw[requests_expected]=1;qdata[requests_expected]=data;qstrb[requests_expected]=15;requests_expected=requests_expected+1;end
    endtask
    function [31:0] store(input [4:0] b,input [4:0] a,input integer v);
        begin store={v[11:5],b,a,3'b010,v[4:0],7'h23};end
    endfunction
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
    task wait_irqs(input integer n);
        begin timeout=0;while(irqs<n)begin tick;timeout=timeout+1;
            if(timeout>50)$fatal(1,"IRQ bounded delivery timeout mode=%0d case=%0d events=%0d/%0d",MODE,case_no,irqs,n);end end
    endtask
    task enable_external;
        begin emit(addi(1,0,'h800),1,32'hfffff800);emit_csr(1,0,'h304,1,0);
            emit_csr(5,0,'h300,8,'h1800);wait_retired(expected);repeat(2)tick;end
    endtask
    task quiet_sources;
        begin @(negedge clk);irq_external=0;irq_software=0;irq_timer=0;end
    endtask
    task wait_armed;
        begin repeat(4)tick;if(!model_arm)$fatal(1,"IRQ stimulus failed to form armed candidate");end
    endtask
    task finish_case;
        begin in_valid=0;timeout=0;
            while(retired!=expected || wb_count!=expected || traps!=traps_expected || irqs!=irqs_expected || dut.idex_valid_q ||
                dut.exmem_valid_q || dut.memwb_valid_q || dut.ram_owner_valid || dut.m_owner_valid || bus_pending)begin
                tick;timeout=timeout+1;if(timeout>120)$fatal(1,"CSR drain mode=%0d case=%0d retire=%0d/%0d wb=%0d traps=%0d/%0d",MODE,case_no,retired,expected,wb_count,traps,traps_expected);
            end
            repeat(4)tick;
            if(requests!=requests_expected||responses!=requests)$fatal(1,"M D ledger not closed");
            if(m_issued!=m_expected||m_completed+m_drained!=m_issued)$fatal(1,"M issue/completion ledger not closed mode=%0d case=%0d starts=%0d/%0d complete=%0d drain=%0d",MODE,case_no,m_issued,m_expected,m_completed,m_drained);
            for(j=1;j<32;j=j+1)if(model_known[j]&&dut.u_regfile.regs[j]!==model_gpr[j])
                $fatal(1,"CSR physical GPR mismatch mode=%0d case=%0d reg=%0d",MODE,case_no,j);
            passed=passed+1;$display("CPU5_IRQ_CONTROL_CASE_PASS mode=%0d case=%0d retire=%0d traps=%0d req=%0d",MODE,case_no,retired,traps,requests);
        end
    endtask
    task check_state;
        begin
            if(dut.g_csr.u_csr.csr_mie!==model_mie||dut.g_csr.u_csr.csr_mstatus!==model_status||dut.g_csr.u_csr.csr_mtvec!==model_vector||
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
            last_accept=0;last_rsp=0;last_trap=0;last_mret=0;last_irq=0;irqs=0;live_count=0;model_mie=0;model_arm=0;model_meta=0;model_sync=0;m_issued=0;m_completed=0;m_drained=0;m_active=-1;m_held=0;m_just_started=0;model_known=1;model_gpr[0]=0;
            arch_expected=0;saved_seq=0;saved_pc=0;saved_cause=0;saved_tval=0;
            model_status='h1800;model_vector=VECTOR;model_scratch=0;model_epc=0;model_cause=0;model_tval=0;
            if(wb_we||retire_fire||trap_fire||dut.irq_take||redirect_valid||dmem_req_valid||dmem_rsp_ready)$fatal(1,"CSR reset side effect");
            #1;check_state;
            if(trap_valid||retire_valid||trap_pc!==0||trap_cause!==0||trap_tval!==0||trap_seq!==0||instret_count!==0||arch_next_pc_q!==0)
                $fatal(1,"CSR reset descriptor state");
        end else begin
            check_state;
            model_pending_pre=model_sync;
            model_eligible=model_status[3]&&|(model_mie&model_pending_pre);
            model_irq=model_arm&&model_eligible&&model_safe&&mem_enable&&!flush_valid&&!sync_expected_now;
            if(dut.irq_pending_sync!==model_pending_pre||dut.irq_arm_q!==model_arm||dut.irq_eligible_now!==model_eligible||dut.irq_take!==model_irq)
                $fatal(1,"IRQ independent arbitration model mode=%0d case=%0d pending=%h/%h arm=%b/%b eligible=%b/%b take=%b/%b",MODE,case_no,dut.irq_pending_sync,model_pending_pre,dut.irq_arm_q,model_arm,dut.irq_eligible_now,model_eligible,dut.irq_take,model_irq);
            if(model_arm)total_arm_edges=total_arm_edges+1;
            if(model_arm&&!model_eligible)total_revoke_edges=total_revoke_edges+1;
            pre_irq=model_irq;last_irq=model_irq;
            model_irq_pc=arch_expected;model_irq_seq=64'hffffffffffffffff;
            for(li=0;li<live_count;li=li+1)if(live_valid[li]&&live_seq[li]<model_irq_seq)model_irq_seq=live_seq[li];
            if(in_valid&&in_seq<model_irq_seq)model_irq_seq=in_seq;
            model_irq_cause=(model_mie[11]&&model_pending_pre[11])?32'h8000000b:
                (model_mie[3]&&model_pending_pre[3])?32'h80000003:32'h80000007;
            last_accept=in_valid&&in_ready;last_accept_seq=in_seq;last_rsp=dmem_rsp_valid&&dmem_rsp_ready;
            pre_trap=trap_fire;last_trap=trap_fire;pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;
            last_mret=pre_retire&&dut.exmem_q.instr==32'h30200073;
            pre_wb_hold=dut.memwb_valid_q&&!wb_ready;pre_wb_seq=dut.memwb_q.seq;
            pre_wb_pc=wb_pc;pre_wb_value=wb_data;pre_wb_rd=wb_rd;
            if(last_accept)begin live_seq[live_count]=in_seq;live_valid[live_count]=1;live_count=live_count+1;end
            if(flush_fire)for(li=0;li<live_count;li=li+1)if(live_seq[li]>=flush_cut_seq)live_valid[li]=0;
            ri=retired;wi=wb_count;ti=traps;
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
                if(trap_fire||pre_irq||retire_fire||dut.csr_commit_fire||dut.mret_fire)$fatal(1,"CSR MEM enable ignored");end
            if(pre_wb_hold)total_held_wb=total_held_wb+1;
            if(pre_wb_hold&&dut.exmem_valid_q&&dut.exmem_q.is_m)total_m_wb_hold=total_m_wb_hold+1;
            if(held&&(!dmem_req_valid||{dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq}!==held_fields))
                $fatal(1,"CSR changed held D request");
            held=dmem_req_valid&&!dmem_req_ready;
            held_fields={dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq};
            if(held)total_held_d=total_held_d+1;
            if(dmem_req_valid&&(requests>=requests_expected||dut.ram_req_seq!==qseq[requests]||
                dmem_req_addr!==qa[requests]||dmem_req_write!==qw[requests]||dmem_req_size!==2||dmem_req_wstrb!==qstrb[requests]||dmem_req_wdata!==qdata[requests]))
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
            if(pre_irq)begin
                if(irqs>=irqs_expected||pre_trap||pre_retire||bp_commit_valid||last_accept||!redirect_valid||!redirect_kill_ifid||
                    redirect_pc!==model_vector||redirect_seq!==model_irq_seq||dut.ram_issue_fire||dut.m_issue_fire)
                    $fatal(1,"IRQ entry priority/diagnostic owner mode=%0d case=%0d seq=%h/%h pc=%h",MODE,case_no,redirect_seq,model_irq_seq,redirect_pc);
                if(pre_wb&&pre_we)total_irq_with_old_wb=total_irq_with_old_wb+1;
                if(pre_wb_hold)total_irq_with_held_wb=total_irq_with_held_wb+1;
                if(dut.m_owner_valid&&dut.m_owner_killed)total_irq_while_m_drain=total_irq_while_m_drain+1;
                if(dut.ram_owner_valid&&dut.ram_owner_killed)total_irq_while_d_drain=total_irq_while_d_drain+1;
                model_epc=model_irq_pc&32'hfffffffc;model_cause=model_irq_cause;model_tval=0;
                model_status='h1800|(model_status[3]?'h80:0);
                saved_pc=model_irq_pc;saved_cause=model_irq_cause;saved_tval=0;saved_seq=model_irq_seq;
                arch_expected=model_vector;irqs=irqs+1;total_irqs=total_irqs+1;total_irq_safe_edges=total_irq_safe_edges+1;
                $fdisplay(trace_fd,"irq,%0d,%0d,%h,%h,%h,%h",case_no,cycles,saved_seq,saved_pc,saved_cause,saved_tval);
                for(li=0;li<live_count;li=li+1)live_valid[li]=0;
            end else if(pre_trap)begin
                if(ti>=traps_expected||dut.exmem_q.seq!==tseq[ti]||dut.exmem_q.pc!==tpc[ti]||halt_cause!==tcause[ti]||halt_tval!==ttval[ti]||
                    pre_retire||bp_commit_valid||last_accept||!redirect_valid||!redirect_kill_ifid||redirect_pc!==tvector[ti]||redirect_seq!==tseq[ti])
                    $fatal(1,"CSR precise trap/priority mode=%0d case=%0d event=%0d seq=%0d pc=%h cause=%0d tval=%h redirect=%h",MODE,case_no,ti,dut.exmem_q.seq,dut.exmem_q.pc,halt_cause,halt_tval,redirect_pc);
                if(pre_wb&&pre_we)total_old_wb=total_old_wb+1;
                model_status={19'd0,2'b11,3'd0,model_status[3],3'd0,1'b0,3'd0};
                model_epc=tpc[ti]&32'hfffffffc;model_cause=tcause[ti];model_tval=ttval[ti];
                saved_seq=tseq[ti];saved_pc=tpc[ti];saved_cause=tcause[ti];saved_tval=ttval[ti];
                arch_expected=tvector[ti];traps=traps+1;total_traps=total_traps+1;
                $fdisplay(trace_fd,"trap,%0d,%0d,%h,%h,%h,%h",case_no,cycles,tseq[ti],tpc[ti],tcause[ti],ttval[ti]);
                for(li=0;li<live_count;li=li+1)live_valid[li]=0;
            end else if(redirect_valid&&!last_mret)$fatal(1,"CSR unexpected younger redirect mode=%0d case=%0d seq=%0d",MODE,case_no,redirect_seq);
            if(pre_retire)begin
                if(ri>=expected||dut.exmem_q.seq!==eseq[ri]||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri])
                    $fatal(1,"CSR killed/fault token retired mode=%0d case=%0d index=%0d seq=%0d",MODE,case_no,ri,dut.exmem_q.seq);
                if(dut.ram_owner_valid&&dut.ram_owner_killed)total_drain=total_drain+1;
                if(dut.m_owner_valid&&dut.m_owner_killed)total_handler_drain=total_handler_drain+1;
                for(li=0;li<live_count;li=li+1)if(live_seq[li]==eseq[ri])live_valid[li]=0;
                model_word=eins[ri];
                if(model_word==32'h30200073)begin
                    if(!redirect_valid||!redirect_kill_ifid||redirect_pc!==model_epc||redirect_seq!==eseq[ri]||last_accept||dut.ram_issue_fire)
                        $fatal(1,"CSR MRET MEM authorization/priority mode=%0d case=%0d",MODE,case_no);
                    model_status=(model_status&32'hffffff77)|32'h80|(model_status[7]?32'h8:32'h0)|32'h1800;
                    if(enext[ri]!==model_epc)$fatal(1,"CSR test MRET oracle mismatch");total_mret=total_mret+1;
                    if(pre_wb&&pre_we)total_mret_old_wb=total_mret_old_wb+1;
                    for(li=0;li<live_count;li=li+1)live_valid[li]=0;
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
                        12'h304:model_mie=newcsr&32'h888;12'h344:begin end
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
            if(pre_irq||pre_trap)model_arm=0;
            else model_arm=model_status[3]&&|(model_mie&model_pending_pre);
            model_sync=model_meta;model_meta=(irq_external?32'h800:0)|(irq_software?32'h8:0)|(irq_timer?32'h80:0);
            #1;check_state;
            if(dut.irq_arm_q!==model_arm||dut.irq_pending_sync!==model_sync)$fatal(1,"IRQ post-commit arm/synchronizer model");
            if(trap_valid!==(pre_trap||pre_irq)||retire_valid!==pre_retire)$fatal(1,"CSR registered event mismatch");
            if((pre_trap||pre_irq)&&pre_wb_hold&&(!dut.memwb_valid_q||dut.memwb_q.seq!==pre_wb_seq||wb_pc!==pre_wb_pc||wb_data!==pre_wb_value||wb_rd!==pre_wb_rd))
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
        trace_fd=$fopen($sformatf("build/cpu5_s9_irq_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc,instruction_or_cause,value_or_tval");
        reset_case(1);emit(addi(1,0,-1),1,32'hffffffff);emit_csr(1,5,'h304,1,0);emit_csr(2,6,'h304,0,'h888);emit_csr(2,10,'h344,0,0);
        @(negedge clk);irq_external=1;irq_software=1;irq_timer=1;repeat(4)tick;
        emit_csr(2,7,'h344,0,'h888);emit_csr(1,8,'h344,0,'h888);emit_csr(2,9,'h344,0,'h888);quiet_sources;repeat(3)tick;finish_case;

        // With uninterrupted ordinary ALU work, first eligible synchronized
        // sample permits one retirement; the immediately following E takes.
        reset_case(2);enable_external;irqs_expected=1;
        expect_packet(s,p,addi(5,0,11),5,11,p+4);offer(s,p,addi(5,0,11));irq_external=1;tick;
        if(!last_accept)$fatal(1,"IRQ continuous ALU fixture admission");s=s+1;p=p+4;
        send(s,p,addi(6,0,22));s=s+1;p=p+4;
        send(s,p,addi(7,0,33));s=s+1;p=p+4;offer(s,p,addi(8,0,44));tick;wait_irqs(1);quiet_sources;
        s=s+3;p=VECTOR;emit_csr(2,10,'h342,0,'h8000000b);finish_case;

        // A CSR enable at T0 forms arm from its newly committed MIE; T1 takes.
        reset_case(3);emit(addi(1,0,'h800),1,32'hfffff800);emit_csr(1,0,'h304,1,0);wait_retired(expected);
        @(negedge clk);irq_external=1;repeat(4)tick;irqs_expected=1;
        emit_csr(5,0,'h300,8,'h1800);wait_retired(expected);tick;
        if(irqs!=1)$fatal(1,"IRQ CSR-enable T0/T1 latency");quiet_sources;s=s+3;p=VECTOR;
        emit_csr(2,5,'h300,0,'h1880);finish_case;

        reset_case(4);emit(addi(1,0,'h800),1,32'hfffff800);emit_csr(1,0,'h304,1,0);
        emit(addi(2,0,'h80),2,'h80);emit_csr(1,0,'h300,2,'h1800);emit(addi(3,0,'h700),3,'h700);emit_csr(1,0,'h341,3,0);wait_retired(expected);
        @(negedge clk);irq_external=1;repeat(4)tick;irqs_expected=1;
        expect_packet(s,p,32'h30200073,0,0,'h700);send(s,p,32'h30200073);wait_retired(expected);tick;
        if(irqs!=1||model_epc!=='h700)$fatal(1,"IRQ MRET T0/T1 return-PC latency");quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h341,0,'h700);finish_case;

        // The queued CSR-disable is uncommitted when an already armed IRQ wins.
        reset_case(5);enable_external;mem_enable=0;send(s,p,csr(5,0,'h300,0));repeat(3)tick;
        @(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        @(negedge clk);mem_enable=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h300,0,'h1880);finish_case;

        reset_case(6);enable_external;mem_enable=0;emit(addi(5,0,17),5,17);repeat(3)tick;
        @(negedge clk);irq_external=1;wait_armed;quiet_sources;repeat(2)tick;
        if(!model_arm||model_sync!=0)$fatal(1,"IRQ revoked pending fixture lacks old armed/current ineligible edge");
        @(negedge clk);mem_enable=1;tick;
        if(model_arm||irqs)$fatal(1,"IRQ revoked pending did not withdraw candidate");finish_case;

        // All sources stay high through the first event; mask/priority choose
        // external, then software, then timer as each prior source disappears.
        reset_case(7);emit(addi(1,0,-1),1,32'hffffffff);emit_csr(1,0,'h304,1,0);wait_retired(expected);
        @(negedge clk);irq_external=1;irq_software=1;irq_timer=1;repeat(4)tick;irqs_expected=3;
        emit_csr(5,0,'h300,8,'h1800);wait_irqs(1);s=s+3;p=VECTOR;emit_csr(2,5,'h342,0,'h8000000b);
        @(negedge clk);irq_external=0;repeat(3)tick;
        expect_packet(s,p,32'h30200073,0,0,'h20c);send(s,p,32'h30200073);wait_retired(expected);wait_irqs(2);
        s=s+3;p=VECTOR;emit_csr(2,6,'h342,0,'h80000003);@(negedge clk);irq_software=0;repeat(3)tick;
        expect_packet(s,p,32'h30200073,0,0,'h20c);send(s,p,32'h30200073);wait_retired(expected);wait_irqs(3);
        quiet_sources;s=s+3;p=VECTOR;emit_csr(2,7,'h342,0,'h80000007);finish_case;

        reset_case(8);emit(addi(1,0,'h80),1,'h80);emit_csr(1,0,'h304,1,0);wait_retired(expected);
        @(negedge clk);irq_external=1;irq_software=1;irq_timer=1;repeat(4)tick;irqs_expected=1;
        emit_csr(5,0,'h300,8,'h1800);wait_irqs(1);quiet_sources;s=s+3;p=VECTOR;emit_csr(2,5,'h342,0,'h80000007);finish_case;

        reset_case(9);enable_external;wb_ready=0;emit(addi(5,0,91),5,91);wait_retired(expected);
        @(negedge clk);irq_external=1;irqs_expected=1;wait_irqs(1);quiet_sources;repeat(4)tick;
        @(negedge clk);wb_ready=1;s=s+4;p=VECTOR;emit(addi(6,5,1),6,92);finish_case;

        reset_case(10);enable_external;wb_ready=0;emit(addi(5,0,91),5,91);wait_retired(expected);mem_enable=0;
        @(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        @(negedge clk);mem_enable=1;wb_ready=1;#1;if(!wb_we||!dut.irq_take)$fatal(1,"IRQ old WB simultaneous edge absent");
        tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit(addi(6,5,1),6,92);finish_case;

        reset_case(11);enable_external;mem_enable=0;expect_trap(s,p,11,0,VECTOR);send(s,p,32'h00000073);repeat(3)tick;
        @(negedge clk);irq_external=1;wait_armed;
        @(negedge clk);mem_enable=1;sync_expected_now=1;tick;@(negedge clk);sync_expected_now=0;wait_traps(1);
        quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h342,0,11);finish_case;

        // An unissued MEM STORE has no external side effect and is preemptible.
        reset_case(12);enable_external;emit(32'h00010137,2,'h10000);emit(addi(3,0,'h55),3,'h55);wait_retired(expected);
        mem_enable=0;send(s,p,store(3,2,0));repeat(3)tick;@(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        if(dmem_req_valid||requests)$fatal(1,"IRQ unissued STORE prematurely presented");
        @(negedge clk);mem_enable=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h342,0,'h8000000b);finish_case;

        // Once a STORE is presented, held, accepted and completing phases all
        // defer IRQ through its successful retirement, then take next E.
        reset_case(13);enable_external;emit(32'h00010137,2,'h10000);emit(addi(3,0,'h55),3,'h55);wait_retired(expected);
        dmem_req_ready=0;expect_store(s,'h10000,'h55);emit(store(3,2,0),0,0);
        timeout=0;while(!dmem_req_valid)begin tick;timeout=timeout+1;if(timeout>50)$fatal(1,"IRQ held STORE fixture");end
        model_safe=0;@(negedge clk);irq_external=1;irqs_expected=1;wait_armed;repeat(3)tick;
        @(negedge clk);dmem_req_ready=1;wait_requests(1);repeat(3)tick;respond(0,0);model_safe=1;tick;wait_irqs(1);
        quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h342,0,'h8000000b);finish_case;

        reset_case(14);enable_external;emit(32'h00010137,2,'h10000);emit(addi(3,0,'h55),3,'h55);wait_retired(expected);
        expect_store(s,'h10000,'h55);expect_trap(s,p,7,'h10000,VECTOR);send(s,p,store(3,2,0));wait_requests(1);model_safe=0;
        @(negedge clk);irq_external=1;wait_armed;sync_expected_now=1;respond(0,1);sync_expected_now=0;model_safe=1;wait_traps(1);
        quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h342,0,7);finish_case;

        reset_case(15);enable_external;emit(32'h00010137,2,'h10000);emit(addi(3,0,'h66),3,'h66);wait_retired(expected);
        expect_store(s,'h10000,'h66);emit(store(3,2,0),0,0);wait_requests(1);model_safe=0;
        @(negedge clk);irq_external=1;irqs_expected=1;wait_armed;mem_enable=0;respond(0,0);repeat(4)tick;
        @(negedge clk);mem_enable=1;tick;model_safe=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h342,0,'h8000000b);finish_case;

        reset_case(16);enable_external;emit(32'h00010137,2,'h10000);wait_retired(expected);
        expect_request(s,'h10000);expect_packet(s,p,load(5,2,0),5,'h12345678,p+4);send(s,p,load(5,2,0));s=s+1;p=p+4;wait_requests(1);model_safe=0;
        @(negedge clk);irq_external=1;irqs_expected=1;wait_armed;respond('h12345678,0);model_safe=1;tick;wait_irqs(1);quiet_sources;
        s=s+4;p=VECTOR;emit(addi(6,5,1),6,'h12345679);finish_case;

        reset_case(17);enable_external;emit(32'h00010137,2,'h10000);wait_retired(expected);
        expect_request(s,'h10000);expect_trap(s,p,5,'h10000,VECTOR);send(s,p,load(5,2,0));wait_requests(1);model_safe=0;
        @(negedge clk);irq_external=1;wait_armed;sync_expected_now=1;respond(0,1);sync_expected_now=0;model_safe=1;wait_traps(1);
        quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h342,0,5);finish_case;

        reset_case(18);enable_external;emit(addi(2,0,1000),2,1000);emit(addi(3,0,7),3,7);wait_retired(expected);
        expect_m(s,p,mop(4,5,2,3),142,1);send(s,p,mop(4,5,2,3));wait_m_started(1);
        @(negedge clk);irq_external=1;irqs_expected=1;wait_irqs(1);
        if(!dut.m_owner_valid||!dut.m_owner_killed||!dut.m_unit_busy)$fatal(1,"IRQ did not cancel running M owner");
        quiet_sources;s=s+4;p=VECTOR;
        emit(addi(6,0,19),6,19);emit_csr(2,7,'h342,0,'h8000000b);emit_m(0,8,3,3,49);finish_case;

        // A held canceled pure read continues unchanged across IRQ and errors
        // only drain. Handler ALU/CSR progress before its physical response.
        reset_case(19);enable_external;emit(32'h00010137,2,'h10000);wait_retired(expected);
        dmem_req_ready=0;expect_request(s,'h10000);send(s,p,load(5,2,0));repeat(3)tick;flush_at(s);
        @(negedge clk);irq_external=1;irqs_expected=1;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;
        emit(addi(6,0,23),6,23);emit_csr(2,7,'h342,0,'h8000000b);wait_retired(expected);
        @(negedge clk);dmem_req_ready=1;wait_requests(1);respond('hdeadbeef,1);finish_case;

        reset_case(20);enable_external;@(negedge clk);flush_valid=1;flush_cut_seq=64'hfffffffffffffffe;irq_external=1;irqs_expected=1;wait_armed;repeat(3)tick;
        @(negedge clk);flush_valid=0;tick;wait_irqs(1);quiet_sources;finish_case;

        reset_case(21);enable_external;s=64'hffffffff;p=32'h80000000;emit(addi(5,0,9),5,9);wait_retired(expected);mem_enable=0;
        send(s,p,addi(6,0,33));repeat(3)tick;@(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        @(negedge clk);mem_enable=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit_csr(2,7,'h341,0,32'h80000004);finish_case;

        // EX M is cancelable: an armed IRQ also suppresses a would-be first M
        // start, then the handler's independent multiply obtains a new owner.
        reset_case(22);enable_external;emit(addi(2,0,7),2,7);wait_retired(expected);mem_enable=0;ex_enable=0;
        send(s,p,mop(0,5,2,2));@(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        @(negedge clk);mem_enable=1;ex_enable=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit_m(0,6,2,2,49);finish_case;

        reset_case(23);enable_external;mem_enable=0;send(s,p,addi(5,0,11));s=s+1;p=p+4;send(s,p,addi(6,0,22));s=s+1;p=p+4;
        offer(s,p,jal(7,16));@(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        @(negedge clk);mem_enable=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit(addi(8,0,31),8,31);finish_case;

        // Enabling mie (rather than mstatus) also uses the T0 post-commit
        // candidate and must deliver on T1 with the newly committed mask.
        reset_case(24);emit_csr(5,0,'h300,8,'h1800);emit(addi(1,0,'h800),1,32'hfffff800);wait_retired(expected);
        @(negedge clk);irq_external=1;repeat(4)tick;irqs_expected=1;
        emit_csr(1,0,'h304,1,0);wait_retired(expected);tick;
        if(irqs!=1)$fatal(1,"IRQ mie-enable T0/T1 latency");quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h304,0,'h800);finish_case;

        reset_case(25);enable_external;mem_enable=0;send(s,p,csr(5,0,'h304,0));repeat(3)tick;
        @(negedge clk);irq_external=1;irqs_expected=1;wait_armed;
        @(negedge clk);mem_enable=1;tick;wait_irqs(1);quiet_sources;s=s+4;p=VECTOR;emit_csr(2,5,'h304,0,'h800);finish_case;

        // Volatile MIP must not be captured by an ID branch before the CSR
        // can retire. Change synchronized pending while WB is full / MEM is
        // paused; the eventual CSR result and branch must both observe 0x800.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(26+stage);wb_ready=0;emit(addi(5,0,0),5,0);wait_retired(1);
            if(stage)begin @(negedge clk);wb_ready=1;mem_enable=0;end
            emit_csr(2,5,'h344,0,'h800);expect_packet(s,p,beq(5,0,8),0,0,p+4);
            offer(s,p,beq(5,0,8));repeat(5)tick;
            if(MODE&&!in_valid)$fatal(1,"IRQ volatile MIP branch captured before CSR retirement");
            @(negedge clk);irq_external=1;repeat(4)tick;
            if(retired!=1||model_sync!=='h800)$fatal(1,"IRQ volatile MIP fixture lost pending transition");
            @(negedge clk);wb_ready=1;mem_enable=1;tick;
            if(MODE&&!(last_accept&&last_accept_seq==s))$fatal(1,"IRQ volatile MIP branch did not resolve with retiring CSR");
            s=s+1;p=p+4;emit(addi(6,5,1),6,'h801);finish_case;
        end

        if(passed!=27||total_irqs<22||total_irq_with_held_wb==0||total_irq_with_old_wb==0||total_revoke_edges==0||
            total_m_drained!=1||total_m_completed!=2||total_killed!=1||total_handler_drain<2||total_held_d==0)
            $fatal(1,"IRQ coverage mode=%0d cases=%0d irq=%0d heldWB=%0d writeWB=%0d revoke=%0d Mdrain=%0d Mcomplete=%0d Dkill=%0d handler=%0d",MODE,passed,total_irqs,total_irq_with_held_wb,total_irq_with_old_wb,total_revoke_edges,total_m_drained,total_m_completed,total_killed,total_handler_drain);
        summary_fd=$fopen($sformatf("build/cpu5_s9_irq_control/mode%0d_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"mode\":%0d,\"cases\":%0d,\"retired\":%0d,\"wb\":%0d,\"sync_traps\":%0d,\"irqs\":%0d,\"requests\":%0d,\"responses\":%0d,\"m_issued\":%0d,\"m_completed\":%0d,\"m_drained\":%0d,\"irq_with_old_wb_write\":%0d,\"irq_with_held_wb\":%0d,\"revoked_arm_edges\":%0d,\"arm_edges\":%0d,\"killed_d_responses\":%0d,\"handler_retire_during_m_drain\":%0d,\"held_d_edges\":%0d,\"committed_state_checks\":%0d}",
            MODE,passed,total_retired,total_wb,total_traps,total_irqs,total_requests,total_responses,total_m_issued,total_m_completed,total_m_drained,total_irq_with_old_wb,total_irq_with_held_wb,total_revoke_edges,total_arm_edges,total_killed,total_handler_drain,total_held_d,total_status_checks);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule
module cpu5_irq_control_tb;
    wire [1:0] done;reg test_pass=0;
    cpu5_irq_control_case #(.MODE(0)) ex_mode(done[0]);
    cpu5_irq_control_case #(.MODE(1)) id_mode(done[1]);
    initial begin wait(&done);test_pass=1;$display("CPU5 IRQ CONTROL TEST PASS");$stop;end
    initial begin #500000;$fatal(1,"CPU5 IRQ control timeout");end
endmodule
