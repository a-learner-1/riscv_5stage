// UART receiver: eight data bits, no parity, one stop bit, LSB first.
// A frame is accepted only when its stop-bit center is high. valid and
// frame_error are one-clock pulses. A bad stop waits for idle-high before
// rearming, so a continuous low (break) reports one error and no data.
module uart_rx #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        frame_error
);
    localparam integer RAW_DIVISOR =
        (BAUD > 0) ? ((CLOCK_HZ + BAUD / 2) / BAUD) : 0;
    // Keep declarations well formed even for a rejected parameter set.
    localparam integer CLOCKS_PER_BIT =
        (RAW_DIVISOR >= 4) ? RAW_DIVISOR : 4;
    localparam integer HALF_BIT = (CLOCKS_PER_BIT + 1) / 2;
    localparam integer TIMER_WIDTH = $clog2(CLOCKS_PER_BIT);

    localparam [2:0] IDLE      = 3'd0;
    localparam [2:0] START_BIT = 3'd1;
    localparam [2:0] DATA_BITS = 3'd2;
    localparam [2:0] STOP_BIT  = 3'd3;
    localparam [2:0] WAIT_HIGH = 3'd4;

    (* ASYNC_REG = "TRUE" *) reg rx_meta;
    (* ASYNC_REG = "TRUE" *) reg rx_sync;
    reg [2:0] state;
    reg [TIMER_WIDTH-1:0] bit_timer;
    reg [2:0] bit_index;
    reg [7:0] received_data;

    // synthesis translate_off
    initial begin
        if (CLOCK_HZ <= 0 || BAUD <= 0 || RAW_DIVISOR < 4)
            $fatal(1, "UART RX requires CLOCK_HZ>0, BAUD>0 and clocks/bit>=4");
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            bit_timer     <= 0;
            bit_index     <= 0;
            received_data <= 0;
            data          <= 0;
            valid         <= 1'b0;
            frame_error   <= 1'b0;
        end else begin
            valid       <= 1'b0;
            frame_error <= 1'b0;
            case (state)
                IDLE: begin
                    bit_timer <= 0;
                    if (!rx_sync)
                        state <= START_BIT;
                end
                START_BIT: begin
                    if (bit_timer == HALF_BIT - 1) begin
                        bit_timer <= 0;
                        // Reject a short low pulse that is high at center.
                        if (rx_sync) begin
                            state <= IDLE;
                        end else begin
                            bit_index <= 0;
                            state <= DATA_BITS;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end
                DATA_BITS: begin
                    if (bit_timer == CLOCKS_PER_BIT - 1) begin
                        bit_timer <= 0;
                        received_data[bit_index] <= rx_sync;
                        if (bit_index == 3'd7)
                            state <= STOP_BIT;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end
                STOP_BIT: begin
                    if (bit_timer == CLOCKS_PER_BIT - 1) begin
                        bit_timer <= 0;
                        if (rx_sync) begin
                            data  <= received_data;
                            valid <= 1'b1;
                            state <= IDLE;
                        end else begin
                            frame_error <= 1'b1;
                            state <= WAIT_HIGH;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end
                WAIT_HIGH: begin
                    bit_timer <= 0;
                    if (rx_sync)
                        state <= IDLE;
                end
                default: begin
                    state <= IDLE;
                    bit_timer <= 0;
                end
            endcase
        end
    end
endmodule
