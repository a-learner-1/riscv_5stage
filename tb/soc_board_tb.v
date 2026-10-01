`timescale 1ns/1ps
module soc_board_tb;
    wire [1:0] done;
    reg test_pass=0;
    soc_echo_board_case echo_board(done[0]);
    soc_demo_board_case demo_board(done[1]);
    initial begin
        wait(&done);
        test_pass=1;
        $display("PASS: SoC board wrappers: physical-rate RX/TX 16-byte echo and KEY1 restart; existing Hello/GPIO firmware, LED heartbeat, KEY2 and second boot");
        $stop;
    end
    initial begin #5000000; $fatal(1,"SoC board timeout done=%b",done); end
endmodule

`timescale 1ns/1ps
module soc_echo_board_case(output reg done=0);
    reg clk_50m = 0;
    reg key1_n = 1;
    reg rx = 1;
    wire tx;
    wire [7:0] led;
    integer received = 0;
    integer bit_index;
    integer send_index;
    reg [7:0] value;
    localparam integer BIT_NS = 434 * 20;

    soc_board_top #(
        .PROGRAM_FILE("programs/uart_rx_echo.hex"),
        .DATA_FILE("programs/uart_rx_echo_data.hex"),
        .RESET_HOLD_CYCLES(16)
    ) dut (
        .clk_50m(clk_50m), .key1_n(key1_n), .keys_n(7'h7f),
        .led(led), .uart_tx(tx), .uart_rx(rx)
    );
    always #10 clk_50m = ~clk_50m;

    function [7:0] expected_byte;
        input integer index;
        begin
            case (index % 8)
                0: expected_byte = 8'h00;
                1: expected_byte = 8'hff;
                2: expected_byte = "R";
                3: expected_byte = "X";
                4: expected_byte = 8'h55;
                5: expected_byte = 8'haa;
                6: expected_byte = 8'h0d;
                7: expected_byte = 8'h0a;
            endcase
        end
    endfunction

    task send_byte;
        input [7:0] character;
        integer bit_number;
        begin
            @(negedge clk_50m); #7;
            rx = 0;
            #(BIT_NS);
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                rx = character[bit_number];
                #(BIT_NS);
            end
            rx = 1;
            #(BIT_NS);
        end
    endtask

    // Decode the actual board-level serial output at 50MHz / 115200.
    initial begin
        forever begin
            @(negedge tx);
            if (!dut.cpu_rst_n) $fatal(1, "Board echo during reset");
            #(BIT_NS / 2);
            if (tx !== 0) $fatal(1, "Board echo start bit");
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #(BIT_NS);
                value[bit_index] = tx;
            end
            #(BIT_NS);
            if (tx !== 1 || received >= 16 || value !== expected_byte(received))
                $fatal(1, "Board echo index=%0d got=%h expected=%h",
                       received, value, expected_byte(received));
            received = received + 1;
        end
    end

    initial begin
        #4000000;
        $fatal(1, "Board RX echo timeout received=%0d", received);
    end

    initial begin
        wait (dut.cpu_rst_n === 1);
        repeat (100) @(posedge clk_50m);
        for (send_index = 0; send_index < 8; send_index = send_index + 1)
            send_byte(expected_byte(send_index));
        wait (received == 8);
        wait (dut.u_soc.u_cpu.uart_busy === 0);
        if (dut.u_soc.u_cpu.u_uart_rx_mmio.read_data[3:2] !== 0 &&
            dut.u_soc.u_cpu.mem_addr_x == 32'h2000001c)
            $fatal(1, "Unexpected board RX errors");

        // KEY1 aborts an incomplete RX frame and clears FIFO/error state.
        @(negedge clk_50m); #7; rx = 0;
        #(BIT_NS * 3);
        key1_n = 0;
        #100;
        if (tx !== 1 || dut.cpu_rst_n !== 0)
            $fatal(1, "Board KEY1 reset failed");
        rx = 1;
        repeat (5) @(negedge clk_50m);
        key1_n = 1;
        wait (dut.cpu_rst_n === 1);
        repeat (100) @(posedge clk_50m);
        if (received != 8 || dut.u_soc.u_cpu.u_uart_rx_mmio.u_fifo.count !== 0)
            $fatal(1, "Partial frame survived reset");
        for (send_index = 8; send_index < 16; send_index = send_index + 1)
            send_byte(expected_byte(send_index));
        wait (received == 16);
        wait (dut.u_soc.u_cpu.uart_busy === 0);
        repeat (100) @(posedge clk_50m);
        if (led !== 0 || dut.u_soc.u_dmem.u_data_mem.mem[4095] !== 0 ||
            dut.u_soc.u_cpu.u_uart_rx_mmio.u_fifo.count !== 0 ||
            dut.u_soc.u_cpu.u_uart_rx_mmio.overflow_sticky !== 0 ||
            dut.u_soc.u_cpu.u_uart_rx_mmio.frame_error_sticky !== 0)
            $fatal(1, "Board infinite echo final state");
        done = 1;
        $display("PASS: board UART RX/TX echo 50MHz 115200 16 bytes and KEY1 mid-frame restart");

    end
    always @(posedge clk_50m) if (dut.cpu_rst_n && !done) begin
        if (dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en ||
            dut.u_soc.u_cpu.u_data_mem.re || dut.u_soc.u_cpu.u_data_mem.we)
            $fatal(1, "SoC board used CPU internal memory");
        if (dut.u_soc.imem_fault || dut.u_soc.dmem_fault)
            $fatal(1, "SoC board memory fault");
    end
endmodule

`timescale 1ns/1ps
module soc_demo_board_case(output reg done=0);
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

    soc_board_top #(
        .DATA_FILE("programs/board_demo_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)
    ) dut (
        .clk_50m(clk_50m), .key1_n(key1_n), .keys_n(keys_n),
        .led(led), .uart_tx(uart_tx), .uart_rx(1'b1)
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
        wait (dut.u_soc.u_cpu.uart_busy === 0);
        if (dut.gpio_oe !== 8'hff)
            $fatal(1, "Firmware did not enable LED outputs");
        old_led = led[0];
        wait_for_led(0, !old_led);
        wait_for_led(0, old_led);
        @(negedge clk_50m); keys_n[0] = 0; // KEY2, active-low -> LED2
        wait_for_led(1, 1);
        @(negedge clk_50m); keys_n[0] = 1;
        wait_for_led(1, 0);
        if (dut.u_soc.u_dmem.u_data_mem.mem[4095] !== 0)
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
        wait (dut.u_soc.u_cpu.uart_busy === 0);
        $display("PASS: board power-on reset, 50MHz UART, CPU-driven LED blink, KEY2 and KEY1 restart");
        $display("NOTE: short blink/reset delays used in simulation; physical board not tested");
        done = 1;
    end
    always @(posedge clk_50m) if (dut.cpu_rst_n && !done) begin
        if (dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en ||
            dut.u_soc.u_cpu.u_data_mem.re || dut.u_soc.u_cpu.u_data_mem.we)
            $fatal(1, "SoC board used CPU internal memory");
        if (dut.u_soc.imem_fault || dut.u_soc.dmem_fault)
            $fatal(1, "SoC board memory fault");
    end
endmodule
