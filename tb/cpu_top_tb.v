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
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd0 ||
            instr_x !== 32'h00500093 ||
            wb_we !== 1'b0 ||
            dut.forward_rs1_x !== 1'b0 ||
            dut.alu_a_x !== 32'd0 ||
            dut.alu_b_x !== 32'd5 ||
            dut.alu_result_x !== 32'd5) begin
            $display("FAIL: first ADDI in EX");
            $fatal(1);
        end

        // 25 ns edge: first result enters WB.
        // Second ADDI gets x1 through rs1 forwarding.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd4 ||
            instr_x !== 32'h00308113 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd1 ||
            wb_data !== 32'd5 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.forward_rs2_x !== 1'b0 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd3 ||
            dut.alu_result_x !== 32'd8) begin
            $display("FAIL: second ADDI or rs1 forwarding");
            $fatal(1);
        end
        $display("PASS: ADDI rs1 forwarding, 5 + 3 = 8");

        // 35 ns edge: x1 is written; second result enters WB.
        // ADD reads x1 from the regfile and forwards x2 from WB.
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
            dut.forward_rs1_x !== 1'b0 ||
            dut.forward_rs2_x !== 1'b1 ||
            dut.rs1_data_x !== 32'd5 ||
            dut.rs2_value_x !== 32'd8 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_b_x !== 32'd8 ||
            dut.alu_result_x !== 32'd13) begin
            $display("FAIL: ADD or rs2 forwarding");
            $display("rs1=%h rs2_raw=%h rs2_value=%h",
                     dut.rs1_data_x, dut.rs2_data_x,
                     dut.rs2_value_x);
            $display("forward_rs1=%b forward_rs2=%b result=%h",
                     dut.forward_rs1_x, dut.forward_rs2_x,
                     dut.alu_result_x);
            $fatal(1);
        end
        $display("PASS: ADD rs2 forwarding, 5 + 8 = 13");

        // 45 ns edge: x2 is written; ADD result enters WB.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd8 ||
            wb_rd !== 5'd3 ||
            wb_data !== 32'd13) begin
            $display("FAIL: x2 writeback or ADD result in WB");
            $fatal(1);
        end

        // 55 ns edge: x3 is written; NOP must not write.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            dut.u_regfile.regs[3] !== 32'd13 ||
            wb_we !== 1'b0) begin
            $display("FAIL: final register values or NOP write enable");
            $fatal(1);
        end

        $display("PASS: cpu_top ADDI + ADD test passed, x1=5, x2=8, x3=13");
        $stop;
    end

endmodule