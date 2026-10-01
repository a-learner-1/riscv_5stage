// MES50HP KEY1: active-low reset. FPGA power-up values hold the CPU in
// reset before its first clock. Release is synchronized and then delayed.
module board_reset #(
    parameter integer HOLD_CYCLES = 50000
) (
    input  wire clk,
    input  wire key1_n,
    output reg  cpu_rst_n = 1'b0
);
    localparam integer CW = (HOLD_CYCLES > 1) ? $clog2(HOLD_CYCLES) : 1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] release_sync = 2'b00;
    reg [CW-1:0] hold_count = 0;

    always @(posedge clk or negedge key1_n) begin
        if (!key1_n)
            release_sync <= 2'b00;
        else
            release_sync <= {release_sync[0], 1'b1};
    end

    // Registered reset output: no combinational counter-decode glitches.
    // Every button bounce that asserts reset restarts the release delay.
    always @(posedge clk or negedge key1_n) begin
        if (!key1_n) begin
            hold_count <= 0;
            cpu_rst_n <= 1'b0;
        end else if (!release_sync[1]) begin
            hold_count <= 0;
            cpu_rst_n <= 1'b0;
        end else if (!cpu_rst_n) begin
            if (hold_count == HOLD_CYCLES - 1)
                cpu_rst_n <= 1'b1;
            else
                hold_count <= hold_count + 1'b1;
        end
    end

    // synthesis translate_off
    initial begin
        if (HOLD_CYCLES < 1)
            $fatal(1, "HOLD_CYCLES must be positive");
    end
    // synthesis translate_on
endmodule
