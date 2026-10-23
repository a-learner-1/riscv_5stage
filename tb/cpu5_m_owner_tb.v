`timescale 1ns/1ps
// Independent instruction/operand and generation ledger. No force/deposit and
// no calls into arithmetic RTL helpers. Every live/killed completion is checked.
module cpu5_m_owner_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,issue_valid=0,kill_valid=0,completion_ready=0;
    reg [63:0] issue_seq=0,kill_cut_seq=0;
    reg [31:0] issue_pc=0,issue_instr=0,issue_lhs=0,issue_rhs=0;
    reg [7:0] issue_epoch=0;reg [2:0] issue_op=0;
    wire issue_ready,issue_fire,completion_valid,completion_killed;
    wire [63:0] completion_seq,owner_seq,owner_generation,result_generation;
    wire [31:0] completion_pc,completion_instr,completion_result;
    wire [7:0] completion_epoch;wire [2:0] completion_op;
    wire owner_valid,owner_killed,unit_start_fire,unit_busy,unit_done,drain_fire;
    localparam [63:0] FIRST_GENERATION=64'h00000000fffffffe;
    cpu5_m_owner #(.RESET_GENERATION(FIRST_GENERATION)) dut(.*);
    reg test_pass=0,model_valid=0,model_killed=0,last_issue=0;
    reg [63:0] model_seq=0,model_generation=0,next_generation=FIRST_GENERATION;
    reg [31:0] model_pc=0,model_instr=0,model_result=0,model_lhs=0,model_rhs=0;
    reg [7:0] model_epoch=0;reg [2:0] model_op=0;
    integer cycles=0,start_cycle=0,starts=0,completed=0,drained=0,held=0;
    integer blocked=0,fast=0,cross32=0,kill_edges=0,cases=0,wait_count=0,i,j,k;
    integer trace_fd,summary_fd,saved_starts=0,saved_completed=0,saved_drained=0;
    reg [31:0] rng=32'h3719ace5,a,b;
    reg [63:0] next_seq=64'h0000000100000000;
    reg old_valid,expected_killed,pre_issue,pre_complete,pre_drain;

    function [31:0] reference(input [2:0] op,input [31:0] lhs,input [31:0] rhs);
        reg signed [63:0] sl,sr,product_s;
        reg [63:0] product_u;
        reg signed [31:0] dl,dr;
        begin
            sl={{32{lhs[31]}},lhs};sr={{32{rhs[31]}},rhs};dl=lhs;dr=rhs;
            product_u={32'd0,lhs}*{32'd0,rhs};
            case(op)
                0:reference=product_u[31:0];
                1:begin product_s=sl*sr;reference=product_s[63:32];end
                2:begin product_s=sl*$signed({32'd0,rhs});reference=product_s[63:32];end
                3:reference=product_u[63:32];
                4:begin
                    if(rhs==0)reference=32'hffffffff;
                    else if(lhs==32'h80000000&&rhs==32'hffffffff)reference=32'h80000000;
                    else reference=dl/dr;
                end
                5:reference=rhs==0?32'hffffffff:lhs/rhs;
                6:begin
                    if(rhs==0)reference=lhs;
                    else if(lhs==32'h80000000&&rhs==32'hffffffff)reference=32'd0;
                    else reference=dl%dr;
                end
                7:reference=rhs==0?lhs:lhs%rhs;
            endcase
        end
    endfunction
    function [31:0] random_next(input [31:0] v);
        reg [31:0] x;
        begin x=v^(v<<13);x=x^(x>>17);random_next=x^(x<<5);end
    endfunction
    task tick;
        begin @(posedge clk);#2;end
    endtask
    task offer(input [2:0] op,input [31:0] lhs,input [31:0] rhs,input [63:0] seq);
        begin @(negedge clk);issue_valid=1;issue_op=op;issue_lhs=lhs;issue_rhs=rhs;
            issue_seq=seq;issue_pc=32'h200+(seq[15:0]<<2);
            issue_instr={7'b0000001,5'd2,5'd1,op,5'd3,7'h33};issue_epoch=seq[7:0]^8'h5a;
        end
    endtask
    task send(input [2:0] op,input [31:0] lhs,input [31:0] rhs,input [63:0] seq);
        begin offer(op,lhs,rhs,seq);wait_count=0;tick;
            while(!last_issue)begin tick;wait_count=wait_count+1;
                if(wait_count>45)$fatal(1,"M OWNER issue timeout");end
            @(negedge clk);issue_valid=0;
        end
    endtask
    task await_completion;
        begin wait_count=0;while(!completion_valid)begin tick;wait_count=wait_count+1;
            if(wait_count>40)$fatal(1,"M OWNER completion timeout");end end
    endtask
    task finish_live(input integer hold_cycles);
        begin await_completion;repeat(hold_cycles)begin
                // Changing offered metadata/epoch cannot rename a held owner.
                @(negedge clk);issue_epoch=issue_epoch+1;issue_lhs=~issue_lhs;
                issue_rhs=~issue_rhs;issue_instr=32'hffffffff;issue_pc=issue_pc+4;tick;
            end
            @(negedge clk);completion_ready=1;tick;
            if(owner_valid)$fatal(1,"M OWNER live consume did not release");
            @(negedge clk);completion_ready=0;repeat(2)tick;
            if(completion_valid||drain_fire||!unit_done)$fatal(1,"M OWNER sticky done completed twice");
            cases=cases+1;
        end
    endtask
    task kill_current(input [63:0] cut);
        begin @(negedge clk);kill_valid=1;kill_cut_seq=cut;tick;
            @(negedge clk);kill_valid=0;
        end
    endtask
    task await_drain;
        begin wait_count=0;while(owner_valid)begin tick;wait_count=wait_count+1;
            if(wait_count>40)$fatal(1,"M OWNER killed result did not drain");end
            repeat(3)tick;if(completion_valid||drain_fire)$fatal(1,"M OWNER repeated killed drain");
            cases=cases+1;
        end
    endtask
    task reset_owner;
        begin @(negedge clk);rst_n=0;issue_valid=0;kill_valid=0;completion_ready=0;
            repeat(2)tick;@(negedge clk);rst_n=1;tick;
        end
    endtask

    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst_n)begin
            model_valid=0;model_killed=0;next_generation=FIRST_GENERATION;last_issue=0;
            if(owner_valid||completion_valid||issue_fire||unit_start_fire||drain_fire)
                $fatal(1,"M OWNER reset side effect");
            #1;if(unit_busy||unit_done)$fatal(1,"M OWNER reset did not reset unit");
        end else begin
            old_valid=model_valid;pre_issue=issue_fire;last_issue=issue_fire;
            pre_complete=completion_valid&&completion_ready&&!completion_killed;
            pre_drain=drain_fire;
            if(owner_valid!==model_valid)$fatal(1,"M OWNER ownership ledger");
            if(unit_start_fire!==issue_fire)$fatal(1,"M OWNER repeated/missing unit start");
            if(issue_valid&&!issue_ready)blocked=blocked+1;
            expected_killed=model_killed||(model_valid&&kill_valid&&model_seq>=kill_cut_seq);
            if(model_valid)begin
                if(owner_seq!==model_seq||owner_generation!==model_generation||
                    completion_seq!==model_seq||completion_pc!==model_pc||completion_instr!==model_instr||
                    completion_epoch!==model_epoch||completion_op!==model_op)
                    $fatal(1,"M OWNER metadata/generation changed");
                if(owner_killed!==expected_killed||completion_killed!==expected_killed)
                    $fatal(1,"M OWNER age kill mismatch");
                if(expected_killed)begin model_killed=1;kill_edges=kill_edges+1;end
            end
            if(completion_valid)begin
                if(!old_valid||cycles<=start_cycle||result_generation!==model_generation)
                    $fatal(1,"M OWNER stale generation consumed");
                if(completion_result!==model_result)$fatal(1,"M OWNER arithmetic result op=%0d lhs=%h rhs=%h got=%h expected=%h",model_op,model_lhs,model_rhs,completion_result,model_result);
                if(drain_fire!==expected_killed)$fatal(1,"M OWNER killed completion not auto-drained");
                if(!completion_ready&&!expected_killed)held=held+1;
                if(pre_complete)begin completed=completed+1;model_valid=0;end
                if(pre_drain)begin drained=drained+1;model_valid=0;end
                $fdisplay(trace_fd,"result,%0d,%h,%h,%h,%0d,%0d",cycles,model_seq,model_generation,completion_result,pre_complete,pre_drain);
            end else if(drain_fire)$fatal(1,"M OWNER drain without result");
            if(pre_issue)begin
                if(old_valid||pre_complete||pre_drain||unit_busy)
                    $fatal(1,"M OWNER start/result handoff overlap");
                model_valid=1;model_killed=0;model_seq=issue_seq;
                model_pc=issue_pc;model_instr=issue_instr;model_epoch=issue_epoch;model_op=issue_op;
                model_lhs=issue_lhs;model_rhs=issue_rhs;model_result=reference(issue_op,issue_lhs,issue_rhs);
                model_generation=next_generation;next_generation=next_generation+1;
                if(model_generation[63:32]!=0)cross32=cross32+1;
                starts=starts+1;start_cycle=cycles;
                $fdisplay(trace_fd,"start,%0d,%h,%h,%h,%0d,%0d",cycles,model_seq,model_generation,model_result,issue_op,0);
            end
            #1;
            if(owner_valid!==model_valid)$fatal(1,"M OWNER post-edge ownership ledger");
            if(model_valid&&(owner_seq!==model_seq||owner_generation!==model_generation))
                $fatal(1,"M OWNER post-edge generation allocation");
            if(pre_issue&&model_op[2]&&(model_rhs==0||
                (!model_op[0]&&model_lhs==32'h80000000&&model_rhs==32'hffffffff)))begin
                if(unit_busy||!unit_done||!completion_valid||completion_result!==model_result)
                    $fatal(1,"M OWNER fast result required a busy/done-low transition");
                fast=fast+1;
            end
        end
    end

    initial begin
        trace_fd=$fopen("build/cpu5_s8_m_owner/owner_trace.csv","w");
        $fdisplay(trace_fd,"event,cycle,seq,generation,result,consume_or_op,drain");
        reset_owner;
        // Signed high products, sign combinations, zero, min/max, defined
        // divide-by-zero and signed overflow on every applicable operation.
        for(i=0;i<8;i=i+1)for(j=0;j<9;j=j+1)begin
            case(j)
                0:begin a=0;b=0;end
                1:begin a=32'hffffffff;b=0;end
                2:begin a=32'h80000000;b=32'hffffffff;end
                3:begin a=32'hffffffff;b=2;end
                4:begin a=32'h80000000;b=32'h80000000;end
                5:begin a=32'h7fffffff;b=32'hffffffff;end
                6:begin a=32'hffffffe9;b=5;end
                7:begin a=23;b=32'hfffffffb;end
                8:begin a=32'hffffffff;b=32'hffffffff;end
            endcase
            send(i[2:0],a,b,next_seq);next_seq=next_seq+1;finish_live(j%4);
        end
        for(i=0;i<64;i=i+1)begin
            rng=random_next(rng);a=rng;rng=random_next(rng);b=rng;
            send(i[2:0],a,b,next_seq);next_seq=next_seq+1;finish_live(i%3);
        end
        // A younger redirect cut must preserve an older running owner, even
        // across bit32 and arbitrary offered fetch-epoch changes.
        send(4,32'h87654321,19,64'h00000000ffffffff);
        kill_current(64'h0000000100000000);finish_live(5);
        // Equality and unsigned64 age cuts kill running MUL/DIV and fast done.
        for(i=0;i<8;i=i+1)begin
            send(i[2:0],32'h87654321,i[0]?0:19,64'h0000000100000001+i);
            saved_completed=completed;saved_drained=drained;
            kill_current(64'h0000000100000000);await_drain;
            if(completed!=saved_completed||drained!=saved_drained+1)
                $fatal(1,"M OWNER killed result became a live consume");
        end
        // Completed-but-held results can be killed and drain without READY.
        send(0,13,17,next_seq);next_seq=next_seq+1;await_completion;repeat(6)tick;
        kill_current(model_seq);await_drain;
        // Hold a new request behind a killed DIV. The old result drains once,
        // then the ISR multiply starts at a strictly later edge with new gen.
        send(4,32'h76543210,13,next_seq);next_seq=next_seq+1;
        saved_starts=starts;saved_drained=drained;
        offer(0,19,23,next_seq);next_seq=next_seq+1;repeat(5)tick;
        if(starts!=saved_starts||!unit_busy||!owner_valid)$fatal(1,"M OWNER running owner overwritten");
        kill_current(model_seq);wait_count=0;
        while(starts==saved_starts)begin tick;wait_count=wait_count+1;
            if(wait_count>40)$fatal(1,"M OWNER handler multiply could not start after drain");end
        if(drained!=saved_drained+1)$fatal(1,"M OWNER handler reused old sticky done");
        @(negedge clk);issue_valid=0;finish_live(4);
        // An already killed offered command never starts a physical operation.
        saved_starts=starts;@(negedge clk);kill_valid=1;kill_cut_seq=next_seq;
        issue_valid=1;issue_seq=next_seq;issue_op=0;issue_lhs=7;issue_rhs=9;
        repeat(4)tick;if(starts!=saved_starts||owner_valid)$fatal(1,"M OWNER started killed offered command");
        @(negedge clk);issue_valid=0;kill_valid=0;
        // Reset clears running and held ownership together with the raw unit.
        send(4,32'h71234567,11,next_seq);next_seq=next_seq+1;repeat(4)tick;reset_owner;
        send(6,32'h80000000,32'hffffffff,next_seq);next_seq=next_seq+1;finish_live(2);
        send(0,17,19,next_seq);next_seq=next_seq+1;await_completion;repeat(3)tick;reset_owner;
        send(5,123,0,next_seq);finish_live(3);
        if(starts!=completed+drained+2||completed<140||drained!=10||fast<12||
            held<150||blocked<15||cross32<100||cases<145||kill_edges<20)
            $fatal(1,"M OWNER coverage starts=%0d completed=%0d drained=%0d fast=%0d held=%0d blocked=%0d cross32=%0d cases=%0d kill=%0d",starts,completed,drained,fast,held,blocked,cross32,cases,kill_edges);
        summary_fd=$fopen("build/cpu5_s8_m_owner/owner_summary.json","w");
        $fdisplay(summary_fd,"{\"pass\":true,\"cases\":%0d,\"starts\":%0d,\"live_consumed\":%0d,\"killed_drained\":%0d,\"reset_canceled\":2,\"fast_results\":%0d,\"held_edges\":%0d,\"blocked_issue_edges\":%0d,\"cross_bit32_generations\":%0d,\"kill_edges\":%0d}",cases,starts,completed,drained,fast,held,blocked,cross32,kill_edges);
        $fclose(summary_fd);$fclose(trace_fd);test_pass=1;
        $display("CPU5 M OWNER TEST PASS cases=%0d starts=%0d live=%0d drain=%0d",cases,starts,completed,drained);$stop;
    end
    initial begin #300000;$fatal(1,"M OWNER test timeout");end
endmodule

// Finite exhaustion test using a real 64-bit allocation boundary, not force or
// shortened arithmetic. The runner also overrides SEQ_BITS to test its guard.
module cpu5_m_owner_guard_tb #(
    parameter integer SEQ_BITS=64,EPOCH_BITS=8
);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,issue_valid=0;
    wire unit_start_fire,completion_valid;
    wire [63:0] owner_generation,result_generation;
    cpu5_m_owner #(.SEQ_BITS(SEQ_BITS),.EPOCH_BITS(EPOCH_BITS),
        .RESET_GENERATION(64'hfffffffffffffffe)) dut(
        .clk(clk),.rst_n(rst_n),.issue_valid(issue_valid),.issue_ready(),.issue_fire(),
        .issue_seq({SEQ_BITS{1'b0}}),.issue_pc(32'h200),.issue_instr(32'h022081b3),
        .issue_epoch({EPOCH_BITS{1'b0}}),.issue_op(3'd0),.issue_lhs(32'd7),.issue_rhs(32'd9),
        .kill_valid(1'b0),.kill_cut_seq({SEQ_BITS{1'b0}}),
        .completion_valid(completion_valid),.completion_ready(1'b1),.completion_seq(),.completion_pc(),
        .completion_instr(),.completion_epoch(),.completion_result(),.completion_killed(),.completion_op(),
        .owner_valid(),.owner_seq(),.owner_killed(),.unit_start_fire(unit_start_fire),.unit_busy(),.unit_done(),
        .owner_generation(owner_generation),.result_generation(result_generation),.drain_fire());
    always @(posedge clk)if(rst_n)begin
        if(unit_start_fire)$display("M OWNER EXHAUSTION START");
        if(completion_valid)begin
            if(owner_generation!==64'hfffffffffffffffe||result_generation!==owner_generation)
                $fatal(1,"M OWNER exhaustion fixture generation mismatch");
            $display("M OWNER EXHAUSTION RESULT generation=%h",result_generation);
        end
    end
    initial begin #12;rst_n=1;#8;issue_valid=1;#100;
        $fatal(1,"M OWNER exhausted generation guard failed to stop");end
endmodule
