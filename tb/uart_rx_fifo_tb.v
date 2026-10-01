`timescale 1ns/1ps

// Each checker uses a reference queue, including depths that cannot wrap
// correctly by simply truncating a binary pointer.
module uart_rx_fifo_case #(parameter integer DEPTH = 16) (output reg done = 0);
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    reg clk = 0;
    reg rst_n = 0;
    reg push = 0, pop = 0;
    reg [7:0] push_data = 0;
    wire [7:0] data;
    wire empty, full, overflow;
    wire [COUNT_W-1:0] count;
    reg [7:0] reference_queue [0:DEPTH-1];
    integer reference_count = 0;
    integer reference_head = 0;
    integer reference_tail = 0;
    integer index;

    uart_rx_fifo #(.DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .push(push), .push_data(push_data),
        .pop(pop), .data(data), .empty(empty), .full(full),
        .count(count), .overflow(overflow)
    );
    always #5 clk = ~clk;

    task check_state;
        input expect_overflow;
        begin
            if (count !== reference_count[COUNT_W-1:0] ||
                empty !== (reference_count == 0) ||
                full !== (reference_count == DEPTH))
                $fatal(1, "FIFO depth=%0d count=%0d expected=%0d empty=%b full=%b",
                       DEPTH, count, reference_count, empty, full);
            if (overflow !== expect_overflow)
                $fatal(1, "FIFO depth=%0d overflow=%b expected=%b",
                       DEPTH, overflow, expect_overflow);
            if (reference_count > 0 && data !== reference_queue[reference_head])
                $fatal(1, "FIFO depth=%0d head=%h expected=%h",
                       DEPTH, data, reference_queue[reference_head]);
        end
    endtask

    task cycle;
        input request_push;
        input request_pop;
        input [7:0] value;
        reg accept_push, accept_pop, expect_overflow;
        begin
            @(negedge clk);
            push = request_push;
            pop = request_pop;
            push_data = value;
            accept_pop = request_pop && reference_count > 0;
            accept_push = request_push &&
                          (reference_count < DEPTH || accept_pop);
            expect_overflow = request_push && !accept_push;
            if (accept_pop)
                reference_head = (reference_head + 1) % DEPTH;
            if (accept_push) begin
                reference_queue[reference_tail] = value;
                reference_tail = (reference_tail + 1) % DEPTH;
            end
            reference_count = reference_count + accept_push - accept_pop;
            @(posedge clk);
            #1;
            check_state(expect_overflow);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        #1;
        check_state(1'b0);
        rst_n = 1;
        cycle(0, 0, 0);
        cycle(0, 1, 0);  // Empty pop has no effect.

        // On empty, simultaneous push/pop keeps the newly received byte.
        cycle(1, 1, 8'ha5);
        if (reference_count != 1 || data !== 8'ha5)
            $fatal(1, "FIFO depth=%0d empty simultaneous operation lost byte", DEPTH);
        cycle(0, 1, 0);

        for (index = 0; index < DEPTH; index = index + 1)
            cycle(1, 0, 8'h20 + index);
        cycle(1, 0, 8'hee);  // Reject overflow, preserving order and head.
        cycle(0, 0, 0);     // Overflow indication must clear on the next cycle.

        // A full FIFO can replace the popped head without overflowing.
        cycle(1, 1, 8'hf0);
        for (index = 0; index < DEPTH; index = index + 1)
            cycle(0, 1, 0);
        cycle(0, 1, 0);

        // Repeated wraparound and transitions through both boundary states.
        for (index = 0; index < DEPTH * 4 + 5; index = index + 1) begin
            cycle(1, 0, index[7:0] ^ 8'h5a);
            cycle(1, 1, index[7:0] ^ 8'ha5);
            cycle(0, 1, 0);
        end
        cycle(1, 0, 8'h7e);
        @(negedge clk);
        push = 0;
        pop = 0;
        rst_n = 0;
        reference_count = 0;
        reference_head = 0;
        reference_tail = 0;
        #1;
        check_state(1'b0);
        repeat (2) @(negedge clk);
        rst_n = 1;
        cycle(1, 0, 8'hc3);
        cycle(0, 1, 0);
        @(negedge clk);
        push = 0;
        pop = 0;
        done = 1;
    end
endmodule

module uart_rx_fifo_tb;
    wire done16, done3, done1;
    reg test_pass = 0;
    uart_rx_fifo_case #(.DEPTH(16)) case16 (.done(done16));
    uart_rx_fifo_case #(.DEPTH(3)) case3 (.done(done3));
    uart_rx_fifo_case #(.DEPTH(1)) case1 (.done(done1));
    initial begin
        wait (done16 && done3 && done1);
        test_pass = 1;
        $display("PASS: UART RX FIFO depth16/depth3/depth1 order, wrap, overflow, simultaneous operations and reset");
        $stop;
    end
    initial begin
        #100000;
        $fatal(1, "UART RX FIFO test timeout");
    end
endmodule
