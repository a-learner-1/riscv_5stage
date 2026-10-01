`timescale 1ns/1ps
module board_top_tb;
    reg clk_50m = 0;
    // Test FPGA power-on initialization without an artificial reset pulse.
    reg key1_n = 1;
    reg [6:0] keys_n = 7'h7f;
    wire [7:0] led;
    wire uart_tx;
    integer received = 0;
    integer boots = 0;
    integer watchdog = 0;
    integer wait_cycles;
    reg [7:0] expected [0:13];
    reg [7:0] byte_value;
    reg old_led;
    integer bit_number;
    localparam integer CLOCKS_PER_BIT = 434; // 50MHz / 115200, rounded
    localparam integer BIT_NS = CLOCKS_PER_BIT * 20;

    board_top #(
        .DATA_FILE("programs/board_demo_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)
    ) dut (
        .clk_50m(clk_50m), .key1_n(key1_n), .keys_n(keys_n),
        .led(led), .uart_tx(uart_tx)
    );
    always #10 clk_50m = ~clk_50m;

    // Decode the actual UART pin, not the CPU's simulation console.
    initial begin
        expected[0]="H"; expected[1]="e"; expected[2]="l"; expected[3]="l";
        expected[4]="o"; expected[5]=" "; expected[6]="R"; expected[7]="I";
        expected[8]="S"; expected[9]="C"; expected[10]="-"; expected[11]="V";
        expected[12]=8'h0d; expected[13]=8'h0a;
        forever begin
            @(negedge uart_tx);
            if (dut.cpu_rst_n) begin
                #(BIT_NS / 2);
                if (uart_tx !== 0) $fatal(1, "UART start bit mismatch");
                byte_value = 0;
                for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                    #(BIT_NS);
                    if (uart_tx !== 0 && uart_tx !== 1)
                        $fatal(1, "Unknown UART data");
                    byte_value[bit_number] = uart_tx;
                end
                #(BIT_NS);
                if (uart_tx !== 1) $fatal(1, "UART stop bit mismatch");
                if (byte_value !== expected[received])
                    $fatal(1, "UART byte %0d got=%h expected=%h",
                           received, byte_value, expected[received]);
                received = received + 1;
                if (received == 14) begin
                    received = 0;
                    boots = boots + 1;
                    $display("BOARD: boot=%0d UART received Hello RISC-V (CR LF)", boots);
                end
            end
        end
    end

    task wait_for_led;
        input integer index;
        input reg value;
        begin
            wait_cycles = 0;
            while (led[index] !== value) begin
                @(posedge clk_50m); #2;
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 10000)
                    $fatal(1, "LED%0d timeout expected=%b gpio=%h", index+1, value, led);
            end
        end
    endtask

    always @(posedge clk_50m) begin
        watchdog = watchdog + 1;
        if (watchdog > 180000)
            $fatal(1, "Board demo timeout boots=%0d", boots);
        #2;
        if (led !== (dut.gpio_out & dut.gpio_oe))
            $fatal(1, "Board LED polarity/output-enable mapping failed");
    end

    initial begin
        #2;
        if (dut.cpu_rst_n !== 0 || led !== 0 || uart_tx !== 1)
            $fatal(1, "Board power-on reset/defaults failed");
        repeat (15) @(posedge clk_50m);
        #2;
        if (dut.cpu_rst_n !== 0) $fatal(1, "Power-on reset released too soon");
        wait (dut.cpu_rst_n === 1);
        wait (boots == 1);
        wait (dut.u_cpu.uart_busy === 0);
        if (dut.gpio_oe !== 8'hff)
            $fatal(1, "Firmware did not enable LED outputs");
        old_led = led[0];
        wait_for_led(0, !old_led);
        wait_for_led(0, old_led);
        @(negedge clk_50m); keys_n[0] = 0; // KEY2, active-low -> LED2
        wait_for_led(1, 1);
        @(negedge clk_50m); keys_n[0] = 1;
        wait_for_led(1, 0);
        if (dut.u_cpu.u_data_mem.mem[4095] !== 0)
            $fatal(1, "Board program unexpectedly returned through tohost");

        @(negedge clk_50m); key1_n = 0;
        #2;
        if (dut.cpu_rst_n !== 0 || led !== 0 || uart_tx !== 1)
            $fatal(1, "KEY1 asynchronous reset failed");
        repeat (4) @(negedge clk_50m);
        key1_n = 1;
        repeat (15) @(posedge clk_50m);
        #2;
        if (dut.cpu_rst_n !== 0) $fatal(1, "KEY1 release hold failed");
        wait (boots == 2);
        wait (dut.u_cpu.uart_busy === 0);
        $display("PASS: board power-on reset, 50MHz UART, CPU-driven LED blink, KEY2 and KEY1 restart");
        $display("NOTE: short blink/reset delays used in simulation; physical board not tested");
        $stop;
    end
endmodule
