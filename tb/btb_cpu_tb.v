`timescale 1ns/1ps

// Future regression: the same instruction stream is checked with prediction
// disabled/enabled and with local/external delayed instruction responses.
// This source has been prepared only, not executed in the current step.
module btb_cpu_tb;
    wire [4:0] done;
    reg test_pass = 0;
    btb_cpu_case #(.CASE_ID(0), .PRED(0), .MODE(0)) local_off(done[0]);
    btb_cpu_case #(.CASE_ID(1), .PRED(1), .MODE(0)) local_on(done[1]);
    btb_cpu_case #(.CASE_ID(2), .PRED(0), .MODE(1)) external_off(done[2]);
    btb_cpu_case #(.CASE_ID(3), .PRED(1), .MODE(1)) external_on(done[3]);
    btb_cpu_case #(.CASE_ID(4), .PRED(1), .MODE(2)) external_random(done[4]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("BTB CPU PASS: exact retire trace, six branches, loop direction changes, JAL/JALR and once-only stores across off/on and delayed buses");
        $stop;
    end
    initial begin
        #1000000;
        $fatal(1, "BTB CPU timeout done=%b", done);
    end
endmodule

module btb_cpu_case #(
    parameter integer CASE_ID = 0,
    parameter integer PRED = 1,
    parameter integer MODE = 0
) (output reg done = 0);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [31:0] rom [0:255];
    reg [31:0] expected_pc [0:255];
    reg [31:0] random_q = 32'h39179a65 ^ CASE_ID;
    reg active = 0, rsp_valid = 0;
    reg [31:0] rsp_data = 0;
    integer delay_left = 0;
    wire req_valid, rsp_ready;
    wire [31:0] req_addr;
    wire response_fire = rsp_valid && rsp_ready;
    wire ready_slot = !active || response_fire;
    wire req_ready = rst_n && ready_slot && (MODE != 2 || random_q[0]);
    wire retire_valid, wb_we, imem_fault, dmem_fault, trap_valid;
    wire [31:0] wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire [7:0] gpio_out, gpio_oe;
    integer cursor = 0, expected_count = 0, retired_count = 0;
    integer ram_stores = 0, gpio_stores = 0, completed = 0;
    integer blocked_requests = 0, data_holds = 0, redirects = 0;
    integer outer, inner, k, terminal_pc, call_pc;
    integer inner_init_pc, loop_store_pc, loop_add_pc, loop_branch_pc;
    integer outer_add_pc, outer_branch_pc;
    reg held_req = 0, held_rsp = 0;
    reg [31:0] held_addr = 0, held_data = 0;
    reg [31:0] ex_snapshot_pc = 0, ex_snapshot_prediction = 0;
    reg ex_held = 0;

    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
              .IMEM_WORDS(256), .DMEM_WORDS(64), .DMEM_BASE_ADDR(0),
              .SIM_CONSOLE_ECHO(0), .ENABLE_TRAPS(1), .ENABLE_BRANCH_PRED(PRED),
              .EXTERNAL_IMEM(MODE != 0),
              .DMEM_REQ_WAIT_CYCLES(2), .DMEM_RSP_WAIT_CYCLES(6)) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(), .instr_x(), .valid_x(),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(), .instret_count(),
        .uart_rx(1'b1), .uart_tx(), .gpio_in(8'd0), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(dmem_fault),
        .imem_req_valid(req_valid), .imem_req_ready(req_ready), .imem_req_addr(req_addr),
        .imem_rsp_valid(rsp_valid), .imem_rsp_ready(rsp_ready),
        .imem_rsp_rdata(rsp_data), .imem_rsp_error(1'b0),
        .imem_fault(imem_fault), .imem_fault_pc(), .trap_valid(trap_valid),
        .trap_pc(), .trap_cause(), .trap_tval()
    );
    function [31:0] addi;
        input integer imm; input [4:0] rs1, rd;
        begin addi = {imm[11:0], rs1, 3'b000, rd, 7'h13}; end
    endfunction
    function [31:0] store;
        input integer imm; input [4:0] rs2, rs1;
        begin store = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'h23}; end
    endfunction
    function [31:0] branch;
        input integer offset; input [4:0] rs2, rs1; input [2:0] kind;
        begin branch = {offset[12],offset[10:5],rs2,rs1,kind,offset[4:1],offset[11],7'h63}; end
    endfunction
    function [31:0] jal;
        input integer offset; input [4:0] rd;
        begin jal = {offset[20],offset[10:1],offset[11],offset[19:12],rd,7'h6f}; end
    endfunction
    function [31:0] jalr;
        input integer imm; input [4:0] rs1, rd;
        begin jalr = {imm[11:0],rs1,3'b000,rd,7'h67}; end
    endfunction
    task expected;
        input integer pc;
        begin expected_pc[expected_count] = pc; expected_count = expected_count + 1; end
    endtask
    task emit;
        input [31:0] instruction; input executed;
        begin
            rom[cursor] = instruction;
            if (executed) expected(cursor * 4);
            cursor = cursor + 1;
        end
    endtask
    task branch_case;
        input [2:0] kind; input [4:0] rs1, rs2; input taken;
        begin
            emit(branch(12,rs2,rs1,kind),1);
            if (taken) begin
                emit(store(8,5,1),0); // forbidden wrong-path memory effects
                emit(store(52,5,10),0); // forbidden wrong-path GPIO effects
            end else begin
                emit(addi(1,11,11),1);
                emit(32'h00000013,1);
            end
            emit(32'h00000013,1);
        end
    endtask
    initial begin
        #1;
        for (k=0;k<256;k=k+1) rom[k] = 32'h00000013;
        for (k=0;k<64;k=k+1) dut.u_data_mem.mem[k] = 0;
        emit(addi(0,0,1),1);
        emit(addi(4,0,2),1);
        emit(addi(-1,0,4),1);
        emit(addi(1,0,5),1);
        emit({20'h20000,5'd10,7'h37},1);
        emit(addi(0,0,11),1);
        branch_case(3'b000,5,5,1); // BEQ
        branch_case(3'b001,5,4,1); // BNE
        branch_case(3'b100,4,5,1); // BLT signed
        branch_case(3'b101,5,4,1); // BGE signed
        branch_case(3'b110,5,4,1); // BLTU
        branch_case(3'b111,4,5,1); // BGEU
        branch_case(3'b000,5,4,0);
        branch_case(3'b001,5,5,0);
        branch_case(3'b100,5,4,0);
        branch_case(3'b101,4,5,0);
        branch_case(3'b110,4,5,0);
        branch_case(3'b111,5,4,0);
        emit(addi(2,0,6),1);
        inner_init_pc = cursor * 4; emit(addi(0,0,3),0);
        loop_store_pc = cursor * 4; emit(store(0,3,1),0);
        loop_add_pc = cursor * 4; emit(addi(1,3,3),0);
        loop_branch_pc = cursor * 4; emit(branch(loop_store_pc-loop_branch_pc,2,3,3'b001),0);
        outer_add_pc = cursor * 4; emit(addi(-1,6,6),0);
        outer_branch_pc = cursor * 4; emit(branch(inner_init_pc-outer_branch_pc,0,6,3'b001),0);
        for (outer=0;outer<2;outer=outer+1) begin
            expected(inner_init_pc);
            for (inner=0;inner<4;inner=inner+1) begin
                expected(loop_store_pc); expected(loop_add_pc); expected(loop_branch_pc);
            end
            expected(outer_add_pc); expected(outer_branch_pc);
        end
        call_pc = cursor * 4;
        emit(jal(12,7),1);
        emit(store(8,5,1),0);
        emit(store(52,5,10),0);
        emit(addi(99,0,9),1);
        emit(jalr(20,7,8),1); // link x8=call_pc+20; target call_pc+24
        emit(store(8,5,1),0);
        emit(store(4,3,1),1);
        emit(addi(7,0,12),1);
        emit(store(32,12,10),1);
        emit(store(40,12,10),1);
        terminal_pc = cursor * 4; emit(addi(77,0,13),1);
        emit(jal(0,0),0);
        for (k=0;k<256;k=k+1) dut.u_if_stage.u_instr_mem.mem[k] = rom[k];
        repeat(3) @(negedge clk); rst_n = 1;
    end

    // A single-outstanding external ROM permits response/request overlap,
    // holds its response under data stalls and varies latency independently.
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 0; rsp_valid <= 0; rsp_data <= 0; delay_left <= 0;
            random_q <= 32'h39179a65 ^ CASE_ID;
        end else if (MODE != 0) begin
            random_q <= {random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
            if (response_fire) begin active <= 0; rsp_valid <= 0; end
            if (req_valid && req_ready) begin
                if (req_addr[1:0] || req_addr >= 1024) $fatal(1,"BTB case %0d invalid request %h",CASE_ID,req_addr);
                active <= 1; rsp_valid <= 0;
                rsp_data <= rom[req_addr >> 2];
                delay_left <= (MODE == 2) ? 1 + random_q[4:2] : 3;
            end else if (active && !rsp_valid) begin
                if (delay_left <= 1) rsp_valid <= 1;
                else delay_left <= delay_left - 1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            retired_count = 0; ram_stores = 0; gpio_stores = 0;
            held_req = 0; held_rsp = 0; ex_held = 0;
            redirects = 0; blocked_requests = 0; data_holds = 0;
        end else if (!done) begin
            if (MODE != 0) begin
                if (held_req && (!req_valid || req_addr !== held_addr))
                    $fatal(1,"BTB case %0d withdrew or changed held request",CASE_ID);
                held_req = req_valid && !req_ready;
                if (held_req) begin held_addr = req_addr; blocked_requests = blocked_requests + 1; end
                if (held_rsp && (!rsp_valid || rsp_data !== held_data))
                    $fatal(1,"BTB case %0d changed held ROM response",CASE_ID);
                held_rsp = rsp_valid && !rsp_ready;
                if (held_rsp) begin held_data = rsp_data; data_holds = data_holds + 1; end
            end
            if (ex_held && !dut.redirect_x &&
                (dut.pc_x !== ex_snapshot_pc || dut.predicted_next_pc_x !== ex_snapshot_prediction))
                $fatal(1,"BTB case %0d changed EX prediction while data instruction stalled",CASE_ID);
            ex_held = dut.valid_x && dut.stall_x && !dut.redirect_x;
            ex_snapshot_pc = dut.pc_x; ex_snapshot_prediction = dut.predicted_next_pc_x;
            if (dut.redirect_x) redirects = redirects + 1;
            if (dut.mem_req_fire && dut.mem_req_write) begin
                if (dut.dmem_req_addr == 0 || dut.dmem_req_addr == 4) ram_stores = ram_stores + 1;
                else if (dut.dmem_req_addr == 32'h20000020 || dut.dmem_req_addr == 32'h20000028)
                    gpio_stores = gpio_stores + 1;
                else $fatal(1,"BTB case %0d wrong-path store addr=%h",CASE_ID,dut.dmem_req_addr);
            end
            if (imem_fault || dmem_fault || trap_valid)
                $fatal(1,"BTB case %0d unexpected fault/trap",CASE_ID);
        end
        #1;
        if (rst_n && !done && retire_valid) begin
            if (retired_count >= expected_count || wb_pc !== expected_pc[retired_count])
                $fatal(1,"BTB case %0d retire index=%0d expected=%h actual=%h",CASE_ID,retired_count,expected_pc[retired_count],wb_pc);
            if (wb_pc == call_pc && (!wb_we || wb_rd != 7 || wb_data !== call_pc+4))
                $fatal(1,"BTB JAL link mismatch");
            if (wb_pc == call_pc+16 && (!wb_we || wb_rd != 8 || wb_data !== call_pc+20))
                $fatal(1,"BTB JALR link mismatch");
            retired_count = retired_count + 1;
            if (wb_pc == terminal_pc) begin
                if (!wb_we || wb_rd != 13 || wb_data !== 77 || retired_count != expected_count)
                    $fatal(1,"BTB case %0d completion mismatch",CASE_ID);
                if (ram_stores != 9 || gpio_stores != 2 ||
                    dut.u_data_mem.mem[0] !== 3 || dut.u_data_mem.mem[1] !== 4 || dut.u_data_mem.mem[2] !== 0 ||
                    gpio_out !== 7 || gpio_oe !== 7)
                    $fatal(1,"BTB case %0d duplicate/wrong store effects RAM=%0d GPIO=%0d",CASE_ID,ram_stores,gpio_stores);
                if (PRED && (dut.u_if_stage.bp_hit_count == 0 || dut.u_if_stage.bp_taken_count == 0))
                    $fatal(1,"BTB case %0d did not exercise trained prediction",CASE_ID);
                if (!PRED && (dut.u_if_stage.bp_lookup_count || dut.u_if_stage.bp_hit_count || dut.u_if_stage.bp_taken_count))
                    $fatal(1,"BTB disabled case emitted prediction counters");
                $display("BTB CPU case %0d PASS: retired=%0d RAM/GPIO stores=%0d/%0d redirects=%0d held req/rsp=%0d/%0d",CASE_ID,retired_count,ram_stores,gpio_stores,redirects,blocked_requests,data_holds);
                done = 1;
            end
        end
    end
endmodule
