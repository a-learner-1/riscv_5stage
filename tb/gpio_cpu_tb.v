`timescale 1ns/1ps
module gpio_cpu_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg [7:0] gpio_in = 8'ha5;
    wire [7:0] gpio_out, gpio_oe;
    wire [31:0] pc_x, instr_x;
    wire [63:0] cycle_count, instret_count;
    reg [7:0] expected_out = 0;
    reg [7:0] expected_oe = 0;
    reg [7:0] captured_input;
    integer gpio_writes = 0;
    integer gpio_reads = 0;
    integer input_a5_reads = 0;
    integer input_3c_reads = 0;
    integer checks = 0;
    integer watchdog = 0;
    reg marker_seen = 0;
    localparam integer TOHOST_WORD = 4095;

    cpu_top #(
        .PROGRAM_FILE("programs/gpio_test.hex"),
        .DATA_FILE("programs/gpio_test_data.hex"),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000), .SIM_CONSOLE_ECHO(0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(),
        .wb_pc(), .wb_rd(), .wb_data(), .wb_we(), .retire_valid(),
        .cycle_count(cycle_count), .instret_count(instret_count), .uart_tx(),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe)
    );
    always #5 clk = ~clk;

    // Change external data away from a clock edge. The CPU must see the new
    // value through the two-stage synchronizer, not through combinational IO.
    always @(negedge clk) begin
        if (rst_n && !marker_seen && gpio_out == 8'h69) begin
            gpio_in = 8'h3c;
            marker_seen = 1;
        end
    end

    // Independent reference model: every accepted GPIO store is checked.
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.mmio_gpio_write_x) begin
                if (dut.mem_re_x || dut.mem_we_x)
                    $fatal(1, "GPIO write accessed ordinary RAM");
                gpio_writes = gpio_writes + 1;
                case (dut.mem_addr_x)
                    32'h20000020: expected_out = dut.rs2_value_x[7:0];
                    32'h20000028: expected_oe = dut.rs2_value_x[7:0];
                    32'h2000002c: expected_out = expected_out | dut.rs2_value_x[7:0];
                    32'h20000030: expected_out = expected_out & ~dut.rs2_value_x[7:0];
                    32'h20000034: expected_out = expected_out ^ dut.rs2_value_x[7:0];
                    default: $fatal(1, "Unexpected GPIO write address");
                endcase
                if (expected_out == 8'hee)
                    $fatal(1, "Squashed wrong-path GPIO store was accepted");
            end
            if (dut.load_issue_x && dut.gpio_read_hit_x) begin
                if (dut.mem_re_x || dut.mem_we_x)
                    $fatal(1, "GPIO read accessed ordinary RAM");
                gpio_reads = gpio_reads + 1;
                if (dut.mem_addr_x == 32'h20000024) begin
                    captured_input = dut.mmio_read_data_x[7:0];
                    if (captured_input === 8'ha5) input_a5_reads = input_a5_reads + 1;
                    if (captured_input === 8'h3c) input_3c_reads = input_3c_reads + 1;
                end
            end
            #1;
            checks = checks + 1;
            if (gpio_out !== expected_out || gpio_oe !== expected_oe)
                $fatal(1, "GPIO mismatch out=%h/%h oe=%h/%h",
                       gpio_out, expected_out, gpio_oe, expected_oe);
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        #2;
        if (gpio_out !== 0 || gpio_oe !== 0 || dut.u_gpio.gpio_in_sync !== 0)
            $fatal(1, "GPIO reset defaults failed");
        @(negedge clk); rst_n = 1;
        while (dut.u_data_mem.mem[TOHOST_WORD] === 32'd0) begin
            @(posedge clk); #2;
            watchdog = watchdog + 1;
            if (watchdog > 5000)
                $fatal(1, "GPIO CPU timeout pc=%h instr=%h", pc_x, instr_x);
        end
        if (dut.u_data_mem.mem[TOHOST_WORD] !== 1)
            $fatal(1, "GPIO C self-test failed tohost=%0d pc=%h",
                   dut.u_data_mem.mem[TOHOST_WORD], pc_x);
        if (!marker_seen || input_a5_reads == 0 || input_3c_reads == 0)
            $fatal(1, "GPIO external-input transition was not covered");
        if (gpio_writes != 14 || gpio_reads < 15)
            $fatal(1, "GPIO transaction coverage writes=%0d reads=%0d",
                   gpio_writes, gpio_reads);
        if (gpio_out !== 8'haa || gpio_oe !== 0)
            $fatal(1, "Final GPIO output/direction mismatch");
        @(negedge clk); rst_n = 0;
        #2;
        if (gpio_out !== 0 || gpio_oe !== 0 || dut.u_gpio.gpio_in_sync !== 0)
            $fatal(1, "GPIO asynchronous reset did not clear state");
        $display("GPIO: tohost=1 writes=%0d reads=%0d input=A5->3C", gpio_writes, gpio_reads);
        $display("GPIO: output=AA direction=00 before reset; reset output=00 direction=00");
        $display("PASS: CPU GPIO C program, readback, SET/CLEAR/TOGGLE, squash and RAM isolation");
        $stop;
    end
endmodule
