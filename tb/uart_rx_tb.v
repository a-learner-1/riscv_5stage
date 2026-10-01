`timescale 1ns/1ps
module uart_rx_tb;
    localparam integer CPB = 16;
    localparam integer BIT_NS = CPB * 10;
    reg clk = 0;
    reg rst_n = 0;
    reg rx = 1;
    wire [7:0] data;
    wire valid, frame_error;
    reg [7:0] expected [0:31];
    integer expected_count = 0;
    integer received_count = 0;
    integer error_count = 0;
    reg previous_valid = 0;
    reg previous_error = 0;
    reg test_pass = 0;
    integer before_valid, before_error;

    uart_rx #(.CLOCK_HZ(100000000), .BAUD(6250000)) dut (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(data),
        .valid(valid), .frame_error(frame_error)
    );
    always #5 clk = ~clk;

    // A scoreboard observes the public outputs, independently of RX state.
    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            previous_valid = 0;
            previous_error = 0;
            if (valid !== 0 || frame_error !== 0)
                $fatal(1, "RX reset did not clear pulse outputs");
        end else begin
            if (valid && frame_error)
                $fatal(1, "RX accepted a byte while reporting a framing error");
            if (valid && previous_valid)
                $fatal(1, "RX valid lasted more than one cycle");
            if (frame_error && previous_error)
                $fatal(1, "RX frame_error lasted more than one cycle");
            if (valid) begin
                if (received_count >= expected_count)
                    $fatal(1, "Unexpected RX byte %h", data);
                if (data !== expected[received_count])
                    $fatal(1, "RX byte %0d got=%h expected=%h",
                           received_count, data, expected[received_count]);
                received_count = received_count + 1;
            end
            if (frame_error)
                error_count = error_count + 1;
            previous_valid = valid;
            previous_error = frame_error;
        end
    end

    task wire_frame;
        input [7:0] value;
        input good_stop;
        integer bit_index;
        begin
            rx = 0;
            #(BIT_NS);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rx = value[bit_index];
                #(BIT_NS);
            end
            rx = good_stop;
            #(BIT_NS);
        end
    endtask

    task good_frame;
        input [7:0] value;
        begin
            expected[expected_count] = value;
            expected_count = expected_count + 1;
            wire_frame(value, 1'b1);
        end
    endtask

    task settle;
        begin
            repeat (CPB * 2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        settle;

        // Start at three distinct phases, away from the clock sampling edge.
        #3;
        good_frame(8'h00);
        settle;
        #7;
        good_frame(8'hff);
        settle;
        #1;
        good_frame(8'h55);
        settle;

        // The next start bit immediately follows the preceding stop bit.
        #3;
        good_frame(8'haa);
        good_frame(8'h80);
        good_frame(8'h01);
        good_frame(8'h7e);
        settle;
        if (received_count != 7 || error_count != 0)
            $fatal(1, "RX phase/back-to-back check received=%0d errors=%0d",
                   received_count, error_count);

        // A low pulse much shorter than half a bit is a false start.
        before_valid = received_count;
        before_error = error_count;
        #3;
        rx = 0;
        #20;
        rx = 1;
        repeat (CPB * 12) @(negedge clk);
        if (received_count != before_valid || error_count != before_error)
            $fatal(1, "False start generated a byte or a framing error");
        #7;
        good_frame(8'h3c);
        settle;

        // A bad stop bit must produce one error and must discard the byte.
        before_valid = received_count;
        before_error = error_count;
        #3;
        wire_frame(8'h96, 1'b0);
        rx = 1;
        settle;
        if (received_count != before_valid || error_count != before_error + 1)
            $fatal(1, "Bad stop did not discard exactly one frame");
        #1;
        good_frame(8'hc3);
        settle;

        // A continuous break reports once until the wire returns high.
        before_valid = received_count;
        before_error = error_count;
        #3;
        rx = 0;
        #(BIT_NS * 40);
        if (received_count != before_valid || error_count != before_error + 1)
            $fatal(1, "Continuous break generated repeated errors or a byte");
        rx = 1;
        settle;
        #7;
        good_frame(8'h5a);
        settle;

        // Reset in the middle of a frame aborts it without a later event.
        before_valid = received_count;
        before_error = error_count;
        #3;
        rx = 0;
        #(BIT_NS * 4 + 7);
        rst_n = 0;
        rx = 1;
        #1;
        if (valid !== 0 || frame_error !== 0)
            $fatal(1, "Mid-frame asynchronous reset failed");
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (CPB * 12) @(negedge clk);
        if (received_count != before_valid || error_count != before_error)
            $fatal(1, "Aborted frame generated an event after reset");
        #1;
        good_frame(8'h69);
        settle;

        if (received_count != expected_count || error_count != 2)
            $fatal(1, "RX final received=%0d expected=%0d errors=%0d",
                   received_count, expected_count, error_count);
        test_pass = 1;
        $display("PASS: UART RX asynchronous phases, back-to-back, false start, bad stop, break and reset");
        $stop;
    end

    initial begin
        #200000;
        $fatal(1, "UART RX unit test timeout");
    end
endmodule
