// Single-word AXI4-Lite RAM slave. AW and W are buffered independently.
// Reset clears protocol state; RAM contents and completed writes survive.
module axi_lite_ram #(
    parameter integer WORDS = 4096,
    parameter [31:0] BASE_ADDR = 32'h00010000,
    parameter INIT_FILE = "programs/c_demo_data.hex",
    parameter integer AW_WAIT_CYCLES = 0,
    parameter integer W_WAIT_CYCLES = 0,
    parameter integer AR_WAIT_CYCLES = 0,
    parameter integer B_WAIT_CYCLES = 0,
    parameter integer R_WAIT_CYCLES = 0
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
    output wire s_axi_bvalid,
    input wire s_axi_bready,
    input wire [31:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready
);
    reg aw_pending, w_pending, write_busy, bvalid_q;
    reg [31:0] awaddr_q, wdata_q;
    reg [3:0] wstrb_q;
    reg read_busy, read_capture, read_error_q, rvalid_q;
    integer aw_wait_q, w_wait_q, ar_wait_q, b_wait_q, r_wait_q;

    wire write_commit = rst_n && aw_pending && w_pending && !write_busy;
    wire write_addr_ok = (awaddr_q[1:0] == 0) &&
        ({1'b0, awaddr_q} >= {1'b0, BASE_ADDR}) &&
        ({1'b0, awaddr_q} < ({1'b0, BASE_ADDR} + 33'd4 * WORDS));
    wire read_addr_ok = (s_axi_araddr[1:0] == 0) &&
        ({1'b0, s_axi_araddr} >= {1'b0, BASE_ADDR}) &&
        ({1'b0, s_axi_araddr} < ({1'b0, BASE_ADDR} + 33'd4 * WORDS));
    assign s_axi_awready = rst_n && !write_busy && !aw_pending && aw_wait_q == 0;
    assign s_axi_wready = rst_n && !write_busy && !w_pending && w_wait_q == 0;
    // One physical RAM port: give a paired write priority over a new read.
    assign s_axi_arready = rst_n && !read_busy && !write_commit && ar_wait_q == 0;
    assign s_axi_bvalid = rst_n && bvalid_q;
    assign s_axi_rvalid = rst_n && rvalid_q;
    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire = s_axi_wvalid && s_axi_wready;
    wire ar_fire = s_axi_arvalid && s_axi_arready;
    wire [31:0] ram_rdata;
    wire unused_access_ok;

    data_mem #(.WORDS(WORDS), .BASE_ADDR(BASE_ADDR), .INIT_FILE(INIT_FILE)) u_data_mem (
        .clk(clk), .re(ar_fire && read_addr_ok), .we(write_commit && write_addr_ok),
        .addr(write_commit ? awaddr_q : s_axi_araddr), .size(2'd2),
        .wdata(wdata_q), .wstrb(wstrb_q), .rdata(ram_rdata), .access_ok(unused_access_ok)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_pending <= 0; w_pending <= 0; write_busy <= 0; bvalid_q <= 0;
            awaddr_q <= 0; wdata_q <= 0; wstrb_q <= 0; s_axi_bresp <= 0;
            read_busy <= 0; read_capture <= 0; read_error_q <= 0; rvalid_q <= 0;
            s_axi_rdata <= 0; s_axi_rresp <= 0;
            aw_wait_q <= AW_WAIT_CYCLES; w_wait_q <= W_WAIT_CYCLES;
            ar_wait_q <= AR_WAIT_CYCLES; b_wait_q <= 0; r_wait_q <= 0;
        end else begin
            if (!write_busy && !aw_pending && s_axi_awvalid && aw_wait_q > 0)
                aw_wait_q <= aw_wait_q - 1;
            if (!write_busy && !w_pending && s_axi_wvalid && w_wait_q > 0)
                w_wait_q <= w_wait_q - 1;
            if (aw_fire) begin aw_pending <= 1; awaddr_q <= s_axi_awaddr; end
            if (w_fire) begin w_pending <= 1; wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; end
            if (write_commit) begin
                aw_pending <= 0; w_pending <= 0; write_busy <= 1;
                s_axi_bresp <= write_addr_ok ? 2'b00 : 2'b11;
                b_wait_q <= B_WAIT_CYCLES;
            end
            if (write_busy && !bvalid_q) begin
                if (b_wait_q == 0) bvalid_q <= 1;
                else b_wait_q <= b_wait_q - 1;
            end
            if (s_axi_bvalid && s_axi_bready) begin
                bvalid_q <= 0; write_busy <= 0;
                aw_wait_q <= AW_WAIT_CYCLES; w_wait_q <= W_WAIT_CYCLES;
            end

            if (!read_busy && !write_commit && s_axi_arvalid && ar_wait_q > 0)
                ar_wait_q <= ar_wait_q - 1;
            if (ar_fire) begin
                read_busy <= 1; read_capture <= 1; read_error_q <= !read_addr_ok;
                r_wait_q <= R_WAIT_CYCLES;
                s_axi_rresp <= read_addr_ok ? 2'b00 : 2'b11;
            end
            // data_mem is synchronous: capture its output on the next edge.
            if (read_capture) begin
                read_capture <= 0;
                s_axi_rdata <= read_error_q ? 32'd0 : ram_rdata;
            end
            if (read_busy && !read_capture && !rvalid_q) begin
                if (r_wait_q == 0) rvalid_q <= 1;
                else r_wait_q <= r_wait_q - 1;
            end
            if (s_axi_rvalid && s_axi_rready) begin
                rvalid_q <= 0; read_busy <= 0; ar_wait_q <= AR_WAIT_CYCLES;
            end
        end
    end
    // PROT is accepted but this small bare-metal RAM has no protection policy.
    // synthesis translate_off
    initial begin
        if (WORDS <= 0 || BASE_ADDR[1:0] != 0 ||
            ({32'd0, BASE_ADDR} + 64'd4 * WORDS) > 64'h100000000 ||
            AW_WAIT_CYCLES < 0 || W_WAIT_CYCLES < 0 || AR_WAIT_CYCLES < 0 ||
            B_WAIT_CYCLES < 0 || R_WAIT_CYCLES < 0)
            $fatal(1, "axi_lite_ram invalid size, range, or wait parameter");
    end
    // synthesis translate_on
endmodule
