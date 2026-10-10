// Single level interrupt source used by the standalone machine IRQ self-check.
// This is a test peripheral, not a CNN register map or a PLIC implementation.
// AW/W are collected independently. Only full-word SET/CLEAR writes succeed;
// a source remains pending until software clears it at this peripheral.
module axi_lite_irq_demo #(
    parameter [31:0] BASE_ADDR = 32'h30000000
) (
    input wire clk, rst_n,
    input wire [31:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [31:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,
    output wire irq
);
    localparam [31:0] ID = 32'h49525131;
    reg got_aw, got_w;
    reg [31:0] awaddr_q, wdata_q;
    reg [3:0] wstrb_q;
    reg pending;
    reg [31:0] set_count, clear_count;
    wire [31:0] read_offset = s_axi_araddr - BASE_ADDR;
    wire [31:0] write_offset = awaddr_q - BASE_ADDR;

    assign irq = pending;
    assign s_axi_awready = rst_n && !got_aw && !s_axi_bvalid;
    assign s_axi_wready = rst_n && !got_w && !s_axi_bvalid;
    assign s_axi_arready = rst_n && (!s_axi_rvalid || s_axi_rready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            got_aw <= 0;
            got_w <= 0;
            awaddr_q <= 0;
            wdata_q <= 0;
            wstrb_q <= 0;
            pending <= 0;
            set_count <= 0;
            clear_count <= 0;
            s_axi_bresp <= 0;
            s_axi_bvalid <= 0;
            s_axi_rdata <= 0;
            s_axi_rresp <= 0;
            s_axi_rvalid <= 0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr_q <= s_axi_awaddr;
                got_aw <= 1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
                got_w <= 1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (got_aw && got_w && !s_axi_bvalid) begin
                got_aw <= 0;
                got_w <= 0;
                s_axi_bvalid <= 1;
                s_axi_bresp <= 2'b10;
                if (wstrb_q == 4'hf) begin
                    case (write_offset)
                        32'h08: begin
                            s_axi_bresp <= 0;
                            if (wdata_q[0]) begin
                                pending <= 1;
                                set_count <= set_count + 1;
                            end
                        end
                        32'h0c: begin
                            s_axi_bresp <= 0;
                            if (wdata_q[0]) begin
                                pending <= 0;
                                clear_count <= clear_count + 1;
                            end
                        end
                        default: begin end
                    endcase
                end
            end

            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rresp <= 0;
                case (read_offset)
                    32'h00: s_axi_rdata <= ID;
                    32'h04: s_axi_rdata <= {31'd0, pending};
                    32'h10: s_axi_rdata <= set_count;
                    32'h14: s_axi_rdata <= clear_count;
                    default: begin
                        s_axi_rdata <= 0;
                        s_axi_rresp <= 2'b10;
                    end
                endcase
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (BASE_ADDR[1:0] != 0)
            $fatal(1, "IRQ demo base must be word aligned");
    end
    // synthesis translate_on
endmodule
