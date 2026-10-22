`timescale 1ns/1ps
module cpu5_ram_owner_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,issue_valid=0,issue_is_store=0,kill_valid=0;
    wire issue_ready,issue_fire;
    reg [63:0] issue_seq=0,kill_cut_seq=0;
    reg [31:0] issue_pc=0,issue_instr=0,issue_addr=0,issue_wdata=0;
    reg [7:0] issue_epoch=0;
    reg [1:0] issue_size=0;
    reg [3:0] issue_wstrb=0;
    reg [2:0] issue_funct3=0;
    wire dmem_req_valid,dmem_req_write;
    reg dmem_req_ready=0;
    wire [31:0] dmem_req_addr,dmem_req_wdata;
    wire [1:0] dmem_req_size;
    wire [3:0] dmem_req_wstrb;
    reg dmem_rsp_valid=0,dmem_rsp_error=0;
    reg [31:0] dmem_rsp_rdata=0;
    wire dmem_rsp_ready;
    reg completion_ready=0;
    wire completion_valid,completion_error,completion_killed,completion_is_store;
    wire [63:0] completion_seq;
    wire [31:0] completion_pc,completion_instr,completion_rdata,completion_addr;
    wire [7:0] completion_epoch;
    wire [2:0] completion_funct3;
    wire owner_valid,owner_is_store,owner_killed,owner_sent,store_lock,req_fire,rsp_fire;
    wire [63:0] owner_seq,req_owner_seq,rsp_owner_seq;
    wire [31:0] req_owner_pc,req_owner_instr,rsp_owner_pc,rsp_owner_instr;
    wire [1:0] state_debug;
    reg test_pass=0;
    integer checks=0,scenarios=0,req_count=0,rsp_count=0,issued_count=0;
    integer completion_count=0,killed_drop_count=0,handoff_count=0,store_req_count=0;
    integer trace_file,summary_file,i,before_req,before_rsp;
    reg held=0;
    reg [31:0] held_addr,held_wdata,held_pc,held_instr;
    reg [63:0] held_seq;
    reg held_write;
    reg [1:0] held_size;
    reg [3:0] held_wstrb;
    cpu5_ram_owner dut(.*);

    task check;
        input condition; input [511:0] label;
        begin checks=checks+1; if(condition!==1'b1) $fatal(1,"owner: %0s",label); end
    endtask
    // Finish after the falling edge, leaving all stimulus away from sampling.
    task step;
        begin @(posedge clk); #1; @(negedge clk); #1; end
    endtask
    task offer;
        input [63:0] seqno; input store;
        input [31:0] address; input [7:0] epoch;
        begin
            issue_valid=1; issue_seq=seqno; issue_is_store=store;
            issue_pc=32'h8000+seqno[31:0]*4;
            issue_instr=32'hfeed0000^seqno[31:0]; issue_epoch=epoch;
            issue_addr=address; issue_size=2; issue_wdata=32'ha0000000^seqno[31:0];
            issue_wstrb=store?4'b1111:4'b0000; issue_funct3=2;
        end
    endtask
    task respond;
        input [31:0] data; input error;
        begin dmem_rsp_valid=1; dmem_rsp_rdata=data; dmem_rsp_error=error; end
    endtask
    task idle_inputs;
        begin issue_valid=0; dmem_rsp_valid=0; dmem_rsp_error=0;
            kill_valid=0; completion_ready=0; dmem_req_ready=0; end
    endtask
    always @(posedge clk) begin
        if(rst_n) begin
            if(held) begin
                check(dmem_req_valid,"held request remains valid");
                check({dmem_req_addr,dmem_req_wdata,dmem_req_write,dmem_req_size,
                       dmem_req_wstrb,req_owner_seq,req_owner_pc,req_owner_instr}===
                      {held_addr,held_wdata,held_write,held_size,held_wstrb,
                       held_seq,held_pc,held_instr},"held descriptor stable");
            end
            if(issue_fire) issued_count=issued_count+1;
            if(req_fire) begin req_count=req_count+1;
                if(dmem_req_write) store_req_count=store_req_count+1; end
            if(rsp_fire) rsp_count=rsp_count+1;
            if(completion_valid && completion_ready && !completion_killed)
                completion_count=completion_count+1;
            if(completion_valid && completion_killed) killed_drop_count=killed_drop_count+1;
            if(req_fire && rsp_fire) begin
                handoff_count=handoff_count+1;
                check(!completion_error && !completion_killed && !completion_is_store &&
                      !dmem_req_write && completion_ready,"only successful load handoff");
                check(req_owner_seq!==rsp_owner_seq,"handoff distinguishes owners");
            end
            $fdisplay(trace_file,"%0t,%0d,%0d,%016h,%0d,%0d,%016h,%08h,%08h,%0d,%0d,%016h,%08h,%08h,%0d,%0d,%0d,%0d",
                $time,state_debug,issue_fire,issue_seq,req_fire,dmem_req_write,req_owner_seq,
                dmem_req_addr,dmem_req_wdata,rsp_fire,completion_valid,rsp_owner_seq,
                completion_rdata,completion_addr,completion_error,completion_killed,
                completion_ready,store_lock);
            held=dmem_req_valid && !dmem_req_ready;
            if(held) begin held_addr=dmem_req_addr;held_wdata=dmem_req_wdata;
                held_write=dmem_req_write;held_size=dmem_req_size;held_wstrb=dmem_req_wstrb;
                held_seq=req_owner_seq;held_pc=req_owner_pc;held_instr=req_owner_instr;end
        end else held=0;
    end
    initial begin
        trace_file=$fopen("build/cpu5_s5_ram_owner/trace.csv","w");
        $fdisplay(trace_file,"time,state,issue_fire,issue_seq,req_fire,req_write,req_seq,req_addr,req_wdata,rsp_fire,completion_valid,rsp_seq,rsp_rdata,completion_addr,error,killed,completion_ready,store_lock");
        step;step;rst_n=1;step;

        // Ownership binds even if the first request cannot be accepted.
        scenarios=scenarios+1;
        offer(64'h0000000100000001,0,32'h10003,8'hfe);
        issue_size=0;issue_wdata=32'hdeadbeef;issue_funct3=0;
        #1;check(issue_ready && issue_fire && dmem_req_valid && !req_fire,
                 "offer binds independently of req ready");
        step;check(owner_valid && !owner_sent && owner_seq==64'h100000001 && state_debug==1,
                   "presented owner captured");
        issue_valid=0;offer(99,1,32'h20000,0); // changing upstream cannot replace owner
        #1;check(!issue_ready && !store_lock && dmem_req_addr==32'h10003,
                 "busy owner ignores changing upstream");
        repeat(3) step;
        kill_valid=1;kill_cut_seq=64'h100000001;
        #1;check(owner_killed,"held load killed immediately by 64 bit age");
        step;kill_valid=0;issue_epoch=8'hff;
        #1;check(owner_killed && dmem_req_valid,"kill sticky but held request drains");
        issue_valid=0;dmem_req_ready=1;step;
        check(owner_sent && state_debug==2,"held request accepted once");
        dmem_req_ready=0;respond(32'hbad00001,1);
        #1;check(completion_valid && completion_killed && completion_error &&
                 completion_seq==64'h100000001 && completion_epoch==8'hfe,
                 "killed error response belongs to original owner");
        step;idle_inputs;check(!owner_valid,"killed response drops without completion ready");

        // The completion cache is the equivalent of WB backpressure.
        scenarios=scenarios+1;
        offer(10,0,32'h10010,8'h11);dmem_req_ready=1;step;issue_valid=0;
        respond(32'h12345678,0);
        #1;check(completion_valid && completion_rdata==32'h12345678 && completion_seq==10,
                 "response combinational completion bypass");
        step;dmem_rsp_valid=0;dmem_rsp_rdata=32'hffffffff;dmem_rsp_error=1;
        repeat(4) begin #1;check(completion_valid && completion_rdata==32'h12345678 &&
            !completion_error && completion_addr==32'h10010 && completion_epoch==8'h11,
            "blocked completion stable");step;end
        completion_ready=1;step;idle_inputs;check(!owner_valid,"blocked result consumed once");

        // In the same edge A responds and B requests, metadata remain separate.
        scenarios=scenarios+1;
        offer(20,0,32'h10020,8'hff);dmem_req_ready=1;step;
        offer(21,0,32'h10074,8'h00);completion_ready=1;respond(32'h11223344,0);
        #1;check(issue_fire && req_fire && rsp_fire && req_owner_seq==21 && rsp_owner_seq==20 &&
                 req_owner_pc==32'h8054 && rsp_owner_pc==32'h8050 &&
                 req_owner_instr==32'hfeed0015 && rsp_owner_instr==32'hfeed0014 &&
                 dmem_req_addr==32'h10074 && dmem_req_wdata==32'ha0000015 &&
                 completion_addr==32'h10020 && completion_rdata==32'h11223344 &&
                 completion_epoch==8'hff,"A response and B request have distinct descriptors");
        step;issue_valid=0;dmem_rsp_valid=0;
        check(owner_valid && owner_seq==21 && owner_sent,"B owns next response");
        respond(32'h55667788,0);#1;check(completion_seq==21 && completion_epoch==0 &&
            completion_rdata==32'h55667788,"epoch wrap does not kill B");
        step;idle_inputs;

        // Turnover may also bind B while B's request is held.
        scenarios=scenarios+1;
        offer(30,0,32'h10030,1);dmem_req_ready=1;step;
        offer(31,0,32'h10031,2);dmem_req_ready=0;completion_ready=1;respond(32'h31323334,0);
        #1;check(issue_fire && !req_fire && rsp_fire,"turnover ownership independent of B ready");
        step;issue_valid=0;dmem_rsp_valid=0;
        check(owner_seq==31 && !owner_sent && state_debug==1,"held B captures descriptor");
        repeat(2) step;dmem_req_ready=1;step;respond(32'h35363738,0);step;idle_inputs;

        // A cached successful load can hand over too, still obeying one owner.
        scenarios=scenarios+1;
        offer(40,0,32'h10040,3);dmem_req_ready=1;step;issue_valid=0;respond(32'h41424344,0);
        step;dmem_rsp_valid=0;offer(41,0,32'h10044,4);completion_ready=1;
        #1;check(completion_valid && issue_fire && req_fire && !rsp_fire && completion_seq==40 &&
            req_owner_seq==41,"cached load handoff");step;issue_valid=0;
        respond(32'h45464748,0);step;idle_inputs;

        // No load to STORE shortcut. The new store waits for an empty edge.
        scenarios=scenarios+1;
        offer(50,0,32'h10050,5);dmem_req_ready=1;step;
        offer(51,1,32'h10054,6);completion_ready=1;respond(32'h51525354,0);
        #1;check(!issue_ready && !dmem_req_valid && rsp_fire,"new STORE cannot handoff from load");
        step;dmem_rsp_valid=0;#1;check(issue_ready && dmem_req_valid && !owner_valid,
            "STORE begins after load release edge");step;issue_valid=0;
        before_req=req_count;repeat(4) step;
        check(store_lock && owner_is_store && owner_sent && req_count==before_req,
            "accepted STORE never repeats while waiting");
        kill_valid=1;kill_cut_seq=0;#1;check(!owner_killed && store_lock,"STORE cannot be killed");
        step;kill_valid=0;completion_ready=0;respond(0,0);step;dmem_rsp_valid=0;
        check(store_lock && completion_valid && completion_is_store,"STORE completion remains locked");
        offer(52,0,32'h10058,7);completion_ready=1;
        #1;check(!issue_ready && !dmem_req_valid,"STORE completion cannot handoff to LOAD");
        step;idle_inputs;check(!owner_valid && !store_lock,"STORE unlocks only after consumption");

        // A STORE locks as soon as offered, including request backpressure.
        scenarios=scenarios+1;
        offer(55,1,32'h10057,8'h33);issue_size=0;issue_wstrb=4'b1000;
        issue_wdata=32'h7e000000;step;issue_valid=0;
        check(store_lock && !owner_sent && state_debug==1,"held STORE locks before endpoint ready");
        kill_valid=1;kill_cut_seq=55;offer(56,0,32'h20000,8'h44);
        #1;check(!owner_killed && !issue_ready && dmem_req_write &&
            dmem_req_addr==32'h10057 && dmem_req_size==0 &&
            dmem_req_wstrb==4'b1000 && dmem_req_wdata==32'h7e000000,
            "held STORE ignores kill and preserves complete descriptor");
        repeat(2) step;kill_valid=0;issue_valid=0;dmem_req_ready=1;step;
        respond(0,0);completion_ready=1;step;idle_inputs;

        // A live error survives READY=0, cannot handoff, and supports explicit ack.
        scenarios=scenarios+1;
        offer(60,0,32'h10060,8);dmem_req_ready=1;step;
        offer(61,0,32'h10064,9);respond(32'hbad00060,1);completion_ready=0;
        #1;check(!issue_ready && !dmem_req_valid && completion_error && !completion_killed,
            "error response cannot handoff");step;dmem_rsp_valid=0;dmem_rsp_error=0;
        repeat(3) begin #1;check(completion_valid && completion_error && owner_seq==60,
            "live fault held while not acknowledged");step;end
        completion_ready=1;#1;check(!issue_ready && !dmem_req_valid,"fault ack does not handoff");
        step;idle_inputs;check(!owner_valid,"fault explicit ack releases owner");

        // A kill during a live response suppresses its result and any turnover.
        scenarios=scenarios+1;
        offer(70,0,32'h10070,10);dmem_req_ready=1;step;
        offer(71,0,32'h10074,11);respond(32'h71727374,0);completion_ready=1;
        kill_valid=1;kill_cut_seq=70;
        #1;check(completion_killed && !issue_ready && !dmem_req_valid,"same-cycle kill blocks handoff");
        step;idle_inputs;check(!owner_valid,"killed live response released");

        // Killing a cached fault also drops it with READY=0.
        scenarios=scenarios+1;
        offer(80,0,32'h10080,12);dmem_req_ready=1;step;issue_valid=0;respond(0,1);step;
        dmem_rsp_valid=0;kill_valid=1;kill_cut_seq=80;
        #1;check(completion_valid && completion_killed && completion_error,"cached fault kill visible");
        step;idle_inputs;check(!owner_valid,"cached killed error drops without ready");

        // Full 64 bit age: a higher-word cut must not kill an older owner.
        scenarios=scenarios+1;
        offer(64'h00000000ffffffff,0,32'h10090,8'hff);dmem_req_ready=1;step;issue_valid=0;
        kill_valid=1;kill_cut_seq=64'h0000000100000000;
        issue_epoch=0;repeat(2) begin #1;check(!owner_killed,"64 bit age and epoch independence");step;end
        respond(32'h91929394,0);completion_ready=1;
        #1;check(!completion_killed && completion_seq==64'hffffffff,"older seq survives cut");
        step;idle_inputs;

        // STORE fault has the same explicit ack contract and never loses lock.
        scenarios=scenarios+1;
        offer(100,1,32'h10100,14);dmem_req_ready=1;step;issue_valid=0;respond(0,1);step;
        dmem_rsp_valid=0;kill_valid=1;kill_cut_seq=0;
        #1;check(store_lock && completion_error && !completion_killed,"STORE fault stays locked");
        repeat(2) step;completion_ready=1;step;idle_inputs;
        check(!store_lock && !owner_valid,"STORE fault explicit ack unlocks");

        // Reset cancels each non-idle state without emitting a transaction.
        scenarios=scenarios+1;
        for(i=1;i<=3;i=i+1) begin
            offer(200+i,0,32'h10200+i*4,20+i);dmem_req_ready=i==1?0:1;step;issue_valid=0;
            if(i==3) begin respond(0,0);step;dmem_rsp_valid=0;end
            #1;check(state_debug==i,"reset scenario reaches selected state");
            rst_n=0;#1;check(!owner_valid && !dmem_req_valid && !dmem_rsp_ready &&
                !completion_valid && !store_lock,"asynchronous reset cancels ownership");
            step;idle_inputs;rst_n=1;step;check(state_debug==0,"reset restarts idle");
        end

        check(handoff_count==1,"exactly one simultaneous request/response accepted handoff");
        check(store_req_count==3,"exactly three STORE requests");
        check(req_count==rsp_count+1,"only ACCEPTED reset leaves one unmatched request");
        check(issued_count==req_count+1,"only PRESENTED reset leaves an unaccepted offer");
        $fclose(trace_file);
        summary_file=$fopen("build/cpu5_s5_ram_owner/summary.json","w");
        $fdisplay(summary_file,"{\"pass\":true,\"checks\":%0d,\"scenarios\":%0d,\"issues\":%0d,\"requests\":%0d,\"responses\":%0d,\"completions_acknowledged\":%0d,\"killed_drops\":%0d,\"simultaneous_handoffs\":%0d,\"store_requests\":%0d}",
            checks,scenarios,issued_count,req_count,rsp_count,completion_count,killed_drop_count,handoff_count,store_req_count);
        $fclose(summary_file);test_pass=1;
        $display("CPU5 RAM OWNER PASS checks=%0d scenarios=%0d req=%0d rsp=%0d",checks,scenarios,req_count,rsp_count);
        $stop;
    end
    initial begin #20000;$fatal(1,"ram owner timeout");end
endmodule
