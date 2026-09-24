`timescale 1ns/1ps

module decoder_tb;

    reg  [31:0] instr;
    wire [4:0]  rs1_addr;
    wire [4:0]  rd_addr;
    wire [31:0] imm_i;
    wire        is_addi;

    decoder dut (
        .instr    (instr),
        .rs1_addr (rs1_addr),
        .rd_addr  (rd_addr),
        .imm_i    (imm_i),
        .is_addi  (is_addi)
    );

    task check_decode;
        input [31:0] test_instr;
        input [4:0]  expected_rs1;
        input [4:0]  expected_rd;
        input [31:0] expected_imm;
        input        expected_is_addi;
        begin
            instr = test_instr;
            #1;  // Allow combinational logic to update.

            if ((rs1_addr !== expected_rs1) ||
                (rd_addr  !== expected_rd)  ||
                (imm_i    !== expected_imm) ||
                (is_addi  !== expected_is_addi)) begin
                $display("FAIL: instr=%h", instr);
                $display("  rs1=%d rd=%d imm=%h is_addi=%b",
                         rs1_addr, rd_addr, imm_i, is_addi);
                $display("  expected: rs1=%d rd=%d imm=%h is_addi=%b",
                         expected_rs1, expected_rd,
                         expected_imm, expected_is_addi);
                $fatal(1);
            end

            $display("PASS: instr=%h rs1=%d rd=%d imm=%h is_addi=%b",
                     instr, rs1_addr, rd_addr, imm_i, is_addi);
        end
    endtask

    initial begin
        // addi x1, x0, 5
        check_decode(32'h00500093, 5'd0, 5'd1, 32'd5, 1'b1);

        // addi x2, x0, 3
        check_decode(32'h00300113, 5'd0, 5'd2, 32'd3, 1'b1);

        // addi x3, x1, -1: test rs1 and sign extension.
        check_decode(32'hfff08193, 5'd1, 5'd3, 32'hffffffff, 1'b1);

        // NOP is an alias of addi x0, x0, 0.
        check_decode(32'h00000013, 5'd0, 5'd0, 32'd0, 1'b1);

        // Same opcode, different funct3: not ADDI.
        check_decode(32'h00502093, 5'd0, 5'd1, 32'd5, 1'b0);

        // R-type opcode: not ADDI.
        check_decode(32'h00000033, 5'd0, 5'd0, 32'd0, 1'b0);

        $display("PASS: decoder test passed");
        $stop;
    end

endmodule
