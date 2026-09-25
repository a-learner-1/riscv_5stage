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

        // 15 ns: first instruction is fetched.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd0 ||
            instr_x !== 32'h00500093) begin
            $display("FAIL: first instruction fetch");
            $fatal(1);
        end

        // 25 ns: first result is in WB; second instruction uses forwarding in EX.
        @(posedge clk);
        #1;
        if (pc_x !== 32'd4 ||
            instr_x !== 32'h00308113 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd1 ||
            wb_data !== 32'd5 ||
            dut.forward_rs1_x !== 1'b1 ||
            dut.alu_a_x !== 32'd5 ||
            dut.alu_result_x !== 32'd8) begin
            $display("FAIL: forwarding to second ADDI");
            $display("WB: rd=%d data=%h; forward=%b ALU a=%h result=%h",
                     wb_rd, wb_data, dut.forward_rs1_x,
                     dut.alu_a_x, dut.alu_result_x);
            $fatal(1);
        end

        // 35 ns: x1 is written; second result enters WB.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd4 ||
            wb_rd !== 5'd2 ||
            wb_data !== 32'd8) begin
            $display("FAIL: x1 writeback or second ADDI result");
            $fatal(1);
        end

        // 45 ns: x2 is written.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd8 ||
            wb_we !== 1'b0) begin
            $display("FAIL: final register values");
            $fatal(1);
        end

        $display("PASS: cpu_top test passed, x1=5, x2=8");
        $stop;
    end

endmodule