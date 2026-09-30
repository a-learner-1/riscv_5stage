`timescale 1ns/1ps
module uart_tx_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg valid = 0;
    reg [7:0] data = 0;
    wire tx, busy, done;
    integer received = 0;
    integer done_pulses = 0;
    reg previous_done = 0;
    time accepted_at;
    reg [7:0] byte_value;
    integer bit_number;

    uart_tx #(.CLOCK_HZ(100000000), .BAUD(12500000)) dut (
        .clk(clk), .rst_n(rst_n), .valid(valid), .data(data),
        .tx(tx), .busy(busy), .done(done)
    );
    always #5 clk = ~clk;

    function [7:0] expected_byte;
        input integer index;
        case (index)
            0: expected_byte = 8'h00;
            1: expected_byte = 8'hff;
            2: expected_byte = 8'h55;
            3: expected_byte = 8'haa;
            4: expected_byte = 8'h80;
            default: expected_byte = 8'hxx;
        endcase
    endfunction

    task send_byte;
        input [7:0] value;
        begin
            wait (!busy);
            @(negedge clk);
            valid = 1;
            data = value;
            @(negedge clk);
            valid = 0;
        end
    endtask

    // Check total frame duration and the one-cycle completion pulse.
    always @(posedge clk) begin
        if (rst_n && valid && !busy)
            accepted_at = $time;
        #1;
        if (rst_n) begin
            if (done && previous_done)
                $fatal(1, "UART done lasted more than one cycle");
            if (done) begin
                if (busy || tx !== 1'b1)
                    $fatal(1, "UART completion did not return to idle");
                done_pulses = done_pulses + 1;
            end
            previous_done = done;
        end else
            previous_done = 0;
    end

    always @(negedge busy) begin
        if (rst_n && $time > 0 && ($time - accepted_at) != 800)
            $fatal(1, "Wrong frame length: %0t, expected 800ns",
                   $time - accepted_at);
    end

    // Independent receiver samples the wire at the center of each bit.
    initial begin
        wait (rst_n);
        while (received < 5) begin
            @(negedge tx);
            #40;
            if (tx !== 0 || busy !== 1)
                $fatal(1, "Invalid UART start bit");
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                #80;
                byte_value[bit_number] = tx;
            end
            #80;
            if (tx !== 1 || busy !== 1)
                $fatal(1, "UART stop bit must be high and still busy");
            if (byte_value !== expected_byte(received))
                $fatal(1, "UART byte %0d got=%h expected=%h",
                       received, byte_value, expected_byte(received));
            #41;
            received = received + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        #1;
        if (tx !== 1 || busy !== 0)
            $fatal(1, "UART reset idle state incorrect");

        send_byte(8'h00);
        // Attempt another request during this frame.  It must be ignored.
        repeat (3) @(negedge clk);
        data = 8'hee;
        valid = 1;
        @(negedge clk);
        valid = 0;
        send_byte(8'hff);
        send_byte(8'h55);
        send_byte(8'haa);
        send_byte(8'h80);
        wait (received == 5);
        @(negedge clk);
        if (done_pulses != 5)
            $fatal(1, "Unexpected completion pulse count=%0d", done_pulses);

        // An asynchronous reset in the middle of a frame must abort it.
        send_byte(8'h00);
        repeat (3) @(negedge clk);
        rst_n = 0;
        #1;
        if (tx !== 1 || busy !== 0 || done !== 0)
            $fatal(1, "Mid-frame reset failed");
        @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
        if (tx !== 1 || busy !== 0 || done_pulses != 5)
            $fatal(1, "Unexpected frame after reset");

        $display("PASS: UART TX 8N1 timing, byte patterns, busy and reset");
        $stop;
    end

    initial begin
        #20000;
        $fatal(1, "UART unit test timeout");
    end
endmodule
