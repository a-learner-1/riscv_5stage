// One captured local-device request, one execution edge, one held response.
// Device effects occur at endpoint_fire, never at request acceptance or response
// consumption. UART TX busy returns an access error without sending a byte.
module cpu5_mmio_endpoint #(
    parameter integer UART_CLOCK_HZ = 100000000,
    parameter integer UART_BAUD = 115200,
    parameter integer UART_RX_FIFO_DEPTH = 16,
    parameter integer SIM_CONSOLE_ECHO = 0
) (
    input wire clk, input wire rst_n,
    input wire req_valid, output wire req_ready,
    input wire req_write, input wire [31:0] req_addr,
    input wire [1:0] req_size, input wire [31:0] req_wdata,
    input wire [3:0] req_wstrb,
    output wire rsp_valid, input wire rsp_ready,
    output reg [31:0] rsp_rdata, output reg rsp_error,
    input wire [63:0] cycle_count, input wire [63:0] instret_count,
    input wire uart_rx, output wire uart_tx,
    input wire [7:0] gpio_in, output wire [7:0] gpio_out,
    output wire [7:0] gpio_oe
);
    localparam [1:0] IDLE=2'd0, STAGED=2'd1, RESPONSE=2'd2;
    reg [1:0] state_q;
    reg write_q;
    reg [31:0] addr_q;
    reg [1:0] size_q;
    reg [31:0] wdata_q;
    reg [3:0] wstrb_q;
    wire endpoint_fire;
    wire tx_busy, tx_done;
    wire [31:0] rx_rdata, gpio_rdata;
    wire rx_read_hit, rx_write_hit, gpio_read_hit, gpio_write_hit;
    reg access_legal;
    reg [31:0] read_value;
    wire word_access = (size_q==2'd2) && (addr_q[1:0]==2'b00);
    wire read_shape = !write_q && word_access && (wstrb_q==4'b0000);
    wire write_shape = write_q && word_access && (wstrb_q==4'b1111);
    wire tx_shape = write_q && (addr_q==32'h20000010) &&
        (((size_q==2'd0) && (wstrb_q==4'b0001)) ||
         ((size_q==2'd1) && (wstrb_q==4'b0011)) ||
         ((size_q==2'd2) && (wstrb_q==4'b1111)));
    wire tx_fire = endpoint_fire && access_legal && write_q && (addr_q==32'h20000010);
    wire rx_read_fire = endpoint_fire && access_legal && !write_q && rx_read_hit;
    wire rx_write_fire = endpoint_fire && access_legal && write_q && rx_write_hit;
    wire gpio_write_fire = endpoint_fire && access_legal && write_q && gpio_write_hit;

    assign req_ready = rst_n && (state_q==IDLE);
    assign rsp_valid = rst_n && (state_q==RESPONSE);
    assign endpoint_fire = rst_n && (state_q==STAGED);

    uart_tx #(.CLOCK_HZ(UART_CLOCK_HZ), .BAUD(UART_BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n), .valid(tx_fire), .data(wdata_q[7:0]),
        .tx(uart_tx), .busy(tx_busy), .done(tx_done)
    );
    uart_rx_mmio #(.CLOCK_HZ(UART_CLOCK_HZ), .BAUD(UART_BAUD),
        .FIFO_DEPTH(UART_RX_FIFO_DEPTH)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx), .addr(addr_q),
        .read_enable(rx_read_fire), .write_enable(rx_write_fire),
        .write_data(wdata_q), .read_data(rx_rdata),
        .read_hit(rx_read_hit), .write_hit(rx_write_hit)
    );
    gpio_mmio u_gpio (
        .clk(clk), .rst_n(rst_n), .addr(addr_q),
        .write_enable(gpio_write_fire), .write_data(wdata_q),
        .read_data(gpio_rdata), .read_hit(gpio_read_hit),
        .write_hit(gpio_write_hit), .gpio_in(gpio_in),
        .gpio_out(gpio_out), .gpio_oe(gpio_oe)
    );

    always @* begin
        access_legal=1'b0;
        read_value=32'd0;
        if (read_shape) begin
            case (addr_q)
                32'h20000000: begin access_legal=1'b1; read_value=cycle_count[31:0]; end
                32'h20000004: begin access_legal=1'b1; read_value=instret_count[31:0]; end
                32'h20000014: begin access_legal=1'b1; read_value={31'd0,tx_busy}; end
                32'h20000018,32'h2000001c: begin access_legal=rx_read_hit; read_value=rx_rdata; end
                32'h20000020,32'h20000024,32'h20000028: begin access_legal=gpio_read_hit; read_value=gpio_rdata; end
                default: ;
            endcase
        end else if (tx_shape) begin
            access_legal=!tx_busy;
        end else if (write_shape) begin
            case (addr_q)
                32'h2000001c: access_legal=rx_write_hit;
                32'h20000020,32'h20000028,32'h2000002c,32'h20000030,32'h20000034:
                    access_legal=gpio_write_hit;
                default: ;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q<=IDLE;
            write_q<=1'b0; addr_q<=32'd0; size_q<=2'd0;
            wdata_q<=32'd0; wstrb_q<=4'd0;
            rsp_rdata<=32'd0; rsp_error<=1'b0;
        end else begin
            case (state_q)
                IDLE: if (req_valid && req_ready) begin
                    write_q<=req_write; addr_q<=req_addr; size_q<=req_size;
                    wdata_q<=req_wdata; wstrb_q<=req_wstrb;
                    state_q<=STAGED;
                end
                STAGED: begin
                    rsp_rdata<=access_legal ? read_value : 32'd0;
                    rsp_error<=!access_legal;
                    state_q<=RESPONSE;
                end
                RESPONSE: if (rsp_ready) state_q<=IDLE;
                default: state_q<=IDLE;
            endcase
        end
    end

    // synthesis translate_off
    initial begin
        if (SIM_CONSOLE_ECHO!=0 && SIM_CONSOLE_ECHO!=1)
            $fatal(1,"CPU5 MMIO SIM_CONSOLE_ECHO must be boolean");
        if (UART_CLOCK_HZ<=0 || UART_BAUD<=0 ||
            ((UART_CLOCK_HZ+UART_BAUD/2)/((UART_BAUD>0)?UART_BAUD:1))<4)
            $fatal(1,"CPU5 MMIO UART clock/baud must allow at least four clocks per bit");
        if (UART_RX_FIFO_DEPTH<1 || UART_RX_FIFO_DEPTH>255)
            $fatal(1,"CPU5 MMIO UART_RX_FIFO_DEPTH must be 1..255");
    end
    always @(posedge clk) begin
        if (rst_n && SIM_CONSOLE_ECHO && tx_fire) $write("%c",wdata_q[7:0]);
        if (!rst_n && (endpoint_fire || tx_fire || rx_read_fire || rx_write_fire || gpio_write_fire))
            $fatal(1,"CPU5 MMIO reset produced device action");
    end
    // synthesis translate_on
endmodule
