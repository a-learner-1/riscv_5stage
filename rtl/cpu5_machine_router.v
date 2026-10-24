// Optional CPU5 machine devices wrap the existing MMIO route without changing
// its default latency or local peripheral implementation. Response selection
// belongs to the saved accepted route, never to the current request address.
module cpu5_machine_router #(
    parameter integer ENABLE_TIMER_DEVICE=0, ENABLE_SOFTWARE_DEVICE=0,
    UART_CLOCK_HZ=50000000, UART_BAUD=115200, UART_RX_FIFO_DEPTH=16, SIM_CONSOLE_ECHO=0
)(
    input wire clk,rst_n,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [31:0] req_addr,req_wdata,input wire [1:0] req_size,input wire [3:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,output wire [31:0] rsp_rdata,output wire rsp_error,
    output wire ext_req_valid,input wire ext_req_ready,output wire ext_req_write,
    output wire [31:0] ext_req_addr,ext_req_wdata,output wire [1:0] ext_req_size,output wire [3:0] ext_req_wstrb,
    input wire ext_rsp_valid,output wire ext_rsp_ready,input wire [31:0] ext_rsp_rdata,input wire ext_rsp_error,
    input wire [63:0] cycle_count,instret_count,
    input wire uart_rx,output wire uart_tx,input wire [7:0] gpio_in,output wire [7:0] gpio_out,gpio_oe,
    output wire irq_timer,irq_software
);
    reg busy_q,machine_q;
    wire req_machine=(ENABLE_TIMER_DEVICE && req_addr>=32'h20000040 && req_addr<32'h20000050) ||
        (ENABLE_SOFTWARE_DEVICE && req_addr>=32'h20000050 && req_addr<32'h20000054);
    wire machine_req_ready,machine_rsp_valid,machine_rsp_error;
    wire [31:0] machine_rsp_rdata;
    wire normal_req_ready,normal_rsp_valid,normal_rsp_error;
    wire [31:0] normal_rsp_rdata;
    assign rsp_valid=rst_n && busy_q && (machine_q?machine_rsp_valid:normal_rsp_valid);
    assign rsp_rdata=machine_q?machine_rsp_rdata:normal_rsp_rdata;
    assign rsp_error=machine_q?machine_rsp_error:normal_rsp_error;
    wire response_fire=rsp_valid && rsp_ready;
    // Only normal -> normal can turn over here. The core owner and inner MMIO
    // router additionally restrict this to successful, live ordinary RAM reads.
    wire request_slot=!busy_q || (response_fire && !machine_q && !req_machine);
    assign req_ready=rst_n && request_slot && (req_machine?machine_req_ready:normal_req_ready);
    wire request_fire=req_valid && req_ready;
    cpu5_machine_endpoint #(.ENABLE_TIMER_DEVICE(ENABLE_TIMER_DEVICE),
        .ENABLE_SOFTWARE_DEVICE(ENABLE_SOFTWARE_DEVICE)) u_machine_endpoint(
        .clk(clk),.rst_n(rst_n),.req_valid(rst_n && request_slot && req_valid && req_machine),
        .req_ready(machine_req_ready),.req_write(req_write),.req_addr(req_addr),.req_size(req_size),
        .req_wdata(req_wdata),.req_wstrb(req_wstrb),.rsp_valid(machine_rsp_valid),
        .rsp_ready(rst_n && busy_q && machine_q && rsp_ready),.rsp_rdata(machine_rsp_rdata),.rsp_error(machine_rsp_error),
        .irq_timer(irq_timer),.irq_software(irq_software),.mtime_value(),.mtimecmp_value());
    cpu5_mmio_router #(.UART_CLOCK_HZ(UART_CLOCK_HZ),.UART_BAUD(UART_BAUD),
        .UART_RX_FIFO_DEPTH(UART_RX_FIFO_DEPTH),.SIM_CONSOLE_ECHO(SIM_CONSOLE_ECHO)) u_normal(
        .clk(clk),.rst_n(rst_n),.req_valid(rst_n && request_slot && req_valid && !req_machine),
        .req_ready(normal_req_ready),.req_write(req_write),.req_addr(req_addr),.req_size(req_size),
        .req_wdata(req_wdata),.req_wstrb(req_wstrb),.rsp_valid(normal_rsp_valid),
        .rsp_ready(rst_n && busy_q && !machine_q && rsp_ready),.rsp_rdata(normal_rsp_rdata),.rsp_error(normal_rsp_error),
        .ext_req_valid(ext_req_valid),.ext_req_ready(ext_req_ready),.ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),.ext_req_size(ext_req_size),.ext_req_wdata(ext_req_wdata),.ext_req_wstrb(ext_req_wstrb),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(ext_rsp_ready),.ext_rsp_rdata(ext_rsp_rdata),.ext_rsp_error(ext_rsp_error),
        .cycle_count(cycle_count),.instret_count(instret_count),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .gpio_in(gpio_in),.gpio_out(gpio_out),.gpio_oe(gpio_oe));
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin busy_q<=0;machine_q<=0;end
        else begin
            if(response_fire)busy_q<=0;
            if(request_fire)begin busy_q<=1;machine_q<=req_machine;end
        end
    end
    // synthesis translate_off
    initial if((ENABLE_TIMER_DEVICE!=0 && ENABLE_TIMER_DEVICE!=1) ||
        (ENABLE_SOFTWARE_DEVICE!=0 && ENABLE_SOFTWARE_DEVICE!=1))
        $fatal(1,"CPU5 machine router device parameters must be boolean");
    always @(posedge clk)if(rst_n)begin
        if(request_fire && busy_q && (!response_fire || machine_q || req_machine))
            $fatal(1,"CPU5 machine router overwrote an accepted response route");
        if(machine_rsp_valid && (!busy_q || !machine_q))
            $fatal(1,"CPU5 machine response has no accepted route");
        if(normal_rsp_valid && (!busy_q || machine_q))
            $fatal(1,"CPU5 normal response has no accepted machine-wrapper route");
    end
    // synthesis translate_on
endmodule
