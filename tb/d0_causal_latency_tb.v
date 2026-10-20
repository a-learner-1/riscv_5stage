`timescale 1ns/1ps
// One ROM file, identical ISA instructions and data addresses, two real SoCs.
// The baseline retains the original AXI bridge + 1x2 router + RAM topology.
module d0_causal_latency_tb;
    reg clk=0;
    always #5 clk=~clk;
    wire [1:0] done;
    reg test_pass=0;
    integer index;
    d0_causal_latency_case #(.D0(0)) baseline(clk,done[0]);
    d0_causal_latency_case #(.D0(1)) candidate(clk,done[1]);
    initial begin
        wait(&done);
        for(index=0;index<5;index=index+1) begin
            if(baseline.descriptor[index]!==candidate.descriptor[index] ||
               baseline.descriptor[index]!==baseline.expected_descriptor(index))
                $fatal(1,"Causal STORE descriptor mismatch transaction=%0d",index+1);
            if(baseline.waits[index]!=6 || candidate.waits[index]!=2 ||
               baseline.response_latency[index]!=6 || candidate.response_latency[index]!=2)
                $fatal(1,"Causal STORE latency mismatch transaction=%0d AXI=%0d/%0d D0=%0d/%0d",
                    index+1,baseline.waits[index],baseline.response_latency[index],
                    candidate.waits[index],candidate.response_latency[index]);
        end
        test_pass=1;
        $display("D0 CAUSAL LATENCY PASS: same ROM, five identical STORE PCs/addresses/data/strobes/sizes/hits; AXI6 -> D02; word/byte/halfword, hit/miss, exact commit/response/retire, readbacks and D-cache counters");
        $stop;
    end
    initial begin #1000000;$fatal(1,"D0 causal latency timeout done=%b",done);end
endmodule

module d0_causal_latency_case #(parameter integer D0=0)(input wire clk,output reg done=0);
    reg rst_n=0;
    wire [31:0] pc,insn,wb_pc,wb_data;
    wire [4:0] wb_rd;
    wire valid,wb_we,retire,ifault,dfault,trap;
    wire [31:0] da,dh,dm,dref,de,dw,db;
    wire [31:0] ia,ih,im,ir,ie;
    wire [31:0] bl,bh,bt,br,bm,bd,be;
    wire [31:0] ifault_pc,trap_pc,trap_cause,trap_tval;
    wire [63:0] cycles,instret;
    wire uart_tx;
    wire [7:0] gpio_out,gpio_oe;
    soc_coremark_axi_top #(
        .PROGRAM_FILE("programs/d0_causal_common.hex"), .DATA_FILE(""),
        .IMEM_WORDS(256), .DMEM_WORDS(64), .DMEM_BASE_ADDR(32'h10000),
        .ENABLE_ICACHE(0), .ENABLE_DCACHE(1), .DCACHE_SETS(4), .DCACHE_LINE_WORDS(4),
        .ENABLE_BRANCH_PRED(0), .ENABLE_D0_BRAM(D0),
        .UART_CLOCK_HZ(100000000), .UART_BAUD(10000000), .SIM_CONSOLE_ECHO(0)
    ) soc (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .gpio_in(8'd0),
        .uart_tx(uart_tx), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .pc_x(pc), .instr_x(insn), .valid_x(valid),
        .wb_pc(wb_pc), .wb_data(wb_data), .wb_rd(wb_rd), .wb_we(wb_we), .retire_valid(retire),
        .cycle_count(cycles), .instret_count(instret),
        .imem_fault(ifault), .dmem_fault(dfault), .imem_fault_pc(ifault_pc),
        .trap_valid(trap), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_tval(trap_tval),
        .icache_access_count(ia), .icache_hit_count(ih), .icache_miss_count(im),
        .icache_refill_word_count(ir), .icache_error_count(ie),
        .dcache_access_count(da), .dcache_hit_count(dh), .dcache_miss_count(dm),
        .dcache_refill_word_count(dref), .dcache_error_count(de), .dcache_write_count(dw), .dcache_bypass_count(db),
        .bp_lookup_count(bl), .bp_hit_count(bh), .bp_taken_count(bt), .bp_resolved_count(br),
        .bp_mispredict_count(bm), .bp_direction_error_count(bd), .bp_target_error_count(be)
    );
    wire actual_ram_write;
    wire [31:0] word0,word1,word8;
    generate if(D0) begin: local_evidence
        assign actual_ram_write=soc.u_core.g_d0_bram.u_ram.mem_we;
        assign word0=soc.u_core.g_d0_bram.u_ram.u_data_mem.mem[0];
        assign word1=soc.u_core.g_d0_bram.u_ram.u_data_mem.mem[1];
        assign word8=soc.u_core.g_d0_bram.u_ram.u_data_mem.mem[8];
    end else begin: axi_evidence
        assign actual_ram_write=soc.u_ram.u_data_mem.we && soc.u_ram.u_data_mem.access_ok;
        assign word0=soc.u_ram.u_data_mem.mem[0];
        assign word1=soc.u_ram.u_data_mem.mem[1];
        assign word8=soc.u_ram.u_data_mem.mem[8];
    end endgenerate

    // Descriptor includes cache hit, PC, address, data, size and byte strobes.
    reg [102:0] descriptor[0:4];
    integer waits[0:4],response_latency[0:4];
    function [102:0] expected_descriptor(input integer n);
        begin
            case(n)
                0:expected_descriptor={1'b0,32'd8,32'h10000,32'h123,2'd2,4'hf};
                1:expected_descriptor={1'b1,32'd20,32'h10001,32'h7e00,2'd0,4'h2};
                2:expected_descriptor={1'b1,32'd32,32'h10002,32'h04560000,2'd1,4'hc};
                3:expected_descriptor={1'b0,32'd40,32'h10020,32'h456,2'd2,4'hf};
                4:expected_descriptor={1'b1,32'd48,32'h10004,32'h456,2'd2,4'hf};
                default:expected_descriptor=103'd0;
            endcase
        end
    endfunction
    integer cycle=0,fd,stores=0,ram_writes=0,axi_writes=0,axi_reads=0;
    integer launch=-1,accept=-1,backend_accept=-1,commit=-1,response=-1,wait_count=0;
    reg active=0,completed_this_edge=0;
    reg [102:0] current_descriptor;
    reg [31:0] store_pc;
    always @(posedge clk) begin
        cycle=cycle+1;completed_this_edge=0;
        if(rst_n&&!done) begin
            if(ifault||dfault||trap) $fatal(1,"Causal SoC fault D0=%0d PC=%h",D0,pc);
            if(soc.axi_awvalid&&soc.axi_awready) axi_writes=axi_writes+1;
            if(soc.axi_arvalid&&soc.axi_arready) axi_reads=axi_reads+1;
            if(D0&&(soc.axi_awvalid||soc.axi_wvalid||soc.axi_arvalid))
                $fatal(1,"Causal D0 RAM request escaped to AXI");
            if(soc.u_core.u_cpu.mem_start_x&&soc.u_core.u_cpu.mem_req_write) begin
                if(active||stores>=5) $fatal(1,"Causal STORE overlap/count");
                active=1;launch=cycle;accept=-1;backend_accept=-1;commit=-1;response=-1;wait_count=0;
                store_pc=pc;
            end
            if(active&&soc.u_core.u_cpu.stall_x&&
               (soc.u_core.u_cpu.mem_active||soc.u_core.u_cpu.mem_start_x)&&soc.u_core.u_cpu.mem_req_write)
                wait_count=wait_count+1;
            if(soc.u_core.dmem_req_valid&&soc.u_core.dmem_req_ready&&soc.u_core.dmem_req_write) begin
                if(!active||accept>=0) $fatal(1,"Causal unsolicited/duplicate CPU STORE accept");
                accept=cycle;
                current_descriptor={soc.u_core.g_dcache.u_cache.hit0||soc.u_core.g_dcache.u_cache.hit1,
                    store_pc,soc.u_core.dmem_req_addr,soc.u_core.dmem_req_wdata,
                    soc.u_core.dmem_req_size,soc.u_core.dmem_req_wstrb};
            end
            if(soc.u_core.bridge_req_valid&&soc.u_core.bridge_req_ready&&soc.u_core.bridge_req_write) begin
                if(!active||backend_accept>=0) $fatal(1,"Causal unsolicited/duplicate backend STORE");
                backend_accept=cycle;
            end
            if(actual_ram_write) begin
                if(!active||commit>=0) $fatal(1,"Causal unsolicited/duplicate physical STORE");
                commit=cycle;ram_writes=ram_writes+1;
            end
            if(soc.u_core.dmem_rsp_valid&&soc.u_core.dmem_rsp_ready&&active) begin
                if(soc.u_core.dmem_rsp_error||commit<0||response>=0)
                    $fatal(1,"Causal STORE response preceded physical commit or failed");
                response=cycle;
            end
        end
        #1;
        if(rst_n&&!done&&retire) begin
            if(active&&wb_pc==store_pc) begin
                if(response<0||commit<0||backend_accept<0||accept!=launch||wb_we||
                   !(commit<response)||cycle!=response)
                    $fatal(1,"Causal STORE commit/accept/retirement order D0=%0d",D0);
                descriptor[stores]=current_descriptor;waits[stores]=wait_count;
                response_latency[stores]=response-launch;
                $fwrite(fd,"%0d,%0d,%08h,%08h,%08h,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    D0,stores+1,current_descriptor[101:70],current_descriptor[69:38],current_descriptor[37:6],
                    current_descriptor[3:0],current_descriptor[5:4],current_descriptor[102],
                    launch,accept,backend_accept,commit,response,cycle,wait_count);
                stores=stores+1;active=0;completed_this_edge=1;
            end
            case(wb_pc)
                12:if(!wb_we||wb_rd!=3||wb_data!==32'h123) $fatal(1,"Causal word readback");
                24:if(!wb_we||wb_rd!=4||wb_data!==32'h7e23) $fatal(1,"Causal byte update readback");
                36:if(!wb_we||wb_rd!=5||wb_data!==32'h04567e23) $fatal(1,"Causal halfword update readback");
                44:if(!wb_we||wb_rd!=6||wb_data!==32'h456) $fatal(1,"Causal write-miss readback");
                52:if(!wb_we||wb_rd!=7||wb_data!==32'h456) $fatal(1,"Causal write-hit readback");
                56:begin
                    if(active||stores!=5||ram_writes!=5||!wb_we||wb_rd!=31||wb_data!==1||
                       da!==10||dh!==3||dm!==2||dref!==8||de!==0||dw!==5||db!==0||
                       word0!==32'h04567e23||word1!==32'h456||word8!==32'h456||
                       axi_writes!=(D0?0:5)||axi_reads!=(D0?0:8))
                        $fatal(1,"Causal completion/cache/physical-memory ledger D0=%0d a/h/m/ref/e/wr/b=%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                            D0,da,dh,dm,dref,de,dw,db);
                    $fclose(fd);done=1;$display("D0 CAUSAL CASE PASS D0=%0d stores=5 writes=5 readbacks=5 AXIwrites=%0d AXIreads=%0d",D0,axi_writes,axi_reads);
                end
            endcase
        end
    end
    initial begin
        fd=$fopen($sformatf("build/verification/d0_causal_store_%0d.csv",D0),"w");
        if(!fd) $fatal(1,"Create build/verification before simulation");
        $fwrite(fd,"d0,transaction,pc,addr,wdata,wstrb,size,cache_hit,launch,accept,backend_accept,ram_commit,cpu_response,retire,data_write_wait\n");
        repeat(4) @(negedge clk);rst_n=1;
    end
endmodule
