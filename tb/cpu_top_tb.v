`timescale 1ns/1ps

module cpu_top_tb;

    reg clk;
    reg rst_n;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire valid_x;

    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire wb_we;

    localparam [2:0] ALU_ADD = 3'b000;
    localparam [2:0] ALU_SUB = 3'b001;
    localparam [2:0] ALU_AND = 3'b010;
    localparam [2:0] ALU_OR  = 3'b011;
    localparam [2:0] ALU_XOR = 3'b100;

    // Flag order: ADDI ADD SUB AND OR XOR ANDI ORI XORI.
    localparam [8:0] F_ADDI = 9'b100000000;
    localparam [8:0] F_ADD  = 9'b010000000;
    localparam [8:0] F_SUB  = 9'b001000000;
    localparam [8:0] F_AND  = 9'b000100000;
    localparam [8:0] F_OR   = 9'b000010000;
    localparam [8:0] F_XOR  = 9'b000001000;
    localparam [8:0] F_ANDI = 9'b000000100;
    localparam [8:0] F_ORI  = 9'b000000010;
    localparam [8:0] F_XORI = 9'b000000001;

    localparam integer NUM_INSTR = 15;

    wire [8:0] decode_flags;

    // Explicit expected values for each instruction.
    reg [31:0] expected_instr  [0:NUM_INSTR-1];
    reg [8:0]  expected_flags  [0:NUM_INSTR-1];
    reg [2:0]  expected_op     [0:NUM_INSTR-1];
    reg [1:0]  expected_fwd    [0:NUM_INSTR-1];
    reg [31:0] expected_a      [0:NUM_INSTR-1];
    reg [31:0] expected_b      [0:NUM_INSTR-1];
    reg [31:0] expected_result [0:NUM_INSTR-1];

    integer i;
    reg expected_use_imm;

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
        dut.is_xor_x,
        dut.is_andi_x,
        dut.is_ori_x,
        dut.is_xori_x
    };

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Populate one row of the expected-value table.
    // fwd[1] = rs1 forwarding; fwd[0] = rs2 forwarding.
    task set_case;
        input integer index;
        input [31:0] instruction;
        input [8:0] flags;
        input [2:0] op;
        input [1:0] fwd;
        input [31:0] a;
        input [31:0] b;
        input [31:0] result;
        begin
            expected_instr[index]  = instruction;
            expected_flags[index]  = flags;
            expected_op[index]     = op;
            expected_fwd[index]    = fwd;
            expected_a[index]      = a;
            expected_b[index]      = b;
            expected_result[index] = result;
        end
    endtask

    task check_wb;
        input [31:0] expected_pc;
        input [4:0] expected_rd;
        input [31:0] expected_data;
        begin
            if (wb_we !== 1'b1 ||
                wb_pc !== expected_pc ||
                wb_rd !== expected_rd ||
                wb_data !== expected_data) begin

                $display("FAIL: WB at time=%0t", $time);
                $display("expected pc=%h rd=%0d data=%h we=1",
                         expected_pc, expected_rd, expected_data);
                $display("actual   pc=%h rd=%0d data=%h we=%b",
                         wb_pc, wb_rd, wb_data, wb_we);

                $fatal(1, "WB mismatch");
            end
        end
    endtask

    task check_reg;
        input [4:0] addr;
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

        // index, instruction, flags, ALU op, forwarding, A, B, result.

        // Original nine instructions.
        set_case(0, 32'h00500093, F_ADDI, ALU_ADD, 2'b00,
                 32'd0, 32'd5, 32'd5);

        set_case(1, 32'h00308113, F_ADDI, ALU_ADD, 2'b10,
                 32'd5, 32'd3, 32'd8);

        set_case(2, 32'h002081b3, F_ADD, ALU_ADD, 2'b01,
                 32'd5, 32'd8, 32'd13);

        set_case(3, 32'h00318233, F_ADD, ALU_ADD, 2'b11,
                 32'd13, 32'd13, 32'd26);

        set_case(4, 32'h403202b3, F_SUB, ALU_SUB, 2'b10,
                 32'd26, 32'd13, 32'd13);

        set_case(5, 32'h40508333, F_SUB, ALU_SUB, 2'b01,
                 32'd5, 32'd13, 32'hfffffff8);

        set_case(6, 32'h004373b3, F_AND, ALU_AND, 2'b10,
                 32'hfffffff8, 32'd26, 32'd24);

        set_case(7, 32'h0070e433, F_OR, ALU_OR, 2'b01,
                 32'd5, 32'd24, 32'd29);

        set_case(8, 32'h007444b3, F_XOR, ALU_XOR, 2'b10,
                 32'd29, 32'd24, 32'd5);

        // ANDI: 5 & 9 = 1.
        // Raw rs2 field = 9, matching WB rd = 9.
        // rs2 forwarding must still remain disabled.
        set_case(9, 32'h0094f513, F_ANDI, ALU_AND, 2'b10,
                 32'd5, 32'd9, 32'd1);

        // ORI: 1 | 10 = 11.
        // Raw rs2 field = 10, matching WB rd = 10.
        set_case(10, 32'h00a56593, F_ORI, ALU_OR, 2'b10,
                 32'd1, 32'd10, 32'd11);

        // XORI: 11 ^ 11 = 0.
        // Raw rs2 field = 11, matching WB rd = 11.
        set_case(11, 32'h00b5c613, F_XORI, ALU_XOR, 2'b10,
                 32'd11, 32'd11, 32'd0);

        // XORI with -1: immediate must become ffffffff.
        set_case(12, 32'hfff64693, F_XORI, ALU_XOR, 2'b10,
                 32'd0, 32'hffffffff, 32'hffffffff);

        // ANDI with -2048: immediate must become fffff800.
        set_case(13, 32'h8006f713, F_ANDI, ALU_AND, 2'b10,
                 32'hffffffff, 32'hfffff800, 32'hfffff800);

        // ORI with -1: immediate must become ffffffff.
        set_case(14, 32'hfff76793, F_ORI, ALU_OR, 2'b10,
                 32'hfffff800, 32'hffffffff, 32'hffffffff);

        #1;
        if (valid_x !== 1'b0 ||
            wb_we !== 1'b0 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd0 ||
            wb_data !== 32'd0) begin
            $fatal(1, "CPU reset mismatch");
        end

        #11;
        rst_n = 1'b1;

        // First check occurs at 16 ns.
        // Each subsequent instruction is checked 10 ns later.
        for (i = 0; i < NUM_INSTR; i = i + 1) begin
            tick;

            expected_use_imm =
                (expected_flags[i] == F_ADDI) ||
                (expected_flags[i] == F_ANDI) ||
                (expected_flags[i] == F_ORI) ||
                (expected_flags[i] == F_XORI);

            // Check the instruction currently in EX.
            if (valid_x !== 1'b1 ||
                pc_x !== (i * 4) ||
                instr_x !== expected_instr[i] ||
                decode_flags !== expected_flags[i] ||
                dut.use_imm_x !== expected_use_imm ||
                dut.uses_rs2_x !== (!expected_use_imm) ||
                dut.alu_op_x !== expected_op[i] ||
                dut.forward_rs1_x !== expected_fwd[i][1] ||
                dut.forward_rs2_x !== expected_fwd[i][0] ||
                dut.alu_a_x !== expected_a[i] ||
                dut.alu_b_x !== expected_b[i] ||
                dut.alu_result_x !== expected_result[i]) begin

                $display("FAIL: EX case=%0d time=%0t", i + 1, $time);

                $display("expected pc=%h instr=%h flags=%b op=%b",
                         i * 4,
                         expected_instr[i],
                         expected_flags[i],
                         expected_op[i]);

                $display("actual   pc=%h instr=%h flags=%b op=%b",
                         pc_x, instr_x, decode_flags, dut.alu_op_x);

                $display("expected use_imm=%b fwd=%b a=%h b=%h result=%h",
                         expected_use_imm,
                         expected_fwd[i],
                         expected_a[i],
                         expected_b[i],
                         expected_result[i]);

                $display("actual use_imm=%b uses_rs2=%b fwd=%b a=%h b=%h result=%h",
                         dut.use_imm_x,
                         dut.uses_rs2_x,
                         {dut.forward_rs1_x, dut.forward_rs2_x},
                         dut.alu_a_x,
                         dut.alu_b_x,
                         dut.alu_result_x);

                $fatal(1, "EX mismatch");
            end

            if (expected_use_imm &&
                (dut.imm_x !== expected_b[i])) begin
                $fatal(1, "Immediate sign-extension mismatch");
            end

            // The immediately preceding instruction is in WB.
            if (i == 0) begin
                if (wb_we !== 1'b0)
                    $fatal(1, "Unexpected write during pipeline fill");
            end else begin
                check_wb(
                    (i - 1) * 4,
                    expected_instr[i - 1][11:7],
                    expected_result[i - 1]
                );
            end

            // The instruction two positions earlier has committed.
            if (i >= 2) begin
                check_reg(
                    expected_instr[i - 2][11:7],
                    expected_result[i - 2]
                );
            end

            // Confirm that these cases really exercise a raw-field
            // collision with WB rd, while rs2 forwarding stays off.
            if ((i >= 9) && (i <= 11)) begin
                if (dut.rs2_addr_x !== wb_rd ||
                    dut.forward_rs2_x !== 1'b0) begin
                    $fatal(1, "Immediate raw-rs2 collision test failed");
                end
            end

            $display("PASS: case=%0d pc=%0d instr=%h result=%h",
                     i + 1, pc_x, instr_x, dut.alu_result_x);
        end

        // 166 ns: final instruction is in WB; EX contains a NOP.
        tick;

        check_wb(32'd56, 5'd15, 32'hffffffff);
        check_reg(5'd14, 32'hfffff800);

        if (valid_x !== 1'b1 ||
            pc_x !== 32'd60 ||
            instr_x !== 32'h00000013 ||
            decode_flags !== F_ADDI ||
            dut.use_imm_x !== 1'b1 ||
            dut.alu_a_x !== 32'd0 ||
            dut.alu_b_x !== 32'd0 ||
            dut.alu_result_x !== 32'd0) begin
            $fatal(1, "Trailing NOP mismatch");
        end

        // 176 ns: x15 is written; NOP must not enable a write.
        tick;

        if (wb_we !== 1'b0)
            $fatal(1, "NOP must not enable register writeback");

        // All 15 instructions have different destination registers.
        for (i = 0; i < NUM_INSTR; i = i + 1) begin
            check_reg(
                expected_instr[i][11:7],
                expected_result[i]
            );
        end

        $display("PASS: immediate instructions do not forward rs2");
        $display("PASS: negative immediate sign extension");
        $display("PASS: cpu_top immediate logic integration test passed");
        $display("PASS: x1=5 x2=8 x3=13 x4=26 x5=13");
        $display("PASS: x6=fffffff8 x7=24 x8=29 x9=5");
        $display("PASS: x10=1 x11=11 x12=0");
        $display("PASS: x13=ffffffff x14=fffff800 x15=ffffffff");

        $stop;
    end

    initial begin
        #2000;
        $fatal(1, "CPU test timeout");
    end

endmodule