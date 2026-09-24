`timescale 1ns/1ps

module regfile_tb;

    reg         clk;
    reg         we;
    reg  [4:0]  rs1_addr;
    reg  [4:0]  rs2_addr;
    reg  [4:0]  rd_addr;
    reg  [31:0] rd_data;
    wire [31:0] rs1_data;
    wire [31:0] rs2_data;

    regfile dut (
        .clk      (clk),
        .we       (we),
        .rs1_addr (rs1_addr),
        .rs2_addr (rs2_addr),
        .rd_addr  (rd_addr),
        .rd_data  (rd_data),
        .rs1_data (rs1_data),
        .rs2_data (rs2_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task check_reads;
        input [31:0] expected_rs1;
        input [31:0] expected_rs2;
        begin
            #1;
            if ((rs1_data !== expected_rs1) ||
                (rs2_data !== expected_rs2)) begin
                $display("FAIL: rs1=%h expected=%h, rs2=%h expected=%h",
                         rs1_data, expected_rs1,
                         rs2_data, expected_rs2);
                $fatal(1);
            end
        end
    endtask

    initial begin
        we       = 1'b0;
        rs1_addr = 5'd0;
        rs2_addr = 5'd0;
        rd_addr  = 5'd0;
        rd_data  = 32'd0;

        // x0 must always read as zero.
        check_reads(32'd0, 32'd0);

        // Write x1 = 5.
        @(negedge clk);
        we      = 1'b1;
        rd_addr = 5'd1;
        rd_data = 32'd5;
        @(posedge clk);
        #1;
        we       = 1'b0;
        rs1_addr = 5'd1;
        rs2_addr = 5'd0;
        check_reads(32'd5, 32'd0);

        // Write x2 = 3; read x1 and x2 at the same time.
        @(negedge clk);
        we      = 1'b1;
        rd_addr = 5'd2;
        rd_data = 32'd3;
        @(posedge clk);
        #1;
        we       = 1'b0;
        rs1_addr = 5'd1;
        rs2_addr = 5'd2;
        check_reads(32'd5, 32'd3);

        // Swap read addresses without waiting for another clock.
        rs1_addr = 5'd2;
        rs2_addr = 5'd1;
        check_reads(32'd3, 32'd5);

        // Attempt to write x0 = 99. It must remain zero.
        @(negedge clk);
        we      = 1'b1;
        rd_addr = 5'd0;
        rd_data = 32'd99;
        @(posedge clk);
        #1;
        we       = 1'b0;
        rs1_addr = 5'd0;
        rs2_addr = 5'd1;
        check_reads(32'd0, 32'd5);

        // With we=0, an attempted write must not change x1.
        @(negedge clk);
        we      = 1'b0;
        rd_addr = 5'd1;
        rd_data = 32'd99;
        @(posedge clk);
        #1;
        rs1_addr = 5'd1;
        rs2_addr = 5'd2;
        check_reads(32'd5, 32'd3);

        $display("PASS: regfile test passed");
        $finish;
    end

endmodule