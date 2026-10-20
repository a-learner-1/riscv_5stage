// CPU command endpoint plus a synthesizable AXI4 read-only manager.
// CSR writes are aligned/full-strobe. Buffer byte writes use SEED_STRB.
// Four data registers absorb the complete response even after a beat error.
module axi_lite_burst_reader #(
    parameter [31:0] BASE_ADDR=32'h30001000
) (
    input wire clk,rst_n,
    input wire [31:0] s_axi_awaddr,input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,output wire s_axi_wready,
    output wire [1:0] s_axi_bresp,output wire s_axi_bvalid,input wire s_axi_bready,
    input wire [31:0] s_axi_araddr,input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,output wire s_axi_arready,
    output wire [31:0] s_axi_rdata,output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,input wire s_axi_rready,
    output wire [31:0] m_axi_araddr,output wire [2:0] m_axi_arprot,
    output wire [7:0] m_axi_arlen,output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,input wire m_axi_arready,
    input wire [31:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,input wire m_axi_rvalid,output wire m_axi_rready,
    output wire seed_valid,input wire seed_ready,
    output wire [31:0] seed_addr,seed_wdata,
    output wire [3:0] seed_wstrb,input wire seed_error,
    output wire busy,done,error
);
    localparam [1:0] W_COLLECT=0,W_SEED=1,W_RESPONSE=2;
    localparam [1:0] R_IDLE=0,R_ADDRESS=1,R_DATA=2;
    reg [1:0] write_state,read_state,bresp_q,rresp_q;
    reg aw_pending,w_pending,rvalid_q,aw_busy_q,w_busy_q;
    reg [31:0] awaddr_q,wdata_q,rdata_q;
    reg [3:0] wstrb_q;
    reg [31:0] source_q,seed_addr_cfg,seed_data_cfg;
    reg [7:0] length_q,active_length_q;
    reg [3:0] seed_strb_cfg;
    reg [31:0] seed_addr_q,seed_data_q,active_addr_q;
    reg [3:0] seed_strb_q;
    reg done_q,error_q;
    reg [1:0] beat_q;
    reg [2:0] received_q;
    reg [31:0] result_q[0:3];
    reg [31:0] seed_count_q,ar_count_q,r_count_q;
    localparam [32:0] CSR_END={1'b0,BASE_ADDR}+33'h100;
    wire [31:0] write_offset=awaddr_q-BASE_ADDR;
    wire [31:0] read_offset=s_axi_araddr-BASE_ADDR;
    wire write_address_ok=awaddr_q[1:0]==0&&({1'b0,awaddr_q}>={1'b0,BASE_ADDR})&&({1'b0,awaddr_q}<CSR_END);
    wire read_address_ok=s_axi_araddr[1:0]==0&&({1'b0,s_axi_araddr}>={1'b0,BASE_ADDR})&&({1'b0,s_axi_araddr}<CSR_END);
    wire write_pair=write_state==W_COLLECT&&aw_pending&&w_pending;
    wire write_legal=write_address_ok&&wstrb_q==4'hf&&!busy&&!aw_busy_q&&!w_busy_q;
    wire start_fire=write_pair&&write_legal&&write_offset==0&&wdata_q==1;
    wire clear_fire=write_pair&&write_legal&&write_offset==0&&wdata_q==2;
    assign busy=read_state!=R_IDLE;
    assign done=done_q,error=error_q;
    assign s_axi_awready=rst_n&&write_state==W_COLLECT&&!aw_pending;
    assign s_axi_wready=rst_n&&write_state==W_COLLECT&&!w_pending;
    assign s_axi_bvalid=rst_n&&write_state==W_RESPONSE;
    assign s_axi_bresp=bresp_q;
    assign s_axi_arready=rst_n&&!rvalid_q;
    assign s_axi_rvalid=rst_n&&rvalid_q;
    assign s_axi_rdata=rdata_q,s_axi_rresp=rresp_q;
    assign seed_valid=rst_n&&write_state==W_SEED;
    assign seed_addr=seed_addr_q,seed_wdata=seed_data_q,seed_wstrb=seed_strb_q;
    assign m_axi_araddr=active_addr_q,m_axi_arprot=3'b000;
    assign m_axi_arlen=active_length_q,m_axi_arsize=3'd2,m_axi_arburst=2'b01;
    assign m_axi_arvalid=rst_n&&read_state==R_ADDRESS;
    assign m_axi_rready=rst_n&&read_state==R_DATA;
    wire ar_fire=m_axi_arvalid&&m_axi_arready;
    wire r_fire=m_axi_rvalid&&m_axi_rready;

    // Independent AW/W slots retain payloads until the paired write executes.
    // A seed write's B response is generated only after its actual handshake.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            write_state<=W_COLLECT;aw_pending<=0;w_pending<=0;aw_busy_q<=0;w_busy_q<=0;
            awaddr_q<=0;wdata_q<=0;wstrb_q<=0;bresp_q<=0;
            source_q<=32'h40000000;length_q<=3;
            seed_addr_cfg<=32'h40000000;seed_data_cfg<=0;seed_strb_cfg<=4'hf;
            seed_addr_q<=0;seed_data_q<=0;seed_strb_q<=0;seed_count_q<=0;
        end else begin
            case(write_state)
                W_COLLECT: begin
                    if(s_axi_awvalid&&s_axi_awready) begin awaddr_q<=s_axi_awaddr;aw_pending<=1;aw_busy_q<=busy;end
                    if(s_axi_wvalid&&s_axi_wready) begin wdata_q<=s_axi_wdata;wstrb_q<=s_axi_wstrb;w_pending<=1;w_busy_q<=busy;end
                    if(write_pair) begin
                        aw_pending<=0;w_pending<=0;aw_busy_q<=0;w_busy_q<=0;write_state<=W_RESPONSE;bresp_q<=2'b10;
                        if(write_legal) begin
                            case(write_offset)
                                32'h00: if(wdata_q==1||wdata_q==2) bresp_q<=0;
                                32'h04: begin source_q<=wdata_q;bresp_q<=0;end
                                32'h08: if(wdata_q==0||wdata_q==3) begin length_q<=wdata_q[7:0];bresp_q<=0;end
                                32'h20: begin seed_addr_cfg<=wdata_q;bresp_q<=0;end
                                32'h24: begin seed_data_cfg<=wdata_q;bresp_q<=0;end
                                32'h28: if(wdata_q[31:4]==0) begin seed_strb_cfg<=wdata_q[3:0];bresp_q<=0;end
                                32'h2c: if(wdata_q==1) begin
                                    seed_addr_q<=seed_addr_cfg;seed_data_q<=seed_data_cfg;seed_strb_q<=seed_strb_cfg;
                                    write_state<=W_SEED;
                                end
                                default: bresp_q<=2'b10;
                            endcase
                        end
                    end
                end
                W_SEED: if(seed_valid&&seed_ready) begin
                    bresp_q<=seed_error?2'b10:2'b00;write_state<=W_RESPONSE;
                    if(!seed_error) seed_count_q<=seed_count_q+1'b1;
                end
                W_RESPONSE: if(s_axi_bvalid&&s_axi_bready) write_state<=W_COLLECT;
                default: write_state<=W_COLLECT;
            endcase
        end
    end

    // A read captures its pre-edge CSR value; backpressure cannot alter it.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin rvalid_q<=0;rdata_q<=0;rresp_q<=0;end
        else begin
            if(s_axi_rvalid&&s_axi_rready) rvalid_q<=0;
            if(s_axi_arvalid&&s_axi_arready) begin
                rvalid_q<=1;rdata_q<=0;rresp_q<=0;
                if(!read_address_ok) rresp_q<=2'b10;
                else case(read_offset)
                    32'h00:rdata_q<={29'd0,error_q,done_q,busy};
                    32'h04:rdata_q<=source_q;
                    32'h08:rdata_q<={24'd0,length_q};
                    32'h0c:rdata_q<={29'd0,received_q};
                    32'h10:rdata_q<=result_q[0];
                    32'h14:rdata_q<=result_q[1];
                    32'h18:rdata_q<=result_q[2];
                    32'h1c:rdata_q<=result_q[3];
                    32'h20:rdata_q<=seed_addr_cfg;
                    32'h24:rdata_q<=seed_data_cfg;
                    32'h28:rdata_q<={28'd0,seed_strb_cfg};
                    32'h2c:rdata_q<=seed_count_q;
                    32'h30:rdata_q<=ar_count_q;
                    32'h34:rdata_q<=r_count_q;
                    32'h38:rdata_q<=32'h42525354;
                    32'h3c:rdata_q<=1;
                    default:rresp_q<=2'b10;
                endcase
            end
        end
    end

    // Errors are sticky through the complete accepted burst. RLAST is checked
    // against the accepted length; no early-error completion is permitted.
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            read_state<=R_IDLE;active_addr_q<=0;active_length_q<=0;beat_q<=0;
            received_q<=0;done_q<=0;error_q<=0;ar_count_q<=0;r_count_q<=0;
            for(i=0;i<4;i=i+1) result_q[i]<=0;
        end else begin
            case(read_state)
                R_IDLE: begin
                    if(clear_fire) begin done_q<=0;error_q<=0;end
                    if(start_fire) begin
                        active_addr_q<=source_q;active_length_q<=length_q;
                        beat_q<=0;received_q<=0;done_q<=0;error_q<=0;read_state<=R_ADDRESS;
                        for(i=0;i<4;i=i+1) result_q[i]<=0;
                    end
                end
                R_ADDRESS: if(ar_fire) begin ar_count_q<=ar_count_q+1'b1;read_state<=R_DATA;end
                R_DATA: if(r_fire) begin
                    received_q<=received_q+1'b1;r_count_q<=r_count_q+1'b1;
                    result_q[beat_q]<=m_axi_rresp==0?m_axi_rdata:32'd0;
                    case(m_axi_rresp)
                        2'b00: begin end
                        default:error_q<=1;
                    endcase
                    case({m_axi_rlast,(beat_q==active_length_q)})
                        2'b00,2'b11: begin end
                        default:error_q<=1;
                    endcase
                    if(beat_q==active_length_q) begin done_q<=1;read_state<=R_IDLE;end
                    else beat_q<=beat_q+1'b1;
                end
                default:read_state<=R_IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(BASE_ADDR[1:0]!=0||CSR_END>33'h100000000)
            $fatal(1,"axi_lite_burst_reader requires an aligned non-wrapping CSR window");
    end
    // synthesis translate_on
endmodule
