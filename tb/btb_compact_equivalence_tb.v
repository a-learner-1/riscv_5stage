`timescale 1ns/1ps
// The full-tag parent implementation is a behavioral reference, not a model
// rewritten from the compact state encoding. Guard-only inputs are checked
// separately because the parent deliberately accepted the entire 32-bit space.
module btb_compact_equivalence_tb;
    wire [5:0] done;reg test_pass=0;
    btb_compact_equivalence_case #(.ENTRIES(1)) one(done[0]);
    btb_compact_equivalence_case #(.ENTRIES(64)) sixtyfour(done[1]);
    btb_compact_equivalence_case #(.ENTRIES(1024)) thousand(done[2]);
    btb_compact_equivalence_case #(.ENTRIES(64),.WORDS(1000)) nonpower_rom(done[3]);
    btb_compact_equivalence_case #(.ENTRIES(1024),.WORDS(1000)) more_slots_than_rom(done[4]);
    btb_compact_minimal_case minimal_rom(done[5]);
    initial begin wait(&done);test_pass=1;$display("BTB COMPACT EQUIVALENCE TESTS PASS: parent reference pre/post edges, entries1/64/1024 and nonpower ROM; independent high-PC/target guards");$stop;end
    initial begin #300000;$fatal(1,"BTB compact equivalence timeout done=%b",done);end
endmodule
module btb_compact_equivalence_case #(parameter integer ENTRIES=64,WORDS=8192)(output reg done=0);
    reg clk=0,rst_n=0,uv=0,ut=0,ub=0,uj=0,compare_enabled=1;
    reg [31:0] qp=0,up=0,ud=0,random_q=32'hc105f00d;
    always #5 clk=~clk;
    wire h,t,rh,rt;wire [31:0] d,rd;
    integer comparisons=0,guard_checks=0,k;
    localparam [31:0] OTHER_PC=(ENTRIES<WORDS)?ENTRIES*4:4;
    branch_predictor #(.BTB_ENTRIES(ENTRIES),.IMEM_WORDS(WORDS)) dut(
        .clk(clk),.rst_n(rst_n),.query_pc(qp),.lookup_hit(h),.lookup_taken(t),.lookup_target(d),
        .update_valid(uv),.update_pc(up),.update_target(ud),.update_taken(ut),.update_is_branch(ub),.update_is_jal(uj));
    branch_predictor_reference_f115192 #(.BTB_ENTRIES(ENTRIES)) parent(
        .clk(clk),.rst_n(rst_n),.query_pc(qp),.lookup_hit(rh),.lookup_taken(rt),.lookup_target(rd),
        .update_valid(uv),.update_pc(up),.update_target(ud),.update_taken(ut),.update_is_branch(ub),.update_is_jal(uj));
    task compare_now;
        begin if(compare_enabled) begin
            comparisons=comparisons+1;
            if({h,t,d}!=={rh,rt,rd}) $fatal(1,"Compact/reference differ entries=%0d words=%0d q=%h update=%b/%h/%h got=%b/%b/%h expected=%b/%b/%h",ENTRIES,WORDS,qp,uv,up,ud,h,t,d,rh,rt,rd);
        end end
    endtask
    task step(input [31:0] query,input bit valid,input [31:0] pc,input [31:0] destination,input bit taken,input bit branch,input bit jal);
        begin @(negedge clk);qp=query;uv=valid;up=pc;ud=destination;ut=taken;ub=branch;uj=jal;
            #1;compare_now;@(posedge clk);#1;compare_now;
        end
    endtask
    task expect_lookup(input [31:0] query,input bit hit,input bit taken,input [31:0] destination);
        begin @(negedge clk);uv=0;qp=query;#1;compare_now;
            if({h,t,d}!=={hit,taken,destination}) $fatal(1,"Compact boundary/direction lookup q=%h got=%b/%b/%h expected=%b/%b/%h",query,h,t,d,hit,taken,destination);
            guard_checks=guard_checks+1;
        end
    endtask
    task reset_both;
        begin @(negedge clk);rst_n=0;uv=0;repeat(2) @(negedge clk);rst_n=1;#1;compare_now;end
    endtask
    initial begin
        random_q=random_q^ENTRIES^WORDS;reset_both;
        expect_lookup(0,0,0,4);
        step(0,1,0,8,1,1,0);expect_lookup(0,1,1,8);
        repeat(6) step(0,1,0,8,1,1,0);
        step(0,1,0,8,0,1,0);expect_lookup(0,1,1,8);
        step(0,1,0,8,0,1,0);expect_lookup(0,1,0,8);
        repeat(6) step(0,1,0,8,0,1,0);
        step(0,1,0,12,1,1,0);expect_lookup(0,1,0,12);
        step(0,1,0,16,1,1,0);expect_lookup(0,1,1,16);
        step(0,1,OTHER_PC,20,0,1,0);
        if(ENTRIES<WORDS) expect_lookup(0,0,0,4);else expect_lookup(0,1,1,16);
        expect_lookup(OTHER_PC,1,0,20);
        step(OTHER_PC,1,0,0,0,0,0);expect_lookup(OTHER_PC,1,0,20);
        step(OTHER_PC,1,OTHER_PC,24,1,0,1);expect_lookup(OTHER_PC,1,1,24);
        step(OTHER_PC,1,OTHER_PC,28,0,1,0);expect_lookup(OTHER_PC,1,0,28);
        step(OTHER_PC,1,OTHER_PC,0,0,0,0);expect_lookup(OTHER_PC,0,0,OTHER_PC+4);
        step(0,1,0,0,1,0,1);expect_lookup(0,1,1,0);
        step(0,1,0,WORDS*4-4,1,0,1);expect_lookup(0,1,1,WORDS*4-4);
        // Legal randomized collisions and same-cycle query/update combinations.
        for(k=0;k<4096;k=k+1) begin
            random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            up=((random_q>>3)%((ENTRIES*2<WORDS)?ENTRIES*2:WORDS))*4;
            step(random_q[2]?up:((random_q>>15)%WORDS)*4,random_q[0]||random_q[1],up,
                 ((random_q>>7)%WORDS)*4,random_q[8],random_q[5],random_q[6]);
        end
        reset_both;expect_lookup(0,0,0,4);

        // The following cases intentionally differ from the 32-bit parent.
        compare_enabled=0;
        step(0,1,0,8,1,0,1);expect_lookup(0,1,1,8);
        expect_lookup(32'h80000000,0,0,32'h80000004);
        expect_lookup(WORDS*4,0,0,WORDS*4+4);
        expect_lookup(32'hffff8000,0,0,32'hffff8004);
        step(0,1,32'h80000000,12,1,0,1);expect_lookup(0,1,1,8);
        step(0,1,32'h80000000,0,0,0,0);expect_lookup(0,1,1,8);
        step(0,1,2,12,1,0,1);expect_lookup(0,1,1,8);
        step(0,1,0,WORDS*4,1,0,1);expect_lookup(0,0,0,4);
        step(0,1,0,8,1,0,1);step(0,1,0,32'h80000008,1,1,0);expect_lookup(0,0,0,4);
        step(0,1,0,8,1,0,1);step(0,1,0,WORDS*4+4,1,1,0);expect_lookup(0,0,0,4);
        step(0,1,0,8,1,0,1);step(0,1,0,10,1,1,0);expect_lookup(0,0,0,4);
        step(0,1,0,8,1,0,1);step(0,0,0,32'h80000008,1,0,1);expect_lookup(0,1,1,8);
        reset_both;compare_enabled=1;expect_lookup(0,0,0,4);
        if(comparisons<8200||guard_checks<25) $fatal(1,"BTB equivalence/guard coverage ledger insufficient");
        done=1;$display("BTB COMPACT CASE PASS entries=%0d words=%0d reference_checks=%0d explicit_checks=%0d",ENTRIES,WORDS,comparisons,guard_checks);
    end
endmodule

// One ROM word exercises the minimum-width slices independently of a larger
// directed suite whose legal target set deliberately contains several words.
module btb_compact_minimal_case(output reg done=0);
    reg clk=0,rst_n=0,uv=0,ut=0,ub=0,uj=0;
    reg [31:0] qp=0,up=0,ud=0;
    wire h,t,rh,rt;wire [31:0] d,rd;integer k;
    always #5 clk=~clk;
    branch_predictor #(.BTB_ENTRIES(1),.IMEM_WORDS(1)) dut(
        .clk(clk),.rst_n(rst_n),.query_pc(qp),.lookup_hit(h),.lookup_taken(t),.lookup_target(d),
        .update_valid(uv),.update_pc(up),.update_target(ud),.update_taken(ut),.update_is_branch(ub),.update_is_jal(uj));
    branch_predictor_reference_f115192 #(.BTB_ENTRIES(1)) parent(
        .clk(clk),.rst_n(rst_n),.query_pc(qp),.lookup_hit(rh),.lookup_taken(rt),.lookup_target(rd),
        .update_valid(uv),.update_pc(up),.update_target(ud),.update_taken(ut),.update_is_branch(ub),.update_is_jal(uj));
    initial begin
        repeat(2) @(negedge clk);rst_n=1;
        for(k=0;k<32;k=k+1) begin
            @(negedge clk);qp=0;up=0;ud=0;uv=1;ub=k[0]||k[1];uj=k[2];ut=k[3];
            #1;if({h,t,d}!=={rh,rt,rd}) $fatal(1,"Minimal ROM reference pre-edge mismatch");
            @(posedge clk);#1;if({h,t,d}!=={rh,rt,rd}) $fatal(1,"Minimal ROM reference post-edge mismatch");
        end
        @(negedge clk);uv=0;qp=4;#1;if(h||t||d!==8) $fatal(1,"One-word ROM accepted query at its boundary");
        @(negedge clk);qp=32'h80000000;#1;if(h||t||d!==32'h80000004) $fatal(1,"One-word ROM high query alias");
        @(negedge clk);qp=0;up=0;ud=4;uv=1;ub=0;uj=1;
        @(posedge clk);#1;if(h||t||d!==4) $fatal(1,"One-word ROM truncated an unencodable target");
        @(negedge clk);rst_n=0;uv=0;#1;if(h||t||d!==4) $fatal(1,"One-word ROM reset retained state");
        done=1;$display("BTB COMPACT MINIMAL ROM PASS: words=1 entries=1, 64 reference edges and independent guards");
    end
endmodule
