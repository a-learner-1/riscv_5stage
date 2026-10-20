// Synchronous BRAM subordinate for the AXI4 read subset. Native seed writes
// share its physical port and have priority while idle. RAM survives reset.
module axi4_read_ram #(
    parameter integer WORDS=1024,
    parameter [31:0] BASE_ADDR=32'h40000000,
    parameter INIT_FILE=""
) (
    input wire clk,rst_n,
    input wire [31:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire [7:0] s_axi_arlen,
    input wire [2:0] s_axi_arsize,
    input wire [1:0] s_axi_arburst,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output wire [31:0] s_axi_rdata, output wire [1:0] s_axi_rresp,
    output wire s_axi_rlast, output wire s_axi_rvalid, input wire s_axi_rready,
    input wire seed_valid, output wire seed_ready,
    input wire [31:0] seed_addr,seed_wdata,
    input wire [3:0] seed_wstrb, output wire seed_error
);
    localparam [63:0] END_ADDR={32'd0,BASE_ADDR}+64'd4*WORDS;
    localparam [1:0] IDLE=0,FETCH=1,CAPTURE=2,HOLD=3;
    reg [1:0] state,read_error_q,response_error_q;
    reg [31:0] addr_q,response_data_q;
    reg [7:0] len_q,beat_q;
    wire [32:0] end_address={1'b0,s_axi_araddr}+(({25'd0,s_axi_arlen}+33'd1)<<2);
    wire fields_ok=(s_axi_arlen==0||s_axi_arlen==3)&&s_axi_arsize==2&&s_axi_arburst==1&&s_axi_araddr[1:0]==0;
    wire page_ok=({1'b0,s_axi_araddr[11:0]}+(({5'd0,s_axi_arlen}+13'd1)<<2))<=13'd4096;
    wire end_ok=end_address<=33'h100000000;
    wire range_ok=({32'd0,s_axi_araddr}>={32'd0,BASE_ADDR})&&({31'd0,end_address}<=END_ADDR)&&end_ok;
    assign seed_ready=rst_n&&state==IDLE;
    assign seed_error=seed_addr[1:0]!=0||({32'd0,seed_addr}<{32'd0,BASE_ADDR})||({32'd0,seed_addr}>=END_ADDR);
    wire seed_fire=seed_valid&&seed_ready;
    assign s_axi_arready=rst_n&&state==IDLE&&!seed_valid;
    assign s_axi_rvalid=rst_n&&state==HOLD;
    assign s_axi_rdata=response_data_q;
    assign s_axi_rresp=response_error_q;
    assign s_axi_rlast=rst_n&&state==HOLD&&beat_q==len_q;
    wire [31:0] ram_rdata;
    wire unused_access_ok;
    // Array write occurs exactly at a legal seed handshake. No protocol
    // reset is connected to its array contents or synchronous read register.
    data_mem #(.WORDS(WORDS),.BASE_ADDR(BASE_ADDR),.INIT_FILE(INIT_FILE)) u_data_mem (
        .clk(clk),.re(rst_n&&state==FETCH&&read_error_q==0),
        .we(rst_n&&seed_fire&&!seed_error),
        .addr(seed_fire?seed_addr:addr_q),.size(2'd2),
        .wdata(seed_wdata),.wstrb(seed_wstrb),.rdata(ram_rdata),.access_ok(unused_access_ok)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;read_error_q<=0;response_error_q<=0;
            addr_q<=0;response_data_q<=0;len_q<=0;beat_q<=0;
        end else begin
            case(state)
                IDLE: if(s_axi_arvalid&&s_axi_arready) begin
                    addr_q<=s_axi_araddr;len_q<=s_axi_arlen;beat_q<=0;
                    read_error_q<=(!fields_ok||!page_ok||!end_ok)?2'b10:!range_ok?2'b11:2'b00;
                    state<=FETCH;
                end
                FETCH: state<=CAPTURE;
                CAPTURE: begin
                    response_data_q<=read_error_q==0?ram_rdata:32'd0;
                    response_error_q<=read_error_q;state<=HOLD;
                end
                HOLD: if(s_axi_rvalid&&s_axi_rready) begin
                    if(beat_q==len_q) state<=IDLE;
                    else begin beat_q<=beat_q+1'b1;addr_q<=addr_q+32'd4;state<=FETCH;end
                end
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(WORDS<=0||BASE_ADDR[1:0]!=0||END_ADDR>64'h100000000)
            $fatal(1,"axi4_read_ram requires a positive aligned non-wrapping RAM range");
    end
    // synthesis translate_on
endmodule
