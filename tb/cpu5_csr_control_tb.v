`timescale 1ns/1ps
// Hand-authored instruction streams and an independent, retire-edge machine
// model. No force, deposit, or reference to RTL decode/RMW helper functions.
module cpu5_csr_control_case #(parameter integer MODE=0)(output reg done=0);
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
        .DMEM_WORDS(8),.ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.TRAP_VECTOR(VECTOR)) dut(.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),.perf_cycle_events(),.*);
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
    function [31:0] read_model(input [11:0] a);
        begin case(a)
            12'h300:read_model=model_status;12'h301:read_model=32'h40000100;
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
            case_no=n;expected=0;traps_expected=0;requests_expected=0;s=1;p='h200;
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
                dut.exmem_valid_q || dut.memwb_valid_q || dut.ram_owner_valid || bus_pending)begin
                tick;timeout=timeout+1;if(timeout>120)$fatal(1,"CSR drain mode=%0d case=%0d retire=%0d/%0d wb=%0d traps=%0d/%0d",MODE,case_no,retired,expected,wb_count,traps,traps_expected);
            end
            repeat(4)tick;
            if(requests!=requests_expected||responses!=requests)$fatal(1,"CSR D ledger not closed");
            for(j=1;j<32;j=j+1)if(model_known[j]&&dut.u_regfile.regs[j]!==model_gpr[j])
                $fatal(1,"CSR physical GPR mismatch mode=%0d case=%0d reg=%0d",MODE,case_no,j);
            passed=passed+1;$display("CPU5_CSR_CONTROL_CASE_PASS mode=%0d case=%0d retire=%0d traps=%0d req=%0d",MODE,case_no,retired,traps,requests);
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
            last_accept=0;last_rsp=0;last_trap=0;last_mret=0;model_known=1;model_gpr[0]=0;
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
            if(in_valid&&id_raw_wait)total_raw_wait=total_raw_wait+1;
            if(!mem_enable&&dut.exmem_valid_q)begin total_stall=total_stall+1;
                if(trap_fire||retire_fire||dut.csr_commit_fire||dut.mret_fire)$fatal(1,"CSR MEM enable ignored");end
            if(pre_wb_hold)total_held_wb=total_held_wb+1;
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
                model_word=eins[ri];
                if(model_word==32'h30200073)begin
                    if(!redirect_valid||!redirect_kill_ifid||redirect_pc!==model_epc||redirect_seq!==eseq[ri]||last_accept||dut.ram_issue_fire)
                        $fatal(1,"CSR MRET MEM authorization/priority mode=%0d case=%0d",MODE,case_no);
                    model_status=(model_status&32'hffffff77)|32'h80|(model_status[7]?32'h8:32'h0)|32'h1800;
                    if(enext[ri]!==model_epc)$fatal(1,"CSR test MRET oracle mismatch");total_mret=total_mret+1;
                    if(pre_wb&&pre_we)total_mret_old_wb=total_mret_old_wb+1;
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
        trace_fd=$fopen($sformatf("build/cpu5_s7_csr_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc,instruction_or_cause,value_or_tval");
        reset_case(1);
        emit_csr(2,5,'h300,0,'h1800);emit_csr(2,6,'h305,0,VECTOR);
        emit_csr(2,7,'h340,0,0);emit_csr(2,8,'h341,0,0);emit_csr(2,9,'h342,0,0);emit_csr(2,10,'h343,0,0);
        emit_csr(2,11,'h301,0,'h40000100);
        for(k='hf11;k<='hf15;k=k+1)emit_csr(2,12,k,0,0);
        emit_csr(2,0,'h300,0,'h1800);finish_case;

        reset_case(2);
        emit(addi(1,0,'h55),1,'h55);emit(addi(2,0,'ha),2,'ha);emit(addi(3,0,'hc),3,'hc);emit(addi(4,0,0),4,0);
        emit_csr(1,5,'h340,1,0);emit_csr(2,6,'h340,2,'h55);emit_csr(3,7,'h340,3,'h5f);
        emit_csr(2,8,'h340,0,'h53);emit_csr(3,9,'h340,0,'h53);
        emit_csr(2,10,'h340,4,'h53);emit_csr(3,11,'h340,4,'h53);
        emit_csr(1,0,'h340,0,'h53);emit_csr(2,12,'h340,0,0);finish_case;

        reset_case(3);
        emit_csr(5,5,'h340,31,0);emit_csr(6,6,'h340,16,31);emit_csr(7,7,'h340,3,31);
        emit_csr(6,8,'h340,0,28);emit_csr(7,9,'h340,0,28);emit_csr(5,10,'h340,0,28);
        emit_csr(2,11,'h340,0,0);finish_case;

        reset_case(4);emit(addi(1,0,-1),1,32'hffffffff);
        emit_csr(1,5,'h300,1,'h1800);emit_csr(2,6,'h300,0,'h1888);
        emit_csr(5,7,'h300,0,'h1888);emit_csr(6,8,'h300,8,'h1800);emit_csr(2,9,'h300,0,'h1808);
        emit_csr(1,5,'h305,1,VECTOR);emit_csr(2,6,'h305,0,32'hfffffffc);
        emit(addi(2,0,'h123),2,'h123);emit_csr(1,7,'h341,2,0);emit_csr(2,8,'h341,0,'h120);
        emit_csr(1,9,'h342,1,0);emit_csr(1,10,'h343,1,0);
        emit_csr(2,11,'h342,0,32'hffffffff);emit_csr(2,12,'h343,0,32'hffffffff);finish_case;

        // The newest CSR rd must supply the ALU operand even with an older WB
        // of the same register, and CSR RMW must see the preceding commit.
        reset_case(5);emit_csr(5,0,'h340,23,0);emit(addi(5,0,77),5,77);
        emit_csr(1,5,'h340,0,23);emit(addi(6,5,1),6,24);
        emit_csr(6,7,'h340,3,0);emit_csr(7,8,'h340,1,3);emit_csr(2,9,'h340,0,2);finish_case;

        reset_case(6);mem_enable=0;emit_csr(5,5,'h340,17,0);repeat(7)tick;
        if(retired||model_scratch)$fatal(1,"CSR changed before MEM enable");
        @(negedge clk);mem_enable=1;finish_case;

        reset_case(7);wb_ready=0;emit(addi(5,0,91),5,91);wait_retired(1);
        emit_csr(5,6,'h340,19,0);repeat(6)tick;
        if(retired!=1||model_scratch)$fatal(1,"CSR committed without WB slot");
        @(negedge clk);wb_ready=1;finish_case;

        reset_case(8);mem_enable=0;send(1,'h200,csr(5,5,'h340,27));repeat(3)tick;flush_at(1);
        @(negedge clk);mem_enable=1;s=4;p='h300;emit_csr(2,6,'h340,0,0);finish_case;

        reset_case(9);emit_csr(5,0,'h300,8,'h1800);emit(addi(1,0,'h403),1,'h403);
        emit_csr(1,0,'h305,1,VECTOR);emit(addi(2,0,'h503),2,'h503);emit_csr(1,0,'h341,2,0);
        expect_trap(s,p,11,0,'h400);send(s,p,32'h00000073);s=s+3;p='h400;wait_traps(1);
        emit_csr(2,5,'h300,0,'h1880);emit_csr(2,6,'h341,0,'h214);emit_csr(2,7,'h342,0,11);emit_csr(2,8,'h343,0,0);
        emit(addi(3,0,'h503),3,'h503);emit_csr(1,0,'h341,3,'h214);emit_csr(5,0,'h342,27,11);emit_csr(5,0,'h343,31,0);
        expect_packet(s,p,32'h30200073,0,0,'h500);send(s,p,32'h30200073);s=s+3;p='h500;wait_retired(expected);
        emit_csr(2,9,'h300,0,'h1888);emit_csr(2,10,'h341,0,'h500);finish_case;

        reset_case(10);expect_trap(1,'h200,11,0,VECTOR);send(1,'h200,32'h00000073);wait_traps(1);
        expect_trap(4,VECTOR,3,VECTOR,VECTOR);send(4,VECTOR,32'h00100073);wait_traps(2);
        s=7;p=VECTOR;emit_csr(2,5,'h300,0,'h1800);emit_csr(2,6,'h341,0,VECTOR);
        expect_packet(s,p,32'h30200073,0,0,VECTOR);send(s,p,32'h30200073);s=s+3;p=VECTOR;wait_retired(expected);
        emit_csr(2,7,'h300,0,'h1880);finish_case;

        reset_case(11);emit(addi(1,0,'h600),1,'h600);emit_csr(1,0,'h341,1,0);wait_retired(expected);
        @(negedge clk);mem_enable=0;expect_packet(s,p,32'h30200073,0,0,'h600);send(s,p,32'h30200073);
        send(s+1,p+4,load(6,0,0));offer(s+2,p+8,jal(7,16));repeat(5)tick;
        @(negedge clk);mem_enable=1;tick;wait_retired(expected);s=s+4;p='h600;emit_csr(2,8,'h300,0,'h1880);finish_case;

        reset_case(12);emit_csr(5,0,'h300,8,'h1800);wait_retired(expected);
        @(negedge clk);mem_enable=0;send(s,p,32'h30200073);repeat(3)tick;flush_at(s);
        @(negedge clk);mem_enable=1;s=s+3;p='h300;emit_csr(2,5,'h300,0,'h1808);finish_case;

        // An older LOAD error cancels a young CSR operation in EX.
        reset_case(13);emit(32'h000100b7,1,'h10000);wait_retired(expected);
        expect_trap(s,p,5,'h10000,VECTOR);expect_request(s,'h10000);send(s,p,load(5,1,0));wait_requests(1);
        send(s+1,p+4,csr(5,6,'h340,29));respond(0,1);wait_traps(1);
        s=s+4;p=VECTOR;emit_csr(2,7,'h340,0,0);finish_case;

        // A retired CSR rd is held independently while a younger trap saves
        // different software CSRs; release gives an old WB write on trap edge.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(14+stage);wb_ready=0;emit_csr(2,5,'h300,0,'h1800);wait_retired(1);
            mem_enable=0;expect_trap(2,'h204,11,0,VECTOR);send(2,'h204,32'h00000073);repeat(4)tick;
            @(negedge clk);mem_enable=1;if(stage)wb_ready=1;tick;wait_traps(1);
            if(!stage)begin repeat(4)tick;@(negedge clk);wb_ready=1;end
            s=5;p=VECTOR;emit(addi(6,5,1),6,'h1801);finish_case;
        end

        // CSR/MRET can progress while an externally canceled old pure LOAD
        // drains; the handler's LOAD must wait for that unique owner.
        for(stage=0;stage<2;stage=stage+1)begin
            reset_case(16+stage);emit(32'h000100b7,1,'h10000);wait_retired(1);
            dmem_req_ready=stage;expect_request(2,'h10000);send(2,'h204,load(5,1,0));
            if(stage)wait_requests(1);else begin timeout=0;while(!dmem_req_valid)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"CSR held D timeout");end repeat(3)tick;end
            flush_at(2);s=5;p='h300;emit(addi(2,0,'h700),2,'h700);emit_csr(1,0,'h341,2,0);
            expect_packet(s,p,32'h30200073,0,0,'h700);send(s,p,32'h30200073);wait_retired(expected);
            if(!dut.ram_owner_valid||!dut.ram_owner_killed)$fatal(1,"CSR MRET lost killed D drain");
            s=s+3;p='h700;emit(addi(7,0,19),7,19);wait_retired(expected);
            expect_packet(s,p,load(8,1,4),8,32'h12345678,p+4);expect_request(s,'h10004);send(s,p,load(8,1,4));repeat(4)tick;
            if(retired!=5||requests>stage)$fatal(1,"CSR handler LOAD stole draining owner");
            @(negedge clk);dmem_req_ready=1;wait_requests(1);respond('hdeadbeef,1);wait_requests(2);respond('h12345678,0);finish_case;
        end

        reset_case(18);s=64'hffffffff;emit_csr(5,5,'h340,21,0);
        expect_trap(s,p,11,0,VECTOR);send(s,p,32'h00000073);wait_traps(1);s=s+3;p=VECTOR;
        emit_csr(2,6,'h340,0,21);emit_csr(2,7,'h341,0,'h204);emit(addi(1,0,'h780),1,'h780);
        emit_csr(1,0,'h341,1,'h204);expect_packet(s,p,32'h30200073,0,0,'h780);send(s,p,32'h30200073);wait_retired(expected);finish_case;

        // Truthful fixed misa accepts writes without changing advertised I.
        reset_case(19);emit(addi(1,0,-1),1,32'hffffffff);
        emit_csr(1,5,'h301,0,'h40000100);emit_csr(2,6,'h301,1,'h40000100);emit_csr(3,7,'h301,1,'h40000100);
        emit_csr(5,8,'h301,31,'h40000100);emit_csr(6,9,'h301,31,'h40000100);emit_csr(7,10,'h301,31,'h40000100);
        emit_csr(2,11,'h301,0,'h40000100);finish_case;

        // Unimplemented interrupt/counter/unknown CSRs are precise illegal.
        for(stage=0;stage<11;stage=stage+1)begin
            reset_case(20+stage);
            case(stage)0:addr='h304;1:addr='h344;2:addr='hb00;3:addr='hb02;4:addr='hb80;5:addr='hb82;
                6:addr='hc00;7:addr='hc01;8:addr='hc02;9:addr='hfff;10:addr='h306;endcase
            word=csr(2,5,addr,0);expect_trap(1,'h200,2,word,VECTOR);send(1,'h200,word);wait_traps(1);
            s=4;p=VECTOR;emit_csr(2,6,'h342,0,2);emit_csr(2,7,'h343,0,word);finish_case;
        end

        // Read-only ID legality follows encoded write intent, even if a
        // nonzero source register happens to contain a zero value.
        for(stage=0;stage<5;stage=stage+1)begin
            reset_case(31+stage);emit(addi(1,0,0),1,0);word=csr(stage[0]?2:1,5,'hf11+stage,stage[0]?1:0);
            expect_trap(2,'h204,2,word,VECTOR);send(2,'h204,word);wait_traps(1);s=5;p=VECTOR;
            emit_csr(6,6,'hf11+stage,0,0);emit_csr(7,7,'hf11+stage,0,0);finish_case;
        end

        // Only the exact MRET machine word is accepted.
        for(stage=0;stage<5;stage=stage+1)begin
            reset_case(36+stage);
            case(stage)0:word=32'h302000f3;1:word=32'h30208073;2:word=32'h30201073;3:word=32'h10200073;4:word=32'h10500073;endcase
            expect_trap(1,'h200,2,word,VECTOR);send(1,'h200,word);wait_traps(1);s=4;p=VECTOR;
            emit_csr(2,6,'h341,0,'h200);emit_csr(2,7,'h343,0,word);finish_case;
        end

        // Fetch packet errors outrank the instruction bits, including an
        // unknown CSR encoding that would otherwise be illegal in MEM.
        reset_case(41);word=csr(2,5,'hfff,0);in_fetch_error=1;in_fetch_tval='hdead0000;
        expect_trap(1,'h200,1,'hdead0000,VECTOR);send(1,'h200,word);
        @(negedge clk);in_fetch_error=0;wait_traps(1);s=4;p=VECTOR;
        emit_csr(2,6,'h341,0,'h200);emit_csr(2,7,'h342,0,1);emit_csr(2,8,'h343,0,'hdead0000);finish_case;

        // MRET waits for its own WB packet slot while preserving an already
        // retired writer, then shares its retirement edge with that old WB.
        reset_case(42);wb_ready=0;emit(addi(5,0,91),5,91);wait_retired(1);
        expect_packet(2,'h204,32'h30200073,0,0,0);send(2,'h204,32'h30200073);repeat(6)tick;
        if(retired!=1||wb_count!=0)$fatal(1,"CSR MRET ignored full WB slot");
        @(negedge clk);wb_ready=1;#1;
        if(!dut.mret_fire||!wb_fire||!wb_we||wb_data!==91)
            $fatal(1,"CSR MRET lost simultaneous old WB write");
        tick;wait_retired(2);s=5;p=0;emit(addi(6,5,1),6,92);finish_case;

        // A pending newest CSR rd is ready for ID branch forwarding while its
        // commit waits for WB. An older held WB of x5 contains zero; selecting
        // it would wrongly take BEQ instead of observing the CSR's old value23.
        reset_case(43);emit_csr(5,0,'h340,23,0);wait_retired(1);repeat(2)tick;
        @(negedge clk);wb_ready=0;emit(addi(5,0,0),5,0);wait_retired(2);
        emit_csr(1,5,'h340,0,23);expect_packet(s,p,beq(5,0,8),0,0,p+4);
        send(s,p,beq(5,0,8));s=s+1;p=p+4;repeat(5)tick;
        if(retired!=2||model_scratch!==23)$fatal(1,"CSR branch fixture lost pending newest writer");
        @(negedge clk);wb_ready=1;emit(addi(6,5,1),6,24);emit_csr(2,7,'h340,0,0);finish_case;

        if(passed!=43||total_csr<120||total_mret<7||total_stall==0||total_held_wb==0||total_old_wb==0||
            total_killed!=2||total_drain<8||total_held_d==0||total_status_checks<500||
            total_mret_old_wb==0||(MODE&&total_pending_csr_branch==0))
            $fatal(1,"CSR coverage mode=%0d cases=%0d csr=%0d mret=%0d stalls=%0d oldwb=%0d killed=%0d drain=%0d checks=%0d",MODE,passed,total_csr,total_mret,total_stall,total_old_wb,total_killed,total_drain,total_status_checks);
        summary_fd=$fopen($sformatf("build/cpu5_s7_csr_control/mode%0d_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"mode\":%0d,\"cases\":%0d,\"csr_retired\":%0d,\"mret_retired\":%0d,\"traps\":%0d,\"retired\":%0d,\"wb\":%0d,\"requests\":%0d,\"responses\":%0d,\"mem_wait_edges\":%0d,\"held_wb_edges\":%0d,\"trap_with_old_wb_write\":%0d,\"killed_error_responses\":%0d,\"retire_during_killed_drain\":%0d,\"committed_state_checks\":%0d,\"raw_wait_edges\":%0d,\"held_d_edges\":%0d,\"mret_with_old_wb_write\":%0d,\"id_branch_from_pending_csr\":%0d}",
            MODE,passed,total_csr,total_mret,total_traps,total_retired,total_wb,total_requests,total_responses,total_stall,total_held_wb,total_old_wb,total_killed,total_drain,total_status_checks,total_raw_wait,total_held_d,total_mret_old_wb,total_pending_csr_branch);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule
module cpu5_csr_control_tb;
    wire [1:0] done;reg test_pass=0;
    cpu5_csr_control_case #(.MODE(0)) ex_mode(done[0]);
    cpu5_csr_control_case #(.MODE(1)) id_mode(done[1]);
    initial begin wait(&done);test_pass=1;$display("CPU5 CSR CONTROL TEST PASS");$stop;end
    initial begin #300000;$fatal(1,"CPU5 CSR control timeout");end
endmodule
