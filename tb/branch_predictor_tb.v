`timescale 1ns/1ps

// Future directed checks. Prepared only; this step has not been simulated.
module branch_predictor_tb;
    wire [1:0] done;
    reg test_pass = 0;
    btb_predictor_unit_case unit_case(done[0]);
    btb_frontend_metadata_case frontend_case(done[1]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("BTB UNIT PASS: saturation, full tags, JAL, stale invalidation, held-request metadata, stale errors and reset");
        $stop;
    end
    initial begin
        #100000;
        $fatal(1, "BTB unit timeout done=%b", done);
    end
endmodule

module btb_predictor_unit_case(output reg done = 0);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] query_pc = 0, update_pc = 0, update_target = 0;
    reg update_valid = 0, update_taken = 0;
    reg update_is_branch = 0, update_is_jal = 0;
    wire hit, taken;
    wire [31:0] target;
    branch_predictor #(.BTB_ENTRIES(64)) dut (
        .clk(clk), .rst_n(rst_n), .query_pc(query_pc),
        .lookup_hit(hit), .lookup_taken(taken), .lookup_target(target),
        .update_valid(update_valid), .update_pc(update_pc),
        .update_target(update_target), .update_taken(update_taken),
        .update_is_branch(update_is_branch), .update_is_jal(update_is_jal)
    );
    task train;
        input [31:0] pc, destination;
        input outcome, conditional_branch, jal;
        begin
            @(negedge clk);
            update_pc = pc; update_target = destination;
            update_taken = outcome; update_is_branch = conditional_branch;
            update_is_jal = jal; update_valid = 1;
            @(negedge clk); update_valid = 0;
        end
    endtask
    task check;
        input [31:0] pc, destination;
        input expected_hit, expected_taken;
        begin
            query_pc = pc; #1;
            if (hit !== expected_hit || taken !== expected_taken || target !== destination)
                $fatal(1, "BTB lookup pc=%h hit=%b taken=%b target=%h expected=%b/%b/%h",
                       pc, hit, taken, target, expected_hit, expected_taken, destination);
        end
    endtask
    initial begin
        repeat (2) @(negedge clk); rst_n = 1;
        check(32'h100, 32'h104, 0, 0);
        train(32'h100, 32'h200, 1, 1, 0); // new => weakly taken (10)
        check(32'h100, 32'h200, 1, 1);
        train(32'h100, 32'h200, 1, 1, 0); // 11
        train(32'h100, 32'h200, 1, 1, 0); // saturated 11
        train(32'h100, 32'h200, 0, 1, 0); // 10
        check(32'h100, 32'h200, 1, 1);
        train(32'h100, 32'h200, 0, 1, 0); // 01
        check(32'h100, 32'h200, 1, 0);
        train(32'h100, 32'h200, 0, 1, 0); // 00
        train(32'h100, 32'h200, 0, 1, 0); // saturated 00
        train(32'h100, 32'h200, 1, 1, 0); // 01
        check(32'h100, 32'h200, 1, 0);
        train(32'h100, 32'h240, 1, 1, 0); // 10, target replaced
        check(32'h100, 32'h240, 1, 1);

        // Full tags distinguish PCs that alias the same 64-entry index.
        check(32'h200, 32'h204, 0, 0);
        train(32'h200, 32'h300, 0, 1, 0);
        check(32'h100, 32'h104, 0, 0);
        check(32'h200, 32'h300, 1, 0);
        train(32'h100, 0, 0, 0, 0); // ordinary aliased PC cannot evict PC 200
        check(32'h200, 32'h300, 1, 0);
        train(32'h200, 32'h400, 1, 0, 1);
        check(32'h200, 32'h400, 1, 1);
        train(32'h200, 32'h440, 0, 1, 0); // JAL -> branch restarts at 01
        check(32'h200, 32'h440, 1, 0);
        train(32'h200, 0, 0, 0, 0); // same-PC ordinary/JALR invalidation
        check(32'h200, 32'h204, 0, 0);
        train(32'h100, 32'h202, 1, 1, 0);
        check(32'h100, 32'h104, 0, 0); // no misaligned target prediction
        train(32'h102, 32'h300, 1, 0, 1);
        check(32'h102, 32'h106, 0, 0); // misaligned update/query rejected
        train(32'h104, 32'h300, 1, 0, 1);
        check(32'h104, 32'h300, 1, 1);
        @(negedge clk); rst_n = 0;
        @(negedge clk); rst_n = 1;
        check(32'h104, 32'h108, 0, 0);
        done = 1;
    end
endmodule

module btb_frontend_metadata_case(output reg done = 0);
    reg clk = 0, rst_n = 0, stall = 1, redirect = 0;
    always #5 clk = ~clk;
    reg [31:0] redirect_pc = 0;
    reg update_valid = 0;
    reg [31:0] update_pc = 0, update_target = 0;
    reg req_ready = 0, rsp_valid = 0, rsp_error = 0;
    reg [31:0] rsp_data = 32'h00000013;
    wire req_valid, rsp_ready, valid_x, fault;
    wire [31:0] req_addr, pc_f, pc_x, pred_next, instr_x, fault_pc;
    wire pred_taken, pred_hit;
    wire [31:0] lookups, hits, takens;
    if_stage #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
               .IMEM_WORDS(256), .EXTERNAL_IMEM(1),
               .ENABLE_TRAPS(1), .ENABLE_BRANCH_PRED(1)) dut (
        .clk(clk), .rst_n(rst_n), .redirect_x(redirect), .redirect_pc_x(redirect_pc),
        .stall_x(stall), .bp_update_valid(update_valid), .bp_update_pc(update_pc),
        .bp_update_target(update_target), .bp_update_taken(1'b1),
        .bp_update_is_branch(1'b0), .bp_update_is_jal(1'b1),
        .pc_f(pc_f), .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .predicted_next_pc_x(pred_next), .prediction_taken_x(pred_taken),
        .prediction_hit_x(pred_hit), .bp_lookup_count(lookups),
        .bp_hit_count(hits), .bp_taken_count(takens),
        .imem_req_valid(req_valid), .imem_req_ready(req_ready), .imem_req_addr(req_addr),
        .imem_rsp_valid(rsp_valid), .imem_rsp_ready(rsp_ready),
        .imem_rsp_rdata(rsp_data), .imem_rsp_error(rsp_error),
        .imem_fault(fault), .imem_fault_pc(fault_pc)
    );
    task train_jal;
        input [31:0] pc, target;
        begin
            @(negedge clk); update_valid = 1; update_pc = pc; update_target = target;
            @(negedge clk); update_valid = 0;
        end
    endtask
    task accept;
        input [31:0] address;
        begin
            wait(req_valid);
            @(negedge clk);
            if (req_addr !== address) $fatal(1, "BTB frontend wanted request %h, got %h", address, req_addr);
            req_ready = 1;
            @(negedge clk); req_ready = 0;
        end
    endtask
    initial begin
        repeat (2) @(negedge clk); rst_n = 1;
        train_jal(0, 64);
        @(negedge clk); stall = 0;
        wait(req_valid); repeat(2) @(negedge clk);
        // Change the BTB while the request is held: metadata stays at 64.
        train_jal(0, 96);
        if (req_addr !== 0 || !req_valid) $fatal(1, "Held PC 0 request changed");
        accept(0);
        if (pc_f !== 64) $fatal(1, "Held request used fresh predictor result instead of snapshot");
        @(negedge clk); rsp_valid = 1;
        @(negedge clk); rsp_valid = 0; stall = 1;
        if (!valid_x || pc_x !== 0 || pred_next !== 64 || !pred_hit || !pred_taken)
            $fatal(1, "EX prediction metadata does not match accepted PC 0");
        repeat(3) @(negedge clk);
        if (!valid_x || pc_x !== 0 || pred_next !== 64)
            $fatal(1, "EX prediction metadata changed under stall");
        if (!req_valid || req_addr !== 64) $fatal(1, "Expected held old-path request");
        @(negedge clk); redirect = 1; redirect_pc = 128;
        @(negedge clk); redirect = 0;
        train_jal(128, 192);
        if (!req_valid || req_addr !== 64 || valid_x)
            $fatal(1, "Redirect withdrew held request or retained EX");
        accept(64);
        @(negedge clk); rsp_valid = 1; rsp_error = 1;
        @(negedge clk); rsp_valid = 0; rsp_error = 0;
        if (fault || valid_x) $fatal(1, "Stale response error became a fault or EX instruction");
        @(negedge clk); stall = 0;
        accept(128);
        if (pc_f !== 192) $fatal(1, "Redirect target was not predicted using its own PC tag");
        @(negedge clk); rsp_valid = 1;
        @(negedge clk); rsp_valid = 0; stall = 1;
        if (!valid_x || pc_x !== 128 || pred_next !== 192 || !pred_hit || !pred_taken)
            $fatal(1, "Redirect target EX prediction mismatch");
        if (lookups !== 2 || hits !== 2 || takens !== 2)
            $fatal(1, "Held/stale requests inflated predictor counters %0d/%0d/%0d", lookups, hits, takens);
        @(negedge clk); rst_n = 0;
        @(negedge clk);
        if (req_valid || rsp_ready || valid_x || fault || lookups || hits || takens)
            $fatal(1, "Frontend/predictor reset did not clear transaction and counters");
        done = 1;
    end
endmodule
