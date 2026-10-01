`timescale 1ns/1ps
module gpio_unit_tb;
    reg clk = 0, rst_n = 0, write_enable = 0;
    reg [31:0] addr = 0, write_data = 0;
    reg [7:0] gpio_in = 8'ha5;
    wire [31:0] read_data;
    wire read_hit, write_hit;
    wire [7:0] gpio_out, gpio_oe;
    gpio_mmio dut (.clk(clk), .rst_n(rst_n), .addr(addr),
        .write_enable(write_enable), .write_data(write_data),
        .read_data(read_data), .read_hit(read_hit), .write_hit(write_hit),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe));
    always #5 clk = ~clk;

    task write_reg;
        input [31:0] address, value;
        input [7:0] out_expected, oe_expected;
        begin
            @(negedge clk); addr = address; write_data = value; write_enable = 1;
            @(posedge clk); #1;
            if (gpio_out !== out_expected || gpio_oe !== oe_expected)
                $fatal(1, "GPIO unit write mismatch addr=%h out=%h oe=%h", addr, gpio_out, gpio_oe);
            @(negedge clk); write_enable = 0;
        end
    endtask
    task read_reg;
        input [31:0] address, value;
        input expected_read_hit, expected_write_hit;
        begin
            addr = address; #1;
            if (read_data !== value || read_hit !== expected_read_hit || write_hit !== expected_write_hit)
                $fatal(1, "GPIO unit decode/read mismatch addr=%h data=%h", addr, read_data);
        end
    endtask
    initial begin
        repeat (2) @(posedge clk); #1;
        if (gpio_out !== 0 || gpio_oe !== 0) $fatal(1, "GPIO unit reset failed");
        @(negedge clk); rst_n = 1; addr = 32'h20000024;
        @(posedge clk); #1;
        if (read_data !== 0) $fatal(1, "GPIO input bypassed synchronizer");
        @(posedge clk); #1;
        if (read_data !== 32'ha5) $fatal(1, "GPIO synchronizer latency failed");
        @(negedge clk); gpio_in = 8'h3c;
        @(posedge clk); #1;
        if (read_data !== 32'ha5) $fatal(1, "GPIO changed after only one stage");
        @(posedge clk); #1;
        if (read_data !== 32'h3c) $fatal(1, "GPIO second-stage sample failed");
        write_reg(32'h20000020, 32'h1234565a, 8'h5a, 0);
        write_reg(32'h20000028, 32'h123456f0, 8'h5a, 8'hf0);
        write_reg(32'h2000002c, 32'h81, 8'hdb, 8'hf0);
        write_reg(32'h20000030, 32'h18, 8'hc3, 8'hf0);
        write_reg(32'h20000034, 32'h0f, 8'hcc, 8'hf0);
        write_reg(32'h20000034, 32'hffffff00, 8'hcc, 8'hf0);
        write_reg(32'h20000024, 32'hff, 8'hcc, 8'hf0); // IN write ignored
        read_reg(32'h20000020, 32'hcc, 1, 1);
        read_reg(32'h20000024, 32'h3c, 1, 0);
        read_reg(32'h20000028, 32'hf0, 1, 1);
        read_reg(32'h2000002c, 0, 0, 1);
        read_reg(32'h20000030, 0, 0, 1);
        read_reg(32'h20000034, 0, 0, 1);
        read_reg(32'h20000021, 0, 0, 0);
        read_reg(32'h20000038, 0, 0, 0);
        @(negedge clk); rst_n = 0; #1;
        read_reg(32'h20000020, 0, 1, 1);
        read_reg(32'h20000028, 0, 1, 1);
        read_reg(32'h20000024, 0, 1, 0);
        $display("PASS: GPIO peripheral decode, masking, synchronization and reset");
        $stop;
    end
endmodule
