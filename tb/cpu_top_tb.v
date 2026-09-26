`timescale 1ns/1ps

module cpu_top_tb;

    reg         clk;
    reg         rst_n;

    wire [31:0] pc_x;
    wire [31:0] instr_x;
    wire        valid_x;
    wire [31:0] wb_pc;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;
    wire        wb_we;

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

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        #12 rst_n = 1'b1;

        // 15 ns edge: first ADDI enters EX.
        // addi x1, x0, 5
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd0 ||
            instr_x !== 32'h00500093 ||
            wb_we !== 1'b0 ||
            dut.is_sub_x !== 1'b0 ||
            dut.forward_rs1_x !== 1'b0 ||
            dut.alu_a_x !== 32'd0 ||
            dut.alu_b_x !== 32'd5 ||
            dut.alu_result_x !== 32'd5) begin
            $display("FAIL: first ADDI in EX");
            $fatal(1);
        end

        // 25 ns edge: first result enters WB.
        // addi x2, x1, 3 uses rs1 forwarding.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd4 ||
            instr_x !== 32'h00308113 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd1 ||
            wb_data !== 32'd5 ||
            dut.is_sub_x !== 1'b0 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.forward_rs2_x !== 1'b0 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd3 ||
            dut.alu_result_x !== 32'd8) begin
            $display("FAIL: second ADDI or rs1 forwarding");
            $fatal(1);
        end

        $display("PASS: ADDI rs1 forwarding, 5 + 3 = 8");

        // 35 ns edge: x1 is written; x2 result enters WB.
        // add x3, x1, x2 uses rs2 forwarding.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd8 ||
            instr_x !== 32'h002081b3 ||
            dut.u_regfile.regs[1] !== 32'd5 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd4 ||
            wb_rd !== 5'd2 ||
            wb_data !== 32'd8 ||
            dut.is_add_x !== 1'b1 ||
            dut.is_addi_x !== 1'b0 ||
            dut.is_sub_x !== 1'b0 ||
            dut.forward_rs1_x !== 1'b0 ||
            dut.forward_rs2_x !== 1'b1 ||
            dut.rs1_data_x !== 32'd5 ||
            dut.rs2_value_x !== 32'd8 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd8 ||
            dut.alu_result_x !== 32'd13) begin
            $display("FAIL: ADD x3 or rs2 forwarding");
            $fatal(1);
        end

        $display("PASS: ADD rs2 forwarding, 5 + 8 = 13");

        // 45 ns edge: x2 is written; x3 result enters WB.
        // add x4, x3, x3 uses BOTH forwarding paths.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd12 ||
            instr_x !== 32'h00318233 ||
            dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd8 ||
            wb_rd !== 5'd3 ||
            wb_data !== 32'd13 ||
            dut.is_add_x !== 1'b1 ||
            dut.is_addi_x !== 1'b0 ||
            dut.is_sub_x !== 1'b0 ||
            dut.rs1_addr_x !== 5'd3 ||
            dut.rs2_addr_x !== 5'd3 ||
            dut.rd_addr_x !== 5'd4 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.forward_rs2_x !== 1'b1 ||
            dut.rs2_value_x !== 32'd13 ||
            dut.alu_a_x !== 32'd13 ||
            dut.alu_b_x !== 32'd13 ||
            dut.alu_result_x !== 32'd26) begin
            $display("FAIL: simultaneous rs1 and rs2 forwarding");
            $display("WB: we=%b rd=%d data=%h",
                     wb_we, wb_rd, wb_data);
            $display("forward_rs1=%b forward_rs2=%b",
                     dut.forward_rs1_x, dut.forward_rs2_x);
            $display("ALU: a=%h b=%h result=%h",
                     dut.alu_a_x, dut.alu_b_x, dut.alu_result_x);
            $fatal(1);
        end

        $display("PASS: dual-source forwarding, 13 + 13 = 26");

        // 55 ns edge: x3 is written; x4 result enters WB.
        // sub x5, x4, x3 forwards x4 to ALU A.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd16 ||
            instr_x !== 32'h403202b3 ||
            dut.u_regfile.regs[3] !== 32'd13 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd12 ||
            wb_rd !== 5'd4 ||
            wb_data !== 32'd26 ||
            dut.is_sub_x !== 1'b1 ||
            dut.is_add_x !== 1'b0 ||
            dut.is_addi_x !== 1'b0 ||
            dut.rs1_addr_x !== 5'd4 ||
            dut.rs2_addr_x !== 5'd3 ||
            dut.rd_addr_x !== 5'd5 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.forward_rs2_x !== 1'b0 ||
            dut.rs2_data_x !== 32'd13 ||
            dut.alu_a_x !== 32'd26 ||
            dut.alu_b_x !== 32'd13 ||
            dut.alu_result_x !== 32'd13) begin
            $display("FAIL: SUB x5 or rs1 forwarding");
            $display("WB: we=%b rd=%d data=%h",
                     wb_we, wb_rd, wb_data);
            $display("sub=%b fwd1=%b fwd2=%b a=%h b=%h result=%h",
                     dut.is_sub_x,
                     dut.forward_rs1_x, dut.forward_rs2_x,
                     dut.alu_a_x, dut.alu_b_x, dut.alu_result_x);
            $fatal(1);
        end

        $display("PASS: SUB rs1 forwarding, 26 - 13 = 13");

        // 65 ns edge: x4 is written; x5 result enters WB.
        // sub x6, x1, x5 forwards x5 to ALU B.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd20 ||
            instr_x !== 32'h40508333 ||
            dut.u_regfile.regs[4] !== 32'd26 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd16 ||
            wb_rd !== 5'd5 ||
            wb_data !== 32'd13 ||
            dut.is_sub_x !== 1'b1 ||
            dut.is_add_x !== 1'b0 ||
            dut.is_addi_x !== 1'b0 ||
            dut.rs1_addr_x !== 5'd1 ||
            dut.rs2_addr_x !== 5'd5 ||
            dut.rd_addr_x !== 5'd6 ||
            dut.forward_rs1_x !== 1'b0 ||
            dut.forward_rs2_x !== 1'b1 ||
            dut.rs1_data_x !== 32'd5 ||
            dut.rs2_value_x !== 32'd13 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd13 ||
            dut.alu_result_x !== 32'hfffffff8) begin
            $display("FAIL: SUB x6 or rs2 forwarding");
            $display("WB: we=%b rd=%d data=%h",
                     wb_we, wb_rd, wb_data);
            $display("sub=%b fwd1=%b fwd2=%b a=%h b=%h result=%h",
                     dut.is_sub_x,
                     dut.forward_rs1_x, dut.forward_rs2_x,
                     dut.alu_a_x, dut.alu_b_x, dut.alu_result_x);
            $fatal(1);
        end

        $display("PASS: SUB rs2 forwarding, 5 - 13 = -8");

        // 75 ns edge: x5 is written; x6 result enters WB.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd24 ||
            instr_x !== 32'h00000013 ||
            dut.u_regfile.regs[5] !== 32'd13 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd20 ||
            wb_rd !== 5'd6 ||
            wb_data !== 32'hfffffff8) begin
            $display("FAIL: x5 writeback or x6 result in WB");
            $fatal(1);
        end

        // 85 ns edge: x6 is written; NOP must not write.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            dut.u_regfile.regs[3] !== 32'd13 ||
            dut.u_regfile.regs[4] !== 32'd26 ||
            dut.u_regfile.regs[5] !== 32'd13 ||
            dut.u_regfile.regs[6] !== 32'hfffffff8 ||
            wb_we !== 1'b0) begin
            $display("FAIL: final registers or NOP write enable");
            $display("x1=%h x2=%h x3=%h",
                     dut.u_regfile.regs[1],
                     dut.u_regfile.regs[2],
                     dut.u_regfile.regs[3]);
            $display("x4=%h x5=%h x6=%h",
                     dut.u_regfile.regs[4],
                     dut.u_regfile.regs[5],
                     dut.u_regfile.regs[6]);
            $fatal(1);
        end

        $display("PASS: cpu_top ADDI/ADD/SUB test passed");
        $display("PASS: x1=5 x2=8 x3=13 x4=26 x5=13 x6=fffffff8 (-8)");
        $stop;
    end

endmodule