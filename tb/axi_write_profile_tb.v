`timescale 1ns/1ps

// Simulation instrumentation only: CPU -> optional D-cache -> bridge -> 1x2
// router -> real axi_lite_ram. The RV32I stream is assembled below, without GCC.
// Timestamp E means the numbered rising edge, not elapsed nanoseconds:
//   * launch, handshakes and RAM write enable are sampled BEFORE NBA updates;
//   * first VALID and registered retirement are sampled AFTER NBA updates (#1).
// Thus commit -> first BVALID and CPU response -> retirement can both be zero.
// Pair timestamps are max(AW,W), never the first channel accepted.
module axi_write_profile_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    wire [9:0] done;
    reg test_pass = 0;
    axi_write_profile_case #(.CASE_ID(0), .CACHE(0), .SCENARIO(0)) off_zero(clk,done[0]);
    axi_write_profile_case #(.CASE_ID(1), .CACHE(1), .SCENARIO(0)) on_zero(clk,done[1]);
    axi_write_profile_case #(.CASE_ID(2), .CACHE(0), .SCENARIO(1), .UP_W_DELAY(2), .W_WAIT(3)) off_aw_first(clk,done[2]);
    axi_write_profile_case #(.CASE_ID(3), .CACHE(1), .SCENARIO(1), .UP_W_DELAY(2), .W_WAIT(3)) on_aw_first(clk,done[3]);
    axi_write_profile_case #(.CASE_ID(4), .CACHE(0), .SCENARIO(2), .UP_AW_DELAY(2), .AW_WAIT(3)) off_w_first(clk,done[4]);
    axi_write_profile_case #(.CASE_ID(5), .CACHE(1), .SCENARIO(2), .UP_AW_DELAY(2), .AW_WAIT(3)) on_w_first(clk,done[5]);
    axi_write_profile_case #(.CASE_ID(6), .CACHE(0), .SCENARIO(3), .AW_WAIT(2), .W_WAIT(2), .B_WAIT(2)) off_equal_wait(clk,done[6]);
    axi_write_profile_case #(.CASE_ID(7), .CACHE(1), .SCENARIO(3), .AW_WAIT(2), .W_WAIT(2), .B_WAIT(2)) on_equal_wait(clk,done[7]);
    axi_write_profile_case #(.CASE_ID(8), .CACHE(0), .SCENARIO(4), .B_HOLD(4)) off_b_stall(clk,done[8]);
    axi_write_profile_case #(.CASE_ID(9), .CACHE(1), .SCENARIO(4), .B_HOLD(4)) on_b_stall(clk,done[9]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("AXI WRITE PROFILE TESTS PASS");
        #1; $stop;
    end
    initial begin
        #1000000;
        $fatal(1,"AXI write profile timeout done=%b",done);
    end
endmodule

module axi_write_profile_case #(
    parameter integer CASE_ID=0, CACHE=0, SCENARIO=0,
    parameter integer UP_AW_DELAY=0, UP_W_DELAY=0,
    parameter integer AW_WAIT=0, W_WAIT=0, B_WAIT=0, B_HOLD=0
) (input wire clk, output reg done=0);
    localparam [31:0] BASE=32'h00010000;
    localparam integer METRICS=27;
    reg rst_n=0;
    integer phase=0, epoch=0;
    integer cycle=0,transaction=0,successes=0,canceled=0,errors=0,memory_writes=0;
    reg active=0,error_complete=0;
    reg [31:0] txn_pc=0,txn_addr=0,txn_data=0;
    reg [3:0] txn_strb=0;
    integer txn_cache_hit=-1;
    integer t_launch,t_cpu_req,t_bridge_req,t_up_aw,t_up_w,t_up_pair,t_down_aw,t_down_w,t_down_pair;
    integer t_commit,t_ram_b,t_router_b,t_bridge_b,t_down_bhs,t_up_bhs;
    integer t_bridge_first,t_bridge_rsp,t_cpu_first,t_cpu_rsp,t_retire,write_waits;
    integer values[0:METRICS-1],totals[0:METRICS-1],minimums[0:METRICS-1],maximums[0:METRICS-1];
    integer tx_file,stats_file,m,lane,slot,sum_segments;
    reg [31:0] expected_mem[0:15];
    reg held_b=0,held_up_aw=0,held_up_w=0;
    reg [1:0] held_bresp=0;
    reg [31:0] held_awaddr=0,held_wdata=0;
    reg [3:0] held_wstrb=0;
    wire cq_valid,cq_ready,cq_write,cp_valid,cp_ready,cp_error;
    wire [31:0] cq_addr,cq_data,cp_data;
    wire [1:0] cq_size;
    wire [3:0] cq_strb;
    wire bq_valid,bq_ready,bq_write,bp_valid,bp_ready,bp_error;
    wire [31:0] bq_addr,bq_data,bp_data;
    wire [1:0] bq_size;
    wire [3:0] bq_strb;
    wire iq_valid,iq_ready,ip_ready;
    wire [31:0] iq_addr;
    reg ip_valid=0,ip_active=0;
    reg [31:0] ip_data=0;
    reg [31:0] rom[0:63];
    wire retire_valid,imem_fault,dmem_fault;
    wire [31:0] wb_pc;
    wire cache_lookup_hit,cold_line_valid;

    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(256),.DMEM_WORDS(16),.DMEM_BASE_ADDR(BASE),
        .SIM_CONSOLE_ECHO(0),.EXTERNAL_IMEM(1),.EXTERNAL_DMEM(1)) cpu (
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(retire_valid),
        .cycle_count(),.instret_count(),.uart_tx(),.uart_rx(1'b1),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .dmem_req_valid(cq_valid),.dmem_req_ready(cq_ready),.dmem_req_write(cq_write),
        .dmem_req_addr(cq_addr),.dmem_req_size(cq_size),.dmem_req_wdata(cq_data),.dmem_req_wstrb(cq_strb),
        .dmem_rsp_valid(cp_valid),.dmem_rsp_ready(cp_ready),.dmem_rsp_rdata(cp_data),.dmem_rsp_error(cp_error),.dmem_fault(dmem_fault),
        .imem_req_valid(iq_valid),.imem_req_ready(iq_ready),.imem_req_addr(iq_addr),
        .imem_rsp_valid(ip_valid),.imem_rsp_ready(ip_ready),.imem_rsp_rdata(ip_data),
        .imem_rsp_error(1'b0),.imem_fault(imem_fault),.imem_fault_pc(),
        .trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.irq_external(1'b0),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),
        .bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .perf_cycle_events()
    );
    assign iq_ready=rst_n && (!ip_active || (ip_valid && ip_ready));
    always @(posedge clk) begin
        if(!rst_n) begin ip_active<=0;ip_valid<=0;ip_data<=0;end
        else begin
            if(ip_valid && ip_ready) begin ip_active<=0;ip_valid<=0;end
            if(iq_valid && iq_ready) begin
                if(iq_addr[1:0] || iq_addr>=256) $fatal(1,"profile %0d ROM address %h",CASE_ID,iq_addr);
                ip_active<=1;ip_valid<=1;ip_data<=rom[iq_addr>>2];
            end
        end
    end
    generate if(CACHE) begin: with_cache
        data_cache #(.SETS(2),.LINE_WORDS(4),.MEM_WORDS(16),.BASE_ADDR(BASE)) cache (
            .clk(clk),.rst_n(rst_n),.req_valid(cq_valid),.req_ready(cq_ready),
            .req_write(cq_write),.req_addr(cq_addr),.req_size(cq_size),.req_wdata(cq_data),.req_wstrb(cq_strb),
            .rsp_valid(cp_valid),.rsp_ready(cp_ready),.rsp_rdata(cp_data),.rsp_error(cp_error),
            .mem_req_valid(bq_valid),.mem_req_ready(bq_ready),.mem_req_write(bq_write),
            .mem_req_addr(bq_addr),.mem_req_size(bq_size),.mem_req_wdata(bq_data),.mem_req_wstrb(bq_strb),
            .mem_rsp_valid(bp_valid),.mem_rsp_ready(bp_ready),.mem_rsp_rdata(bp_data),.mem_rsp_error(bp_error),
            .access_count(),.hit_count(),.miss_count(),.refill_word_count(),.error_count(),.write_count(),.bypass_count()
        );
        assign cache_lookup_hit=cache.hit0 || cache.hit1;
        // BASE+32 maps to set 0, tag 1. The warmup loads set 0, tag 0.
        assign cold_line_valid=(cache.valid0[0] && cache.tag0[0]==1'b1) ||
                               (cache.valid1[0] && cache.tag1[0]==1'b1);
    end else begin: without_cache
        assign bq_valid=cq_valid,bq_write=cq_write,bq_addr=cq_addr,bq_size=cq_size,bq_data=cq_data,bq_strb=cq_strb;
        assign cq_ready=bq_ready,cp_valid=bp_valid,cp_data=bp_data,cp_error=bp_error,bp_ready=cp_ready;
        assign cache_lookup_hit=1'b0,cold_line_valid=1'b0;
    end endgenerate

    wire [31:0] ua,ud,uar,urd;
    wire [2:0] uap,urp;
    wire [3:0] us;
    wire uav,uaw,uwv,uww,ubv,ubr,uarv,uarr,urv,urr;
    wire [1:0] ubresp,urresp;
    wire raw_uaw,raw_uww,raw_ubv;
    wire [1:0] raw_ubresp;
    integer aw_gate=0,w_gate=0,b_hold_count=0;
    wire aw_allow=aw_gate==0;
    wire w_allow=w_gate==0;
    // This test-only channel gate masks BOTH sides of a handshake. It never
    // withdraws a visible VALID and never allows the router to consume a B
    // response hidden from the bridge. Phase 1 holds B until a shared reset.
    wire b_allow=(phase!=1) && b_hold_count>=B_HOLD;
    assign uaw=raw_uaw && aw_allow;
    assign uww=raw_uww && w_allow;
    assign ubv=raw_ubv && b_allow;
    assign ubresp=raw_ubresp;
    always @(posedge clk) begin
        if(!rst_n) begin aw_gate<=0;w_gate<=0;b_hold_count<=0;end
        else begin
            if(aw_gate>0) aw_gate<=aw_gate-1;
            if(w_gate>0) w_gate<=w_gate-1;
            if(raw_ubv && !b_allow) b_hold_count<=b_hold_count+1;
            if(bq_valid && bq_ready && bq_write) begin
                aw_gate<=UP_AW_DELAY;w_gate<=UP_W_DELAY;b_hold_count<=0;
            end
        end
    end
    dmem_axi_lite_bridge bridge (
        .clk(clk),.rst_n(rst_n),.req_valid(bq_valid),.req_ready(bq_ready),.req_write(bq_write),
        .req_addr(bq_addr),.req_size(bq_size),.req_wdata(bq_data),.req_wstrb(bq_strb),
        .rsp_valid(bp_valid),.rsp_ready(bp_ready),.rsp_rdata(bp_data),.rsp_error(bp_error),
        .m_axi_awaddr(ua),.m_axi_awprot(uap),.m_axi_awvalid(uav),.m_axi_awready(uaw),
        .m_axi_wdata(ud),.m_axi_wstrb(us),.m_axi_wvalid(uwv),.m_axi_wready(uww),
        .m_axi_bresp(ubresp),.m_axi_bvalid(ubv),.m_axi_bready(ubr),
        .m_axi_araddr(uar),.m_axi_arprot(urp),.m_axi_arvalid(uarv),.m_axi_arready(uarr),
        .m_axi_rdata(urd),.m_axi_rresp(urresp),.m_axi_rvalid(urv),.m_axi_rready(urr)
    );
    wire [31:0] da,dd,dar,drd;
    wire [2:0] dap,drp;
    wire [3:0] ds;
    wire dav,daw,dwv,dww,dbv,dbr,darv,darr,drv,drr;
    wire [1:0] dbresp,drresp;
    axi_lite_1x2 #(.M0_BASE_ADDR(BASE),.M0_SIZE_BYTES(64)) router (
        .clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(ua),.s_axi_awprot(uap),.s_axi_awvalid(uav && aw_allow),.s_axi_awready(raw_uaw),
        .s_axi_wdata(ud),.s_axi_wstrb(us),.s_axi_wvalid(uwv && w_allow),.s_axi_wready(raw_uww),
        .s_axi_bresp(raw_ubresp),.s_axi_bvalid(raw_ubv),.s_axi_bready(ubr && b_allow),
        .s_axi_araddr(uar),.s_axi_arprot(urp),.s_axi_arvalid(uarv),.s_axi_arready(uarr),
        .s_axi_rdata(urd),.s_axi_rresp(urresp),.s_axi_rvalid(urv),.s_axi_rready(urr),
        .m0_axi_awaddr(da),.m0_axi_awprot(dap),.m0_axi_awvalid(dav),.m0_axi_awready(daw),
        .m0_axi_wdata(dd),.m0_axi_wstrb(ds),.m0_axi_wvalid(dwv),.m0_axi_wready(dww),
        .m0_axi_bresp(dbresp),.m0_axi_bvalid(dbv),.m0_axi_bready(dbr),
        .m0_axi_araddr(dar),.m0_axi_arprot(drp),.m0_axi_arvalid(darv),.m0_axi_arready(darr),
        .m0_axi_rdata(drd),.m0_axi_rresp(drresp),.m0_axi_rvalid(drv),.m0_axi_rready(drr),
        .m1_axi_awaddr(),.m1_axi_awprot(),.m1_axi_awvalid(),.m1_axi_awready(1'b0),
        .m1_axi_wdata(),.m1_axi_wstrb(),.m1_axi_wvalid(),.m1_axi_wready(1'b0),
        .m1_axi_bresp(2'b00),.m1_axi_bvalid(1'b0),.m1_axi_bready(),
        .m1_axi_araddr(),.m1_axi_arprot(),.m1_axi_arvalid(),.m1_axi_arready(1'b0),
        .m1_axi_rdata(32'd0),.m1_axi_rresp(2'b00),.m1_axi_rvalid(1'b0),.m1_axi_rready()
    );
    axi_lite_ram #(.WORDS(16),.BASE_ADDR(BASE),.INIT_FILE(""),
        .AW_WAIT_CYCLES(AW_WAIT),.W_WAIT_CYCLES(W_WAIT),.B_WAIT_CYCLES(B_WAIT)) ram (
        .clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(da),.s_axi_awprot(dap),.s_axi_awvalid(dav),.s_axi_awready(daw),
        .s_axi_wdata(dd),.s_axi_wstrb(ds),.s_axi_wvalid(dwv),.s_axi_wready(dww),
        .s_axi_bresp(dbresp),.s_axi_bvalid(dbv),.s_axi_bready(dbr),
        .s_axi_araddr(dar),.s_axi_arprot(drp),.s_axi_arvalid(darv),.s_axi_arready(darr),
        .s_axi_rdata(drd),.s_axi_rresp(drresp),.s_axi_rvalid(drv),.s_axi_rready(drr)
    );

    function [31:0] addi;
        input integer imm;input [4:0] rs1,rd;
        begin addi={imm[11:0],rs1,3'b000,rd,7'h13};end
    endfunction
    function [31:0] store;
        input integer imm;input [2:0] funct3;
        begin store={imm[11:5],5'd2,5'd1,funct3,imm[4:0],7'h23};end
    endfunction
    integer i;
    initial begin
        for(i=0;i<64;i=i+1) rom[i]=32'h00000013;
        rom[0]={20'h00010,5'd1,7'h37}; // LUI x1,0x10
        rom[1]=addi(17,0,2);
        rom[2]={12'd0,5'd1,3'b010,5'd3,7'h03}; // cache-line warmup LOAD
        rom[3]=store(0,3'b010);
        rom[4]=addi(170,0,2);rom[5]=store(1,3'b000);
        rom[6]=addi(85,0,2);rom[7]=store(2,3'b001);
        rom[8]=store(4,3'b010);rom[9]=store(4,3'b010);rom[10]=store(7,3'b000);
        rom[11]=store(32,3'b010); // cold line: write miss must not allocate
        rom[12]=store(256,3'b010); // unmapped route: DECERR, no RAM commit/retirement
        rom[13]=32'h0000006f;
        repeat(3) @(negedge clk);epoch=1;rst_n=1;
        // Cancel before the bridge has emitted any AXI handshake.
        wait(t_bridge_req>=0);@(negedge clk);rst_n=0;
        repeat(3) @(negedge clk);phase=1;epoch=2;rst_n=1;
        // Cancel AFTER a physical RAM write. That side effect must survive.
        wait(t_commit>=0);@(negedge clk);rst_n=0;
        repeat(3) @(negedge clk);phase=2;epoch=3;rst_n=1;
        wait(errors==1);
        repeat(5) @(negedge clk);
        check_memory();
        if(expected_mem[0]!==32'h0055aa11 || expected_mem[1]!==32'h55000055 || expected_mem[8]!==32'h00000055)
            $fatal(1,"profile %0d architectural byte/halfword STORE result mismatch",CASE_ID);
        if(successes!=7 || canceled!=2 || memory_writes!=8 || active || !dmem_fault)
            $fatal(1,"profile %0d terminal counts success=%0d cancel=%0d error=%0d effects=%0d active=%b fault=%b",
                CASE_ID,successes,canceled,errors,memory_writes,active,dmem_fault);
        write_summary();
        $fclose(tx_file);$fclose(stats_file);
        $display("AXI write profile case %0d PASS cache=%0d scenario=%0d successful=%0d canceled=%0d errors=%0d RAM_writes=%0d mean_total=%0.3f",
            CASE_ID,CACHE,SCENARIO,successes,canceled,errors,memory_writes,$itor(totals[12])/successes);
        done=1;
    end

    initial begin
        clear_times();
        for(m=0;m<METRICS;m=m+1) begin totals[m]=0;minimums[m]=32'h7fffffff;maximums[m]=0;end
        for(m=0;m<16;m=m+1) expected_mem[m]=0;
        tx_file=$fopen($sformatf("build/axi_write_profile_%0d_transactions.csv",CASE_ID),"w");
        stats_file=$fopen($sformatf("build/axi_write_profile_%0d_summary.csv",CASE_ID),"w");
        if(!tx_file || !stats_file) $fatal(1,"Cannot open profile CSV files; create build/ first");
        $fwrite(tx_file,"case_id,cache,scenario,epoch,transaction,status,pc,addr,wdata,wstrb,cache_hit,launch,cpu_req,bridge_req,up_aw,up_w,up_pair,down_aw,down_w,down_pair,ram_commit,ram_b_first,router_b_first,bridge_b_first,down_b_handshake,up_b_handshake,bridge_rsp_first,bridge_rsp,cpu_rsp_first,cpu_rsp,retire,ram_effects,data_write_wait\n");
        $fwrite(stats_file,"case_id,cache,scenario,metric,classification,count,min_cycles,max_cycles,mean_cycles,total_cycles\n");
    end
    task clear_times;
        begin
            t_launch=-1;t_cpu_req=-1;t_bridge_req=-1;t_up_aw=-1;t_up_w=-1;t_up_pair=-1;
            t_down_aw=-1;t_down_w=-1;t_down_pair=-1;t_commit=-1;t_ram_b=-1;t_router_b=-1;t_bridge_b=-1;
            t_down_bhs=-1;t_up_bhs=-1;t_bridge_first=-1;t_bridge_rsp=-1;t_cpu_first=-1;t_cpu_rsp=-1;t_retire=-1;write_waits=0;
        end
    endtask
    task stamp;
        inout integer timestamp;
        begin
            if(!active || timestamp>=0) $fatal(1,"profile %0d unsolicited/duplicate event cycle=%0d pc=%h",CASE_ID,cycle,txn_pc);
            timestamp=cycle;
        end
    endtask
    task write_transaction;
        input [127:0] status;
        begin
            $fwrite(tx_file,"%0d,%0d,%0d,%0d,%0d,%0s,%08h,%08h,%08h,%01h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                CASE_ID,CACHE,SCENARIO,epoch,transaction,status,txn_pc,txn_addr,txn_data,txn_strb,txn_cache_hit,
                t_launch,t_cpu_req,t_bridge_req,t_up_aw,t_up_w,t_up_pair,t_down_aw,t_down_w,t_down_pair,
                t_commit,t_ram_b,t_router_b,t_bridge_b,t_down_bhs,t_up_bhs,t_bridge_first,t_bridge_rsp,
                t_cpu_first,t_cpu_rsp,t_retire,(t_commit>=0 ? 1:0),write_waits);
        end
    endtask
    function [319:0] metric_name;
        input integer index;
        begin
            case(index)
                0:metric_name="launch_to_cpu_accept";
                1:metric_name="cpu_accept_to_bridge_accept";
                2:metric_name="bridge_accept_to_up_pair";
                3:metric_name="up_pair_to_down_pair";
                4:metric_name="down_pair_to_ram_commit";
                5:metric_name="ram_commit_to_ram_b_first";
                6:metric_name="ram_b_first_to_router_b_first";
                7:metric_name="router_b_first_to_bridge_b_first";
                8:metric_name="bridge_b_first_to_b_handshake";
                9:metric_name="b_handshake_to_bridge_rsp";
                10:metric_name="bridge_rsp_to_cpu_rsp";
                11:metric_name="cpu_rsp_to_retire";
                12:metric_name="launch_to_retire";
                13:metric_name="bridge_accept_to_up_aw";
                14:metric_name="bridge_accept_to_up_w";
                15:metric_name="up_aw_w_skew";
                16:metric_name="up_pair_to_down_aw";
                17:metric_name="up_pair_to_down_w";
                18:metric_name="down_aw_w_skew";
                19:metric_name="down_pair_to_ram_b_first";
                20:metric_name="ram_b_first_to_b_handshake";
                21:metric_name="launch_to_cpu_rsp";
                22:metric_name="bridge_rsp_first_to_handshake";
                23:metric_name="cpu_rsp_first_to_handshake";
                24:metric_name="data_write_wait";
                25:metric_name="up_pair_to_b_handshake";
                26:metric_name="bridge_accept_to_bridge_rsp";
                default:metric_name="INVALID";
            endcase
        end
    endfunction
    task accumulate_success;
        begin
            values[0]=t_cpu_req-t_launch;values[1]=t_bridge_req-t_cpu_req;
            values[2]=t_up_pair-t_bridge_req;values[3]=t_down_pair-t_up_pair;
            values[4]=t_commit-t_down_pair;values[5]=t_ram_b-t_commit;
            values[6]=t_router_b-t_ram_b;values[7]=t_bridge_b-t_router_b;
            values[8]=t_up_bhs-t_bridge_b;values[9]=t_bridge_rsp-t_up_bhs;
            values[10]=t_cpu_rsp-t_bridge_rsp;values[11]=t_retire-t_cpu_rsp;
            values[12]=t_retire-t_launch;
            values[13]=t_up_aw-t_bridge_req;values[14]=t_up_w-t_bridge_req;
            values[15]=(t_up_aw>t_up_w ? t_up_aw-t_up_w:t_up_w-t_up_aw);
            values[16]=t_down_aw-t_up_pair;values[17]=t_down_w-t_up_pair;
            values[18]=(t_down_aw>t_down_w ? t_down_aw-t_down_w:t_down_w-t_down_aw);
            values[19]=t_ram_b-t_down_pair;values[20]=t_up_bhs-t_ram_b;
            values[21]=t_cpu_rsp-t_launch;values[22]=t_bridge_rsp-t_bridge_first;
            values[23]=t_cpu_rsp-t_cpu_first;values[24]=write_waits;
            values[25]=t_up_bhs-t_up_pair;values[26]=t_bridge_rsp-t_bridge_req;
            sum_segments=0;
            for(m=0;m<12;m=m+1) sum_segments=sum_segments+values[m];
            if(sum_segments!=values[12] || write_waits!=values[21] || t_down_bhs!=t_up_bhs ||
                t_ram_b-t_down_pair!=(B_WAIT==0 ? 1:B_WAIT+2))
                $fatal(1,"profile %0d additive/latency/handshake contract failed",CASE_ID);
            if(SCENARIO==1 && !(t_up_aw<t_up_w && t_down_aw<t_down_w)) $fatal(1,"AW-first coverage failed");
            if(SCENARIO==2 && !(t_up_w<t_up_aw && t_down_w<t_down_aw)) $fatal(1,"W-first coverage failed");
            if((SCENARIO==0 || SCENARIO==3 || SCENARIO==4) && (t_up_aw!=t_up_w || t_down_aw!=t_down_w)) $fatal(1,"same-edge AW/W coverage failed");
            if(t_bridge_b-t_router_b!=B_HOLD) $fatal(1,"B gate did not supply requested backpressure");
            for(m=0;m<METRICS;m=m+1) begin
                if(values[m]<0) $fatal(1,"profile %0d missing/out-of-order metric %0s",CASE_ID,metric_name(m));
                totals[m]=totals[m]+values[m];
                if(values[m]<minimums[m]) minimums[m]=values[m];
                if(values[m]>maximums[m]) maximums[m]=values[m];
            end
            successes=successes+1;
        end
    endtask
    task write_summary;
        begin
            for(m=0;m<METRICS;m=m+1)
                $fwrite(stats_file,"%0d,%0d,%0d,%0s,%0s,%0d,%0d,%0d,%0.3f,%0d\n",CASE_ID,CACHE,SCENARIO,
                    metric_name(m),(m<12 ? "additive":"diagnostic"),successes,minimums[m],maximums[m],$itor(totals[m])/successes,totals[m]);
        end
    endtask
    task check_memory;
        integer word_index;
        begin
            for(word_index=0;word_index<16;word_index=word_index+1)
                if(ram.u_data_mem.mem[word_index]!==expected_mem[word_index])
                    $fatal(1,"profile %0d RAM[%0d]=%h expected=%h",CASE_ID,word_index,ram.u_data_mem.mem[word_index],expected_mem[word_index]);
        end
    endtask

    // The monitor has a single owner for all timestamps. Completion is delayed
    // until after NBA so a same-edge first VALID/retirement is never lost.
    always @(posedge clk) begin
        cycle=cycle+1;
        error_complete=0;
        if(!rst_n) begin
            if(active) begin
                write_transaction("canceled");canceled=canceled+1;active=0;
            end
            clear_times();held_b=0;held_up_aw=0;held_up_w=0;
        end else if(!done) begin
            if(imem_fault) $fatal(1,"profile %0d unexpected instruction fault",CASE_ID);
            if(cpu.mem_start_x && cpu.is_store_x) begin
                if(active) $fatal(1,"profile %0d overlapping CPU stores",CASE_ID);
                clear_times();active=1;transaction=transaction+1;
                txn_pc=cpu.pc_x;txn_addr=cq_addr;txn_data=cq_data;txn_strb=cq_strb;
                txn_cache_hit=-1;
                stamp(t_launch);
            end
            if(active && cpu.stall_x && (cpu.mem_active || cpu.mem_start_x) && cpu.mem_req_write)
                write_waits=write_waits+1;
            if(cq_valid && cq_ready && cq_write) begin
                stamp(t_cpu_req);
                if(CACHE && txn_addr>=BASE && txn_addr<BASE+64) txn_cache_hit=cache_lookup_hit;
                if(CACHE && txn_addr==BASE+32 && (cache_lookup_hit || cold_line_valid))
                    $fatal(1,"profile %0d cold STORE did not exercise a cache miss",CASE_ID);
            end
            if(bq_valid && bq_ready && bq_write) stamp(t_bridge_req);
            if(uav && uaw) stamp(t_up_aw);
            if(uwv && uww) stamp(t_up_w);
            if(t_up_pair<0 && t_up_aw>=0 && t_up_w>=0) t_up_pair=(t_up_aw>t_up_w ? t_up_aw:t_up_w);
            if(dav && daw) stamp(t_down_aw);
            if(dwv && dww) stamp(t_down_w);
            if(t_down_pair<0 && t_down_aw>=0 && t_down_w>=0) t_down_pair=(t_down_aw>t_down_w ? t_down_aw:t_down_w);
            // This is the actual synchronous data_mem write enable, not a
            // guessed AXI write-pair or a response-related proxy for a write.
            if(ram.u_data_mem.we && ram.u_data_mem.access_ok) begin
                stamp(t_commit);memory_writes=memory_writes+1;
                if(t_down_pair<0 || ram.awaddr_q!={txn_addr[31:2],2'b00} || ram.wdata_q!==txn_data || ram.wstrb_q!==txn_strb)
                    $fatal(1,"profile %0d wrong/unsolicited RAM side effect",CASE_ID);
                slot=(txn_addr-BASE)>>2;
                if(slot<0 || slot>=16) $fatal(1,"profile RAM out-of-range side effect");
                for(lane=0;lane<4;lane=lane+1)
                    if(txn_strb[lane]) expected_mem[slot][lane*8+:8]=txn_data[lane*8+:8];
            end
            if(dbv && dbr) stamp(t_down_bhs);
            if(ubv && ubr) stamp(t_up_bhs);
            if(active && bp_valid && bp_ready) stamp(t_bridge_rsp);
            if(active && cp_valid && cp_ready) begin
                stamp(t_cpu_rsp);error_complete=cp_error;
            end
            if(held_b && (!dbv || dbresp!==held_bresp)) $fatal(1,"profile B payload changed under backpressure");
            held_b=dbv && !dbr;if(held_b) held_bresp=dbresp;
            if(held_up_aw && (!uav || ua!==held_awaddr)) $fatal(1,"profile AW changed under backpressure");
            held_up_aw=uav && !uaw;if(held_up_aw) held_awaddr=ua;
            if(held_up_w && (!uwv || ud!==held_wdata || us!==held_wstrb)) $fatal(1,"profile W changed under backpressure");
            held_up_w=uwv && !uww;if(held_up_w) begin held_wdata=ud;held_wstrb=us;end
            #1;
            check_memory();
            if(active) begin
                if(dbv && t_ram_b<0) stamp(t_ram_b);
                if(raw_ubv && t_router_b<0) stamp(t_router_b);
                if(ubv && t_bridge_b<0) stamp(t_bridge_b);
                if(bp_valid && t_bridge_first<0) stamp(t_bridge_first);
                if(cp_valid && t_cpu_first<0) stamp(t_cpu_first);
                if(retire_valid && wb_pc==txn_pc) begin
                    if(t_cpu_rsp<0 || error_complete || t_commit<0 || cp_error)
                        $fatal(1,"profile %0d STORE retired before successful completion",CASE_ID);
                    stamp(t_retire);accumulate_success();write_transaction("success");active=0;
                    if(CACHE && txn_addr==BASE+32 && cold_line_valid)
                        $fatal(1,"profile %0d write miss incorrectly allocated a cache line",CASE_ID);
                end else if(error_complete) begin
                    if(t_commit>=0 || t_down_pair>=0 || t_up_bhs<0 || !dmem_fault)
                        $fatal(1,"profile %0d unmapped STORE error side-effect/fault mismatch",CASE_ID);
                    write_transaction("error");errors=errors+1;active=0;
                end
            end else if(retire_valid && wb_pc<256 && rom[wb_pc>>2][6:0]==7'h23)
                $fatal(1,"profile %0d duplicate/untracked STORE retirement",CASE_ID);
        end
    end
endmodule
