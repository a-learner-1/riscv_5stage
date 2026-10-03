`timescale 1ns/1ps
module instr_cache_tb;
    wire [1:0] done;
    reg test_pass=0;
    instr_cache_case fast(done[0]);
    instr_cache_case #(.WAIT_CYCLES(3)) delayed(done[1]);
    initial begin wait(&done);test_pass=1;$display("INSTR CACHE UNIT TESTS PASS");$stop;end
    initial begin #1000000;$fatal(1,"Instruction cache unit timeout");end
endmodule

module instr_cache_case #(parameter integer WAIT_CYCLES=0)(output reg done=0);
    reg clk=0,rst_n=0,req_valid=0,rsp_ready=0,force_block=0;
    reg [31:0] req_addr=0,fault_addr=32'hffffffff;
    wire req_ready,rsp_valid,rsp_error,mreq_valid,mreq_ready,mrsp_ready;
    wire [31:0] rsp_rdata,mreq_addr,accesses,hits,misses,words,errors;
    reg mrsp_valid=0,mrsp_error=0,pending=0;
    reg [31:0] mrsp_data=0,saved_addr=0;
    integer delay=0,cycle=0,reads=0,checks=0,i,j;
    reg held_req=0,held_rsp=0;
    reg [31:0] held_addr=0,held_data=0;
    reg held_error=0;
    reg ref_valid[0:3][0:1];
    integer ref_tag[0:3][0:1],ref_lru[0:3];
    integer ref_access=0,ref_hit=0,ref_miss=0,ref_words=0,ref_error=0;
    reg [31:0] random_state=32'h45678abc;
    instr_cache #(.SETS(4),.LINE_WORDS(4),.MEM_WORDS(2048)) dut (
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),
        .mem_req_valid(mreq_valid),.mem_req_ready(mreq_ready),.mem_req_addr(mreq_addr),
        .mem_rsp_valid(mrsp_valid),.mem_rsp_ready(mrsp_ready),.mem_rsp_rdata(mrsp_data),.mem_rsp_error(mrsp_error),
        .access_count(accesses),.hit_count(hits),.miss_count(misses),.refill_word_count(words),.error_count(errors)
    );
    always #5 clk=~clk;
    function [31:0] memory_value(input [31:0] addr);
        memory_value=(addr*32'h01010101)^32'hbada5678;
    endfunction
    assign mreq_ready=rst_n && !force_block && !pending && !mrsp_valid &&
                      (WAIT_CYCLES==0 || cycle%(WAIT_CYCLES+1)==0);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pending<=0;mrsp_valid<=0;delay<=0;reads<=0;cycle<=0;end
        else begin
            cycle<=cycle+1;
            if(mrsp_valid && mrsp_ready) mrsp_valid<=0;
            if(mreq_valid && mreq_ready) begin
                pending<=1;saved_addr<=mreq_addr;delay<=WAIT_CYCLES;reads<=reads+1;
            end
            if(pending) begin
                if(delay>0) delay<=delay-1;
                else begin
                    pending<=0;mrsp_valid<=1;mrsp_data<=memory_value(saved_addr);
                    mrsp_error<=saved_addr==fault_addr;
                end
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin held_req=0;held_rsp=0;end
        else begin
            if(held_req && (!mreq_valid || mreq_addr!==held_addr)) $fatal(1,"Cache backend request changed under stall");
            if(held_rsp && (!rsp_valid || rsp_rdata!==held_data || rsp_error!==held_error))
                $fatal(1,"Cache CPU response changed under stall");
            held_req=mreq_valid&&!mreq_ready;held_addr=mreq_addr;
            held_rsp=rsp_valid&&!rsp_ready;held_data=rsp_rdata;held_error=rsp_error;
        end
    end
    task reset_cache;
        begin
            @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;force_block=0;fault_addr=32'hffffffff;
            ref_access=0;ref_hit=0;ref_miss=0;ref_words=0;ref_error=0;
            for(i=0;i<4;i=i+1) begin ref_lru[i]=0;ref_valid[i][0]=0;ref_valid[i][1]=0;end
            repeat(3) @(negedge clk);
            if(req_ready||rsp_valid||mreq_valid||mrsp_ready||accesses||hits||misses||words||errors)
                $fatal(1,"Cache shared reset did not clear interfaces/counters");
            rst_n=1;
        end
    endtask
    task fetch(input [31:0] addr,input integer hold_cycles);
        integer set_index,tag,way,expected_reads,prior_reads,k;
        reg expected_error;
        begin
            // Independent two-way model: invalid-first allocation, then LRU.
            set_index=(addr/16)%4;tag=addr/64;way=-1;expected_reads=0;expected_error=0;
            ref_access=ref_access+1;
            if(addr%4!=0 || addr>=8192) begin expected_error=1;ref_error=ref_error+1;end
            else begin
                for(k=0;k<2;k=k+1) if(ref_valid[set_index][k] && ref_tag[set_index][k]==tag) way=k;
                if(way>=0) begin ref_hit=ref_hit+1;ref_lru[set_index]=1-way;end
                else begin
                    ref_miss=ref_miss+1;
                    way=!ref_valid[set_index][0]?0:!ref_valid[set_index][1]?1:ref_lru[set_index];
                    ref_valid[set_index][way]=0;
                    expected_reads=4;
                    if(fault_addr>=((addr/16)*16) && fault_addr<((addr/16)*16+16)) begin
                        expected_reads=(fault_addr%16)/4+1;expected_error=1;
                        ref_words=ref_words+expected_reads-1;ref_error=ref_error+1;
                    end else begin
                        ref_words=ref_words+4;ref_valid[set_index][way]=1;
                        ref_tag[set_index][way]=tag;ref_lru[set_index]=1-way;
                    end
                end
            end
            prior_reads=reads;
            @(negedge clk);req_valid=1;req_addr=addr;rsp_ready=0;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;
            wait(rsp_valid);#1;
            if(rsp_error!==expected_error || rsp_rdata!==(expected_error?32'd0:memory_value(addr)))
                $fatal(1,"Cache data/error %m addr=%h got=%h error=%b",addr,rsp_rdata,rsp_error);
            // Counter events are pipelined one clock, independent of hit reply.
            repeat(hold_cycles+2) @(negedge clk);
            if(reads-prior_reads!=expected_reads) $fatal(1,"Cache refill/LRU %m addr=%h reads=%0d expected=%0d",addr,reads-prior_reads,expected_reads);
            if(accesses!==ref_access || hits!==ref_hit || misses!==ref_miss || words!==ref_words || errors!==ref_error)
                $fatal(1,"Cache counters %m got=%0d/%0d/%0d/%0d/%0d expected=%0d/%0d/%0d/%0d/%0d",
                       accesses,hits,misses,words,errors,ref_access,ref_hit,ref_miss,ref_words,ref_error);
            @(negedge clk);rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;
            checks=checks+1;
        end
    endtask
    initial begin
        reset_cache;
        // All word offsets, two resident tags, LRU hit update and eviction.
        fetch(0,3);fetch(4,0);fetch(8,0);fetch(12,0);
        fetch(64,0);fetch(0,0);fetch(128,0);fetch(0,0);fetch(64,0);
        fetch(16,0);fetch(28,0);fetch(8192,3);fetch(3,2);fetch(8188,0);
        // Fill failure after two successful words: do not expose a partial line.
        fault_addr=32'd200;fetch(192,4);fetch(64,0);
        fault_addr=32'hffffffff;fetch(192,0);fetch(196,0);
        for(j=0;j<4;j=j+1) begin
            fault_addr=1024+j*64+j*4;fetch(1024+j*64,2);
            fault_addr=32'hffffffff;fetch(1024+j*64+12,0);
        end
        // Long request-side stall while the backend address must remain stable.
        force_block=1;
        fork
            begin fetch(512,4);end
            begin repeat(20) @(negedge clk);force_block=0;end
        join
        for(j=0;j<160;j=j+1) begin
            random_state=(random_state<<1)^((random_state[31])?32'h04c11db7:0);
            fetch((random_state%256)*4,j%4);
        end
        // Shared reset cancels refill request, accepted backend work and reply.
        force_block=1;@(negedge clk);req_addr=4096;req_valid=1;
        @(posedge clk);@(negedge clk);req_valid=0;wait(mreq_valid);reset_cache;fetch(4096,0);
        @(negedge clk);req_addr=6144;req_valid=1;
        @(posedge clk);@(negedge clk);req_valid=0;wait(pending);reset_cache;fetch(6144,0);
        @(negedge clk);req_addr=16;req_valid=1;
        @(posedge clk);@(negedge clk);req_valid=0;wait(rsp_valid);reset_cache;fetch(16,0);
        // Once warm, response consumption and the next request overlap.
        fetch(20,0);fetch(24,0);fetch(28,0);
        @(negedge clk);rsp_ready=1;req_valid=1;req_addr=16;
        for(j=0;j<32;j=j+1) begin
            @(posedge clk);
            if(!req_ready || (j>0 && (!rsp_valid || rsp_error || rsp_rdata!==memory_value(16+((j-1)%4)*4))))
                $fatal(1,"Cache did not sustain one warm hit per clock");
            @(negedge clk);req_addr=16+((j+1)%4)*4;
        end
        req_valid=0;@(posedge clk);
        if(!rsp_valid || rsp_rdata!==memory_value(28)) $fatal(1,"Cache warm stream final response");
        #1;
        if(reads!=4 || hits!=35 || accesses!=36) $fatal(1,"Cache warm stream final counters");
        @(negedge clk);rsp_ready=0;
        $display("CACHE case %m PASS: %0d modeled reads, two-way LRU, faults, reset, backpressure, one hit/clock",checks);
        done=1;
    end
endmodule
