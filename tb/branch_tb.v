`timescale 1ns/1ps

module branch_tb;
    reg clk;
    reg rst_n;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire valid_x, wb_we;
    wire [4:0] wb_rd;

    localparam integer STEPS = 31;
    reg [31:0] exp_pc [0:STEPS-1];
    reg [31:0] exp_instr [0:STEPS-1];
    reg exp_valid [0:STEPS-1];
    reg exp_taken [0:STEPS-1];
    reg [1:0] exp_fwd [0:STEPS-1];
    reg [31:0] exp_imm [0:STEPS-1];
    integer i;

    cpu_top dut (
        .clk(clk), .rst_n(rst_n), .pc_x(pc_x), .instr_x(instr_x),
        .valid_x(valid_x), .wb_pc(wb_pc), .wb_rd(wb_rd),
        .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(), .cycle_count(), .instret_count()
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task step;
        input integer n;
        input [31:0] pc;
        input [31:0] insn;
        input valid;
        input taken;
        input [1:0] fwd;
        input [31:0] branch_imm;
        begin
            exp_pc[n] = pc;
            exp_instr[n] = insn;
            exp_valid[n] = valid;
            exp_taken[n] = taken;
            exp_fwd[n] = fwd;
            exp_imm[n] = branch_imm;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #1;
        if (valid_x !== 1'b0 || pc_x !== 32'd0)
            $fatal(1, "Branch test reset mismatch");

        // Expected EX trace includes a bubble after every taken branch.
        step( 0, 308, 32'h00300713, 1, 0, 2'b00, 0); // x14 = 3
        step( 1, 312, 32'h00300793, 1, 0, 2'b00, 0); // x15 = 3
        step( 2, 316, 32'h00f70463, 1, 1, 2'b01, 8); // BEQ, rs2 forwarded
        step( 3, 320, 32'h00000013, 0, 0, 2'b00, 0); // squash x16 = 99
        step( 4, 324, 32'h00100893, 1, 0, 2'b00, 0);
        step( 5, 328, 32'h00f71463, 1, 0, 2'b00, 8); // BNE not taken
        step( 6, 332, 32'h00200913, 1, 0, 2'b00, 0);
        step( 7, 336, 32'h00400793, 1, 0, 2'b00, 0); // x15 = 4
        step( 8, 340, 32'h00f71463, 1, 1, 2'b01, 8); // BNE, rs2 forwarded
        step( 9, 344, 32'h00000013, 0, 0, 2'b00, 0); // squash x19 = 99
        step(10, 348, 32'h00100a13, 1, 0, 2'b00, 0);
        step(11, 352, 32'h00f70463, 1, 0, 2'b00, 8); // BEQ not taken
        step(12, 356, 32'h00500a93, 1, 0, 2'b00, 0);
        step(13, 360, 32'h00300b93, 1, 0, 2'b00, 0); // x23 = 3
        step(14, 364, 32'h00000b13, 1, 0, 2'b00, 0); // x22 = 0
        step(15, 368, 32'h001b0b13, 1, 0, 2'b00, 0); // x22 = 1
        step(16, 372, 32'hff7b1ee3, 1, 1, 2'b10, 32'hfffffffc);
        step(17, 376, 32'h00000013, 0, 0, 2'b00, 0);
        step(18, 368, 32'h001b0b13, 1, 0, 2'b00, 0); // x22 = 2
        step(19, 372, 32'hff7b1ee3, 1, 1, 2'b10, 32'hfffffffc);
        step(20, 376, 32'h00000013, 0, 0, 2'b00, 0);
        step(21, 368, 32'h001b0b13, 1, 0, 2'b00, 0); // x22 = 3
        step(22, 372, 32'hff7b1ee3, 1, 0, 2'b10, 32'hfffffffc);
        step(23, 376, 32'h017b0463, 1, 1, 2'b00, 8); // BEQ taken
        step(24, 380, 32'h00000013, 0, 0, 2'b00, 0); // squash x24 = 99
        step(25, 384, 32'h00fb0d33, 1, 0, 2'b00, 0); // x26 = 3 + 4
        step(26, 388, 32'h00900d93, 1, 0, 2'b00, 0); // x27 = 9
        step(27, 392, 32'h01bd8463, 1, 1, 2'b11, 8); // both sources forwarded
        step(28, 396, 32'h00000013, 0, 0, 2'b00, 0); // squash x29 = 99
        step(29, 400, 32'h01bd9463, 1, 0, 2'b00, 8); // BNE not taken
        step(30, 404, 32'h00700e13, 1, 0, 2'b00, 0); // x28 = 7

        #11;
        rst_n = 1'b1;
        // Keep the original 77-instruction ROM regression intact.
        for (i=0; i<77; i=i+1) begin
            tick;
            if (valid_x !== 1'b1 || pc_x !== i*4)
                $fatal(1, "Legacy fetch changed at i=%0d", i);
        end

        for (i=0; i<STEPS; i=i+1) begin
            tick;
            if (pc_x !== exp_pc[i] || instr_x !== exp_instr[i] ||
                valid_x !== exp_valid[i] ||
                dut.branch_taken_x !== exp_taken[i]) begin
                $display("FAIL: step=%0d pc=%h instr=%h valid=%b taken=%b",
                         i, pc_x, instr_x, valid_x, dut.branch_taken_x);
                $fatal(1, "Branch EX trace mismatch");
            end
            if (exp_valid[i] && exp_instr[i][6:0] == 7'b1100011) begin
                if ({dut.forward_rs1_x,dut.forward_rs2_x} !== exp_fwd[i] ||
                    dut.imm_b_x !== exp_imm[i] ||
                    dut.branch_target_x !== exp_pc[i] + exp_imm[i] ||
                    dut.writes_rd_x !== 1'b0)
                    $fatal(1, "Branch decode/forward/target mismatch at PC=%0d", exp_pc[i]);
            end
            if (i>0 && (!exp_valid[i-1] ||
                        exp_instr[i-1][6:0] == 7'b1100011) && wb_we !== 1'b0)
                $fatal(1, "Branch or bubble wrote a register at step=%0d", i);
            if (wb_we && (wb_pc == 320 || wb_pc == 344 ||
                          wb_pc == 380 || wb_pc == 396))
                $fatal(1, "Wrong-path instruction committed at PC=%0d", wb_pc);
        end

        // Drain the last ADDI writeback before the new jump program begins.
        tick;
        tick;

        if (dut.u_regfile.regs[14] !== 3 || dut.u_regfile.regs[15] !== 4 ||
            dut.u_regfile.regs[16] !== 0 || dut.u_regfile.regs[17] !== 1 ||
            dut.u_regfile.regs[18] !== 2 || dut.u_regfile.regs[19] !== 1 ||
            dut.u_regfile.regs[20] !== 1 || dut.u_regfile.regs[21] !== 5 ||
            dut.u_regfile.regs[22] !== 3 || dut.u_regfile.regs[23] !== 3 ||
            dut.u_regfile.regs[24] !== 32 || dut.u_regfile.regs[26] !== 7 ||
            dut.u_regfile.regs[27] !== 9 || dut.u_regfile.regs[28] !== 7 ||
            dut.u_regfile.regs[29] !== 32'hf0000000)
            $fatal(1, "Final register or wrong-path squash mismatch");

        $display("PASS: BEQ/BNE forward, taken/not-taken, backward loop and squash");
        $display("PASS: original 77 instructions preserved");
        $stop;
    end

    initial begin
        #2000;
        $fatal(1, "Branch test timeout");
    end
endmodule
