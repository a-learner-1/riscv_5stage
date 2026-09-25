`timescale 1ns/1ps

module decoder_tb;

    reg  [31:0] instr;
    wire [4:0]  rs1_addr;
    wire [4:0]  rs2_addr;
    wire [4:0]  rd_addr;
    wire [31:0] imm_i;
    wire        is_addi;
    wire        is_add;

    decoder dut (
        .instr    (instr),
        .rs1_addr (rs1_addr),
        .rs2_addr (rs2_addr),
        .rd_addr  (rd_addr),
        .imm_i    (imm_i),
        .is_addi  (is_addi),
        .is_add   (is_add)
    );

    task check_decode;
        input [31:0] test_instr;
        input [4:0]  expected_rs1;
        input [4:0]  expected_rs2;
        input [4:0]  expected_rd;
        input [31:0] expected_imm;
        input        expected_is_addi;
        input        expected_is_add;
        begin
            instr = test_instr;
            #1;  // Allow combinational logic to settle.

            // Check raw address fields and instruction recognition.
            if ((rs1_addr !== expected_rs1) ||
                (rs2_addr !== expected_rs2) ||
                (rd_addr  !== expected_rd)  ||
                (is_addi  !== expected_is_addi) ||
                (is_add   !== expected_is_add)) begin

                $display("FAIL: instr=%h", instr);
                $display(
                    "  actual:   rs1=%d rs2=%d rd=%d addi=%b add=%b",
                    rs1_addr, rs2_addr, rd_addr, is_addi, is_add
                );
                $display(
                    "  expected: rs1=%d rs2=%d rd=%d addi=%b add=%b",
                    expected_rs1, expected_rs2, expected_rd,
                    expected_is_addi, expected_is_add
                );
                $fatal(1);
            end

            // The I-type immediate is used only by ADDI here.
            if (expected_is_addi &&
                (imm_i !== expected_imm)) begin
                $display(
                    "FAIL: instr=%h imm=%h expected=%h",
                    instr, imm_i, expected_imm
                );
                $fatal(1);
            end

            $display(
                "PASS: instr=%h rs1=%d rs2=%d rd=%d addi=%b add=%b",
                instr, rs1_addr, rs2_addr, rd_addr, is_addi, is_add
            );
        end
    endtask

    initial begin
        // Arguments:
        // instruction, rs1, rs2 field, rd, immediate, is_addi, is_add.
        // The immediate argument is ignored for non-ADDI instructions.

        // addi x1, x0, 5
        check_decode(
            32'h00500093, 5'd0, 5'd5, 5'd1, 32'd5, 1'b1, 1'b0
        );

        // addi x2, x0, 3
        check_decode(
            32'h00300113, 5'd0, 5'd3, 5'd2, 32'd3, 1'b1, 1'b0
        );

        // addi x2, x1, 3: the current ROM instruction at PC=4.
        check_decode(
            32'h00308113, 5'd1, 5'd3, 5'd2, 32'd3, 1'b1, 1'b0
        );

        // addi x3, x1, -1: verify sign extension.
        check_decode(
            32'hfff08193, 5'd1, 5'd31, 5'd3,
            32'hffffffff, 1'b1, 1'b0
        );

        // NOP: addi x0, x0, 0.
        check_decode(
            32'h00000013, 5'd0, 5'd0, 5'd0, 32'd0, 1'b1, 1'b0
        );

        // slti x1, x0, 5: different funct3, neither ADDI nor ADD.
        check_decode(
            32'h00502093, 5'd0, 5'd5, 5'd1, 32'd0, 1'b0, 1'b0
        );

        // add x3, x1, x2: the next instruction to integrate.
        check_decode(
            32'h002081b3, 5'd1, 5'd2, 5'd3, 32'd0, 1'b0, 1'b1
        );

        // add x0, x0, x0: still a valid ADD instruction.
        check_decode(
            32'h00000033, 5'd0, 5'd0, 5'd0, 32'd0, 1'b0, 1'b1
        );

        // sub x3, x1, x2: different funct7, must not decode as ADD.
        check_decode(
            32'h402081b3, 5'd1, 5'd2, 5'd3, 32'd0, 1'b0, 1'b0
        );

        // xor x3, x1, x2: different funct3, must not decode as ADD.
        check_decode(
            32'h0020c1b3, 5'd1, 5'd2, 5'd3, 32'd0, 1'b0, 1'b0
        );

        $display("PASS: decoder ADDI + ADD test passed");
        $stop;
    end

endmodule
