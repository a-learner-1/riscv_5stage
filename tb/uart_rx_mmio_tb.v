`timescale 1ns/1ps
module uart_rx_mmio_tb;
    localparam integer CPB = 16;
    localparam integer BIT_NS = CPB * 10;
    localparam integer FIFO_DEPTH = 16;
    localparam [31:0] RX_DATA = 32'h20000018;
    localparam [31:0] RX_STATUS = 32'h2000001c;
    reg clk = 0;
    reg rst_n = 0;
    reg rx = 1;
    reg [31:0] addr = 0;
    reg read_enable = 0, write_enable = 0;
    reg [31:0] write_data = 0;
    wire [31:0] read_data;
    wire read_hit, write_hit;
    reg test_pass = 0;
    integer index;

    uart_rx_mmio #(.CLOCK_HZ(100000000), .BAUD(6250000),
                   .FIFO_DEPTH(FIFO_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .rx(rx), .addr(addr),
        .read_enable(read_enable), .write_enable(write_enable),
        .write_data(write_data), .read_data(read_data),
        .read_hit(read_hit), .write_hit(write_hit)
    );
    always #5 clk = ~clk;

    function [31:0] status_value;
        input integer occupancy;
        input has_overflow, has_frame_error;
        begin
            status_value = (occupancy << 8) |
                           ((occupancy != 0) ? 32'h1 : 32'h0) |
                           ((occupancy == FIFO_DEPTH) ? 32'h2 : 32'h0) |
                           (has_overflow ? 32'h4 : 32'h0) |
                           (has_frame_error ? 32'h8 : 32'h0);
        end
    endfunction

    // Data is sampled before the active edge, when a successful read pops it.
    task bus_read;
        input [31:0] read_address;
        input [31:0] expected_data;
        input expected_hit;
        begin
            @(negedge clk);
            addr = read_address;
            read_enable = 1;
            write_enable = 0;
            #1;
            if (read_hit !== expected_hit || write_hit !== (addr == RX_STATUS))
                $fatal(1, "MMIO read hit addr=%h read_hit=%b write_hit=%b",
                       addr, read_hit, write_hit);
            if (expected_hit && read_data !== expected_data)
                $fatal(1, "MMIO read addr=%h got=%h expected=%h",
                       addr, read_data, expected_data);
            @(posedge clk);
            #1;
            @(negedge clk);
            read_enable = 0;
            addr = 0;
        end
    endtask

    task bus_write;
        input [31:0] write_address;
        input [31:0] value;
        input expected_hit;
        begin
            @(negedge clk);
            addr = write_address;
            write_enable = 1;
            read_enable = 0;
            write_data = value;
            #1;
            if (write_hit !== expected_hit ||
                read_hit !== ((addr == RX_DATA) || (addr == RX_STATUS)))
                $fatal(1, "MMIO write hit addr=%h write_hit=%b read_hit=%b",
                       addr, write_hit, read_hit);
            @(posedge clk);
            #1;
            @(negedge clk);
            write_enable = 0;
            write_data = 0;
            addr = 0;
        end
    endtask

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

    task settle;
        begin
            repeat (CPB * 2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        settle;
        bus_read(RX_STATUS, 0, 1);
        bus_read(RX_DATA, 0, 1);
        bus_read(RX_DATA, 0, 1);
        bus_read(RX_STATUS, 0, 1);
        bus_read(RX_DATA + 1, 0, 0);
        bus_read(32'h20000010, 0, 0);
        bus_write(RX_DATA, 32'hff, 0);
        bus_write(RX_STATUS + 1, 32'hc, 0);
        bus_read(RX_STATUS, 0, 1);

        #3;
        wire_frame(8'h80, 1'b1);
        settle;
        bus_read(RX_STATUS, status_value(1, 0, 0), 1);
        bus_read(RX_STATUS, status_value(1, 0, 0), 1); // Status does not pop.
        // Address decoding alone must not perform a read without its strobe.
        @(negedge clk);
        addr = RX_DATA;
        read_enable = 0;
        write_enable = 0;
        repeat (4) @(negedge clk);
        bus_read(RX_STATUS, status_value(1, 0, 0), 1);
        bus_write(RX_DATA, 32'hff, 0);               // Data is read-only.
        bus_read(RX_DATA, 32'h80, 1);
        bus_read(RX_STATUS, 0, 1);
        bus_read(RX_DATA, 0, 1);

        // Fill using actual asynchronous serial frames, with no idle gap.
        #7;
        for (index = 0; index < FIFO_DEPTH; index = index + 1)
            wire_frame(8'h40 + index, 1'b1);
        settle;
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 0, 0), 1);
        #3;
        wire_frame(8'hee, 1'b1); // Full queue rejects byte and records overflow.
        settle;
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 1, 0), 1);
        bus_write(RX_STATUS, 32'h4, 1);
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 0, 0), 1);

        // Bad stop is discarded, even with a full queue; it is not overflow.
        #1;
        wire_frame(8'h96, 1'b0);
        rx = 1;
        settle;
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 0, 1), 1);
        bus_write(RX_STATUS, 32'h8, 1);
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 0, 0), 1);

        // Only this coincidence test injects internal error events. Fresh
        // errors must take priority over a W1C issued on the same clock.
        @(negedge clk);
        force dut.fifo_overflow = 1'b1;
        force dut.rx_frame_error = 1'b1;
        bus_write(RX_STATUS, 32'hc, 1);
        release dut.fifo_overflow;
        release dut.rx_frame_error;
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 1, 1), 1);
        bus_write(RX_STATUS, 32'hfffffff3, 1); // Zeros in W1C bits retain flags.
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 1, 1), 1);
        bus_write(RX_STATUS, 32'hc, 1);
        bus_read(RX_STATUS, status_value(FIFO_DEPTH, 0, 0), 1);

        // Clearing flags never clears the queue or changes byte order.
        for (index = 0; index < FIFO_DEPTH; index = index + 1) begin
            bus_read(RX_DATA, 32'h40 + index, 1);
            bus_read(RX_STATUS, status_value(FIFO_DEPTH - index - 1, 0, 0), 1);
        end
        bus_read(RX_DATA, 0, 1);

        // A bad frame on an empty queue still leaves it empty.
        #3;
        wire_frame(8'h00, 1'b0);
        rx = 1;
        settle;
        bus_read(RX_STATUS, status_value(0, 0, 1), 1);
        bus_read(RX_DATA, 0, 1);
        #7;
        wire_frame(8'ha5, 1'b1);
        settle;
        bus_read(RX_STATUS, status_value(1, 0, 1), 1);
        @(negedge clk);
        rst_n = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        settle;
        bus_read(RX_STATUS, 0, 1);
        bus_read(RX_DATA, 0, 1);

        test_pass = 1;
        $display("PASS: UART RX MMIO serial input, FIFO order/count, empty reads, W1C, fresh-error priority and reset");
        $stop;
    end

    initial begin
        #200000;
        $fatal(1, "UART RX MMIO test timeout");
    end
endmodule
