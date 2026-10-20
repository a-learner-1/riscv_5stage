// AXI4 read subset: one implicit ID, one outstanding request, LEN=0/3,
// SIZE=2, INCR. Unsupported requests return LEN+1 error beats locally.
// Both endpoints share reset and hold each response until its handshake.
module axi4_read_1x2 #(
    parameter [31:0] M0_BASE_ADDR=32'h40000000, M0_SIZE_BYTES=32'h1000,
    parameter [31:0] M1_BASE_ADDR=32'h40001000, M1_SIZE_BYTES=32'h1000
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
    output wire [31:0] m0_axi_araddr,
    output wire [2:0] m0_axi_arprot,
    output wire [7:0] m0_axi_arlen,
    output wire [2:0] m0_axi_arsize,
    output wire [1:0] m0_axi_arburst,
    output wire m0_axi_arvalid, input wire m0_axi_arready,
    input wire [31:0] m0_axi_rdata, input wire [1:0] m0_axi_rresp,
    input wire m0_axi_rlast, input wire m0_axi_rvalid, output wire m0_axi_rready,
    output wire [31:0] m1_axi_araddr,
    output wire [2:0] m1_axi_arprot,
    output wire [7:0] m1_axi_arlen,
    output wire [2:0] m1_axi_arsize,
    output wire [1:0] m1_axi_arburst,
    output wire m1_axi_arvalid, input wire m1_axi_arready,
    input wire [31:0] m1_axi_rdata, input wire [1:0] m1_axi_rresp,
    input wire m1_axi_rlast, input wire m1_axi_rvalid, output wire m1_axi_rready
);
    localparam [32:0] M0_END={1'b0,M0_BASE_ADDR}+{1'b0,M0_SIZE_BYTES};
    localparam [32:0] M1_END={1'b0,M1_BASE_ADDR}+{1'b0,M1_SIZE_BYTES};
    localparam [1:0] IDLE=0,SEND=1,DATA=2,LOCAL_ERROR=3;
    reg [1:0] state,error_q;
    reg target_q;
    reg [31:0] addr_q;
    reg [2:0] prot_q,size_q;
    reg [7:0] len_q,beat_q;
    reg [1:0] burst_q;
    wire [32:0] end_address={1'b0,s_axi_araddr}+(({25'd0,s_axi_arlen}+33'd1)<<2);
    wire fields_ok=(s_axi_arlen==0 || s_axi_arlen==3) &&
        s_axi_arsize==2 && s_axi_arburst==1 && s_axi_araddr[1:0]==0;
    wire page_ok=({1'b0,s_axi_araddr[11:0]}+(({5'd0,s_axi_arlen}+13'd1)<<2))<=13'd4096;
    wire in0=({1'b0,s_axi_araddr}>={1'b0,M0_BASE_ADDR}) && ({1'b0,s_axi_araddr}<M0_END);
    wire in1=({1'b0,s_axi_araddr}>={1'b0,M1_BASE_ADDR}) && ({1'b0,s_axi_araddr}<M1_END);
    wire span0=in0 && end_address<=M0_END;
    wire span1=in1 && end_address<=M1_END;
    wire end_ok=end_address<=33'h100000000;
    wire request_ok=fields_ok && page_ok && end_ok && (span0||span1);
    wire expected_last=beat_q==len_q;
    wire selected_valid=target_q ? m1_axi_rvalid : m0_axi_rvalid;
    wire selected_last=target_q ? m1_axi_rlast : m0_axi_rlast;
    wire [31:0] selected_data=target_q ? m1_axi_rdata : m0_axi_rdata;
    wire [1:0] selected_resp=target_q ? m1_axi_rresp : m0_axi_rresp;
    assign s_axi_arready=rst_n && state==IDLE;
    assign m0_axi_araddr=addr_q,m1_axi_araddr=addr_q;
    assign m0_axi_arprot=prot_q,m1_axi_arprot=prot_q;
    assign m0_axi_arlen=len_q,m1_axi_arlen=len_q;
    assign m0_axi_arsize=size_q,m1_axi_arsize=size_q;
    assign m0_axi_arburst=burst_q,m1_axi_arburst=burst_q;
    assign m0_axi_arvalid=rst_n && state==SEND && !target_q;
    assign m1_axi_arvalid=rst_n && state==SEND && target_q;
    assign s_axi_rvalid=rst_n && (state==LOCAL_ERROR || (state==DATA&&selected_valid));
    assign s_axi_rdata=state==DATA ? selected_data : 32'd0;
    // RLAST is derived from the accepted descriptor. A malformed endpoint
    // RLAST becomes SLVERR; error responses never release the route early.
    assign s_axi_rlast=rst_n && (state==DATA||state==LOCAL_ERROR) && expected_last;
    assign s_axi_rresp=state==LOCAL_ERROR ? error_q :
        state==DATA ? ((selected_resp==0 && selected_last!=expected_last) ? 2'b10 : selected_resp) : 2'b00;
    assign m0_axi_rready=rst_n && state==DATA && !target_q && s_axi_rready;
    assign m1_axi_rready=rst_n && state==DATA && target_q && s_axi_rready;
    wire ar_fire=s_axi_arvalid&&s_axi_arready;
    wire downstream_ar_fire=(m0_axi_arvalid&&m0_axi_arready)||(m1_axi_arvalid&&m1_axi_arready);
    wire r_fire=s_axi_rvalid&&s_axi_rready;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;error_q<=0;target_q<=0;addr_q<=0;prot_q<=0;
            size_q<=0;len_q<=0;beat_q<=0;burst_q<=0;
        end else begin
            case(state)
                IDLE: if(ar_fire) begin
                    addr_q<=s_axi_araddr;prot_q<=s_axi_arprot;len_q<=s_axi_arlen;
                    size_q<=s_axi_arsize;burst_q<=s_axi_arburst;beat_q<=0;target_q<=span1;
                    if(request_ok) state<=SEND;
                    else begin
                        state<=LOCAL_ERROR;
                        error_q<=(!fields_ok||!page_ok||!end_ok) ? 2'b10 :
                                 (!in0&&!in1) ? 2'b11 : 2'b10;
                    end
                end
                SEND: if(downstream_ar_fire) state<=DATA;
                DATA,LOCAL_ERROR: if(r_fire) begin
                    if(expected_last) state<=IDLE;
                    else beat_q<=beat_q+1'b1;
                end
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(M0_SIZE_BYTES==0||M1_SIZE_BYTES==0||M0_BASE_ADDR[1:0]!=0||M1_BASE_ADDR[1:0]!=0||
           M0_SIZE_BYTES[1:0]!=0||M1_SIZE_BYTES[1:0]!=0||M0_END>33'h100000000||M1_END>33'h100000000||
           !((M0_END<={1'b0,M1_BASE_ADDR})||(M1_END<={1'b0,M0_BASE_ADDR})))
            $fatal(1,"axi4_read_1x2 requires disjoint aligned non-wrapping ranges");
    end
    // synthesis translate_on
endmodule
