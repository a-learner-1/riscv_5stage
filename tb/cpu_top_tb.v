`timescale 1ns/1ps

module cpu_top_tb;

    reg clk;
    reg rst_n;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;

    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire        wb_we;

    localparam [2:0] ALU_ADD = 3'b000;
    localparam [2:0] ALU_SUB = 3'b001;
    localparam [2:0] ALU_AND = 3'b010;
    localparam [2:0] ALU_OR  = 3'b011;
    localparam [2:0] ALU_XOR = 3'b100;

    // Flag order: ADDI ADD SUB AND OR XOR.
    localparam [5:0] FLAG_ADDI = 6'b100000;
    localparam [5:0] FLAG_ADD  = 6'b010000;
    localparam [5:0] FLAG_SUB  = 6'b001000;
    localparam [5:0] FLAG_AND  = 6'b000100;
    localparam [5:0] FLAG_OR   = 6'b000010;
    localparam [5:0] FLAG_XOR  = 6'b000001;

    wire [5:0] decode_flags;

    cpu_top dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .pc_x    (pc_x),
        .instr_x (instr_x),
        .valid_x (valid_x),
        .wb_pc   (wb_pc),
        .wb_rd   (wb_rd),
        .wb_data (wb_data),
        .wb_we   (wb_we)
    );

    assign decode_flags = {
        dut.is_addi_x,
        dut.is_add_x,
        dut.is_sub_x,
        dut.is_and_x,
        dut.is_or_x,
        dut.is_xor_x
    };

    // Clock period: 10 ns.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Wait for a rising edge, then let register updates settle.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Check instruction, decoding, forwarding and ALU result in EX.
    task check_ex;
        input [31:0] expected_pc;
        input [31:0] expected_instr;
        input [5:0]  expected_flags;
        input [2:0]  expected_op;
        input        expected_forward_rs1;
        input        expected_forward_rs2;
        input [31:0] expected_a;
        input [31:0] expected_b;
        input [31:0] expected_result;
        begin
            if (valid_x !== 1'b1 ||
                pc_x !== expected_pc ||
                instr_x !== expected_instr ||
                decode_flags !== expected_flags ||
                dut.alu_op_x !== expected_op ||
                dut.forward_rs1_x !== expected_forward_rs1 ||
                dut.forward_rs2_x !== expected_forward_rs2 ||
                dut.alu_a_x !== expected_a ||
                dut.alu_b_x !== expected_b ||
                dut.alu_result_x !== expected_result) begin

                $display("FAIL: EX stage at time=%0t", $time);

                $display("  expected pc=%h instr=%h flags=%b op=%b",
                         expected_pc,
                         expected_instr,
                         expected_flags,
                         expected_op);

                $display("  actual   pc=%h instr=%h flags=%b op=%b",
                         pc_x,
                         instr_x,
                         decode_flags,
                         dut.alu_op_x);

                $display("  expected forward_rs1=%b forward_rs2=%b",
                         expected_forward_rs1,
                         expected_forward_rs2);

                $display("  actual   forward_rs1=%b forward_rs2=%b",
                         dut.forward_rs1_x,
                         dut.forward_rs2_x);

                $display("  expected a=%h b=%h result=%h",
                         expected_a,
                         expected_b,
                         expected_result);

                $display("  actual   a=%h b=%h result=%h",
                         dut.alu_a_x,
                         dut.alu_b_x,
                         dut.alu_result_x);

                $fatal(1, "EX stage mismatch");
            end
        end
    endtask

    // Check the result held in the EX/WB pipeline registers.
    task check_wb;
        input [31:0] expected_pc;
        input [4:0]  expected_rd;
        input [31:0] expected_data;
        begin
            if (wb_we !== 1'b1 ||
                wb_pc !== expected_pc ||
                wb_rd !== expected_rd ||
                wb_data !== expected_data) begin

                $display("FAIL: WB stage at time=%0t", $time);

                $display("  expected pc=%h rd=%0d data=%h we=1",
                         expected_pc,
                         expected_rd,
                         expected_data);

                $display("  actual   pc=%h rd=%0d data=%h we=%b",
                         wb_pc,
                         wb_rd,
                         wb_data,
                         wb_we);

                $fatal(1, "WB stage mismatch");
            end
        end
    endtask

    // Check the value actually written into the register file.
    task check_reg;
        input [4:0]  addr;
        input [31:0] expected_data;
        begin
            if (dut.u_regfile.regs[addr] !== expected_data) begin
                $display("FAIL: x%0d expected=%h actual=%h",
                         addr,
                         expected_data,
                         dut.u_regfile.regs[addr]);

                $fatal(1, "Register writeback mismatch");
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;

        // Check reset.
        #1;
        if (valid_x !== 1'b0 ||
            wb_we !== 1'b0 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd0 ||
            wb_data !== 32'd0) begin
            $fatal(1, "CPU reset mismatch");
        end

        // Release reset at 12 ns.
        #11;
        rst_n = 1'b1;

        // 16 ns: EX = addi x1, x0, 5.
        tick;
        check_ex(
            32'd0, 32'h00500093,
            FLAG_ADDI, ALU_ADD,
            1'b0, 1'b0,
            32'd0, 32'd5, 32'd5
        );

        if (wb_we !== 1'b0) begin
            $fatal(1, "Unexpected writeback during pipeline fill");
        end

        // 26 ns: EX = addi x2, x1, 3.
        // WB holds x1 = 5; forward it to rs1.
        tick;
        check_ex(
            32'd4, 32'h00308113,
            FLAG_ADDI, ALU_ADD,
            1'b1, 1'b0,
            32'd5, 32'd3, 32'd8
        );
        check_wb(32'd0, 5'd1, 32'd5);

        $display("PASS: ADDI rs1 forwarding, 5 + 3 = 8");

        // 36 ns: EX = add x3, x1, x2.
        // WB holds x2 = 8; forward it to rs2.
        tick;
        check_ex(
            32'd8, 32'h002081b3,
            FLAG_ADD, ALU_ADD,
            1'b0, 1'b1,
            32'd5, 32'd8, 32'd13
        );
        check_wb(32'd4, 5'd2, 32'd8);
        check_reg(5'd1, 32'd5);

        $display("PASS: ADD rs2 forwarding, 5 + 8 = 13");

        // 46 ns: EX = add x4, x3, x3.
        // WB holds x3 = 13; forward it to both sources.
        tick;
        check_ex(
            32'd12, 32'h00318233,
            FLAG_ADD, ALU_ADD,
            1'b1, 1'b1,
            32'd13, 32'd13, 32'd26
        );
        check_wb(32'd8, 5'd3, 32'd13);
        check_reg(5'd2, 32'd8);

        $display("PASS: dual-source forwarding, 13 + 13 = 26");

        // 56 ns: EX = sub x5, x4, x3.
        // WB holds x4 = 26; forward it to rs1.
        tick;
        check_ex(
            32'd16, 32'h403202b3,
            FLAG_SUB, ALU_SUB,
            1'b1, 1'b0,
            32'd26, 32'd13, 32'd13
        );
        check_wb(32'd12, 5'd4, 32'd26);
        check_reg(5'd3, 32'd13);

        $display("PASS: SUB rs1 forwarding, 26 - 13 = 13");

        // 66 ns: EX = sub x6, x1, x5.
        // WB holds x5 = 13; forward it to rs2.
        tick;
        check_ex(
            32'd20, 32'h40508333,
            FLAG_SUB, ALU_SUB,
            1'b0, 1'b1,
            32'd5, 32'd13, 32'hfffffff8
        );
        check_wb(32'd16, 5'd5, 32'd13);
        check_reg(5'd4, 32'd26);

        $display("PASS: SUB rs2 forwarding, 5 - 13 = -8");

        // 76 ns: EX = and x7, x6, x4.
        // WB holds x6 = -8; forward it to rs1.
        tick;
        check_ex(
            32'd24, 32'h004373b3,
            FLAG_AND, ALU_AND,
            1'b1, 1'b0,
            32'hfffffff8, 32'd26, 32'd24
        );
        check_wb(32'd20, 5'd6, 32'hfffffff8);
        check_reg(5'd5, 32'd13);

        $display("PASS: AND rs1 forwarding, -8 & 26 = 24");

        // 86 ns: EX = or x8, x1, x7.
        // WB holds x7 = 24; forward it to rs2.
        tick;
        check_ex(
            32'd28, 32'h0070e433,
            FLAG_OR, ALU_OR,
            1'b0, 1'b1,
            32'd5, 32'd24, 32'd29
        );
        check_wb(32'd24, 5'd7, 32'd24);
        check_reg(5'd6, 32'hfffffff8);

        $display("PASS: OR rs2 forwarding, 5 | 24 = 29");

        // 96 ns: EX = xor x9, x8, x7.
        // WB holds x8 = 29; forward it to rs1.
        tick;
        check_ex(
            32'd32, 32'h007444b3,
            FLAG_XOR, ALU_XOR,
            1'b1, 1'b0,
            32'd29, 32'd24, 32'd5
        );
        check_wb(32'd28, 5'd8, 32'd29);
        check_reg(5'd7, 32'd24);

        $display("PASS: XOR rs1 forwarding, 29 ^ 24 = 5");

        // 106 ns: EX = NOP; WB holds x9 = 5.
        tick;
        check_ex(
            32'd36, 32'h00000013,
            FLAG_ADDI, ALU_ADD,
            1'b0, 1'b0,
            32'd0, 32'd0, 32'd0
        );
        check_wb(32'd32, 5'd9, 32'd5);
        check_reg(5'd8, 32'd29);

        // 116 ns: x9 has been written into the register file.
        // The NOP in WB must not enable a write to x0.
        tick;

        if (wb_we !== 1'b0) begin
            $fatal(1, "NOP must not enable register writeback");
        end

        check_reg(5'd1, 32'd5);
        check_reg(5'd2, 32'd8);
        check_reg(5'd3, 32'd13);
        check_reg(5'd4, 32'd26);
        check_reg(5'd5, 32'd13);
        check_reg(5'd6, 32'hfffffff8);
        check_reg(5'd7, 32'd24);
        check_reg(5'd8, 32'd29);
        check_reg(5'd9, 32'd5);

        $display("PASS: cpu_top logic integration test passed");
        $display("PASS: x1=5 x2=8 x3=13 x4=26 x5=13");
        $display("PASS: x6=fffffff8 (-8) x7=24 x8=29 x9=5");

        $stop;
    end

    // Prevent the test from running forever if the clock stops.
    initial begin
        #1000;
        $fatal(1, "CPU test timeout");
    end

endmodule