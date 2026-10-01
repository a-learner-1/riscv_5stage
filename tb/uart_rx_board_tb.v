`timescale 1ns/1ps
module uart_rx_board_tb;
    reg clk_50m = 0;
    reg key1_n = 1;
    reg rx = 1;
    wire tx;
    wire [7:0] led;
    integer received = 0;
    integer bit_index;
    integer send_index;
    reg [7:0] value;
    reg test_pass = 0;
    localparam integer BIT_NS = 434 * 20;

    board_top #(
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
        wait (dut.u_cpu.uart_busy === 0);
        if (dut.u_cpu.u_uart_rx_mmio.read_data[3:2] !== 0 &&
            dut.u_cpu.mem_addr_x == 32'h2000001c)
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
        if (received != 8 || dut.u_cpu.u_uart_rx_mmio.u_fifo.count !== 0)
            $fatal(1, "Partial frame survived reset");
        for (send_index = 8; send_index < 16; send_index = send_index + 1)
            send_byte(expected_byte(send_index));
        wait (received == 16);
        wait (dut.u_cpu.uart_busy === 0);
        repeat (100) @(posedge clk_50m);
        if (led !== 0 || dut.u_cpu.u_data_mem.mem[4095] !== 0 ||
            dut.u_cpu.u_uart_rx_mmio.u_fifo.count !== 0 ||
            dut.u_cpu.u_uart_rx_mmio.overflow_sticky !== 0 ||
            dut.u_cpu.u_uart_rx_mmio.frame_error_sticky !== 0)
            $fatal(1, "Board infinite echo final state");
        test_pass = 1;
        $display("PASS: board UART RX/TX echo 50MHz 115200 16 bytes and KEY1 mid-frame restart");
        $stop;
    end
endmodule
