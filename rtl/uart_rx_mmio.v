// UART receive MMIO, used only with CPU-validated aligned LW/SW accesses.
// 0x20000018 RX_DATA: read head byte, pop once on read_enable, empty -> 0.
// 0x2000001c RX_STATUS: bit0 nonempty, bit1 full, bit2 sticky overflow,
// bit3 sticky framing error, bits15:8 occupancy. Write-one-clear bits2/3.
// New events take priority over software clearing the corresponding flag.
module uart_rx_mmio #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200,
    parameter integer FIFO_DEPTH = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,
    input  wire [31:0] addr,
    input  wire        read_enable,
    input  wire        write_enable,
    input  wire [31:0] write_data,
    output reg  [31:0] read_data,
    output wire        read_hit,
    output wire        write_hit
);
    localparam [31:0] RX_DATA_ADDR = 32'h2000_0018;
    localparam [31:0] RX_STATUS_ADDR = 32'h2000_001c;

    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_frame_error;
    wire [7:0] fifo_data;
    wire fifo_empty;
    wire fifo_full;
    wire [$clog2(FIFO_DEPTH+1)-1:0] fifo_count;
    wire fifo_overflow;
    wire fifo_pop;
    wire clear_overflow;
    wire clear_frame_error;
    wire [7:0] occupancy;
    reg overflow_sticky;
    reg frame_error_sticky;

    assign read_hit = (addr == RX_DATA_ADDR) || (addr == RX_STATUS_ADDR);
    assign write_hit = (addr == RX_STATUS_ADDR);
    assign fifo_pop = read_enable && (addr == RX_DATA_ADDR);
    assign clear_overflow = write_enable && write_hit && write_data[2];
    assign clear_frame_error = write_enable && write_hit && write_data[3];
    assign occupancy = fifo_count;

    // synthesis translate_off
    initial begin
        if (FIFO_DEPTH < 1 || FIFO_DEPTH > 255)
            $fatal(1, "UART RX MMIO FIFO_DEPTH must be 1..255 for 8-bit occupancy");
    end
    // synthesis translate_on

    uart_rx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(rx),
        .data(rx_data), .valid(rx_valid), .frame_error(rx_frame_error)
    );

    uart_rx_fifo #(.DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk), .rst_n(rst_n), .push(rx_valid), .push_data(rx_data),
        .pop(fifo_pop), .data(fifo_data), .empty(fifo_empty),
        .full(fifo_full), .count(fifo_count), .overflow(fifo_overflow)
    );

    always @* begin
        case (addr)
            RX_DATA_ADDR: read_data = {24'd0, fifo_data};
            RX_STATUS_ADDR: read_data = {
                16'd0, occupancy, 4'd0, frame_error_sticky,
                overflow_sticky, fifo_full, !fifo_empty
            };
            default: read_data = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow_sticky    <= 1'b0;
            frame_error_sticky <= 1'b0;
        end else begin
            overflow_sticky <= fifo_overflow ||
                               (overflow_sticky && !clear_overflow);
            frame_error_sticky <= rx_frame_error ||
                                  (frame_error_sticky && !clear_frame_error);
        end
    end
endmodule
