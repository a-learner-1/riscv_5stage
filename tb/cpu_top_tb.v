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

        // First fetch: addi x1, x0, 5.
        @(posedge clk);
        #1;
        if (valid_x !== 1'b1 ||
            pc_x !== 32'd0 ||
            instr_x !== 32'h00500093) begin
            $display("FAIL: first instruction fetch");
            $fatal(1);
        end

        // First result enters EX/WB; second instruction is fetched.
        @(posedge clk);
        #1;
        if (pc_x !== 32'd4 ||
            instr_x !== 32'h00300113 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd0 ||
            wb_rd !== 5'd1 ||
            wb_data !== 32'd5) begin
            $display("FAIL: first ADDI result or second fetch");
            $fatal(1);
        end

        // x1 is written; second result enters EX/WB.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            wb_we !== 1'b1 ||
            wb_pc !== 32'd4 ||
            wb_rd !== 5'd2 ||
            wb_data !== 32'd3) begin
            $display("FAIL: x1 writeback or second ADDI result");
            $fatal(1);
        end

        // x2 is written. Later ROM instructions are NOPs.
        @(posedge clk);
        #1;
        if (dut.u_regfile.regs[1] !== 32'd5 ||
            dut.u_regfile.regs[2] !== 32'd3 ||
            wb_we !== 1'b0) begin
            $display("FAIL: final register values");
            $fatal(1);
        end

        $display("PASS: cpu_top test passed, x1=5, x2=3");
        $stop;
    end

endmodule