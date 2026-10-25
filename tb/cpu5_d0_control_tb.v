`timescale 1ns/1ps
// Hand-authored instruction streams and an independent, retire-edge machine
// model. No force, deposit, or reference to RTL decode/RMW helper functions.
module cpu5_d0_control_case #(parameter integer D0=1,CACHE=1,WAIT=0,MODE=0,FENCE_FEATURE=1)(output reg done=0);
    localparam [31:0] VECTOR=32'h100;
    localparam integer CONFIG=D0*4+CACHE*2+WAIT;
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
    wire dmem_req_ready,dmem_rsp_valid,dmem_rsp_error;wire [31:0] dmem_rsp_rdata;
    wire backend_req_valid,backend_req_write,backend_rsp_ready;
    wire [31:0] backend_req_addr,backend_req_wdata;wire [1:0] backend_req_size;wire [3:0] backend_req_wstrb;
    wire backend_req_ready,backend_rsp_valid,backend_rsp_error;wire [31:0] backend_rsp_rdata;
    wire [31:0] dc_access,dc_hit,dc_miss,dc_refill,dc_error,dc_write,dc_bypass;
    wire [31:0] dmem_req_addr,dmem_req_wdata;wire [1:0] dmem_req_size;wire [3:0] dmem_req_wstrb;
    cpu5_cache_adapter #(.ENABLE_ICACHE(0),.ENABLE_DCACHE(CACHE),.ICACHE_SETS(2),.DCACHE_SETS(2),
        .ICACHE_LINE_WORDS(4),.DCACHE_LINE_WORDS(4),.IMEM_WORDS(8),.DMEM_WORDS(8),.DMEM_BASE_ADDR(32'h10000)) adapter(
        .clk(clk),.rst_n(rst_n),
        .cpu_imem_req_valid(1'b0),.cpu_imem_req_ready(),.cpu_imem_req_addr(32'd0),
        .cpu_imem_rsp_valid(),.cpu_imem_rsp_ready(1'b1),.cpu_imem_rsp_rdata(),.cpu_imem_rsp_error(),
        .mem_imem_req_valid(),.mem_imem_req_ready(1'b1),.mem_imem_req_addr(),
        .mem_imem_rsp_valid(1'b0),.mem_imem_rsp_ready(),.mem_imem_rsp_rdata(32'd0),.mem_imem_rsp_error(1'b0),
        .cpu_dmem_req_valid(dmem_req_valid),.cpu_dmem_req_ready(dmem_req_ready),.cpu_dmem_req_write(dmem_req_write),
        .cpu_dmem_req_addr(dmem_req_addr),.cpu_dmem_req_size(dmem_req_size),.cpu_dmem_req_wdata(dmem_req_wdata),.cpu_dmem_req_wstrb(dmem_req_wstrb),
        .cpu_dmem_rsp_valid(dmem_rsp_valid),.cpu_dmem_rsp_ready(dmem_rsp_ready),.cpu_dmem_rsp_rdata(dmem_rsp_rdata),.cpu_dmem_rsp_error(dmem_rsp_error),
        .mem_dmem_req_valid(backend_req_valid),.mem_dmem_req_ready(backend_req_ready),.mem_dmem_req_write(backend_req_write),
        .mem_dmem_req_addr(backend_req_addr),.mem_dmem_req_size(backend_req_size),.mem_dmem_req_wdata(backend_req_wdata),.mem_dmem_req_wstrb(backend_req_wstrb),
        .mem_dmem_rsp_valid(backend_rsp_valid),.mem_dmem_rsp_ready(backend_rsp_ready),.mem_dmem_rsp_rdata(backend_rsp_rdata),.mem_dmem_rsp_error(backend_rsp_error),
        .icache_access_count(),.icache_hit_count(),.icache_miss_count(),.icache_refill_word_count(),.icache_error_count(),
        .dcache_access_count(dc_access),.dcache_hit_count(dc_hit),.dcache_miss_count(dc_miss),.dcache_refill_word_count(dc_refill),
        .dcache_error_count(dc_error),.dcache_write_count(dc_write),.dcache_bypass_count(dc_bypass));
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),
        .BRANCH_RESOLVE_IN_ID(MODE),.ENABLE_BRANCH_PRED(1),.ENABLE_RAM(1),.ENABLE_MMIO(1),.ENABLE_FENCE(FENCE_FEATURE),
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
    integer trace_fd,summary_fd,io_reads=0,io_writes=0,side_effects=0,expected_effects=0,
        total_io_reads=0,total_io_writes=0,total_flush_rejected=0,total_ex_deferred=0,total_turnover=0,total_cached=0,
        total_io_blocked=0,total_reset_phases=0,total_reset_abandoned_requests=0;
    integer total_retired=0,total_wb=0,total_traps=0,total_requests=0,total_responses=0;
    integer total_reset_abandoned_wb=0;
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
    integer total_fences=0,total_fence_wait=0,total_fence_barrier=0,total_fence_retire_barrier=0,total_fence_m_background=0,total_fence_redirect=0;
    reg fence_live=0;reg [63:0] fence_saved_seq=0,pred_seq=0,saved_store_seq=0;reg pred_expected=0;
    integer fence_before=0;
    function [31:0] fence(input [3:0] fm,input [3:0] pred,input [3:0] succ,input [4:0] a,input [4:0] d);
        begin fence={fm,pred,succ,a,3'b000,d,7'h0f};end
    endfunction
    function is_fence_word(input [31:0] ins);
        begin is_fence_word=ins[6:0]==7'h0f&&ins[14:12]==0;end
    endfunction
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
            default:begin read_model=32'hxxxxxxxx;$fatal(1,"FENCE model unsupported retired address=%h",a);end
        endcase end
    endfunction
    // The backend ledger is driven only by CPU request descriptors and
    // observed backend handshakes, never by cache tag/state internals.
    reg backend_pending=0,last_backend_rsp=0,cpu_cache_active=0;
    reg [31:0] cache_addr=0,cache_data=0;reg [1:0] cache_size=0;reg [3:0] cache_strobe=0;
    reg cache_write=0,cache_refill=0;integer backend_word=0;
    reg [31:0] backend_ram[0:7];integer init_word;
    integer backend_requests=0,backend_responses=0,total_backend_requests=0,total_backend_responses=0,total_backend_abandoned=0;
    integer total_backend_writes=0,total_backend_held=0,total_cache_faults=0,total_killed_refill_faults=0;
    reg backend_held=0;reg [134:0] backend_payload;
    reg pre_backend_error=0;
    reg axi_gate=1;reg [1:0] axi_code=0;
    task tick;
        begin @(posedge clk);#2;
            if((last_accept&&last_accept_seq==in_seq)||last_trap||last_mret||last_irq)in_valid=0;
        end
    endtask
    task reset_case(input integer n);
        begin @(negedge clk);total_reset_abandoned_wb=total_reset_abandoned_wb+retired-wb_count;
            rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            axi_code=0;axi_gate=1;irq_external=0;irq_software=0;irq_timer=0;model_safe=1;sync_expected_now=0;
            pred_expected=0;case_no=n;expected_effects=0;expected=0;traps_expected=0;requests_expected=0;m_expected=0;irqs_expected=0;s=1;p='h200;
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
                if(timeout>1200)$fatal(1,"FENCE ID timeout mode=%0d case=%0d seq=%0d ID=%b MEM=%b kex=%b kfault=%b fault=%b s=%h",MODE,case_no,age,dut.idex_valid_q,dut.exmem_valid_q,dut.kill_ex,dut.known_ex_fault,dut.mem_fault,dut.idex_q.seq);end
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
        begin timeout=0;while(m_issued<n)begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"M start timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_m_done;
        begin timeout=0;while(!dut.m_completion_valid)begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"M completion timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_retired(input integer n);
        begin timeout=0;while(retired<n)begin tick;timeout=timeout+1;
            if(timeout>1200)$fatal(1,"FENCE retire timeout mode=%0d case=%0d have=%0d want=%0d",MODE,case_no,retired,n);end end
    endtask
    task wait_traps(input integer n);
        begin timeout=0;while(traps<n)begin tick;timeout=timeout+1;
            if(timeout>1200)$fatal(1,"FENCE trap timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_requests(input integer n);
        begin timeout=0;while(requests<n)begin tick;timeout=timeout+1;
            if(timeout>1200)$fatal(1,"FENCE D request timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task flush_at(input [63:0] cut);
        begin @(negedge clk);flush_valid=1;flush_cut_seq=cut;in_valid=0;#1;
            if(!flush_ready||!flush_fire)$fatal(1,"FENCE cancelable flush rejected");
            tick;@(negedge clk);flush_valid=0;end
    endtask
    task wait_irqs(input integer n);
        begin timeout=0;while(irqs<n)begin tick;timeout=timeout+1;
            if(timeout>1200)$fatal(1,"IRQ bounded delivery timeout mode=%0d case=%0d events=%0d/%0d",MODE,case_no,irqs,n);end end
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
                tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"FENCE drain mode=%0d case=%0d retire=%0d/%0d wb=%0d traps=%0d/%0d",MODE,case_no,retired,expected,wb_count,traps,traps_expected);
            end
            repeat(4)tick;
            if(requests!=requests_expected||responses!=requests||side_effects!=expected_effects)$fatal(1,"FENCE effect/transaction ledger not closed effect=%0d/%0d",side_effects,expected_effects);
            if(m_issued!=m_expected||m_completed+m_drained!=m_issued)$fatal(1,"M issue/completion ledger not closed mode=%0d case=%0d starts=%0d/%0d complete=%0d drain=%0d",MODE,case_no,m_issued,m_expected,m_completed,m_drained);
            for(j=1;j<32;j=j+1)if(model_known[j]&&dut.u_regfile.regs[j]!==model_gpr[j])
                $fatal(1,"FENCE physical GPR mismatch mode=%0d case=%0d reg=%0d",MODE,case_no,j);
            passed=passed+1;$display("CPU5_D0_CONTROL_CASE_PASS config=%0d case=%0d retire=%0d traps=%0d req=%0d",CONFIG,case_no,retired,traps,requests);
        end
    endtask
    task check_state;
        begin
            if(dut.g_csr.u_csr.csr_mie!==model_mie||dut.g_csr.u_csr.csr_mstatus!==model_status||dut.g_csr.u_csr.csr_mtvec!==model_vector||
                dut.g_csr.u_csr.csr_mscratch!==model_scratch||dut.g_csr.u_csr.csr_mepc!==model_epc||
                dut.g_csr.u_csr.csr_mcause!==model_cause||dut.g_csr.u_csr.csr_mtval!==model_tval)
                $fatal(1,"FENCE committed state mode=%0d case=%0d status=%h/%h vector=%h/%h scratch=%h/%h epc=%h/%h cause=%h/%h tval=%h/%h",MODE,case_no,
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
            io_reads=0;io_writes=0;side_effects=0;last_accept=0;last_rsp=0;last_trap=0;last_mret=0;last_irq=0;irqs=0;live_count=0;model_mie=0;model_arm=0;model_meta=0;model_sync=0;m_issued=0;m_completed=0;m_drained=0;m_active=-1;m_held=0;m_just_started=0;model_known=1;model_gpr[0]=0;
            arch_expected=0;saved_seq=0;saved_pc=0;saved_cause=0;saved_tval=0;
            model_status='h1800;model_vector=VECTOR;model_scratch=0;model_epc=0;model_cause=0;model_tval=0;
            if(wb_we||retire_fire||trap_fire||dut.irq_take||redirect_valid||dmem_req_valid||dmem_rsp_ready)$fatal(1,"FENCE reset side effect");
            #1;check_state;
            if(trap_valid||retire_valid||trap_pc!==0||trap_cause!==0||trap_tval!==0||trap_seq!==0||instret_count!==0||arch_next_pc_q!==0)
                $fatal(1,"FENCE reset descriptor state");
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
            fence_live=dut.exmem_valid_q&&is_fence_word(dut.exmem_q.instr)&&!dut.exmem_q.exception_valid;
            if(fence_live)begin
                total_fence_barrier=total_fence_barrier+1;
                if(dut.ex_move||dut.ram_issue_fire||dut.m_issue_fire)$fatal(1,"FENCE younger action crossed live MEM barrier");
                if(dut.ram_owner_valid)begin total_fence_wait=total_fence_wait+1;
                    if(pre_retire)$fatal(1,"FENCE retired before pre-edge D owner drained");end
                if(pre_retire)begin
                    total_fences=total_fences+1;total_fence_retire_barrier=total_fence_retire_barrier+1;
                    if(dut.m_owner_valid&&dut.m_owner_killed)total_fence_m_background=total_fence_m_background+1;
                    if(bp_commit_is_branch||bp_commit_is_jal||bp_commit_taken)$fatal(1,"FENCE trained branch flags");
                end
            end
            if(in_valid&&is_fence_word(in_instr)&&id_raw_wait)$fatal(1,"FENCE reserved operands caused RAW wait");
            if(dut.idex_valid_q&&is_fence_word(dut.idex_q.instr)&&!dut.idex_q.exception_valid&&
                (dut.idex_q.uses_rs1||dut.idex_q.uses_rs2||dut.idex_q.writes_rd||dut.idex_q.rd!=0))$fatal(1,"FENCE reserved operand metadata");
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
                if(trap_fire||pre_irq||retire_fire||dut.csr_commit_fire||dut.mret_fire)$fatal(1,"FENCE MEM enable ignored");end
            if(pre_wb_hold)total_held_wb=total_held_wb+1;
            if(pre_wb_hold&&dut.exmem_valid_q&&dut.exmem_q.is_m)total_m_wb_hold=total_m_wb_hold+1;
            if(held&&(!dmem_req_valid||{dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq}!==held_fields))
                $fatal(1,"FENCE changed held D request");
            held=dmem_req_valid&&!dmem_req_ready;
            held_fields={dmem_req_write,dmem_req_addr,dmem_req_size,dmem_req_wdata,dmem_req_wstrb,dut.ram_req_seq};
            if(held)total_held_d=total_held_d+1;
            if(dut.ram_issue_fire && (dmem_req_addr<32'h10000 || {1'b0,dmem_req_addr}+3>=33'h10020))begin
                if(!dut.exmem_valid_q || dut.exmem_q.seq!==dut.ram_req_seq ||
                    dut.exmem_q.mem_class!==2'd1 || !dut.exmem_q.mem_order_barrier ||
                    dut.ram_issue_store!==dut.exmem_q.is_store || !mem_enable || flush_valid || dut.irq_take || dut.mem_fault)
                    $fatal(1,"FENCE first presentation lacks oldest MEM authorization");
                if(!dmem_req_write && (dmem_req_wstrb!=0 ||
                    (dut.ram_owner_valid&&dut.ram_owner_seq==dut.ram_req_seq&&dut.ram_owner_store)))
                    $fatal(1,"FENCE read mislabeled STORE");
            end
            if(dut.ram_owner_valid && dut.ram_owner_seq==dut.exmem_q.seq &&
                dut.exmem_q.mem_order_barrier && !dut.ram_store_lock)
                $fatal(1,"FENCE owner lost irrevocable lock");
            if(dmem_req_valid&&(requests>=requests_expected||dut.ram_req_seq!==qseq[requests]||
                dmem_req_addr!==qa[requests]||dmem_req_write!==qw[requests]||dmem_req_size!==2||dmem_req_wstrb!==qstrb[requests]||dmem_req_wdata!==qdata[requests]))
                $fatal(1,"FENCE unexpected/younger D request mode=%0d case=%0d seq=%0d",MODE,case_no,dut.ram_req_seq);
            if(last_rsp)begin
                if(!bus_pending||dut.ram_rsp_seq!==bus_seq)$fatal(1,"FENCE D response owner mismatch");
                if(dut.ram_owner_killed)begin total_killed=total_killed+1;if(pre_trap)$fatal(1,"FENCE killed D error trapped");end
                bus_pending=0;responses=responses+1;total_responses=total_responses+1;
            end
            if(dmem_req_valid&&dmem_req_ready)begin
                if(bus_pending)$fatal(1,"FENCE multiple D owners");
                bus_pending=1;bus_seq=dut.ram_req_seq;requests=requests+1;total_requests=total_requests+1;
                if(dmem_req_addr<32'h10000 || {1'b0,dmem_req_addr}+3>=33'h10020)begin
                    if(dmem_req_write)begin io_writes=io_writes+1;total_io_writes=total_io_writes+1;end
                    else begin io_reads=io_reads+1;total_io_reads=total_io_reads+1;end
                    if(dmem_req_addr==32'h20000000)side_effects=side_effects+1;
                end
            end
            if(pre_wb)begin
                if(wi>=retired||dut.memwb_q.seq!==eseq[wi]||wb_pc!==epc[wi]||wb_rd!==erd[wi]||wb_data!==eval[wi]||pre_we!==(erd[wi]!=0))
                    $fatal(1,"FENCE WB stream mode=%0d case=%0d index=%0d seq=%0d value=%h/%h",MODE,case_no,wi,dut.memwb_q.seq,wb_data,eval[wi]);
                wb_count=wb_count+1;total_wb=total_wb+1;
            end
            if(bp_commit_valid!==(retire_fire&&dut.exmem_q.instr!=32'h30200073&&!(dut.exmem_q.instr[6:0]==7'h73&&dut.exmem_q.instr[14:12]!=0)))$fatal(1,"FENCE BP authorization mismatch");
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
                    $fatal(1,"FENCE precise trap/priority mode=%0d case=%0d event=%0d seq=%0d pc=%h cause=%0d tval=%h redirect=%h",MODE,case_no,ti,dut.exmem_q.seq,dut.exmem_q.pc,halt_cause,halt_tval,redirect_pc);
                if(pre_wb&&pre_we)total_old_wb=total_old_wb+1;
                model_status={19'd0,2'b11,3'd0,model_status[3],3'd0,1'b0,3'd0};
                model_epc=tpc[ti]&32'hfffffffc;model_cause=tcause[ti];model_tval=ttval[ti];
                saved_seq=tseq[ti];saved_pc=tpc[ti];saved_cause=tcause[ti];saved_tval=ttval[ti];
                arch_expected=tvector[ti];traps=traps+1;total_traps=total_traps+1;
                $fdisplay(trace_fd,"trap,%0d,%0d,%h,%h,%h,%h",case_no,cycles,tseq[ti],tpc[ti],tcause[ti],ttval[ti]);
                for(li=0;li<live_count;li=li+1)live_valid[li]=0;
            end else if(redirect_valid&&!last_mret)begin
                if(!pred_expected||redirect_seq!==pred_seq||redirect_pc!==p+4||!redirect_kill_ifid||!dut.idex_valid_q||dut.idex_q.seq!==pred_seq)
                    $fatal(1,"FENCE stale BTB correction/EX ownership mode=%0d case=%0d seq=%0d",MODE,case_no,redirect_seq);
                pred_expected=0;total_fence_redirect=total_fence_redirect+1;
            end
            if(pre_retire)begin
                if(ri>=expected||dut.exmem_q.seq!==eseq[ri]||bp_commit_seq!==eseq[ri]||bp_commit_pc!==epc[ri])
                    $fatal(1,"FENCE killed/fault token retired mode=%0d case=%0d index=%0d seq=%0d",MODE,case_no,ri,dut.exmem_q.seq);
                if(dut.ram_owner_valid&&dut.ram_owner_killed)total_drain=total_drain+1;
                if(dut.m_owner_valid&&dut.m_owner_killed)total_handler_drain=total_handler_drain+1;
                for(li=0;li<live_count;li=li+1)if(live_seq[li]==eseq[ri])live_valid[li]=0;
                model_word=eins[ri];
                if(model_word==32'h30200073)begin
                    if(!redirect_valid||!redirect_kill_ifid||redirect_pc!==model_epc||redirect_seq!==eseq[ri]||last_accept||dut.ram_issue_fire)
                        $fatal(1,"FENCE MRET MEM authorization/priority mode=%0d case=%0d",MODE,case_no);
                    model_status=(model_status&32'hffffff77)|32'h80|(model_status[7]?32'h8:32'h0)|32'h1800;
                    if(enext[ri]!==model_epc)$fatal(1,"FENCE test MRET oracle mismatch");total_mret=total_mret+1;
                    if(pre_wb&&pre_we)total_mret_old_wb=total_mret_old_wb+1;
                    for(li=0;li<live_count;li=li+1)live_valid[li]=0;
                end else if(model_word[6:0]==7'h33&&model_word[31:25]==1)begin
                    if(!model_known[model_word[19:15]]||!model_known[model_word[24:20]])$fatal(1,"M oracle uninitialized source");
                    math_value=m_math(model_word[14:12],model_gpr[model_word[19:15]],model_gpr[model_word[24:20]]);
                    if(math_value!==eval[ri])$fatal(1,"M mathematical oracle differs from directed expected value");
                end else if(model_word[6:0]==7'h73&&model_word[14:12]!=0)begin
                    model_addr=model_word[31:20];funct=model_word[14:12];oldcsr=read_model(model_addr);
                    if(eval[ri]!==oldcsr)$fatal(1,"FENCE read/RMW old value mode=%0d case=%0d csr=%h got=%h expected=%h",MODE,case_no,model_addr,eval[ri],oldcsr);
                    if(!funct[2]&&!model_known[model_word[19:15]])$fatal(1,"FENCE oracle uninitialized source");
                    operand=funct[2]?{27'd0,model_word[19:15]}:model_gpr[model_word[19:15]];
                    write_intent=funct[1:0]==1||model_word[19:15]!=0;
                    case(funct[1:0])1:newcsr=operand;2:newcsr=oldcsr|operand;3:newcsr=oldcsr&~operand;default:$fatal(1,"FENCE oracle funct");endcase
                    if(write_intent)case(model_addr)
                        12'h300:model_status=(newcsr&32'h88)|32'h1800;
                        12'h305:model_vector=newcsr&32'hfffffffc;
                        12'h304:model_mie=newcsr&32'h888;12'h344:begin end
                        12'h340:model_scratch=newcsr;12'h341:model_epc=newcsr&32'hfffffffc;
                        12'h342:model_cause=newcsr;12'h343:model_tval=newcsr;
                        12'h301:begin end
                        default:$fatal(1,"FENCE read-only ID write retired");
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
            if(trap_valid!==(pre_trap||pre_irq)||retire_valid!==pre_retire)$fatal(1,"FENCE registered event mismatch");
            if((pre_trap||pre_irq)&&pre_wb_hold&&(!dut.memwb_valid_q||dut.memwb_q.seq!==pre_wb_seq||wb_pc!==pre_wb_pc||wb_data!==pre_wb_value||wb_rd!==pre_wb_rd))
                $fatal(1,"FENCE trap destroyed held old WB");
            if(trap_seq!==saved_seq||trap_pc!==saved_pc||trap_cause!==saved_cause||trap_tval!==saved_tval)
                $fatal(1,"FENCE software FENCE write changed persistent trap descriptor");
            if(pre_retire)begin
                if(retire_seq!==eseq[ri]||retire_pc!==epc[ri]||retire_instr!==eins[ri]||retire_rd!==erd[ri]||retire_value!==eval[ri]||retire_writes_rd!==(erd[ri]!=0))
                    $fatal(1,"FENCE retirement payload mode=%0d case=%0d index=%0d seq=%0d value=%h/%h rd=%0d/%0d",MODE,case_no,ri,retire_seq,retire_value,eval[ri],retire_rd,erd[ri]);
                retired=retired+1;total_retired=total_retired+1;
                $fdisplay(trace_fd,"retire,%0d,%0d,%h,%h,%h,%h",case_no,cycles,retire_seq,retire_pc,retire_instr,retire_value);
            end
            if(instret_count!==retired||arch_next_pc_q!==arch_expected)$fatal(1,"FENCE instret/arch-next-PC mode=%0d case=%0d pc=%h/%h",MODE,case_no,arch_next_pc_q,arch_expected);
        end
    end

    task wait_present;
        begin timeout=0;while(!(dmem_req_valid||bus_pending))begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"FENCE request presentation timeout");end end
    endtask
    task wait_fence;
        begin timeout=0;while(!(dut.exmem_valid_q&&dut.exmem_q.seq==fence_saved_seq))begin tick;timeout=timeout+1;
            if(timeout>1200)$fatal(1,"FENCE MEM arrival timeout case=%0d",case_no);end end
    endtask
    task emit_fence(input [31:0] ins);
        begin fence_saved_seq=s;emit(ins,0,0);end
    endtask
    task setup_ram;
        begin const32(2,32'h10000);emit(addi(3,0,'h55),3,'h55);wait_retired(expected);repeat(2)tick;end
    endtask
    // The AXI slave is a physical endpoint, independent of the architectural
    // queues above. RAM writes use observed WDATA, while the golden RAM below
    // uses the already validated instruction/request descriptor.
    wire [31:0] awaddr,wdata,araddr;wire [2:0] awprot,arprot;wire [3:0] wstrb;
    wire awvalid,wvalid,bready,arvalid,rready;
    wire awready,wready,arready;
    reg bvalid=0,rvalid=0;reg [1:0] bresp=0,rresp=0;reg [31:0] rdata=0;
    reg aw_seen=0,w_seen=0,wr_pending=0,rd_pending=0;
    reg [31:0] aw_saved=0,w_saved=0,ar_saved=0;reg [3:0] strb_saved=0;
    integer accept_delay=0,write_delay=0,read_delay=0;
    reg [31:0] axi_ram[0:7];reg [31:0] axi_io=0,gold_io=0;
    reg [31:0] be_addr=0,be_data=0,be_expected=0;reg be_write=0,be_local=0,be_error=0;
    reg [1:0] cache_code=0;
    reg [1:0] line_valid=0;integer cache_beats=0;
    reg [31:0] cpu_expected=0;reg cpu_error=0;
    integer total_local=0,total_axi_ar=0,total_axi_aw=0,total_axi_w=0,total_axi_r=0,total_axi_b=0;
    integer total_ram_writes=0,total_axi_effects=0,total_precise_errors=0,total_reset_checks=0;
    integer total_kill_held=0,total_kill_accepted=0,total_kill_complete=0;
    integer total_store_wb_hold=0,total_local_held=0,total_router_bubble=0;
    integer total_cache_hits=0;
    integer sim_i,base_count,write_before,old_retired,old_expected;
    reg prev_be_response=0;reg [31:0] physical_addr;
    assign awready=rst_n&&axi_gate&&!aw_seen&&!wr_pending&&!bvalid&&accept_delay>=(WAIT?20:0);
    assign wready=rst_n&&axi_gate&&!w_seen&&!wr_pending&&!bvalid&&accept_delay>=(WAIT?20:0);
    assign arready=rst_n&&axi_gate&&!rd_pending&&!rvalid&&accept_delay>=(WAIT?20:0);
    cpu5_d0_backend #(.ENABLE_D0_BRAM(D0),.DMEM_WORDS(8),.DMEM_BASE_ADDR(32'h10000),
        .D0_REQ_WAIT_CYCLES(WAIT?20:0),.D0_RSP_WAIT_CYCLES(WAIT?20:0)) backend(
        .clk(clk),.rst_n(rst_n),.req_valid(backend_req_valid),.req_ready(backend_req_ready),
        .req_write(backend_req_write),.req_addr(backend_req_addr),.req_size(backend_req_size),
        .req_wdata(backend_req_wdata),.req_wstrb(backend_req_wstrb),.rsp_valid(backend_rsp_valid),
        .rsp_ready(backend_rsp_ready),.rsp_rdata(backend_rsp_rdata),.rsp_error(backend_rsp_error),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    function in_ram(input [31:0] a);begin in_ram=a>=32'h10000&&a<32'h10020;end endfunction
    wire local_fire,local_write,local_held;
    wire [31:0] local_addr,local_data;
    generate if(D0)begin:g_local_observe
        assign local_fire=backend.g_d0.ram_req_valid&&backend.g_d0.ram_req_ready;
        assign local_held=backend.g_d0.ram_req_valid&&!backend.g_d0.ram_req_ready;
        assign local_write=backend.g_d0.ram_req_write;
        assign local_addr=backend.g_d0.ram_req_addr;
        assign local_data=backend.g_d0.ram_req_wdata;
        always @(posedge clk)begin
            if(rst_n)begin
                if(local_fire!==(backend_req_valid&&backend_req_ready&&in_ram(backend_req_addr)))
                    $fatal(1,"D0 route acceptance mismatch");
                if(backend.g_d0.ram_rsp_valid&&backend.g_d0.ram_rsp_error)
                    $fatal(1,"Legal RAM access returned local error");
            end
            #2;for(sim_i=0;sim_i<8;sim_i=sim_i+1)
                if(backend.g_d0.u_ram.u_data_mem.mem[sim_i]!==backend_ram[sim_i])
                    $fatal(1,"D0 physical RAM mismatch config=%0d word=%0d got=%h expected=%h",CONFIG,sim_i,backend.g_d0.u_ram.u_data_mem.mem[sim_i],backend_ram[sim_i]);
        end
    end else begin:g_axi_ram_observe
        assign local_fire=0;assign local_write=0;assign local_held=0;assign local_addr=0;assign local_data=0;
        always @(posedge clk)begin #2;
            for(sim_i=0;sim_i<8;sim_i=sim_i+1)if(axi_ram[sim_i]!==backend_ram[sim_i])
                $fatal(1,"AXI physical RAM mismatch config=%0d word=%0d",CONFIG,sim_i);
        end
    end endgenerate
    always @(posedge clk)begin
        if(!rst_n)begin
            bvalid<=0;rvalid<=0;aw_seen=0;w_seen=0;wr_pending=0;rd_pending=0;
            accept_delay=0;write_delay=0;read_delay=0;
        end else begin
            if(awvalid||wvalid||arvalid)accept_delay=accept_delay+1;else accept_delay=0;
            if(bvalid&&bready)begin bvalid<=0;total_axi_b=total_axi_b+1;end
            if(rvalid&&rready)begin rvalid<=0;total_axi_r=total_axi_r+1;end
            if(awvalid&&awready)begin
                if(awprot!==0||!backend_pending||be_local||!be_write||awaddr!==be_addr)$fatal(1,"D0 AXI AW unauthorized/address");
                aw_seen=1;aw_saved=awaddr;total_axi_aw=total_axi_aw+1;
                $fdisplay(trace_fd,"axi_aw,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,awaddr,32'd0,32'd0);
            end
            if(wvalid&&wready)begin
                if(!backend_pending||be_local||!be_write||wdata!==be_data||wstrb!==15)$fatal(1,"D0 AXI W payload/authorization");
                w_seen=1;w_saved=wdata;strb_saved=wstrb;total_axi_w=total_axi_w+1;
                $fdisplay(trace_fd,"axi_w,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,be_addr,wdata,{28'd0,wstrb});
            end
            if(aw_seen&&w_seen&&!wr_pending&&!bvalid)begin
                if(in_ram(aw_saved))begin
                    if(D0)$fatal(1,"D0 RAM write escaped to AXI");
                    axi_ram[(aw_saved-32'h10000)>>2]<=w_saved;
                    backend_ram[(aw_saved-32'h10000)>>2]=be_data;total_ram_writes=total_ram_writes+1;
                end else if(aw_saved==32'h40000000)begin
                    axi_io<=w_saved;gold_io=be_data;total_axi_effects=total_axi_effects+1;
                end else $fatal(1,"D0 AXI write unsupported address");
                aw_seen=0;w_seen=0;wr_pending=1;write_delay=0;
                $fdisplay(trace_fd,"axi_physical_write,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,aw_saved,w_saved,{28'd0,strb_saved});
            end
            if(wr_pending&&!bvalid)begin
                if(write_delay>=(WAIT?20:1))begin bvalid<=1;bresp<=cache_code;wr_pending=0;end
                else write_delay=write_delay+1;
            end
            if(arvalid&&arready)begin
                if(arprot!==0||!backend_pending||be_local||be_write||araddr!==be_addr)$fatal(1,"D0 AXI AR unauthorized/address");
                ar_saved=araddr;rd_pending=1;read_delay=0;total_axi_ar=total_axi_ar+1;
                $fdisplay(trace_fd,"axi_ar,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,araddr,32'd0,32'd0);
            end
            if(rd_pending&&!rvalid)begin
                if(read_delay>=(WAIT?20:1))begin
                    if(in_ram(ar_saved))begin
                        if(D0)$fatal(1,"D0 RAM read escaped to AXI");
                        rdata<=axi_ram[(ar_saved-32'h10000)>>2];
                    end else if(ar_saved==32'h40000000)rdata<=axi_io;
                    else $fatal(1,"D0 AXI read unsupported address");
                    rvalid<=1;rresp<=cache_code;rd_pending=0;
                end else read_delay=read_delay+1;
            end
        end
    end
    // Independent route/refill ledger: expected addresses come from the CPU
    // descriptor, and expected contents from physical accepted writes only.
    always @(posedge clk)begin
        last_backend_rsp=0;
        if(!rst_n)begin
            if(backend_pending)total_backend_abandoned=total_backend_abandoned+1;
            backend_pending=0;cpu_cache_active=0;backend_word=0;line_valid=0;backend_held=0;prev_be_response=0;
            if(backend_req_valid||backend_rsp_ready||awvalid||wvalid||arvalid)$fatal(1,"D0 shared reset protocol leakage");
        end else begin
            if(backend_held&&(!backend_req_valid||{backend_req_write,backend_req_addr,backend_req_size,backend_req_wdata,backend_req_wstrb}!==backend_payload))
                $fatal(1,"D0 backend held request changed");
            backend_held=backend_req_valid&&!backend_req_ready;
            backend_payload={backend_req_write,backend_req_addr,backend_req_size,backend_req_wdata,backend_req_wstrb};
            if(backend_held)total_backend_held=total_backend_held+1;
            if(local_held)total_local_held=total_local_held+1;
            if(D0&&backend_rsp_valid&&backend_rsp_ready&&backend_req_ready)$fatal(1,"D0 router illegally turned over response/request");
            if(prev_be_response&&D0)total_router_bubble=total_router_bubble+1;
            prev_be_response=backend_rsp_valid&&backend_rsp_ready;
            if(backend_rsp_valid&&backend_rsp_ready)begin
                if(!backend_pending||backend_rsp_error!==be_error||(!be_error&&backend_rsp_rdata!==be_expected))
                    $fatal(1,"D0 backend response data/error/owner config=%0d case=%0d addr=%h data=%h/%h error=%b/%b",CONFIG,case_no,be_addr,backend_rsp_rdata,be_expected,backend_rsp_error,be_error);
                backend_pending=0;last_backend_rsp=1;total_backend_responses=total_backend_responses+1;
                $fdisplay(trace_fd,"backend_rsp,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,be_addr,backend_rsp_rdata,{31'd0,backend_rsp_error});
            end
            if(dmem_rsp_valid&&dmem_rsp_ready)begin
                if(!cpu_cache_active||backend_pending||backend_word!=cache_beats||dmem_rsp_error!==cpu_error||(!cpu_error&&dmem_rsp_rdata!==cpu_expected))
                    $fatal(1,"D0 cache response ledger config=%0d case=%0d beats=%0d/%0d data=%h/%h err=%b/%b",CONFIG,case_no,backend_word,cache_beats,dmem_rsp_rdata,cpu_expected,dmem_rsp_error,cpu_error);
                if(CACHE&&!cache_write&&in_ram(cache_addr)&&!cpu_error)line_valid[cache_addr[4]]=1;
                cpu_cache_active=0;
                $fdisplay(trace_fd,"cpu_rsp,%0d,%0d,%h,%h,%h,%h",case_no,cycles,dut.ram_rsp_seq,cache_addr,dmem_rsp_rdata,{31'd0,dmem_rsp_error});
            end
            if(dmem_req_valid&&dmem_req_ready)begin
                if(cpu_cache_active)$fatal(1,"D0 cache multiple CPU owners");
                cpu_cache_active=1;cache_addr=dmem_req_addr;cache_data=dmem_req_wdata;
                cache_size=dmem_req_size;cache_strobe=dmem_req_wstrb;cache_write=dmem_req_write;cache_code=in_ram(dmem_req_addr)?0:axi_code;
                cache_refill=CACHE&&!cache_write&&in_ram(cache_addr)&&!line_valid[cache_addr[4]];
                cache_beats=cache_refill?4:(CACHE&&!cache_write&&in_ram(cache_addr)&&line_valid[cache_addr[4]]?0:1);
                if(cache_beats==0)total_cache_hits=total_cache_hits+1;
                cpu_expected=cache_write?0:(in_ram(cache_addr)?backend_ram[(cache_addr-32'h10000)>>2]:gold_io);
                cpu_error=cache_code!=0;backend_word=0;
                $fdisplay(trace_fd,"cpu_req,%0d,%0d,%h,%h,%h,%h",case_no,cycles,dut.ram_req_seq,cache_addr,cache_data,{31'd0,cache_write});
            end
            if(backend_req_valid&&backend_req_ready)begin
                if(!cpu_cache_active||backend_pending)$fatal(1,"D0 backend ownership/serialization");
                if(cache_refill)begin
                    if(backend_word>=4||backend_req_addr!==((cache_addr&32'hfffffff0)+backend_word*4)||backend_req_write||backend_req_size!==2||backend_req_wstrb!==0)
                        $fatal(1,"D0 refill address/shape oracle");
                end else if(backend_word!=0||backend_req_addr!==cache_addr||backend_req_write!==cache_write||backend_req_size!==cache_size||backend_req_wdata!==cache_data||backend_req_wstrb!==cache_strobe)
                    $fatal(1,"D0 bypass/write descriptor oracle");
                be_addr=backend_req_addr;be_data=cache_data;be_write=cache_write;be_local=D0&&in_ram(be_addr);
                be_expected=be_write?0:(in_ram(be_addr)?backend_ram[(be_addr-32'h10000)>>2]:gold_io);be_error=cache_code!=0;
                backend_word=backend_word+1;backend_pending=1;total_backend_requests=total_backend_requests+1;
                $fdisplay(trace_fd,"backend_req,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,be_addr,be_data,{31'd0,be_write});
                if(be_local)begin
                    total_local=total_local+1;
                    if(be_write)begin
                        backend_ram[(be_addr-32'h10000)>>2]=cache_data;total_ram_writes=total_ram_writes+1;
                        $fdisplay(trace_fd,"d0_physical_write,%0d,%0d,%h,%h,%h,%h",case_no,cycles,bus_seq,be_addr,local_data,32'd15);
                    end
                end
            end
            if(local_fire&&local_write&&(local_addr!==be_addr||local_data!==be_data))$fatal(1,"D0 physical write descriptor mismatch");
        end
    end
    task wait_backend_accepted;
        begin timeout=0;while(!backend_pending)begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"D0 backend acceptance timeout");end end
    endtask
    task wait_physical_write(input integer target);
        begin timeout=0;while(total_ram_writes<target)begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"D0 physical write timeout");end end
    endtask
    task reject_flush;
        begin @(negedge clk);flush_valid=1;flush_cut_seq=1;#1;
            if(flush_ready||flush_fire)$fatal(1,"D0 irrevocable STORE accepted flush");
            total_flush_rejected=total_flush_rejected+1;tick;@(negedge clk);flush_valid=0;end
    endtask
    task cancel_read(input integer phase);
        begin
            @(negedge clk);mem_enable=0;
            expect_request(s,32'h10000);send(s,p,load(5,2,0));wait_present;
            if(phase==0)begin
                timeout=0;while(!backend_req_valid)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"D0 held fixture timeout");end
                tick;
                if(D0&&WAIT&&backend_req_ready)$fatal(1,"D0 held fixture already accepted");
                if(!dut.ram_owner_valid)$fatal(1,"D0 held fixture lacks allocated owner");
                if(!D0&&!(arvalid&&!arready))$fatal(1,"AXI held read fixture already accepted");
                total_kill_held=total_kill_held+1;
            end else if(phase==1)begin
                wait_backend_accepted;
                if(!D0)begin timeout=0;while(!(rd_pending||rvalid))begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"AXI accepted read fixture timeout");end end
                total_kill_accepted=total_kill_accepted+1;
            end else begin timeout=0;while(dut.ram_owner_state!=3)begin tick;timeout=timeout+1;if(timeout>1200)$fatal(1,"D0 COMPLETE fixture timeout");end total_kill_complete=total_kill_complete+1;end
            flush_at(s);s=s+1;p=p+4;
            @(negedge clk);mem_enable=1;
        end
    endtask
    initial begin
        for(init_word=0;init_word<8;init_word=init_word+1)begin backend_ram[init_word]=0;axi_ram[init_word]=0;end
        trace_fd=$fopen($sformatf("build/cpu5_s15_d0_control/config%0d_trace.csv",CONFIG),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc,instruction_or_cause,value_or_tval");
        // Real local RAM or the same RAM behind AXI; a warm read may bypass
        // the backend only in the cache-enabled configurations.
        reset_case(1);setup_ram;
        expect_store(s,'h10000,'h55);emit(store(3,2,0),0,0);
        expect_request(s,'h10000);emit(load(5,2,0),5,'h55);
        emit_fence(fence(8,3,3,31,31));
        expect_request(s,'h10000);emit(load(6,2,0),6,'h55);finish_case;

        // A killed pure read still drains a real endpoint/refill. FENCE may
        // retire only after the outstanding physical response is consumed.
        for(stage=0;stage<3;stage=stage+1)if(WAIT||stage==2)begin
            reset_case(2+stage);setup_ram;cancel_read(stage);
            emit_fence(fence(0,15,15,5,5));emit(addi(9,0,29),9,29);finish_case;
        end

        // An old WB entry stalls STORE retirement after the physical write.
        // Its irrevocable lock rejects flush and the write must occur once.
        reset_case(5);setup_ram;
        @(negedge clk);wb_ready=0;emit(addi(10,0,101),10,101);wait_retired(expected);
        write_before=total_ram_writes;old_retired=retired;
        expect_store(s,'h10004,'h55);emit(store(3,2,4),0,0);wait_physical_write(write_before+1);
        repeat(4)tick;if(retired!=old_retired||total_ram_writes!=write_before+1)$fatal(1,"D0 STORE escaped WB hold or wrote twice");
        total_store_wb_hold=total_store_wb_hold+1;reject_flush;
        emit_fence(fence(0,15,15,0,0));
        @(negedge clk);wb_ready=1;finish_case;

        // Shared reset cancels owner/protocol state after a physical write;
        // RAM contents persist even when the instruction never retired.
        reset_case(6);setup_ram;emit(addi(3,0,119),3,119);wait_retired(expected);repeat(2)tick;
        @(negedge clk);wb_ready=0;emit(addi(10,0,102),10,102);wait_retired(expected);
        write_before=total_ram_writes;expect_store(s,'h10008,119);emit(store(3,2,8),0,0);wait_physical_write(write_before+1);
        if(requests>responses)total_reset_abandoned_requests=total_reset_abandoned_requests+requests-responses;
        total_reset_phases=total_reset_phases+1;reset_case(7);setup_ram;
        expect_request(s,'h10008);emit(load(7,2,8),7,119);finish_case;total_reset_checks=total_reset_checks+1;

        // Accepted local writes are the only source of RAM changes. A reset
        // while the real D0 endpoint holds a request must leave RAM untouched.
        if(D0&&WAIT)begin
            reset_case(8);setup_ram;write_before=total_ram_writes;
            expect_store(s,'h1000c,'h55);emit(store(3,2,12),0,0);
            timeout=0;while(!local_held)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"D0 reset held fixture timeout");end
            if(requests>responses)total_reset_abandoned_requests=total_reset_abandoned_requests+requests-responses;
            total_reset_phases=total_reset_phases+1;reset_case(9);setup_ram;
            if(total_ram_writes!=write_before)$fatal(1,"D0 preaccept reset wrote RAM");
            expect_request(s,'h1000c);emit(load(7,2,12),7,0);finish_case;total_reset_checks=total_reset_checks+1;
        end

        // Ordered non-RAM AXI requests keep the full independent ledger alive
        // with D0 enabled, then real AXI responses produce precise bus faults.
        reset_case(10);setup_ram;const32(4,'h40000000);wait_retired(expected);repeat(2)tick;
        expect_store(s,'h40000000,'h55);emit(store(3,4,0),0,0);
        expect_request(s,'h40000000);emit(load(8,4,0),8,'h55);
        emit_fence(fence(0,15,15,0,0));expect_request(s,'h10000);emit(load(9,2,0),9,'h55);finish_case;
        for(stage=1;stage<4;stage=stage+1)begin
            reset_case(10+stage);const32(4,'h40000000);wait_retired(expected);repeat(2)tick;
            @(negedge clk);axi_code=stage;
            expect_request(s,'h40000000);expect_trap(s,p,5,'h40000000,VECTOR);send(s,p,load(11,4,0));s=s+1;
            wait_traps(1);@(negedge clk);axi_code=0;p=VECTOR;
            emit(addi(12,0,stage),12,stage);finish_case;total_precise_errors=total_precise_errors+1;
        end
        // Interrupt eligibility is independently modeled in the inherited
        // scoreboard. A waiting irrevocable store defers the interrupt until
        // its architectural retirement, then delivers on the first safe edge.
        reset_case(14);setup_ram;enable_external;
        @(negedge clk);wb_ready=0;emit(addi(10,0,103),10,103);wait_retired(expected);
        @(negedge clk);model_safe=0;irqs_expected=1;
        write_before=total_ram_writes;expect_store(s,'h10010,'h55);emit(store(3,2,16),0,0);
        wait_physical_write(write_before+1);@(negedge clk);irq_external=1;repeat(5)tick;
        if(irqs!=0)$fatal(1,"D0 IRQ crossed STORE lock");reject_flush;
        @(negedge clk);wb_ready=1;wait_retired(expected);
        @(negedge clk);model_safe=1;wait_irqs(1);quiet_sources;p=VECTOR;s=s+10;
        emit(addi(13,0,13),13,13);finish_case;
        if(total_requests!=total_responses+total_reset_abandoned_requests||total_retired!=total_wb+total_reset_abandoned_wb)
            $fatal(1,"D0 architectural final ledger did not close req=%0d rsp=%0d drop=%0d retire=%0d wb=%0d wb_reset=%0d",total_requests,total_responses,total_reset_abandoned_requests,total_retired,total_wb,total_reset_abandoned_wb);
        if(total_backend_requests!=total_backend_responses+total_backend_abandoned)
            $fatal(1,"D0 physical final ledger did not close");
        summary_fd=$fopen($sformatf("build/cpu5_s15_d0_control/config%0d_summary.json",CONFIG),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"config\":%0d,\"d0\":%0d,\"cache\":%0d,\"wait\":%0d,\"cases\":%0d,\"retired\":%0d,\"wb\":%0d,\"reset_abandoned_wb\":%0d,\"sync_traps\":%0d,\"irqs\":%0d,\"requests\":%0d,\"responses\":%0d,\"reset_abandoned_requests\":%0d,\"backend_requests\":%0d,\"backend_responses\":%0d,\"backend_reset_abandoned\":%0d,\"local_requests\":%0d,\"axi_ar\":%0d,\"axi_aw\":%0d,\"axi_w\":%0d,\"axi_r\":%0d,\"axi_b\":%0d,\"ram_writes\":%0d,\"axi_effects\":%0d,\"precise_errors\":%0d,\"reset_checks\":%0d,\"kill_held\":%0d,\"kill_accepted\":%0d,\"kill_complete\":%0d,\"killed_responses\":%0d,\"cache_hits\":%0d,\"fences\":%0d,\"fence_wait_edges\":%0d,\"flush_rejected\":%0d,\"store_wb_hold\":%0d,\"held_backend_edges\":%0d,\"held_local_edges\":%0d}",
            CONFIG,D0,CACHE,WAIT,passed,total_retired,total_wb,total_reset_abandoned_wb,total_traps,total_irqs,total_requests,total_responses,total_reset_abandoned_requests,total_backend_requests,total_backend_responses,total_backend_abandoned,total_local,total_axi_ar,total_axi_aw,total_axi_w,total_axi_r,total_axi_b,total_ram_writes,total_axi_effects,total_precise_errors,total_reset_checks,total_kill_held,total_kill_accepted,total_kill_complete,total_killed,total_cache_hits,total_fences,total_fence_wait,total_flush_rejected,total_store_wb_hold,total_backend_held,total_local_held);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
        $display("CPU5_D0_CONTROL_CONFIG_PASS config=%0d d0=%0d cache=%0d wait=%0d cases=%0d",CONFIG,D0,CACHE,WAIT,passed);
    end
endmodule
module cpu5_d0_control_tb;
    wire [7:0] done;reg test_pass=0;
    genvar n;generate for(n=0;n<8;n=n+1)begin:g_case
        cpu5_d0_control_case #(.D0((n>>2)&1),.CACHE((n>>1)&1),.WAIT(n&1)) c(.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 D0 CONTROL REFERENCE PASS");$finish;end
    initial begin #2000000;$fatal(1,"D0 control global timeout");end
endmodule
