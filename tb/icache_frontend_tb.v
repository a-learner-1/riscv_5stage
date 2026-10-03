`timescale 1ns/1ps
// Check stale cache errors with the actual IF stage, including a redirect on
// the exact error-response edge and redirects while a backend request stalls.
module icache_frontend_tb;
    reg clk=0,rst_n=0,redirect=0,stall=0,block_rom=0;
    reg [31:0] target=0,fault_addr=32'hffffffff;
    wire req_valid,req_ready,rsp_valid,rsp_ready,rsp_error;
    wire [31:0] req_addr,rsp_data,pc_x,instruction,fault_pc;
    wire valid_x,fault,mreq_valid,mreq_ready,mrsp_ready;
    wire [31:0] mreq_addr;
    reg mrsp_valid=0,mrsp_error=0;
    reg [31:0] mrsp_data=0;
    reg test_pass=0;
    integer invalidated_errors=0;
    always #5 clk=~clk;
    if_stage #(.PROGRAM_FILE("programs/icache_board.hex"),.IMEM_WORDS(8192),.EXTERNAL_IMEM(1),.ENABLE_TRAPS(1)) front (
        .clk(clk),.rst_n(rst_n),.redirect_x(redirect),.redirect_pc_x(target),.stall_x(stall),
        .pc_f(),.pc_x(pc_x),.instr_x(instruction),.valid_x(valid_x),
        .imem_req_valid(req_valid),.imem_req_ready(req_ready),.imem_req_addr(req_addr),
        .imem_rsp_valid(rsp_valid),.imem_rsp_ready(rsp_ready),.imem_rsp_rdata(rsp_data),
        .imem_rsp_error(rsp_error),.imem_fault(fault),.imem_fault_pc(fault_pc));
    instr_cache #(.SETS(4),.LINE_WORDS(4),.MEM_WORDS(8192)) cache (
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_data),.rsp_error(rsp_error),
        .mem_req_valid(mreq_valid),.mem_req_ready(mreq_ready),.mem_req_addr(mreq_addr),
        .mem_rsp_valid(mrsp_valid),.mem_rsp_ready(mrsp_ready),.mem_rsp_rdata(mrsp_data),.mem_rsp_error(mrsp_error),
        .access_count(),.hit_count(),.miss_count(),.refill_word_count(),.error_count());
    // Address-encoded ADDI instructions make wrong metadata observable.
    function [31:0] instruction_at(input [31:0] addr);
        instruction_at=((addr/4)<<20)|32'h00000513;
    endfunction
    assign mreq_ready=rst_n && !block_rom && !mrsp_valid;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin mrsp_valid<=0;mrsp_error<=0;mrsp_data<=0;end
        else begin
            if(mrsp_valid && mrsp_ready) mrsp_valid<=0;
            if(mreq_valid && mreq_ready) begin
                mrsp_valid<=1;mrsp_error<=mreq_addr==fault_addr;mrsp_data<=instruction_at(mreq_addr);
            end
        end
    end
    always @(posedge clk) begin
        if(rst_n && rsp_valid && rsp_ready && rsp_error && (redirect || front.fetch_stale_q))
            invalidated_errors=invalidated_errors+1;
        #1;
        if(rst_n && valid_x && instruction!==instruction_at(pc_x)) $fatal(1,"Cached frontend instruction/PC mismatch");
    end
    task reset_front;
        begin
            @(negedge clk);rst_n=0;redirect=0;stall=0;block_rom=0;
            repeat(3) @(negedge clk);rst_n=1;
        end
    endtask
    task expect_target(input [31:0] address);
        begin
            wait(valid_x);#1;
            if(pc_x!==address || fault || instruction!==instruction_at(address))
                $fatal(1,"Cached frontend redirect target=%h actual=%h fault=%b",address,pc_x,fault);
            repeat(3) @(negedge clk);if(fault) $fatal(1,"Stale cache error became an architectural fault");
        end
    endtask
    initial begin
        // Cold PC0 line fails. Redirect and error are consumed on same edge.
        fault_addr=8;reset_front;
        wait(rsp_valid && rsp_error);@(negedge clk);target=64;redirect=1;
        @(posedge clk);if(!rsp_ready || !req_ready || req_addr!==64) $fatal(1,"Cached redirect/error coincidence handshake");
        @(negedge clk);redirect=0;expect_target(64);
        // Redirect while an accepted miss is blocked. Its error must drain.
        fault_addr=8;reset_front;block_rom=1;
        wait(mreq_valid);@(negedge clk);target=128;redirect=1;
        @(negedge clk);redirect=0;
        repeat(5) @(negedge clk);block_rom=0;expect_target(128);
        if(invalidated_errors!=2) $fatal(1,"Stale cached errors were not actually injected/drained");
        // A current-path error instead raises a precise PC0 access fault.
        fault_addr=12;reset_front;wait(fault);#1;
        if(fault_pc!==0 || valid_x) $fatal(1,"Current cache error did not retain requested PC");
        @(negedge clk);target=192;redirect=1;
        @(negedge clk);redirect=0;expect_target(192);
        // EX backpressure holds a filled response; redirect discards it.
        fault_addr=32'hffffffff;reset_front;stall=1;
        // No initial request while stalled, so release through acceptance.
        @(negedge clk);stall=0;@(posedge clk);@(negedge clk);stall=1;
        wait(rsp_valid);repeat(5) @(negedge clk);
        if(valid_x || rsp_ready) $fatal(1,"Cache bypassed frontend EX stall");
        target=256;redirect=1;
        @(negedge clk);redirect=0;stall=0;expect_target(256);
        test_pass=1;$display("ICACHE FRONTEND TESTS PASS: stale miss errors, same-edge redirect, current-path precise fault, EX stall and recovery");$stop;
    end
    initial begin #100000;$fatal(1,"Cached frontend timeout");end
endmodule
