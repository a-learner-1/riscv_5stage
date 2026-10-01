// Eight-bit GPIO peripheral. All accesses are aligned 32-bit words; only
// bits [7:0] are implemented. CPU validates LW/SW and alignment before
// accepting a write. IN is sampled regardless of the OE mask.
module gpio_mmio (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] addr,
    input  wire        write_enable,
    input  wire [31:0] write_data,
    output reg  [31:0] read_data,
    output wire        read_hit,
    output wire        write_hit,
    input  wire [7:0]  gpio_in,
    output reg  [7:0]  gpio_out,
    output reg  [7:0]  gpio_oe
);
    localparam [31:0] OUT_ADDR = 32'h2000_0020;
    localparam [31:0] IN_ADDR  = 32'h2000_0024;
    localparam [31:0] OE_ADDR  = 32'h2000_0028;
    localparam [31:0] SET_ADDR = 32'h2000_002c;
    localparam [31:0] CLR_ADDR = 32'h2000_0030;
    localparam [31:0] XOR_ADDR = 32'h2000_0034;

    // Two-stage synchronizers for slow independent external inputs.
    // This is not a debounce filter or a coherent high-speed bus receiver.
    (* ASYNC_REG = "TRUE" *) reg [7:0] gpio_in_meta;
    (* ASYNC_REG = "TRUE" *) reg [7:0] gpio_in_sync;

    assign read_hit = (addr == OUT_ADDR) || (addr == IN_ADDR) ||
                      (addr == OE_ADDR);
    assign write_hit = (addr == OUT_ADDR) || (addr == OE_ADDR) ||
                       (addr == SET_ADDR) || (addr == CLR_ADDR) ||
                       (addr == XOR_ADDR);

    always @* begin
        case (addr)
            OUT_ADDR: read_data = {24'd0, gpio_out};
            IN_ADDR:  read_data = {24'd0, gpio_in_sync};
            OE_ADDR:  read_data = {24'd0, gpio_oe};
            default:  read_data = 32'd0;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_out     <= 8'd0;
            gpio_oe      <= 8'd0;
            gpio_in_meta <= 8'd0;
            gpio_in_sync <= 8'd0;
        end else begin
            gpio_in_meta <= gpio_in;
            gpio_in_sync <= gpio_in_meta;
            if (write_enable) begin
                case (addr)
                    OUT_ADDR: gpio_out <= write_data[7:0];
                    OE_ADDR:  gpio_oe  <= write_data[7:0];
                    SET_ADDR: gpio_out <= gpio_out | write_data[7:0];
                    CLR_ADDR: gpio_out <= gpio_out & ~write_data[7:0];
                    XOR_ADDR: gpio_out <= gpio_out ^ write_data[7:0];
                    default: ;
                endcase
            end
        end
    end
endmodule
