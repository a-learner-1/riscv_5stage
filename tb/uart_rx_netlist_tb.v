// Actual hardware-image synthesis netlist; functional only, no routing SDF.
`timescale 1ns/1ps
module uart_rx_netlist_tb;
    reg clk_50m = 0;
    reg key1_n = 1;
    reg rx = 1;
    wire tx;
    wire [7:0] led;
    integer received = 0;
    integer send_index;
    integer bit_index;
    reg [7:0] value;
    reg test_pass = 0;
    localparam integer BIT_NS = 434 * 20;
    board_top dut (
        .clk_50m(clk_50m), .key1_n(key1_n), .keys_n(7'h7f),
        .led(led), .uart_rx(rx), .uart_tx(tx)
    );
    always #10 clk_50m = ~clk_50m;

    function [7:0] expected_byte;
        input integer index;
        begin
            case (index % 4)
                0: expected_byte = 8'h00;
                1: expected_byte = 8'hff;
                2: expected_byte = 8'h55;
                3: expected_byte = 8'haa;
            endcase
        end
    endfunction

    task send_byte;
        input [7:0] character;
        integer bit_number;
        begin
            @(negedge clk_50m); #7; rx = 0;
            #(BIT_NS);
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                rx = character[bit_number];
                #(BIT_NS);
            end
            rx = 1;
            #(BIT_NS);
        end
    endtask

    initial begin
        forever begin
            @(negedge tx);
            if (!key1_n) $fatal(1, "Netlist echo during reset");
            #(BIT_NS / 2);
            if (tx !== 0) $fatal(1, "Netlist echo start bit");
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #(BIT_NS); value[bit_index] = tx;
            end
            #(BIT_NS);
            if (tx !== 1 || received >= 8 || value !== expected_byte(received))
                $fatal(1, "Netlist echo index=%0d got=%h expected=%h",
                       received, value, expected_byte(received));
            received = received + 1;
        end
    end

    initial begin
        #100;
        if (tx !== 1 || led !== 0) $fatal(1, "Netlist power-on defaults");
        // Hardware uses a 50000-cycle reset hold, rather than the RTL test's 16.
        #1100000;
        for (send_index = 0; send_index < 4; send_index = send_index + 1)
            send_byte(expected_byte(send_index));
        wait (received == 4);
        #(BIT_NS * 2);
        key1_n = 0;
        #200;
        if (tx !== 1 || led !== 0) $fatal(1, "Netlist KEY1 reset defaults");
        key1_n = 1;
        #1100000;
        for (send_index = 4; send_index < 8; send_index = send_index + 1)
            send_byte(expected_byte(send_index));
        wait (received == 8);
        #(BIT_NS * 3);
        if (tx !== 1 || led !== 0) $fatal(1, "Netlist echo final defaults");
        test_pass = 1;
        $display("PASS: synthesized hardware-image UART RX/FIFO/CPU/TX echo 8 bytes and KEY1 restart");
        $stop;
    end
    initial begin #6000000; $fatal(1, "Netlist RX echo timeout received=%0d", received); end
endmodule
