// UART transmitter: eight data bits, no parity, one stop bit, LSB first.
// valid is accepted only when busy=0.  Input data is latched on acceptance.
module uart_tx #(
    parameter integer CLOCK_HZ = 100000000,
    parameter integer BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       valid,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy,
    output reg        done
);
    localparam integer RAW_DIVISOR =
        (BAUD > 0) ? ((CLOCK_HZ + BAUD / 2) / BAUD) : 0;
    localparam integer CLOCKS_PER_BIT =
        (RAW_DIVISOR > 0) ? RAW_DIVISOR : 1;
    localparam integer TIMER_WIDTH =
        (CLOCKS_PER_BIT > 1) ? $clog2(CLOCKS_PER_BIT) : 1;

    reg [TIMER_WIDTH-1:0] bit_timer;
    reg [3:0] bit_index;
    reg [9:0] frame;

    // synthesis translate_off
    initial begin
        if (CLOCK_HZ <= 0 || BAUD <= 0 || BAUD > CLOCK_HZ)
            $fatal(1, "Invalid UART CLOCK_HZ=%0d BAUD=%0d", CLOCK_HZ, BAUD);
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx        <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b0;
            bit_timer <= 0;
            bit_index <= 0;
            frame     <= 10'b11_1111_1111;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                tx <= 1'b1;
                if (valid) begin
                    frame     <= {1'b1, data, 1'b0};
                    tx        <= 1'b0;
                    busy      <= 1'b1;
                    bit_timer <= 0;
                    bit_index <= 0;
                end
            end else if (bit_timer == CLOCKS_PER_BIT - 1) begin
                bit_timer <= 0;
                if (bit_index == 4'd9) begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    tx        <= frame[1];
                    frame     <= {1'b1, frame[9:1]};
                    bit_index <= bit_index + 1'b1;
                end
            end else begin
                bit_timer <= bit_timer + 1'b1;
            end
        end
    end
endmodule
