`timescale 1ns/1ps
// Hand-authored instruction streams and an independent, retire-edge machine
// model. No force, deposit, or reference to RTL decode/RMW helper functions.
module cpu5_axi_control_case #(parameter integer MODE=0,FENCE_FEATURE=1)(output reg done=0);
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
    wire dmem_req_ready,dmem_rsp_valid,dmem_rsp_error;wire [31:0] dmem_rsp_rdata;
    wire backend_req_valid,backend_req_write,backend_rsp_ready;
    wire [31:0] backend_req_addr,backend_req_wdata;wire [1:0] backend_req_size;wire [3:0] backend_req_wstrb;
    wire backend_req_ready,backend_rsp_valid,backend_rsp_error;wire [31:0] backend_rsp_rdata;
    // The bridge accepts native requests first; manual response tasks hold
    // AXI READY/VALID, never gate or inspect the bridge's private state.
    reg backend_fixture_gate=1;
    wire [31:0] awaddr,wdata,araddr;wire [3:0] wstrb;wire [2:0] awprot,arprot;
    wire awvalid,wvalid,bready,arvalid,rready;
    reg awready=0,wready=0,arready=0,bvalid=0,rvalid=0;
    reg [31:0] rdata=0;reg [1:0] bresp=0,rresp=0,fault_code=2;
    integer ax_aw=0,ax_w=0,ax_b=0,ax_ar=0,ax_r=0,ax_native=0,ax_complete=0,ax_drops=0;
    integer ax_aw_first=0,ax_w_first=0,ax_together=0,ax_writes=0;
    integer ax_aw_hold=0,ax_w_hold=0,ax_ar_hold=0,ax_cpu_hold=0;
    integer ax_reset_aw_only=0,ax_reset_w_only=0,ax_reset_pair=0,ax_reset_read=0,ax_reset_captured=0;
    integer ax_r1=0,ax_r2=0,ax_r3=0,ax_b1=0,ax_b2=0,ax_b3=0,ax_irq_store_wait=0;
    reg ax_pending=0,ax_write_q=0,ax_seen_aw=0,ax_seen_w=0,ax_seen_ar=0,ax_pair=0,ax_reply=0;
    reg [31:0] ax_addr_q=0,ax_data_q=0,ax_reply_data=0;reg [3:0] ax_strb_q=0;reg [1:0] ax_reply_code=0;
    reg ax_held_aw=0,ax_held_w=0,ax_held_ar=0,ax_held_rsp=0;
    reg [34:0] ax_aw_saved=0,ax_ar_saved=0;reg [35:0] ax_w_saved=0;reg [32:0] ax_rsp_saved=0;
    integer axi_fd,axis_fd,ax_lane,case_mem_before;

    wire [31:0] dc_access,dc_hit,dc_miss,dc_refill,dc_error,dc_write,dc_bypass;
    wire [31:0] dmem_req_addr,dmem_req_wdata;wire [1:0] dmem_req_size;wire [3:0] dmem_req_wstrb;
    cpu5_cache_adapter #(.ENABLE_ICACHE(0),.ENABLE_DCACHE(1),.ICACHE_SETS(2),.DCACHE_SETS(2),
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
    dmem_axi_lite_bridge bridge(
        .clk(clk),.rst_n(rst_n),.req_valid(backend_req_valid),.req_ready(backend_req_ready),
        .req_write(backend_req_write),.req_addr(backend_req_addr),.req_size(backend_req_size),
        .req_wdata(backend_req_wdata),.req_wstrb(backend_req_wstrb),.rsp_valid(backend_rsp_valid),
        .rsp_ready(backend_rsp_ready),.rsp_rdata(backend_rsp_rdata),.rsp_error(backend_rsp_error),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),
        .BRANCH_RESOLVE_IN_ID(MODE),.ENABLE_BRANCH_PRED(1),.ENABLE_RAM(1),.ENABLE_MMIO(1),.ENABLE_FENCE(FENCE_FEATURE),
        .DMEM_WORDS(8),.ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.ENABLE_EXTERNAL_IRQ(1),.ENABLE_SOFTWARE_IRQ(1),.ENABLE_TIMER_IRQ(1),.TRAP_VECTOR(VECTOR)) dut(.*);
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
    task tick;
        begin @(posedge clk);#2;
            if((last_accept&&last_accept_seq==in_seq)||last_trap||last_mret||last_irq)in_valid=0;
        end
    endtask
    task reset_case(input integer n);
        begin @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;in_pred_taken=0;in_pred_hit=0;
            in_epoch=0;id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            backend_fixture_gate=1;awready=0;wready=0;arready=0;bvalid=0;rvalid=0;fault_code=2;irq_external=0;irq_software=0;irq_timer=0;model_safe=1;sync_expected_now=0;
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
                if(timeout>100)$fatal(1,"FENCE ID timeout mode=%0d case=%0d seq=%0d ID=%b MEM=%b kex=%b kfault=%b fault=%b s=%h",MODE,case_no,age,dut.idex_valid_q,dut.exmem_valid_q,dut.kill_ex,dut.known_ex_fault,dut.mem_fault,dut.idex_q.seq);end
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
            if(timeout>100)$fatal(1,"FENCE retire timeout mode=%0d case=%0d have=%0d want=%0d",MODE,case_no,retired,n);end end
    endtask
    task wait_traps(input integer n);
        begin timeout=0;while(traps<n)begin tick;timeout=timeout+1;
            if(timeout>100)$fatal(1,"FENCE trap timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task wait_requests(input integer n);
        begin timeout=0;while(requests<n)begin tick;timeout=timeout+1;
            if(timeout>100)$fatal(1,"FENCE D request timeout mode=%0d case=%0d",MODE,case_no);end end
    endtask
    task axi_write_channels(input integer ordering);
        integer olda,oldw,limit;
        begin olda=ax_aw;oldw=ax_w;limit=0;
            while(!awvalid||!wvalid)begin tick;limit=limit+1;if(limit>100)$fatal(1,"AXI write presentation timeout");end
            repeat(2)tick;
            if(ordering==0)begin
                @(negedge clk);awready=1;while(ax_aw==olda)tick;
                @(negedge clk);awready=0;repeat(2)tick;
                @(negedge clk);wready=1;while(ax_w==oldw)tick;ax_aw_first=ax_aw_first+1;
            end else if(ordering==1)begin
                @(negedge clk);wready=1;while(ax_w==oldw)tick;
                @(negedge clk);wready=0;repeat(2)tick;
                @(negedge clk);awready=1;while(ax_aw==olda)tick;ax_w_first=ax_w_first+1;
            end else begin
                @(negedge clk);awready=1;wready=1;while(ax_aw==olda||ax_w==oldw)tick;ax_together=ax_together+1;
            end
            @(negedge clk);awready=0;wready=0;
        end
    endtask
    task axi_read_address;
        integer oldar,limit;
        begin oldar=ax_ar;limit=0;
            while(!arvalid)begin tick;limit=limit+1;if(limit>100)$fatal(1,"AXI read presentation timeout");end
            repeat(2)tick;@(negedge clk);arready=1;while(ax_ar==oldar)tick;
            @(negedge clk);arready=0;
        end
    endtask
    task backend_beat(input [31:0] data,input error);
        integer limit,oldresp;
        begin limit=0;
            while(!backend_pending)begin tick;limit=limit+1;if(limit>100)$fatal(1,"AXI native backend request timeout");end
            if(!backend_fixture_gate)$fatal(1,"AXI BFM response started before stimulus release");
            if(ax_write_q)begin
                axi_write_channels(case_no%3);oldresp=ax_b;
                @(negedge clk);bresp=error?fault_code:0;bvalid=1;
                while(ax_b==oldresp)tick;
                @(negedge clk);bvalid=0;
            end else begin
                axi_read_address;oldresp=ax_r;
                @(negedge clk);rdata=data;rresp=error?fault_code:0;rvalid=1;
                while(ax_r==oldresp)tick;
                @(negedge clk);rvalid=0;
            end
            limit=0;
            while(!last_backend_rsp)begin tick;limit=limit+1;if(limit>100)$fatal(1,"AXI final native response timeout");end
            @(negedge clk);
        end
    endtask
    // Reset is asserted on the next negative edge, before a captured AXI
    // response can be delivered to the Cache on the following positive edge.
    task reset_live_transfer;
        begin total_reset_phases=total_reset_phases+1;total_reset_abandoned_requests=total_reset_abandoned_requests+1;
            @(negedge clk);rst_n=0;in_valid=0;awready=0;wready=0;arready=0;bvalid=0;rvalid=0;
            tick;tick;@(negedge clk);rst_n=1;expected=0;requests_expected=0;traps_expected=0;irqs_expected=0;
            s=s+1;p=p+4;emit_fence(fence(0,15,15,0,0));finish_case;
        end
    endtask
    task respond(input [31:0] data,input error);
        integer target,limit;
        begin target=responses+1;limit=0;
            while(responses<target)begin
                if(backend_pending)backend_beat(data,error);else tick;
                limit=limit+1;if(limit>100)$fatal(1,"CACHE final response timeout");
            end
        end
    endtask
    task flush_at(input [63:0] cut);
        begin @(negedge clk);flush_valid=1;flush_cut_seq=cut;in_valid=0;#1;
            if(!flush_ready||!flush_fire)$fatal(1,"FENCE cancelable flush rejected");
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
                tick;timeout=timeout+1;if(timeout>120)$fatal(1,"FENCE drain mode=%0d case=%0d retire=%0d/%0d wb=%0d traps=%0d/%0d",MODE,case_no,retired,expected,wb_count,traps,traps_expected);
            end
            repeat(4)tick;
            if(requests!=requests_expected||responses!=requests||side_effects!=expected_effects)$fatal(1,"FENCE effect/transaction ledger not closed effect=%0d/%0d",side_effects,expected_effects);
            if(m_issued!=m_expected||m_completed+m_drained!=m_issued)$fatal(1,"M issue/completion ledger not closed mode=%0d case=%0d starts=%0d/%0d complete=%0d drain=%0d",MODE,case_no,m_issued,m_expected,m_completed,m_drained);
            for(j=1;j<32;j=j+1)if(model_known[j]&&dut.u_regfile.regs[j]!==model_gpr[j])
                $fatal(1,"FENCE physical GPR mismatch mode=%0d case=%0d reg=%0d",MODE,case_no,j);
            passed=passed+1;$display("CPU5_AXI_CONTROL_CASE_PASS mode=%0d case=%0d retire=%0d traps=%0d req=%0d",MODE,case_no,retired,traps,requests);
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
                if(!dmem_req_write && (dmem_req_wstrb!=0 || dut.ram_owner_store))
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
        begin timeout=0;while(!(dmem_req_valid||bus_pending))begin tick;timeout=timeout+1;if(timeout>60)$fatal(1,"FENCE request presentation timeout");end end
    endtask
    task wait_fence;
        begin timeout=0;while(!(dut.exmem_valid_q&&dut.exmem_q.seq==fence_saved_seq))begin tick;timeout=timeout+1;
            if(timeout>60)$fatal(1,"FENCE MEM arrival timeout case=%0d",case_no);end end
    endtask
    task emit_fence(input [31:0] ins);
        begin fence_saved_seq=s;emit(ins,0,0);end
    endtask
    task setup_ram;
        begin const32(2,32'h10000);emit(addi(3,0,'h55),3,'h55);wait_retired(expected);repeat(2)tick;end
    endtask
    task make_killed_read(input integer phase);
        begin
            @(negedge clk);backend_fixture_gate=(phase!=0);
            expect_request(s,'h10000);send(s,p,load(5,2,0));wait_present;
            if(phase!=0)wait_requests(1);else tick;
            flush_at(s);s=s+1;p=p+4;
            if(!dut.ram_owner_valid||!dut.ram_owner_killed)$fatal(1,"FENCE killed read fixture");
        end
    endtask
    task send_fetch_error_fence;
        begin
            offer(s,p,fence(0,15,15,0,0));in_fetch_error=1;in_fetch_tval=32'hbadc0040;timeout=0;tick;
            while(!(last_accept&&last_accept_seq==s))begin tick;timeout=timeout+1;if(timeout>60)$fatal(1,"FENCE fetch-error ID timeout");end
            @(negedge clk);in_fetch_error=0;
        end
    endtask
    always @(posedge clk)begin
        last_backend_rsp=0;
        if(!rst_n)begin
            if(backend_pending)total_backend_abandoned=total_backend_abandoned+1;
            backend_pending=0;cpu_cache_active=0;backend_word=0;backend_requests=0;backend_responses=0;backend_held=0;
            if(backend_req_valid||backend_rsp_ready)$fatal(1,"CACHE shared reset protocol leakage");
        end else begin
            if(backend_held&&(!backend_req_valid||{backend_req_write,backend_req_addr,backend_req_size,backend_req_wdata,backend_req_wstrb}!==backend_payload))
                $fatal(1,"CACHE backend request changed while held");
            backend_held=backend_req_valid&&!backend_req_ready;
            backend_payload={backend_req_write,backend_req_addr,backend_req_size,backend_req_wdata,backend_req_wstrb};
            if(backend_held)total_backend_held=total_backend_held+1;
            if(dmem_req_valid&&dmem_req_ready)begin
                if(cpu_cache_active)$fatal(1,"CACHE two CPU requests in flight");
                cpu_cache_active=1;cache_addr=dmem_req_addr;cache_data=dmem_req_wdata;
                cache_size=dmem_req_size;cache_strobe=dmem_req_wstrb;cache_write=dmem_req_write;
                cache_refill=!dmem_req_write&&dmem_req_addr>=32'h10000&&dmem_req_addr<32'h10020;
                backend_word=0;
            end
            if(backend_rsp_valid&&backend_rsp_ready)begin
                if(!backend_pending)$fatal(1,"CACHE backend response without accepted owner");
                backend_pending=0;last_backend_rsp=1;backend_responses=backend_responses+1;total_backend_responses=total_backend_responses+1;
                $fdisplay(trace_fd,"backend_rsp,%0d,%0d,%h,%h,%h,%h",case_no,cycles,64'd0,cache_addr,backend_rsp_rdata,{31'd0,backend_rsp_error});
            end
            if(backend_req_valid&&backend_req_ready)begin
                if(!cpu_cache_active||backend_pending)$fatal(1,"CACHE backend ownership/serialization");
                if(cache_refill)begin
                    if(backend_word>=4||backend_req_addr!==((cache_addr&32'hfffffff0)+backend_word*4)||backend_req_write||backend_req_size!==2||backend_req_wstrb!==0)
                        $fatal(1,"CACHE refill independent address/shape oracle mode=%0d case=%0d beat=%0d addr=%h",MODE,case_no,backend_word,backend_req_addr);
                end else if(backend_word!=0||backend_req_addr!==cache_addr||backend_req_write!==cache_write||backend_req_size!==cache_size||backend_req_wdata!==cache_data||backend_req_wstrb!==cache_strobe)
                    $fatal(1,"CACHE write/bypass descriptor or duplicate backend request");
                if(backend_req_write)begin
                    total_backend_writes=total_backend_writes+1;
                    // Physical writes occur only when AXI AW and W have paired.
                end
                backend_word=backend_word+1;backend_pending=1;backend_requests=backend_requests+1;total_backend_requests=total_backend_requests+1;
                $fdisplay(trace_fd,"backend_req,%0d,%0d,%h,%h,%h,%h",case_no,cycles,64'd0,backend_req_addr,backend_req_wdata,{31'd0,backend_req_write});
            end
            if(dmem_rsp_valid&&dmem_rsp_ready)begin
                if(!cpu_cache_active||backend_pending)$fatal(1,"CACHE CPU response before complete backend transaction");
                cpu_cache_active=0;
            end
        end
    end

    always @(posedge clk)begin
        if(!rst_n)begin
            if(ax_pending)begin
                ax_drops=ax_drops+1;
                if(ax_seen_aw&&!ax_seen_w)ax_reset_aw_only=ax_reset_aw_only+1;
                if(ax_seen_w&&!ax_seen_aw)ax_reset_w_only=ax_reset_w_only+1;
                if(ax_pair&&!ax_reply)ax_reset_pair=ax_reset_pair+1;
                if(ax_seen_ar&&!ax_reply)ax_reset_read=ax_reset_read+1;
                if(ax_reply)ax_reset_captured=ax_reset_captured+1;
                $fdisplay(axi_fd,"reset,%0d,%0d,%h,%h,%h,%h",case_no,cycles,ax_addr_q,ax_data_q,ax_strb_q,ax_reply_code);
            end
            ax_pending=0;ax_seen_aw=0;ax_seen_w=0;ax_seen_ar=0;ax_pair=0;ax_reply=0;
            ax_held_aw=0;ax_held_w=0;ax_held_ar=0;ax_held_rsp=0;
            if(awvalid||wvalid||arvalid||bready||rready||backend_rsp_valid)$fatal(1,"AXI shared reset leaked protocol action");
        end else begin
            if(ax_held_aw&&(!awvalid||{awaddr,awprot}!==ax_aw_saved))$fatal(1,"AXI held AW identity changed");
            if(ax_held_w&&(!wvalid||{wdata,wstrb}!==ax_w_saved))$fatal(1,"AXI held W identity changed");
            if(ax_held_ar&&(!arvalid||{araddr,arprot}!==ax_ar_saved))$fatal(1,"AXI held AR identity changed");
            if(ax_held_rsp&&(!backend_rsp_valid||{backend_rsp_error,backend_rsp_rdata}!==ax_rsp_saved))$fatal(1,"AXI held native response changed");
            ax_held_aw=awvalid&&!awready;ax_aw_saved={awaddr,awprot};if(ax_held_aw)ax_aw_hold=ax_aw_hold+1;
            ax_held_w=wvalid&&!wready;ax_w_saved={wdata,wstrb};if(ax_held_w)ax_w_hold=ax_w_hold+1;
            ax_held_ar=arvalid&&!arready;ax_ar_saved={araddr,arprot};if(ax_held_ar)ax_ar_hold=ax_ar_hold+1;
            ax_held_rsp=backend_rsp_valid&&!backend_rsp_ready;ax_rsp_saved={backend_rsp_error,backend_rsp_rdata};if(ax_held_rsp)ax_cpu_hold=ax_cpu_hold+1;
            if(backend_req_valid&&backend_req_ready)begin
                if(ax_pending)$fatal(1,"AXI native owner overwritten");
                ax_pending=1;ax_write_q=backend_req_write;ax_addr_q=backend_req_addr&32'hfffffffc;
                ax_data_q=backend_req_wdata;ax_strb_q=backend_req_wstrb;
                ax_seen_aw=0;ax_seen_w=0;ax_seen_ar=0;ax_pair=0;ax_reply=0;ax_native=ax_native+1;
            end
            if(awvalid&&awready)begin
                if(!ax_pending||!ax_write_q||ax_seen_aw||awaddr!==ax_addr_q||awprot!==0)$fatal(1,"AXI AW descriptor or duplicate");
                ax_seen_aw=1;ax_aw=ax_aw+1;$fdisplay(axi_fd,"aw,%0d,%0d,%h,%h,%h,0",case_no,cycles,awaddr,32'd0,4'd0);
            end
            if(wvalid&&wready)begin
                if(!ax_pending||!ax_write_q||ax_seen_w||wdata!==ax_data_q||wstrb!==ax_strb_q)$fatal(1,"AXI W descriptor or duplicate");
                ax_seen_w=1;ax_w=ax_w+1;$fdisplay(axi_fd,"w,%0d,%0d,%h,%h,%h,0",case_no,cycles,ax_addr_q,wdata,wstrb);
            end
            if(ax_seen_aw&&ax_seen_w&&!ax_pair)begin
                ax_pair=1;ax_writes=ax_writes+1;
                if(ax_addr_q>=32'h10000&&ax_addr_q<32'h10020)
                    for(ax_lane=0;ax_lane<4;ax_lane=ax_lane+1)if(ax_strb_q[ax_lane])backend_ram[(ax_addr_q-32'h10000)>>2][ax_lane*8+:8]=ax_data_q[ax_lane*8+:8];
                $fdisplay(axi_fd,"commit,%0d,%0d,%h,%h,%h,0",case_no,cycles,ax_addr_q,ax_data_q,ax_strb_q);
            end
            if(bvalid&&bready)begin
                if(!ax_pending||!ax_write_q||!ax_pair||ax_reply)$fatal(1,"AXI B has no paired original write");
                ax_reply=1;ax_reply_data=0;ax_reply_code=bresp;ax_b=ax_b+1;
                case(bresp)1:ax_b1=ax_b1+1;2:ax_b2=ax_b2+1;3:ax_b3=ax_b3+1;default:begin end endcase
                $fdisplay(axi_fd,"b,%0d,%0d,%h,%h,%h,%h",case_no,cycles,ax_addr_q,32'd0,4'd0,bresp);
            end
            if(arvalid&&arready)begin
                if(!ax_pending||ax_write_q||ax_seen_ar||araddr!==ax_addr_q||arprot!==0)$fatal(1,"AXI AR descriptor or duplicate");
                ax_seen_ar=1;ax_ar=ax_ar+1;$fdisplay(axi_fd,"ar,%0d,%0d,%h,%h,%h,0",case_no,cycles,araddr,32'd0,4'd0);
            end
            if(rvalid&&rready)begin
                if(!ax_pending||ax_write_q||!ax_seen_ar||ax_reply)$fatal(1,"AXI R lacks original read");
                ax_reply=1;ax_reply_data=rresp==0?rdata:32'd0;ax_reply_code=rresp;ax_r=ax_r+1;
                case(rresp)1:ax_r1=ax_r1+1;2:ax_r2=ax_r2+1;3:ax_r3=ax_r3+1;default:begin end endcase
                $fdisplay(axi_fd,"r,%0d,%0d,%h,%h,%h,%h",case_no,cycles,ax_addr_q,rdata,4'd0,rresp);
            end
            if(backend_rsp_valid&&backend_rsp_ready)begin
                if(!ax_pending||!ax_reply||backend_rsp_error!==(ax_reply_code!=0)||backend_rsp_rdata!==ax_reply_data)
                    $fatal(1,"AXI native response owner/data/error mapping");
                ax_complete=ax_complete+1;ax_pending=0;
            end
        end
    end
    initial begin
        axi_fd=$fopen($sformatf("build/cpu5_s14_axi_control/mode%0d_axi.csv",MODE),"w");
        $fdisplay(axi_fd,"event,case,cycle,addr,data,strb,resp");
        for(init_word=0;init_word<8;init_word=init_word+1)backend_ram[init_word]=0;
        trace_fd=$fopen($sformatf("build/cpu5_s14_axi_control/mode%0d_trace.csv",MODE),"w");
        $fdisplay(trace_fd,"event,case,cycle,seq,pc,instruction_or_cause,value_or_tval");
        // No-pending fences cover all masks, FENCE.TSO, reserved fields and a
        // real unresolved producer whose rd aliases the ignored rs1 field.
        reset_case(1);wb_ready=0;emit(addi(31,0,91),31,91);wait_retired(expected);
        emit_fence(fence(15,0,0,31,31));emit(addi(8,31,1),8,92);repeat(4)tick;
        if(retired!=1)$fatal(1,"FENCE ignored WB backpressure");
        @(negedge clk);wb_ready=1;finish_case;
        reset_case(2);emit_fence(fence(0,0,0,0,0));emit_fence(fence(8,3,3,9,17));emit_fence(fence(4,5,10,31,30));finish_case;

        // A first request from any younger RAM/IO operation is forbidden on
        // both a held fence edge and its successful retirement edge.
        for(stage=0;stage<5;stage=stage+1)begin
            reset_case(3+stage);setup_ram;
            const32(4,stage==4?32'h40000000:32'h20000000);wait_retired(expected);repeat(2)tick;
            @(negedge clk);mem_enable=0;fence_before=retired;
            emit_fence(fence(0,15,15,3,6));
            if(stage==0)begin expect_request(s,'h10000);emit(load(6,2,0),6,'h12345678);end
            if(stage==1)begin expect_store(s,'h10000,'h55);emit(store(3,2,0),0,0);end
            if(stage==2)begin expected_effects=1;expect_request(s,'h20000000);emit(load(6,4,0),6,'h12345678);end
            if(stage>=3)begin expected_effects=(stage==3);expect_store(s,stage==4?'h40000000:'h20000000,'h55);emit(store(3,4,0),0,0);end
            wait_fence;repeat(4)tick;
            if(requests||retired!=fence_before)$fatal(1,"FENCE paused barrier leaked successor");
            @(negedge clk);mem_enable=1;tick;
            if(requests||retired!=fence_before+1)$fatal(1,"FENCE retirement edge admitted successor request");
            wait_requests(1);respond('h12345678,0);finish_case;
        end

        // A killed old RAM read is still a physical transaction. Its held,
        // accepted and error completion phases all serialize a new fence.
        for(stage=0;stage<3;stage=stage+1)begin
            reset_case(8+stage);setup_ram;make_killed_read(stage);fence_before=retired;
            emit_fence(fence(stage,15,15,5,5));emit(addi(9,0,29),9,29);wait_fence;repeat(5)tick;
            if(retired!=fence_before)$fatal(1,"FENCE failed to wait killed D transaction");
            @(negedge clk);backend_fixture_gate=1;wait_requests(1);respond('hdeadcafe,stage==2);
            if(retired!=fence_before)$fatal(1,"FENCE retired on old D response edge");
            finish_case;
        end

        // An architectural STORE / ordered read must complete before the
        // following fence reaches its own MEM retirement point.
        for(stage=0;stage<3;stage=stage+1)begin
            reset_case(11+stage);setup_ram;const32(4,'h20000000);wait_retired(expected);repeat(2)tick;
            @(negedge clk);backend_fixture_gate=0;
            if(stage==0)begin expect_store(s,'h10000,'h55);emit(store(3,2,0),0,0);end
            if(stage==1)begin expected_effects=1;expect_request(s,'h20000000);emit(load(6,4,0),6,'hfeed1234);end
            if(stage==2)begin expected_effects=1;expect_store(s,'h20000000,'h55);emit(store(3,4,0),0,0);end
            wait_present;fence_before=retired;emit_fence(fence(0,15,15,0,0));repeat(5)tick;
            if(retired!=fence_before)$fatal(1,"FENCE bypassed older live STORE/IO");
            @(negedge clk);backend_fixture_gate=1;wait_requests(1);respond('hfeed1234,0);finish_case;
        end

        // An independent killed DIV is background drain, not a fence owner.
        reset_case(14);emit(addi(1,0,107),1,107);emit(addi(2,0,7),2,7);wait_retired(expected);
        expect_m(s,p,mop(4,6,1,2),15,1);send(s,p,mop(4,6,1,2));wait_m_started(1);flush_at(s);s=s+1;p=p+4;
        emit_fence(fence(0,15,15,0,0));wait_retired(expected);
        if(!dut.m_owner_valid||!dut.m_owner_killed)$fatal(1,"FENCE unnecessarily waited killed DIV");finish_case;

        // All 64 age bits participate in cancellation. A high cut preserves the
        // older held fence; a matching high cut cancels the next fence cleanly.
        reset_case(15);s=64'h00000000ffffffff;mem_enable=0;
        emit_fence(fence(0,15,15,0,0));wait_fence;flush_at(64'h0000000100000000);
        @(negedge clk);mem_enable=1;wait_retired(expected);s=64'h0000000100000000;
        @(negedge clk);mem_enable=0;send(s,p,fence(0,15,15,0,0));flush_at(s);
        @(negedge clk);mem_enable=1;finish_case;

        // IRQ preempts a side-effect-free fence even with old killed read drain.
        reset_case(16);enable_external;setup_ram;wb_ready=0;emit(addi(10,0,91),10,91);wait_retired(expected);make_killed_read(1);fence_before=retired;
        fence_saved_seq=s;send(s,p,fence(0,15,15,0,0));wait_fence;
        @(negedge clk);irq_external=1;irqs_expected=1;wait_irqs(1);quiet_sources;
        if(retired!=fence_before||!dut.ram_owner_valid)$fatal(1,"FENCE IRQ waited drain or retired canceled fence");
        @(negedge clk);wb_ready=1;respond(0,1);s=s+1;p=VECTOR;emit(addi(8,0,77),8,77);finish_case;

        // Fetch error has priority over the instruction bits and never waits
        // on a fence drain dependency, including an already armed interrupt.
        reset_case(17);enable_external;setup_ram;make_killed_read(1);
        @(negedge clk);mem_enable=0;expect_trap(s,p,1,'hbadc0040,VECTOR);send_fetch_error_fence;
        repeat(3)tick;@(negedge clk);irq_external=1;wait_armed;sync_expected_now=1;
        @(negedge clk);mem_enable=1;tick;sync_expected_now=0;quiet_sources;wait_traps(1);
        if(!dut.ram_owner_valid)$fatal(1,"FENCE fetch-error fixture lost drain");respond(0,1);finish_case;

        // Older synchronous fault cancels the younger fence. FENCE.I and all
        // other MISC-MEM funct3 encodings remain precise illegal instructions.
        reset_case(18);mem_enable=0;expect_trap(s,p,11,0,VECTOR);send(s,p,32'h73);s=s+1;p=p+4;
        offer(s,p,fence(0,15,15,0,0));repeat(3)tick;@(negedge clk);mem_enable=1;sync_expected_now=1;tick;sync_expected_now=0;finish_case;
        for(stage=1;stage<8;stage=stage+1)begin
            reset_case(18+stage);word=(stage<<12)|32'h0000000f;expect_trap(s,p,2,word,VECTOR);send(s,p,word);finish_case;
        end

        // Stale BTB prediction for an ordinary FENCE is repaired in EX in both
        // branch-resolution modes; retirement trains no branch or JAL flags.
        reset_case(26);pred_expected=1;pred_seq=s;expect_packet(s,p,fence(8,3,3,13,22),0,0,p+4);
        offer(s,p,fence(8,3,3,13,22));in_pred_next_pc='h800;in_pred_taken=1;in_pred_hit=1;tick;
        wait_retired(expected);if(pred_expected)$fatal(1,"FENCE stale BTB prediction was not repaired");finish_case;

        // Reset from a waiting fence and accepted killed read drops that old
        // physical epoch without permitting replay in the next reset epoch.
        reset_case(27);setup_ram;make_killed_read(1);send(s,p,fence(0,15,15,0,0));fence_saved_seq=s;wait_fence;
        total_reset_phases=total_reset_phases+1;total_reset_abandoned_requests=total_reset_abandoned_requests+1;
        @(negedge clk);rst_n=0;in_valid=0;tick;tick;@(negedge clk);rst_n=1;expected=0;requests_expected=0;
        repeat(5)tick;finish_case;
        // A young M instruction can allocate its separate owner before EX
        // movement, so it needs its own held/retirement-edge barrier test.
        reset_case(28);emit(addi(1,0,6),1,6);emit(addi(2,0,7),2,7);wait_retired(expected);
        @(negedge clk);mem_enable=0;emit_fence(fence(0,15,15,0,0));emit_m(0,6,1,2,42);
        wait_fence;repeat(4)tick;
        if(m_issued!=0)$fatal(1,"FENCE young M started while MEM paused");
        @(negedge clk);mem_enable=1;tick;
        if(m_issued!=0)$fatal(1,"FENCE young M started on retirement edge");finish_case;
        // Every refill beat can fault. The requested VA is the last word,
        // so backend failure addresses differ from architectural mtval.
        for(stage=0;stage<4;stage=stage+1)begin
            reset_case(29+stage);setup_ram;expect_request(s,32'h1000c);
            expect_trap(s,p,5,32'h1000c,VECTOR);send(s,p,load(5,2,12));wait_requests(1);
            for(k=0;k<=stage;k=k+1)backend_beat(32'habc00000+k,k==stage);
            wait_traps(1);total_cache_faults=total_cache_faults+1;finish_case;
        end
        // Cancel during each actual refill stage. Old pure reads continue,
        // errors are dropped, and a new FENCE waits for final CPU response.
        for(stage=0;stage<4;stage=stage+1)begin
            reset_case(33+stage);setup_ram;expect_request(s,32'h1000c);send(s,p,load(5,2,12));wait_requests(1);
            for(k=0;k<stage;k=k+1)backend_beat(32'hcafe0000+k,0);
            flush_at(s);s=s+1;p=p+4;fence_before=retired;
            emit_fence(fence(0,15,15,0,0));wait_fence;repeat(4)tick;
            if(retired!=fence_before||!dut.ram_owner_valid||!dut.ram_owner_killed)$fatal(1,"CACHE FENCE skipped killed refill drain");
            backend_beat(0,1);total_killed_refill_faults=total_killed_refill_faults+1;
            finish_case;
        end
        // Shared reset at each refill response boundary abandons the old
        // epoch without replay. A fresh post-reset FENCE must retire normally.
        for(stage=0;stage<4;stage=stage+1)begin
            reset_case(37+stage);setup_ram;expect_request(s,32'h10000);send(s,p,load(5,2,0));wait_requests(1);
            for(k=0;k<stage;k=k+1)backend_beat(32'hface0000+k,0);
            timeout=0;while(!backend_pending)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"CACHE reset refill fixture timeout");end
            total_reset_phases=total_reset_phases+1;total_reset_abandoned_requests=total_reset_abandoned_requests+1;
            @(negedge clk);rst_n=0;in_valid=0;tick;tick;@(negedge clk);rst_n=1;expected=0;requests_expected=0;traps_expected=0;
            s=s+1;p=p+4;emit_fence(fence(0,15,15,0,0));finish_case;
        end
        // A backend may have applied a write before its error response.
        // The precise Trap does not roll back that physical effect.
        reset_case(41);setup_ram;expect_store(s,32'h10000,32'h55);expect_trap(s,p,7,32'h10000,VECTOR);
        send(s,p,store(3,2,0));wait_requests(1);backend_beat(0,1);wait_traps(1);
        if(backend_ram[0]!==32'h55)$fatal(1,"CACHE failed write rolled back backend memory");finish_case;
        // A successful physical STORE may finish while old retired WB is
        // blocked. FENCE waits for architectural retirement, and STORE rejects
        // cancellation through its final response/held completion interval.
        reset_case(42);setup_ram;wb_ready=0;emit(addi(10,0,91),10,91);wait_retired(expected);fence_before=retired;
        saved_store_seq=s;expect_store(s,32'h10000,32'h55);emit(store(3,2,0),0,0);wait_requests(1);emit_fence(fence(0,15,15,0,0));
        @(negedge clk);flush_valid=1;flush_cut_seq=saved_store_seq;#1;
        if(flush_ready||flush_fire)$fatal(1,"CACHE irrevocable write accepted cancellation");tick;@(negedge clk);flush_valid=0;
        backend_beat(0,0);repeat(3)tick;
        if(retired!=fence_before||backend_ram[0]!==32'h55)$fatal(1,"CACHE STORE/WB/FENCE completion order");
        @(negedge clk);wb_ready=1;finish_case;
        // All non-OKAY RRESP values must preserve original load PC/VA.
        for(op_no=1;op_no<4;op_no=op_no+2)for(stage=0;stage<4;stage=stage+1)begin
            reset_case(43+((op_no-1)/2)*4+stage);fault_code=op_no;setup_ram;expect_request(s,32'h1000c);
            expect_trap(s,p,5,32'h1000c,VECTOR);send(s,p,load(5,2,12));wait_requests(1);
            for(k=0;k<=stage;k=k+1)backend_beat(32'h12340000+k,k==stage);
            wait_traps(1);total_cache_faults=total_cache_faults+1;finish_case;
        end
        for(op_no=1;op_no<4;op_no=op_no+2)for(stage=0;stage<4;stage=stage+1)begin
            reset_case(51+((op_no-1)/2)*4+stage);fault_code=op_no;setup_ram;expect_request(s,32'h1000c);
            send(s,p,load(5,2,12));wait_requests(1);
            for(k=0;k<stage;k=k+1)backend_beat(32'habcd0000+k,0);
            flush_at(s);s=s+1;p=p+4;fence_before=retired;emit_fence(fence(0,15,15,0,0));wait_fence;repeat(3)tick;
            if(retired!=fence_before||!dut.ram_owner_killed)$fatal(1,"AXI FENCE skipped canceled refill");
            backend_beat(0,1);total_killed_refill_faults=total_killed_refill_faults+1;finish_case;
        end
        // Error after a physical write to a hit must invalidate that line.
        for(op_no=1;op_no<4;op_no=op_no+1)begin
            reset_case(58+op_no);fault_code=op_no;setup_ram;
            expect_request(s,32'h10000);emit(load(6,2,0),6,32'h11110000);wait_requests(1);respond(32'h11110000,0);wait_retired(expected);
            expect_store(s,32'h10000,32'h55);expect_trap(s,p,7,32'h10000,VECTOR);send(s,p,store(3,2,0));wait_requests(2);
            backend_beat(0,1);wait_traps(1);
            if(backend_ram[0]!==32'h55)$fatal(1,"AXI failed write effect was rolled back");
            s=s+1;p=VECTOR;expect_request(s,32'h10000);emit(load(6,2,0),6,32'h55);wait_requests(3);respond(32'h55,0);finish_case;
        end
        // Half channel, outstanding response, and captured-response reset.
        for(stage=0;stage<6;stage=stage+1)begin
            reset_case(62+stage);setup_ram;emit(addi(3,0,'h66+stage),3,'h66+stage);wait_retired(expected);
            case_mem_before=backend_ram[0];
            if(stage==3||stage==4)begin expect_request(s,32'h10000);send(s,p,load(5,2,0));end
            else begin expect_store(s,32'h10000,'h66+stage);send(s,p,store(3,2,0));end
            wait_requests(1);timeout=0;while(!backend_pending)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"AXI reset native fixture timeout");end
            if(stage==0)begin
                while(!awvalid||!wvalid)tick;@(negedge clk);awready=1;tick;@(negedge clk);awready=0;repeat(3)tick;
                if(backend_ram[0]!==case_mem_before)$fatal(1,"AXI AW-only caused physical write");
            end else if(stage==1)begin
                while(!awvalid||!wvalid)tick;@(negedge clk);wready=1;tick;@(negedge clk);wready=0;repeat(3)tick;
                if(backend_ram[0]!==case_mem_before)$fatal(1,"AXI W-only caused physical write");
            end else if(stage==2||stage==5)begin
                axi_write_channels(2);
                if(backend_ram[0]!==('h66+stage))$fatal(1,"AXI paired write effect missing before reset");
                if(stage==5)begin @(negedge clk);bvalid=1;bresp=0;tick;end
            end else begin
                axi_read_address;
                if(stage==4)begin @(negedge clk);rvalid=1;rresp=0;rdata=32'hfeedface;tick;end
            end
            reset_live_transfer;
            if(stage==2||stage==5)begin if(backend_ram[0]!==('h66+stage))$fatal(1,"AXI reset rolled back completed physical write");end
            else if(backend_ram[0]!==case_mem_before)$fatal(1,"AXI reset invented a physical write");
        end
        // Armed IRQ cannot preempt a STORE with only AW already accepted.
        reset_case(68);enable_external;setup_ram;model_safe=0;fence_before=retired;
        expect_store(s,32'h10000,32'h55);emit(store(3,2,0),0,0);wait_requests(1);
        while(!awvalid||!wvalid)tick;@(negedge clk);awready=1;tick;@(negedge clk);awready=0;irq_external=1;irqs_expected=1;
        repeat(6)begin tick;ax_irq_store_wait=ax_irq_store_wait+1;if(irqs||retired!=fence_before)$fatal(1,"AXI IRQ preempted half-presented STORE");end
        @(negedge clk);wready=1;tick;@(negedge clk);wready=0;repeat(2)tick;
        @(negedge clk);bvalid=1;bresp=0;tick;@(negedge clk);bvalid=0;
        while(!last_backend_rsp)tick;wait_retired(expected);model_safe=1;wait_irqs(1);quiet_sources;finish_case;
        if(ax_native!=ax_complete+ax_drops||ax_aw_first==0||ax_w_first==0||ax_together==0||ax_reset_aw_only!=1||ax_reset_w_only!=1||
           ax_reset_pair!=1||ax_reset_read!=1||ax_reset_captured!=2||ax_r1==0||ax_r2==0||ax_r3==0||ax_b1==0||ax_b2==0||ax_b3==0)
            $fatal(1,"AXI complete channel/reset/response-code coverage");
        axis_fd=$fopen($sformatf("build/cpu5_s14_axi_control/mode%0d_axi_summary.json",MODE),"w");
        $fdisplay(axis_fd,"{\"mode\":%0d,\"native_requests\":%0d,\"native_responses\":%0d,\"native_reset_drops\":%0d,\"aw\":%0d,\"w\":%0d,\"b\":%0d,\"ar\":%0d,\"r\":%0d,\"physical_writes\":%0d,\"aw_first\":%0d,\"w_first\":%0d,\"together\":%0d,\"aw_held\":%0d,\"w_held\":%0d,\"ar_held\":%0d,\"cpu_rsp_held\":%0d,\"reset_aw_only\":%0d,\"reset_w_only\":%0d,\"reset_paired\":%0d,\"reset_read\":%0d,\"reset_captured\":%0d,\"rresp1\":%0d,\"rresp2\":%0d,\"rresp3\":%0d,\"bresp1\":%0d,\"bresp2\":%0d,\"bresp3\":%0d,\"irq_store_wait\":%0d}",MODE,ax_native,ax_complete,ax_drops,ax_aw,ax_w,ax_b,ax_ar,ax_r,ax_writes,ax_aw_first,ax_w_first,ax_together,ax_aw_hold,ax_w_hold,ax_ar_hold,ax_cpu_hold,ax_reset_aw_only,ax_reset_w_only,ax_reset_pair,ax_reset_read,ax_reset_captured,ax_r1,ax_r2,ax_r3,ax_b1,ax_b2,ax_b3,ax_irq_store_wait);
        $fclose(axis_fd);$fclose(axi_fd);
        if(total_backend_requests!=total_backend_responses+total_backend_abandoned||total_cache_faults!=12||total_killed_refill_faults!=12)
            $fatal(1,"CACHE complete backend ledger/coverage req=%0d rsp=%0d reset=%0d",total_backend_requests,total_backend_responses,total_backend_abandoned);
        if(passed!=68||total_fences<24||total_fence_wait<15||total_fence_retire_barrier!=total_fences||
            total_fence_m_background!=1||total_fence_redirect!=1||total_irqs!=2||total_traps!=25||
            total_requests!=total_responses+total_reset_abandoned_requests)
            $fatal(1,"FENCE coverage mode=%0d cases=%0d fence=%0d wait=%0d irq=%0d trap=%0d",MODE,passed,total_fences,total_fence_wait,total_irqs,total_traps);
        summary_fd=$fopen($sformatf("build/cpu5_s14_axi_control/mode%0d_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"mode\":%0d,\"cases\":%0d,\"retired\":%0d,\"wb\":%0d,\"sync_traps\":%0d,\"irqs\":%0d,\"requests\":%0d,\"responses\":%0d,\"fences\":%0d,\"fence_wait_edges\":%0d,\"fence_barrier_edges\":%0d,\"retire_barriers\":%0d,\"fence_m_background\":%0d,\"fence_redirects\":%0d,\"reset_phases\":%0d,\"reset_abandoned_requests\":%0d,\"held_d_edges\":%0d,\"committed_state_checks\":%0d}",
            MODE,passed,total_retired,total_wb,total_traps,total_irqs,total_requests,total_responses,total_fences,total_fence_wait,total_fence_barrier,total_fence_retire_barrier,total_fence_m_background,total_fence_redirect,total_reset_phases,total_reset_abandoned_requests,total_held_d,total_status_checks);
        $fclose(summary_fd);
        summary_fd=$fopen($sformatf("build/cpu5_s14_axi_control/mode%0d_backend_summary.json",MODE),"w");
        $fdisplay(summary_fd,"{\"mode\":%0d,\"requests\":%0d,\"responses\":%0d,\"reset_abandoned\":%0d,\"writes\":%0d,\"held_edges\":%0d,\"live_refill_errors\":%0d,\"killed_refill_errors\":%0d}",MODE,total_backend_requests,total_backend_responses,total_backend_abandoned,total_backend_writes,total_backend_held,total_cache_faults,total_killed_refill_faults);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
endmodule
module cpu5_axi_control_tb;
    wire [3:0] done;reg test_pass=0;
    cpu5_axi_control_case #(.MODE(0)) ex_mode(done[0]);
    cpu5_axi_control_case #(.MODE(1)) id_mode(done[1]);
    cpu5_axi_frontend_case #(.BP(0)) front_bp0(done[2]);
    cpu5_axi_frontend_case #(.BP(1)) front_bp1(done[3]);
    initial begin wait(&done);test_pass=1;$display("CPU5 AXI CONTROL TEST PASS");$stop;end
    initial begin #500000;$fatal(1,"CPU5 FENCE control timeout");end
endmodule

// The real CPU5 IF adapter owns age/epoch and sticky fault-packet conversion.
// The independent ledger below observes only its public cache interface.
module cpu5_axi_frontend_case #(parameter integer BP=0)(output reg done=0);
    reg clk=0,rst_n=0,redirect=0,id_ready=1,block_rom=0;
    reg [31:0] target=0,fault_addr=32'hffffffff;
    wire redirect_ready,req_valid,req_ready,rsp_valid,rsp_ready,rsp_error;
    wire [31:0] req_addr,rsp_data,pc,instruction,fault_pc,next_pc,fetch_tval;
    wire valid,fault,fetch_error,pred_taken,pred_hit;
    wire [63:0] seq;wire [7:0] epoch;
    wire mreq_valid,mreq_ready,mrsp_ready;wire [31:0] mreq_addr;
    reg mrsp_valid=0,mrsp_error=0;reg [31:0] mrsp_data=0;
    integer trace_fd,summary_fd,scenario=0,passed=0,checks=0;
    integer total_requests=0,total_responses=0,total_reset_drops=0,total_backend_requests=0,total_backend_responses=0,total_backend_reset_drops=0;
    integer packets=0,error_packets=0,stale_errors=0,held_edges=0,redirects=0;
    reg pending=0,stale=0;reg [31:0] pending_pc=0;
    reg [63:0] next_seq=0,last_seq=0;reg last_seq_valid=0;
    reg req_held=0,rsp_held=0;reg [31:0] req_saved=0,rsp_saved=0;reg rsp_error_saved=0;
    reg pre_rsp=0,pre_drop=0,pre_error=0;reg [31:0] pre_pc=0,pre_instruction=0;reg [63:0] pre_seq=0;
    always #5 clk=~clk;
    cpu5_if_adapter #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(512),.ENABLE_BRANCH_PRED(BP),.BTB_ENTRIES(4)) front(
        .clk(clk),.rst_n(rst_n),.id_ready(id_ready),.redirect_valid(redirect),.redirect_ready(redirect_ready),.redirect_pc(target),.redirect_kill_ifid(1'b1),
        .ifid_valid(valid),.ifid_pc(pc),.ifid_instr(instruction),.ifid_pred_next_pc(next_pc),.ifid_pred_taken(pred_taken),.ifid_pred_hit(pred_hit),
        .ifid_fetch_error(fetch_error),.ifid_fetch_tval(fetch_tval),.ifid_seq(seq),.ifid_epoch(epoch),
        .imem_req_valid(req_valid),.imem_req_ready(req_ready),.imem_req_addr(req_addr),.imem_rsp_valid(rsp_valid),.imem_rsp_ready(rsp_ready),.imem_rsp_rdata(rsp_data),.imem_rsp_error(rsp_error),
        .bp_commit_valid(1'b0),.bp_commit_ready(),.bp_commit_seq(64'd0),.bp_commit_pc(32'd0),.bp_commit_target(32'd0),.bp_commit_taken(1'b0),.bp_commit_is_branch(1'b0),.bp_commit_is_jal(1'b0),.bp_update_fire(),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.imem_fault(fault),.imem_fault_pc(fault_pc));
    cpu5_cache_adapter #(.ENABLE_ICACHE(1),.ENABLE_DCACHE(0),.ICACHE_SETS(4),.ICACHE_LINE_WORDS(4),.IMEM_WORDS(512)) adapter(
        .clk(clk),.rst_n(rst_n),
        .cpu_imem_req_valid(req_valid),.cpu_imem_req_ready(req_ready),.cpu_imem_req_addr(req_addr),.cpu_imem_rsp_valid(rsp_valid),.cpu_imem_rsp_ready(rsp_ready),.cpu_imem_rsp_rdata(rsp_data),.cpu_imem_rsp_error(rsp_error),
        .mem_imem_req_valid(mreq_valid),.mem_imem_req_ready(mreq_ready),.mem_imem_req_addr(mreq_addr),.mem_imem_rsp_valid(mrsp_valid),.mem_imem_rsp_ready(mrsp_ready),.mem_imem_rsp_rdata(mrsp_data),.mem_imem_rsp_error(mrsp_error),
        .cpu_dmem_req_valid(1'b0),.cpu_dmem_req_ready(),.cpu_dmem_req_write(1'b0),.cpu_dmem_req_addr(32'd0),.cpu_dmem_req_size(2'd2),.cpu_dmem_req_wdata(32'd0),.cpu_dmem_req_wstrb(4'd0),
        .cpu_dmem_rsp_valid(),.cpu_dmem_rsp_ready(1'b1),.cpu_dmem_rsp_rdata(),.cpu_dmem_rsp_error(),
        .mem_dmem_req_valid(),.mem_dmem_req_ready(1'b1),.mem_dmem_req_write(),.mem_dmem_req_addr(),.mem_dmem_req_size(),.mem_dmem_req_wdata(),.mem_dmem_req_wstrb(),
        .mem_dmem_rsp_valid(1'b0),.mem_dmem_rsp_ready(),.mem_dmem_rsp_rdata(32'd0),.mem_dmem_rsp_error(1'b0),
        .icache_access_count(),.icache_hit_count(),.icache_miss_count(),.icache_refill_word_count(),.icache_error_count(),
        .dcache_access_count(),.dcache_hit_count(),.dcache_miss_count(),.dcache_refill_word_count(),.dcache_error_count(),.dcache_write_count(),.dcache_bypass_count());
    function [31:0] instruction_at(input [31:0] address);
        instruction_at=((address/4)<<20)|32'h00000513;
    endfunction
    assign mreq_ready=rst_n&&!block_rom&&!mrsp_valid;
    always @(posedge clk)begin
        if(!rst_n)begin
            if(mrsp_valid)total_backend_reset_drops=total_backend_reset_drops+1;
            mrsp_valid<=0;mrsp_error<=0;mrsp_data<=0;
        end else begin
            if(mrsp_valid&&mrsp_ready)begin mrsp_valid<=0;total_backend_responses=total_backend_responses+1;end
            if(mreq_valid&&mreq_ready)begin
                mrsp_valid<=1;mrsp_error<=mreq_addr==fault_addr;mrsp_data<=instruction_at(mreq_addr);total_backend_requests=total_backend_requests+1;
            end
        end
    end
    always @(posedge clk)begin
        if(!rst_n)begin
            if(pending)total_reset_drops=total_reset_drops+1;
            pending=0;stale=0;next_seq=0;last_seq_valid=0;req_held=0;rsp_held=0;
        end else begin
            checks=checks+1;
            if(redirect&&!redirect_ready)$fatal(1,"CACHE frontend authorized redirect rejected");
            if(req_held&&(!req_valid||req_addr!==req_saved))$fatal(1,"CACHE frontend held CPU request changed");
            if(rsp_held&&(!rsp_valid||rsp_data!==rsp_saved||rsp_error!==rsp_error_saved))$fatal(1,"CACHE frontend held cache response changed");
            req_held=req_valid&&!req_ready;req_saved=req_addr;
            rsp_held=rsp_valid&&!rsp_ready;rsp_saved=rsp_data;rsp_error_saved=rsp_error;
            if(rsp_held)held_edges=held_edges+1;
            if(valid&&id_ready&&!redirect)begin
                if(last_seq_valid&&seq<=last_seq)$fatal(1,"CACHE frontend accepted seq repeated or regressed");
                last_seq=seq;last_seq_valid=1;packets=packets+1;
                if(fetch_error)begin
                    if(scenario!=3||pc!==0||fetch_tval!==0||instruction!==32'h13||next_pc!==4||pred_hit||pred_taken)
                        $fatal(1,"CACHE frontend precise original-PC fault packet");
                    error_packets=error_packets+1;
                end else if(instruction!==instruction_at(pc)||next_pc!==pc+4||fetch_tval!==0)
                    $fatal(1,"CACHE frontend accepted instruction/PC metadata");
                $fdisplay(trace_fd,"packet,%0d,%h,%h,%h,%0d",scenario,seq,pc,instruction,fetch_error);
            end
            pre_rsp=rsp_valid&&rsp_ready;pre_drop=stale||redirect;pre_error=rsp_error;pre_pc=pending_pc;pre_instruction=rsp_data;pre_seq=next_seq;
            if(pre_rsp)begin
                if(!pending)$fatal(1,"CACHE frontend response without original CPU owner");
                if(rsp_error&&pre_drop)stale_errors=stale_errors+1;
                pending=0;stale=0;total_responses=total_responses+1;
                if(!pre_drop)next_seq=next_seq+1;
                $fdisplay(trace_fd,"response,%0d,%h,%h,%h,%0d",scenario,pre_seq,pre_pc,rsp_data,pre_drop);
            end else if(redirect&&pending)stale=1;
            if(redirect)redirects=redirects+1;
            if(req_valid&&req_ready)begin
                if(pending)$fatal(1,"CACHE frontend CPU owner overwritten");
                pending=1;pending_pc=req_addr;stale=0;total_requests=total_requests+1;
            end
            #1;
            if(pre_rsp&&!pre_drop)begin
                if(!valid||pc!==pre_pc||seq!==pre_seq||fetch_error!==pre_error||instruction!==(pre_error?32'h13:pre_instruction)||next_pc!==pre_pc+4||fetch_tval!==(pre_error?pre_pc:32'd0))
                    $fatal(1,"CACHE frontend response/packet independent ownership oracle bp=%0d case=%0d pc=%h/%h seq=%0d/%0d",BP,scenario,pc,pre_pc,seq,pre_seq);
            end
            if(valid&&!fetch_error&&instruction!==instruction_at(pc))$fatal(1,"CACHE frontend held instruction/PC oracle");
        end
    end
    task reset_front(input integer n);
        begin @(negedge clk);rst_n=0;redirect=0;id_ready=1;block_rom=0;scenario=n;
            repeat(3)@(negedge clk);rst_n=1;end
    endtask
    task expect_target(input [31:0] address);
        begin wait(valid);#1;
            if(pc!==address||fetch_error||fault||instruction!==instruction_at(address))$fatal(1,"CACHE frontend redirect target oracle bp=%0d case=%0d target=%h actual=%h",BP,scenario,address,pc);
            repeat(3)@(negedge clk);if(fault)$fatal(1,"CACHE frontend stale refill error escaped");passed=passed+1;end
    endtask
    initial begin
        trace_fd=$fopen($sformatf("build/cpu5_s14_axi_control/frontend%0d_trace.csv",BP),"w");
        $fdisplay(trace_fd,"event,scenario,seq,pc,instruction_or_data,error_or_drop");
        fault_addr=8;reset_front(1);
        wait(rsp_valid&&rsp_error);@(negedge clk);target=64;redirect=1;
        @(posedge clk);if(!rsp_ready||!req_ready||req_addr!==64)$fatal(1,"CACHE frontend same-edge redirect/error handshake");
        @(negedge clk);redirect=0;expect_target(64);
        fault_addr=8;reset_front(2);block_rom=1;
        wait(mreq_valid);@(negedge clk);target=128;redirect=1;
        @(negedge clk);redirect=0;repeat(5)@(negedge clk);block_rom=0;expect_target(128);
        if(stale_errors!=2)$fatal(1,"CACHE frontend stale errors not genuinely injected/drained");
        fault_addr=12;reset_front(3);wait(valid&&fetch_error);#1;
        if(pc!==0||fetch_tval!==0||seq!==0||fault_pc!==0)$fatal(1,"CACHE frontend current-path fault lost PC/seq");
        @(posedge clk);@(negedge clk);target=192;redirect=1;
        @(negedge clk);redirect=0;expect_target(192);
        fault_addr=32'hffffffff;reset_front(4);id_ready=0;
        @(negedge clk);id_ready=1;@(posedge clk);@(negedge clk);id_ready=0;
        wait(rsp_valid);repeat(7)@(negedge clk);
        if(valid||rsp_ready)$fatal(1,"CACHE frontend bypassed ID backpressure");
        target=256;redirect=1;@(negedge clk);redirect=0;id_ready=1;expect_target(256);
        @(negedge clk);rst_n=0;id_ready=0;repeat(3)@(negedge clk);
        if(passed!=4||stale_errors!=2||error_packets!=1||held_edges<5||total_requests!=total_responses+total_reset_drops||total_backend_requests!=total_backend_responses+total_backend_reset_drops)
            $fatal(1,"CACHE frontend terminal coverage/ledger bp=%0d cases=%0d stale=%0d errors=%0d req=%0d rsp=%0d drops=%0d held=%0d backend=%0d/%0d+%0d",BP,passed,stale_errors,error_packets,total_requests,total_responses,total_reset_drops,held_edges,total_backend_requests,total_backend_responses,total_backend_reset_drops);
        summary_fd=$fopen($sformatf("build/cpu5_s14_axi_control/frontend%0d_summary.json",BP),"w");
        $fdisplay(summary_fd,"{\"pass\":true,\"bp\":%0d,\"cases\":%0d,\"packets\":%0d,\"fault_packets\":%0d,\"stale_errors\":%0d,\"held_edges\":%0d,\"requests\":%0d,\"responses\":%0d,\"reset_drops\":%0d,\"backend_requests\":%0d,\"backend_responses\":%0d,\"backend_reset_drops\":%0d,\"checks\":%0d}",BP,passed,packets,error_packets,stale_errors,held_edges,total_requests,total_responses,total_reset_drops,total_backend_requests,total_backend_responses,total_backend_reset_drops,checks);
        $fclose(summary_fd);$fclose(trace_fd);done=1;
    end
    initial begin #100000;$fatal(1,"CACHE frontend timeout bp=%0d",BP);end
endmodule
