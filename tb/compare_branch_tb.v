`timescale 1ns/1ps

module compare_branch_tb;
    reg clk, rst_n;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;

    localparam integer BRANCHES = 22;
    reg [31:0] exp_pc [0:BRANCHES-1];
    reg [31:0] exp_instr [0:BRANCHES-1];
    reg [31:0] exp_a [0:BRANCHES-1];
    reg [31:0] exp_b [0:BRANCHES-1];
    reg [31:0] exp_imm [0:BRANCHES-1];
    reg [1:0] exp_fwd [0:BRANCHES-1];
    reg exp_taken [0:BRANCHES-1];
    integer warm, cycles, seen;
    reg expect_bubble, prev_no_write;
    reg [31:0] bubble_pc;

    cpu_top dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .pc_x(pc_x), .instr_x(instr_x),
        .valid_x(valid_x), .wb_pc(wb_pc), .wb_rd(wb_rd),
        .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count(), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx(),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval()
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task branch_case;
        input integer n;
        input [31:0] pc, insn, a, b, imm;
        input taken;
        input [1:0] fwd;
        begin
            exp_pc[n] = pc;
            exp_instr[n] = insn;
            exp_a[n] = a;
            exp_b[n] = b;
            exp_imm[n] = imm;
            exp_taken[n] = taken;
            exp_fwd[n] = fwd;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        // -1 versus +1 distinguishes signed from unsigned comparison.
        branch_case( 0, 508, 32'h0020c463, 32'hffffffff, 1, 8, 1, 2'b01);
        branch_case( 1, 516, 32'h0020d463, 32'hffffffff, 1, 8, 0, 2'b00);
        branch_case( 2, 524, 32'h0020e463, 32'hffffffff, 1, 8, 0, 2'b00);
        branch_case( 3, 532, 32'h0020f463, 32'hffffffff, 1, 8, 1, 2'b00);

        // Zero versus -1 checks the opposite operand order and rs1 forwarding.
        branch_case( 4, 548, 32'h0063c463, 32'hffffffff, 0, 8, 1, 2'b10);
        branch_case( 5, 556, 32'h00735463, 0, 32'hffffffff, 8, 1, 2'b00);
        branch_case( 6, 564, 32'h00736463, 0, 32'hffffffff, 8, 1, 2'b00);
        branch_case( 7, 572, 32'h00737463, 0, 32'hffffffff, 8, 0, 2'b00);

        // Backward signed BLT loop: 1<3, 2<3, 3<3.
        branch_case( 8, 592, 32'hfe954ee3, 1, 3, 32'hfffffffc, 1, 2'b10);
        branch_case( 9, 592, 32'hfe954ee3, 2, 3, 32'hfffffffc, 1, 2'b10);
        branch_case(10, 592, 32'hfe954ee3, 3, 3, 32'hfffffffc, 0, 2'b10);
        branch_case(11, 596, 32'h00955463, 3, 3, 8, 1, 2'b00);
        branch_case(12, 604, 32'h00956463, 3, 3, 8, 0, 2'b00);
        branch_case(13, 608, 32'h00957463, 3, 3, 8, 1, 2'b00);
        branch_case(14, 620, 32'h00a4c463, 3, 3, 8, 0, 2'b00);
        branch_case(15, 624, 32'h00a4e463, 3, 3, 8, 0, 2'b00);
        branch_case(16, 628, 32'h00a4d463, 3, 3, 8, 1, 2'b00);
        branch_case(17, 636, 32'h00a4f463, 3, 3, 8, 1, 2'b00);

        // INT_MIN versus INT_MAX checks the sign boundary and rs2 forwarding.
        branch_case(18, 660, 32'h00e6c463, 32'h80000000,
                    32'h7fffffff, 8, 1, 2'b01);
        branch_case(19, 668, 32'h00e6e463, 32'h80000000,
                    32'h7fffffff, 8, 0, 2'b00);
        branch_case(20, 676, 32'h00e6f463, 32'h80000000,
                    32'h7fffffff, 8, 1, 2'b00);
        branch_case(21, 684, 32'h00e6d463, 32'h80000000,
                    32'h7fffffff, 8, 0, 2'b00);

        #11;
        rst_n = 1'b1;
        warm = 0;
        while ((pc_x !== 32'd500 || valid_x !== 1'b1) && warm < 180) begin
            tick;
            warm = warm + 1;
        end
        if (warm == 180) $fatal(1, "Comparison-branch program not reached");

        cycles = 0;
        seen = 0;
        expect_bubble = 1'b0;
        prev_no_write = 1'b0;
        while ((pc_x !== 32'd692 || valid_x !== 1'b1) && cycles < 100) begin
            if (prev_no_write && wb_we !== 1'b0)
                $fatal(1, "Branch or bubble wrote a register at PC=%0d", wb_pc);
            if (expect_bubble) begin
                if (pc_x !== bubble_pc || valid_x !== 1'b0 ||
                    instr_x !== 32'h00000013)
                    $fatal(1, "Taken branch did not squash PC=%0d", bubble_pc);
            end
            if (wb_we && (wb_pc == 512 || wb_pc == 536 || wb_pc == 552 ||
                          wb_pc == 560 || wb_pc == 568 || wb_pc == 600 ||
                          wb_pc == 612 || wb_pc == 632 || wb_pc == 640 ||
                          wb_pc == 664 || wb_pc == 680))
                $fatal(1, "Poison instruction committed at PC=%0d", wb_pc);

            expect_bubble = 1'b0;
            prev_no_write = !valid_x;
            if (valid_x && instr_x[6:0] == 7'b1100011) begin
                if (seen >= BRANCHES || pc_x !== exp_pc[seen] ||
                    instr_x !== exp_instr[seen] ||
                    dut.branch_taken_x !== exp_taken[seen] ||
                    dut.imm_b_x !== exp_imm[seen] ||
                    dut.branch_target_x !== pc_x + exp_imm[seen] ||
                    dut.rs1_value_x !== exp_a[seen] ||
                    dut.rs2_value_x !== exp_b[seen] ||
                    {dut.forward_rs1_x,dut.forward_rs2_x} !== exp_fwd[seen] ||
                    dut.writes_rd_x !== 1'b0) begin
                    $display("FAIL branch=%0d pc=%h instr=%h a=%h b=%h taken=%b fwd=%b%b",
                             seen, pc_x, instr_x, dut.rs1_value_x,
                             dut.rs2_value_x, dut.branch_taken_x,
                             dut.forward_rs1_x, dut.forward_rs2_x);
                    $fatal(1, "Comparison branch mismatch");
                end
                prev_no_write = 1'b1;
                if (exp_taken[seen]) begin
                    expect_bubble = 1'b1;
                    bubble_pc = pc_x + 32'd4;
                end
                seen = seen + 1;
            end
            tick;
            cycles = cycles + 1;
        end
        if (cycles == 100 || seen != BRANCHES)
            $fatal(1, "Comparison branch trace ended early: seen=%0d", seen);
        tick;
        tick;
        if (dut.u_regfile.regs[1] !== 32'hffffffff ||
            dut.u_regfile.regs[2] !== 1 ||
            dut.u_regfile.regs[3] !== 7 ||
            dut.u_regfile.regs[4] !== 8 ||
            dut.u_regfile.regs[6] !== 0 ||
            dut.u_regfile.regs[7] !== 32'hffffffff ||
            dut.u_regfile.regs[8] !== 1 ||
            dut.u_regfile.regs[9] !== 3 ||
            dut.u_regfile.regs[10] !== 3 ||
            dut.u_regfile.regs[11] !== 42 ||
            dut.u_regfile.regs[12] !== 11 ||
            dut.u_regfile.regs[13] !== 32'h80000000 ||
            dut.u_regfile.regs[14] !== 32'h7fffffff ||
            dut.u_regfile.regs[15] !== 12 ||
            dut.u_regfile.regs[16] !== 0 ||
            dut.u_regfile.regs[18] !== 13 ||
            dut.u_regfile.regs[19] !== 1 ||
            dut.u_regfile.regs[20] !== 1 ||
            dut.u_regfile.regs[24] !== 32)
            $fatal(1, "Comparison branch final register mismatch");

        $display("PASS: BLT/BGE/BLTU/BGEU signed/unsigned, equality, forwarding, backward loop and squash");
        $display("PASS: %0d comparison branch decisions checked", seen);
        $stop;
    end

    initial begin
        #2500;
        $fatal(1, "Comparison branch test timeout");
    end
endmodule
