// CPU5 captured machine timer / software-interrupt device endpoint.
// Only endpoint_fire executes a validated captured request. Responses freeze
// the pre-edge value; neither response backpressure nor CPU entry clears IRQs.
module cpu5_machine_endpoint #(
    parameter integer ENABLE_TIMER_DEVICE=0,ENABLE_SOFTWARE_DEVICE=0
)(
    input wire clk,rst_n,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [31:0] req_addr,input wire [1:0] req_size,
    input wire [31:0] req_wdata,input wire [3:0] req_wstrb,
    output wire rsp_valid,input wire rsp_ready,
    output reg [31:0] rsp_rdata,output reg rsp_error,
    output wire irq_timer,irq_software,
    output wire [63:0] mtime_value,mtimecmp_value
);
    localparam [1:0] IDLE=0,STAGED=1,RESPONSE=2;
    reg [1:0] state_q;
    reg write_q;
    reg [31:0] addr_q,wdata_q;
    reg [1:0] size_q;
    reg [3:0] wstrb_q;
    reg software_msip;
    wire [31:0] timer_read_data;
    wire timer_read_hit,timer_write_hit;
    wire software_hit=ENABLE_SOFTWARE_DEVICE && addr_q==32'h20000050;
    wire word_shape=size_q==2 && addr_q[1:0]==0;
    wire read_shape=!write_q && word_shape && wstrb_q==0;
    wire write_shape=write_q && word_shape && wstrb_q==15;
    wire access_legal=(read_shape && (timer_read_hit || software_hit)) ||
        (write_shape && (timer_write_hit || software_hit));
    wire [31:0] read_value=write_q?32'd0:timer_read_hit?timer_read_data:
        software_hit?{31'd0,software_msip}:32'd0;
    wire endpoint_fire=rst_n && state_q==STAGED;
    wire timer_write_fire=endpoint_fire && access_legal && write_q && timer_write_hit;
    wire software_write_fire=endpoint_fire && access_legal && write_q && software_hit;
    assign req_ready=rst_n && state_q==IDLE;
    assign rsp_valid=rst_n && state_q==RESPONSE;
    assign irq_software=ENABLE_SOFTWARE_DEVICE && software_msip;
    generate if(ENABLE_TIMER_DEVICE)begin:g_timer
        machine_timer u_timer(.clk(clk),.rst_n(rst_n),.addr(addr_q),
            .write_enable(timer_write_fire),.write_data(wdata_q),
            .read_data(timer_read_data),.read_hit(timer_read_hit),.write_hit(timer_write_hit),
            .mtime(mtime_value),.mtimecmp(mtimecmp_value),.mtip(irq_timer));
    end else begin:g_no_timer
        assign timer_read_data=0;assign timer_read_hit=0;assign timer_write_hit=0;
        assign mtime_value=0;assign mtimecmp_value=64'hffffffffffffffff;assign irq_timer=0;
    end endgenerate
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state_q<=IDLE;write_q<=0;addr_q<=0;size_q<=0;wdata_q<=0;wstrb_q<=0;
            rsp_rdata<=0;rsp_error<=0;software_msip<=0;
        end else begin
            if(software_write_fire)software_msip<=wdata_q[0];
            case(state_q)
                IDLE:if(req_valid && req_ready)begin
                    write_q<=req_write;addr_q<=req_addr;size_q<=req_size;
                    wdata_q<=req_wdata;wstrb_q<=req_wstrb;state_q<=STAGED;
                end
                STAGED:begin
                    rsp_rdata<=access_legal?read_value:32'd0;rsp_error<=!access_legal;
                    state_q<=RESPONSE;
                end
                RESPONSE:if(rsp_ready)state_q<=IDLE;
                default:state_q<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if((ENABLE_TIMER_DEVICE!=0 && ENABLE_TIMER_DEVICE!=1) ||
        (ENABLE_SOFTWARE_DEVICE!=0 && ENABLE_SOFTWARE_DEVICE!=1))
        $fatal(1,"CPU5 machine device enables must be boolean");
    always @(posedge clk)if(!rst_n && (endpoint_fire || timer_write_fire || software_write_fire))
        $fatal(1,"CPU5 machine endpoint reset produced device action");
    // synthesis translate_on
endmodule
