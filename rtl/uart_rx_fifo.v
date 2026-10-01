// Single-clock byte FIFO with combinational head data.
// A full queue accepts push when the same edge pops its old head.
// An empty queue never pops a byte arriving on that same edge.
module uart_rx_fifo #(
    parameter integer DEPTH = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         push,
    input  wire [7:0]                   push_data,
    input  wire                         pop,
    output wire [7:0]                   data,
    output wire                         empty,
    output wire                         full,
    output reg  [$clog2(DEPTH+1)-1:0]    count,
    output reg                          overflow
);
    localparam integer POINTER_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    reg [7:0] memory [0:DEPTH-1];
    reg [POINTER_WIDTH-1:0] read_pointer;
    reg [POINTER_WIDTH-1:0] write_pointer;

    wire do_pop;
    wire do_push;
    assign empty = (count == 0);
    assign full = (count == DEPTH);
    assign do_pop = pop && !empty;
    assign do_push = push && (!full || do_pop);
    assign data = empty ? 8'd0 : memory[read_pointer];

    // synthesis translate_off
    initial begin
        if (DEPTH < 1)
            $fatal(1, "UART RX FIFO DEPTH must be at least one");
    end
    // synthesis translate_on

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_pointer  <= 0;
            write_pointer <= 0;
            count         <= 0;
            overflow      <= 1'b0;
        end else begin
            // Event pulse; software-visible persistence belongs to MMIO.
            overflow <= push && !do_push;
            if (do_push) begin
                memory[write_pointer] <= push_data;
                if (write_pointer == DEPTH - 1)
                    write_pointer <= 0;
                else
                    write_pointer <= write_pointer + 1'b1;
            end
            if (do_pop) begin
                if (read_pointer == DEPTH - 1)
                    read_pointer <= 0;
                else
                    read_pointer <= read_pointer + 1'b1;
            end
            case ({do_push, do_pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
