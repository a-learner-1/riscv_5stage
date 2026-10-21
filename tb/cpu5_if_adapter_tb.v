`timescale 1ns/1ps
module cpu5_if_adapter_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, id_ready=1, redirect_valid=0, redirect_kill_ifid=0;
    reg [31:0] redirect_pc=0;
    wire redirect_ready, ifid_valid, ifid_pred_taken, ifid_pred_hit, ifid_fetch_error;
    wire [31:0] ifid_pc, ifid_instr, ifid_pred_next_pc, ifid_fetch_tval;
    wire [63:0] ifid_seq; wire [7:0] ifid_epoch;
    wire imem_req_valid, imem_rsp_ready;
    wire [31:0] imem_req_addr;
    reg imem_req_ready=0, imem_rsp_valid=0, imem_rsp_error=0;
    reg [31:0] imem_rsp_rdata=0;
    reg bp_commit_valid=0; wire bp_commit_ready, bp_update_fire;
    reg [63:0] bp_commit_seq=0;
    reg [31:0] bp_commit_pc=0, bp_commit_target=0;
    reg bp_commit_taken=0,bp_commit_is_branch=1,bp_commit_is_jal=0;
    wire [31:0] bp_lookup_count,bp_hit_count,bp_taken_count,imem_fault_pc;
    wire imem_fault;
    reg test_pass=0;
    reg negative_expected=0, negative_returned=0;
    integer checks=0, gate=0, fd, gf, cycle=0, updates=0, transfers=0;
    integer reqs=0, rsps=0, redirects=0, faults=0, same_edges=0;
    reg [63:0] consumed_seq;
    reg [31:0] saved_pc,saved_instr,saved_pred;
    reg [63:0] saved_seq; reg [7:0] saved_epoch;
    cpu5_if_adapter #(.ENABLE_BRANCH_PRED(1),.IMEM_WORDS(8192)) dut (.*);
    task step; begin @(posedge clk); #1; end endtask
    task ck(input bit condition,input string label_text);
        begin checks=checks+1; if (!condition) $fatal(1,"IF gate %0d: %s",gate,label_text); end
    endtask
    task reset_dut;
        begin
            rst_n=0; id_ready=1; redirect_valid=0; redirect_kill_ifid=0; redirect_pc=0;
            imem_req_ready=0; imem_rsp_valid=0; imem_rsp_error=0; bp_commit_valid=0;
            repeat(2) step(); rst_n=1; #1; step();
        end
    endtask
    task req(input [31:0] pc);
        begin
            imem_req_ready=1; #1;
            ck(imem_req_valid && imem_req_addr==pc,"request address / valid");
            step(); imem_req_ready=0; #1;
        end
    endtask
    task rsp(input [31:0] data,input bit error_value);
        begin
            imem_rsp_valid=1; imem_rsp_rdata=data; imem_rsp_error=error_value; #1;
            ck(imem_rsp_ready,"expected response ready"); step();
            imem_rsp_valid=0; imem_rsp_error=0; #1;
        end
    endtask
    task older_redirect(input [31:0] pc);
        begin
            redirect_valid=1; redirect_kill_ifid=1; redirect_pc=pc; #1;
            ck(redirect_ready,"older redirect accepted"); step();
            redirect_valid=0; redirect_kill_ifid=0; #1;
        end
    endtask
    task pass_gate(input string text_label);
        begin
            $display("CPU5 IF G%0d PASS: %s",gate,text_label);
            $fdisplay(gf,"%0d,PASS,%s",gate,text_label);
        end
    endtask
    always @(posedge clk) if(rst_n) begin
        cycle=cycle+1;
        if (bp_update_fire) updates=updates+1;
        if (imem_req_valid&&imem_req_ready) reqs=reqs+1;
        if (imem_rsp_valid&&imem_rsp_ready) rsps=rsps+1;
        if (redirect_valid&&redirect_ready) redirects=redirects+1;
        if (imem_req_valid&&imem_req_ready&&imem_rsp_valid&&imem_rsp_ready) same_edges=same_edges+1;
        if (ifid_valid&&id_ready) begin
            transfers=transfers+1; consumed_seq=ifid_seq;
            if(ifid_fetch_error) faults=faults+1;
        end
        $fdisplay(fd,"%0d,%0d,%0b,%0b,%08x,%0b,%0b,%08x,%0b,%0b,%08x,%08x,%0d,%0d,%0b,%0b,%0b,%0b,%0b,%08x,%0b,%0b,%08x,%0b,%0d,%08x,%08x,%0b,%0b,%0b",cycle,gate,
            imem_req_valid,imem_req_ready,imem_req_addr,imem_rsp_valid,imem_rsp_ready,imem_rsp_rdata,
            ifid_valid,id_ready,ifid_pc,ifid_instr,ifid_seq,ifid_epoch,ifid_fetch_error,
            redirect_valid&&redirect_ready,bp_update_fire,imem_fault,imem_rsp_error,
            ifid_pred_next_pc,ifid_pred_taken,ifid_pred_hit,ifid_fetch_tval,redirect_kill_ifid,
            bp_commit_seq,bp_commit_pc,bp_commit_target,bp_commit_taken,bp_commit_is_branch,bp_commit_is_jal);
    end
    initial begin
        if($test$plusargs("IF_SEQ_EXHAUST")) begin
            fd=$fopen("build/cpu5_s1_if/negative_events.csv","w");
            gate=8;reset_dut();req(0);rsp(32'h00100093,0);
            ck(ifid_valid,"real tail packet exists before exhaustion injection");
            id_ready=0;req(4);negative_expected=1;
            // Directed assertion injection only; never a synthesis hierarchy dependency.
            dut.next_seq_q=64'hffffffffffffffff;
            imem_rsp_valid=1;id_ready=1;#1;
            ck(dut.raw_valid&&!imem_rsp_ready&&!ifid_valid,"terminal halt masks retained tail; no response or repeated ID transfer");
            step();negative_returned=1;$finish;
        end
        fd=$fopen("build/cpu5_s1_if/events.csv","w"); gf=$fopen("build/cpu5_s1_if/gates.csv","w");
        if(!fd||!gf) $fatal(1,"cannot open IF evidence");
        $fdisplay(fd,"cycle,gate,req_valid,req_ready,req_addr,rsp_valid,rsp_ready,rsp_data,ifid_valid,id_ready,ifid_pc,ifid_instr,seq,epoch,fetch_error,redirect_fire,bp_update_fire,sticky_fault,rsp_error,pred_next,pred_taken,pred_hit,fetch_tval,redirect_kill,bp_seq,bp_pc,bp_target,bp_taken,bp_branch,bp_jal");
        $fdisplay(gf,"gate,result,case");
        gate=1; reset_dut(); req(0);
        id_ready=0; imem_rsp_valid=1; imem_rsp_rdata=32'h00100093;
        repeat(5) begin #1; ck(!imem_rsp_ready&&!ifid_valid,"blocked response retained at endpoint"); step(); end
        id_ready=1; #1; ck(imem_rsp_ready,"stall release accepts response"); step(); imem_rsp_valid=0;
        ck(ifid_valid&&ifid_pc==0&&ifid_instr==32'h00100093&&ifid_seq==0,"normal packet not delayed a second register");
        id_ready=0; repeat(4) begin step(); ck(ifid_valid&&ifid_instr==32'h00100093,"ID blocked slot stable"); end
        pass_gate("ID stall response retention and IFID stability");

        gate=2;
        saved_seq=ifid_seq; saved_epoch=ifid_epoch;
        redirect_valid=1; redirect_kill_ifid=0; redirect_pc=32'h80;
        repeat(4) begin #1; ck(!redirect_ready,"ID-owned redirect waits for transfer"); step();
            ck(ifid_valid&&ifid_instr==32'h00100093&&ifid_seq==saved_seq&&ifid_epoch==saved_epoch,"no untransferred ID loss"); end
        id_ready=1; #1; ck(redirect_ready&&ifid_valid,"ID branch transfers on accepted redirect");
        step(); redirect_valid=0; ck(!ifid_valid,"transferred ID slot cleared exactly once");
        req(4); rsp(32'hbad00013,1); ck(!ifid_valid&&!imem_fault,"held stale error drained after own redirect");
        step(); req(32'h80); rsp(32'h00200113,0); id_ready=0;
        older_redirect(32'h100); ck(!ifid_valid,"older redirect explicitly kills stalled younger slot");
        pass_gate("redirect plus stall preserves ID owner until transfer; older flush kills");

        gate=3; reset_dut();
        // Initial held PC0 remains stable across redirect, then drains as stale.
        older_redirect(32'h40);
        ck(imem_req_valid&&imem_req_addr==0,"held old request remains presented");
        req(0); rsp(32'hbad00013,1); ck(!ifid_valid&&!imem_fault,"stale fault cannot queue");
        bp_commit_valid=1; bp_commit_seq=1; bp_commit_pc=32'h40;bp_commit_target=32'h80;
        bp_commit_taken=1;bp_commit_is_jal=1; step();bp_commit_valid=0;bp_commit_is_jal=0;
        // PC40 has already been presented by the response edge: its old metadata
        // must stay a miss despite the later BTB update. Drain this request first.
        req(32'h40); rsp(32'h00300193,0);
        ck(ifid_valid&&ifid_pc==32'h40&&!ifid_pred_hit&&ifid_pred_next_pc==32'h44&&ifid_epoch==1,"held request retains original miss metadata");
        older_redirect(32'h40); req(32'h44); rsp(32'hbad00013,1);
        step(); // PC40 is now presented using trained prediction 0x80.
        bp_commit_valid=1;bp_commit_seq=2;bp_commit_target=32'hc0;bp_commit_is_jal=1;step();bp_commit_valid=0;bp_commit_is_jal=0;
        req(32'h40);rsp(32'h00400213,0);
        ck(ifid_valid&&ifid_pc==32'h40&&ifid_pred_hit&&ifid_pred_taken&&ifid_pred_next_pc==32'h80&&ifid_epoch==2,"held taken prediction metadata retained after retrain");
        pass_gate("held and accepted stale drain; prediction metadata and epoch follow request");

        gate=4; reset_dut(); req(0);rsp(32'h00500293,0);id_ready=0;req(4);
        imem_rsp_valid=1;imem_rsp_error=1;imem_rsp_rdata=32'hdeadbeef;
        saved_seq=ifid_seq;
        repeat(4) begin #1;ck(!imem_rsp_ready&&ifid_valid&&!ifid_fetch_error,"younger IF fault waits behind older IFID");step();end
        id_ready=1;#1;ck(ifid_valid&&ifid_pc==0,"older instruction transfers before fault packet");step();
        imem_rsp_valid=0;imem_rsp_error=0;id_ready=0;
        ck(ifid_valid&&ifid_fetch_error&&ifid_pc==4&&ifid_fetch_tval==4&&ifid_seq==saved_seq+1&&imem_fault,"fault packaged with age and PC");
        repeat(5) begin step();ck(ifid_valid&&ifid_fetch_error&&ifid_fetch_tval==4,"fault packet stable while ID blocked");end
        id_ready=1;step();ck(!ifid_valid&&imem_fault,"fault consumed once; sticky IF diagnostic remains");
        repeat(3) begin step();ck(!ifid_valid&&!imem_req_valid,"sticky fault not duplicated");end
        older_redirect(32'h100);ck(!imem_fault,"authorized redirect acknowledges sticky fault");
        req(32'h100);rsp(32'h00600313,0);ck(ifid_valid&&!ifid_fetch_error&&ifid_pc==32'h100&&ifid_epoch==1,"fetch resumes at new epoch");
        pass_gate("sticky fault becomes ordered packet once; no direct architectural trap");

        gate=5; reset_dut(); saved_pc=updates;
        bp_commit_valid=1;bp_commit_seq=10;bp_commit_pc=32'h40;bp_commit_target=32'h80;
        bp_commit_taken=0;bp_commit_is_branch=1;bp_commit_is_jal=0;
        repeat(6)step();bp_commit_valid=0;ck(updates==saved_pc+1,"held MEM BP descriptor trains only once");
        bp_commit_valid=1;bp_commit_seq=11;bp_commit_taken=1;step();bp_commit_valid=0;
        ck(updates==saved_pc+2,"new MEM owner trains once");
        bp_commit_valid=1;bp_commit_seq=10;repeat(3)begin #1;ck(!bp_commit_ready&&!bp_update_fire,"older replay rejected");step();end bp_commit_valid=0;
        older_redirect(32'h40);req(0);rsp(32'hbad00013,0);step();req(32'h40);rsp(32'h00700393,0);
        ck(ifid_pred_hit&&ifid_pred_taken&&ifid_pred_next_pc==32'h80,"one NT then one T trained weakly taken rather than repeated NT");
        pass_gate("MEM authorized seq dedup and observable two-bit predictor state");

        gate=6; reset_dut();
        repeat(16)begin #1;ck(imem_req_valid&&imem_req_addr==0,"long request backpressure valid/address stable");step();end
        older_redirect(32'h200);
        repeat(16)begin #1;ck(imem_req_valid&&imem_req_addr==0,"redirect cannot withdraw held request");step();end
        req(0);rsp(32'hbad00013,0);step();req(32'h200);rsp(32'h00800413,0);
        ck(ifid_valid&&ifid_pc==32'h200&&ifid_epoch==1,"redirect target follows stale drain");
        pass_gate("long request backpressure and redirect preserve valid/address");

        gate=7; reset_dut();req(0);
        imem_rsp_valid=1;imem_rsp_rdata=32'h00900493;imem_req_ready=1;#1;
        ck(imem_rsp_ready&&imem_req_valid&&imem_req_addr==4,"old response plus next request same edge");step();imem_rsp_valid=0;imem_req_ready=0;
        ck(ifid_valid&&ifid_pc==0&&ifid_instr==32'h00900493&&ifid_seq==0,"response A owns packet A");
        rsp(32'h00a00513,0);
        ck(ifid_valid&&ifid_pc==4&&ifid_instr==32'h00a00513&&ifid_seq==1&&ifid_pred_next_pc==8,"request B ownership independent of old response A");
        ck(same_edges>=1&&faults==1,"coverage same-edge and fault-once");
        pass_gate("same-edge response A/request B independent addresses data seq");
        $display("CPU5 IF SUMMARY checks=%0d req=%0d rsp=%0d transfers=%0d faults=%0d redirects=%0d bp_updates=%0d same_edges=%0d",checks,reqs,rsps,transfers,faults,redirects,updates,same_edges);
        $fclose(fd);$fclose(gf);test_pass=1;$finish;
    end
    initial begin #200000;$fatal(1,"CPU5 IF watchdog");end
endmodule
