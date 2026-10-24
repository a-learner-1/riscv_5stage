// One CPU5 D transaction routed to the local MMIO page or the external port.
// The accepted route owns its response; live request addresses never select it.
module cpu5_mmio_router #(
    parameter integer UART_CLOCK_HZ=50000000, UART_BAUD=115200,
    UART_RX_FIFO_DEPTH=16, SIM_CONSOLE_ECHO=0
)(
    input wire clk,rst_n,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [31:0] req_addr,req_wdata,input wire [1:0] req_size,input wire [3:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,output wire [31:0] rsp_rdata,output wire rsp_error,
    output wire ext_req_valid,input wire ext_req_ready,output wire ext_req_write,
    output wire [31:0] ext_req_addr,ext_req_wdata,output wire [1:0] ext_req_size,output wire [3:0] ext_req_wstrb,
    input wire ext_rsp_valid,output wire ext_rsp_ready,input wire [31:0] ext_rsp_rdata,input wire ext_rsp_error,
    input wire [63:0] cycle_count,instret_count,
    input wire uart_rx,output wire uart_tx,input wire [7:0] gpio_in,output wire [7:0] gpio_out,gpio_oe
);
    reg busy_q,local_q;
    wire req_local=req_addr[31:8]==24'h200000;
    wire local_req_ready,local_rsp_valid,local_rsp_error;
    wire [31:0] local_rsp_rdata;
    assign rsp_valid=rst_n && busy_q && (local_q?local_rsp_valid:ext_rsp_valid);
    assign rsp_rdata=local_q?local_rsp_rdata:ext_rsp_rdata;
    assign rsp_error=local_q?local_rsp_error:ext_rsp_error;
    wire response_fire=rsp_valid && rsp_ready;
    // The owner additionally restricts turnover to two pure ordinary-RAM
    // LOADs. This router never crosses local endpoint boundaries in one edge.
    wire request_slot=!busy_q || (response_fire && !local_q && !req_local);
    assign req_ready=rst_n && request_slot && (req_local?local_req_ready:ext_req_ready);
    wire request_fire=req_valid && req_ready;
    assign ext_req_valid=rst_n && request_slot && req_valid && !req_local;
    assign ext_req_write=req_write;assign ext_req_addr=req_addr;assign ext_req_wdata=req_wdata;
    assign ext_req_size=req_size;assign ext_req_wstrb=req_wstrb;
    assign ext_rsp_ready=rst_n && busy_q && !local_q && rsp_ready;
    cpu5_mmio_endpoint #(.UART_CLOCK_HZ(UART_CLOCK_HZ),.UART_BAUD(UART_BAUD),
        .UART_RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH),.SIM_CONSOLE_ECHO(SIM_CONSOLE_ECHO)) u_endpoint(
        .clk(clk),.rst_n(rst_n),.req_valid(rst_n && request_slot && req_valid && req_local),
        .req_ready(local_req_ready),.req_write(req_write),.req_addr(req_addr),.req_size(req_size),
        .req_wdata(req_wdata),.req_wstrb(req_wstrb),.rsp_valid(local_rsp_valid),
        .rsp_ready(rst_n && busy_q && local_q && rsp_ready),.rsp_rdata(local_rsp_rdata),.rsp_error(local_rsp_error),
        .cycle_count(cycle_count),.instret_count(instret_count),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .gpio_in(gpio_in),.gpio_out(gpio_out),.gpio_oe(gpio_oe));
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin busy_q<=0;local_q<=0;end
        else begin
            if(response_fire)busy_q<=0;
            if(request_fire)begin busy_q<=1;local_q<=req_local;end
        end
    end
    // synthesis translate_off
    always @(posedge clk)if(rst_n)begin
        if(request_fire && busy_q && (!response_fire || local_q || req_local))
            $fatal(1,"CPU5 MMIO router overwrote an accepted response route");
        if(local_rsp_valid && (!busy_q || !local_q))
            $fatal(1,"CPU5 MMIO local response has no accepted route");
    end
    // synthesis translate_on
endmodule
