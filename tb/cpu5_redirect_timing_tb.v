`timescale 1ns/1ps
module cpu5_redirect_timing_tb;
    reg clk=0,rst_n=0,redirect=0,rsp_valid=0,rsp_error=0;
    always #5 clk=~clk;
    reg [31:0] target=0;
    wire req_valid,rsp_ready,if_valid,if_error,sticky;
    wire [31:0] req_addr,if_pc;
    wire [63:0] seq;
    wire [7:0] epoch;
    wire legacy_req;
    wire [31:0] legacy_addr;
    reg test_pass=0;
    integer checks=0;
    cpu5_if_adapter dut(.clk(clk),.rst_n(rst_n),.id_ready(1'b1),
        .redirect_valid(redirect),.redirect_ready(),.redirect_pc(target),.redirect_kill_ifid(1'b1),
        .ifid_valid(if_valid),.ifid_pc(if_pc),.ifid_instr(),.ifid_pred_next_pc(),
        .ifid_pred_taken(),.ifid_pred_hit(),.ifid_fetch_error(if_error),.ifid_fetch_tval(),
        .ifid_seq(seq),.ifid_epoch(epoch),.imem_req_valid(req_valid),.imem_req_ready(1'b1),
        .imem_req_addr(req_addr),.imem_rsp_valid(rsp_valid),.imem_rsp_ready(rsp_ready),
        .imem_rsp_rdata(32'h00000013),.imem_rsp_error(rsp_error),.bp_commit_valid(1'b0),
        .bp_commit_ready(),.bp_commit_seq(64'd0),.bp_commit_pc(32'd0),.bp_commit_target(32'd0),
        .bp_commit_taken(1'b0),.bp_commit_is_branch(1'b0),.bp_commit_is_jal(1'b0),
        .bp_update_fire(),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .imem_fault(sticky),.imem_fault_pc());
    // The shared IF default retains CPU3's same-cycle redirect bypass.
    if_stage #(.EXTERNAL_IMEM(1),.ENABLE_TRAPS(1),.IMEM_WORDS(8192)) legacy(
        .clk(clk),.rst_n(rst_n),.redirect_x(redirect),.redirect_pc_x(target),.stall_x(1'b0),
        .pc_f(),.pc_x(),.instr_x(),.valid_x(),.imem_req_valid(legacy_req),.imem_req_ready(1'b1),
        .imem_req_addr(legacy_addr),.imem_rsp_valid(rsp_valid),.imem_rsp_ready(),
        .imem_rsp_rdata(32'h00000013),.imem_rsp_error(rsp_error),.imem_fault(),.imem_fault_pc(),
        .bp_update_valid(1'b0),.bp_update_pc(32'd0),.bp_update_target(32'd0),
        .bp_update_taken(1'b0),.bp_update_is_branch(1'b0),.bp_update_is_jal(1'b0),
        .predicted_next_pc_x(),.prediction_taken_x(),.prediction_hit_x(),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count());
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    task ck(input bit ok,input string message);begin checks++;if(!ok)$fatal(1,"%s",message);end endtask
    initial begin
        tick();tick();rst_n=1;#1;ck(req_valid&&req_addr==0,"boot request");
        tick();
        redirect=1;target=32'h80;rsp_valid=1;rsp_error=1;#1;
        ck(!req_valid&&req_addr==4,"CPU5 redirect target cannot drive an I-cache tag in the same cycle");
        ck(legacy_req&&legacy_addr==32'h80,"CPU3 default redirect bypass preserved");
        ck(rsp_ready,"old response drains on redirect");
        tick();redirect=0;rsp_valid=0;rsp_error=0;#1;
        ck(!if_valid&&!sticky&&req_valid&&req_addr==32'h80,"redirect registered, stale fault discarded");
        tick();rsp_valid=1;#1;ck(rsp_ready,"target response owned");
        tick();rsp_valid=0;#1;
        ck(if_valid&&!if_error&&if_pc==32'h80&&seq==0&&epoch==1,"target instruction delivered once in new epoch");
        rsp_valid=1;rsp_error=1;tick();rsp_valid=0;#1;
        ck(if_valid&&if_error&&if_pc==32'h84&&seq==1&&sticky,"current-path fetch fault remains ordered");
        redirect=1;target=32'h100;#1;
        ck(!req_valid&&req_addr==32'h88,"sticky fault recovery also uses registered address");
        tick();redirect=0;rsp_error=0;#1;
        ck(!if_valid&&!sticky&&req_valid&&req_addr==32'h100,"fault cleared and target request follows redirect");
        tick();rsp_valid=1;tick();rsp_valid=0;#1;
        ck(if_valid&&!if_error&&if_pc==32'h100&&seq==2&&epoch==2,"fault recovery ownership and non-wrapping age");
        test_pass=1;$display("CPU5 REGISTERED REDIRECT PASS checks=%0d",checks);$stop;
    end
    initial begin #5000;$fatal(1,"registered redirect watchdog");end
endmodule

