// Temporary AXI4-Lite control-path demonstration, not a CNN protocol.
// START snapshots two operands; JOB_CYCLES clocks later RESULT is their
// 32-bit modular sum. All protocol, register and job state shares reset.
module axi_lite_ctrl #(
    parameter [31:0] BASE_ADDR = 32'h30000000,
    parameter integer JOB_CYCLES = 64,
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
    input wire s_axi_rready,
    output wire busy, done,
    output wire [31:0] result,
    output wire [31:0] start_count
);
    localparam integer JOB_COUNT_BITS = (JOB_CYCLES <= 1) ? 1 : $clog2(JOB_CYCLES) + 1;
    localparam [31:0] CTRL_OFFSET=32'h00, STATUS_OFFSET=32'h04;
    localparam [31:0] A_OFFSET=32'h08, B_OFFSET=32'h0c;
    localparam [31:0] RESULT_OFFSET=32'h10, COUNT_OFFSET=32'h14;

    reg aw_pending, w_pending, write_busy, bvalid_q;
    reg [31:0] awaddr_q, wdata_q;
    reg [3:0] wstrb_q;
    reg read_busy, rvalid_q;
    integer aw_wait_q, w_wait_q, ar_wait_q, b_wait_q, r_wait_q;

    reg busy_q, done_q;
    reg [31:0] operand_a_q, operand_b_q, snapshot_a_q, snapshot_b_q;
    reg [31:0] result_q, start_count_q;
    reg [JOB_COUNT_BITS-1:0] job_remaining_q;
    assign busy=busy_q;
    assign done=done_q;
    assign result=result_q;
    assign start_count=start_count_q;

    wire pair_commit=rst_n && aw_pending && w_pending && !write_busy;
    wire [31:0] write_offset=awaddr_q-BASE_ADDR;
    wire [31:0] read_offset=s_axi_araddr-BASE_ADDR;
    wire write_in_window=(awaddr_q[1:0]==0) &&
        ({1'b0,awaddr_q}>={1'b0,BASE_ADDR}) &&
        ({1'b0,awaddr_q}<({1'b0,BASE_ADDR}+33'h100));
    wire read_in_window=(s_axi_araddr[1:0]==0) &&
        ({1'b0,s_axi_araddr}>={1'b0,BASE_ADDR}) &&
        ({1'b0,s_axi_araddr}<({1'b0,BASE_ADDR}+33'h100));
    wire writable_offset=(write_offset==CTRL_OFFSET)||(write_offset==A_OFFSET)||(write_offset==B_OFFSET);
    wire readable_offset=(read_offset==CTRL_OFFSET)||(read_offset==STATUS_OFFSET)||
        (read_offset==A_OFFSET)||(read_offset==B_OFFSET)||
        (read_offset==RESULT_OFFSET)||(read_offset==COUNT_OFFSET);
    wire start_requested=(write_offset==CTRL_OFFSET)&&wstrb_q[0]&&wdata_q[0];
    // Rejected START is an atomic rejected CTRL command, including CLEAR.
    wire write_ok=write_in_window && writable_offset && !(start_requested&&busy_q);
    wire read_ok=read_in_window && readable_offset;
    reg [31:0] read_value;
    always @* begin
        case (read_offset)
            CTRL_OFFSET: read_value=32'd0;
            STATUS_OFFSET: read_value={30'd0,done_q,busy_q};
            A_OFFSET: read_value=operand_a_q;
            B_OFFSET: read_value=operand_b_q;
            RESULT_OFFSET: read_value=result_q;
            COUNT_OFFSET: read_value=start_count_q;
            default: read_value=32'd0;
        endcase
    end

    assign s_axi_awready=rst_n&&!write_busy&&!aw_pending&&(aw_wait_q==0);
    assign s_axi_wready=rst_n&&!write_busy&&!w_pending&&(w_wait_q==0);
    // Give a paired write priority over a same-edge register read. A read
    // accepted on a job completion edge captures the pre-edge register value.
    assign s_axi_arready=rst_n&&!read_busy&&!pair_commit&&(ar_wait_q==0);
    assign s_axi_bvalid=rst_n&&bvalid_q;
    assign s_axi_rvalid=rst_n&&rvalid_q;
    wire aw_fire=s_axi_awvalid&&s_axi_awready;
    wire w_fire=s_axi_wvalid&&s_axi_wready;
    wire ar_fire=s_axi_arvalid&&s_axi_arready;

    // Protocol state: one independent AW slot, one W slot, one response
    // per direction. Side effects occur at pairing, before B consumption.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_pending<=0;w_pending<=0;write_busy<=0;bvalid_q<=0;
            awaddr_q<=0;wdata_q<=0;wstrb_q<=0;s_axi_bresp<=0;
            read_busy<=0;rvalid_q<=0;s_axi_rdata<=0;s_axi_rresp<=0;
            aw_wait_q<=AW_WAIT_CYCLES;w_wait_q<=W_WAIT_CYCLES;
            ar_wait_q<=AR_WAIT_CYCLES;b_wait_q<=0;r_wait_q<=0;
        end else begin
            if (!write_busy&&!aw_pending&&s_axi_awvalid&&aw_wait_q>0) aw_wait_q<=aw_wait_q-1;
            if (!write_busy&&!w_pending&&s_axi_wvalid&&w_wait_q>0) w_wait_q<=w_wait_q-1;
            if (aw_fire) begin aw_pending<=1;awaddr_q<=s_axi_awaddr;end
            if (w_fire) begin w_pending<=1;wdata_q<=s_axi_wdata;wstrb_q<=s_axi_wstrb;end
            if (pair_commit) begin
                aw_pending<=0;w_pending<=0;write_busy<=1;
                s_axi_bresp<=write_ok?2'b00:2'b10;
                b_wait_q<=B_WAIT_CYCLES;
            end
            if (write_busy&&!bvalid_q) begin
                if (b_wait_q==0) bvalid_q<=1;
                else b_wait_q<=b_wait_q-1;
            end
            if (s_axi_bvalid&&s_axi_bready) begin
                bvalid_q<=0;write_busy<=0;
                aw_wait_q<=AW_WAIT_CYCLES;w_wait_q<=W_WAIT_CYCLES;
            end
            if (!read_busy&&!pair_commit&&s_axi_arvalid&&ar_wait_q>0) ar_wait_q<=ar_wait_q-1;
            if (ar_fire) begin
                read_busy<=1;r_wait_q<=R_WAIT_CYCLES;
                // A register read captures immediately; no synchronous RAM
                // stage is involved. These values are held through RREADY=0.
                s_axi_rdata<=read_ok?read_value:32'd0;
                s_axi_rresp<=read_ok?2'b00:2'b10;
            end
            if (read_busy&&!rvalid_q) begin
                if (r_wait_q==0) rvalid_q<=1;
                else r_wait_q<=r_wait_q-1;
            end
            if (s_axi_rvalid&&s_axi_rready) begin
                rvalid_q<=0;read_busy<=0;ar_wait_q<=AR_WAIT_CYCLES;
            end
        end
    end

    integer lane;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q<=0;done_q<=0;operand_a_q<=0;operand_b_q<=0;
            snapshot_a_q<=0;snapshot_b_q<=0;result_q<=0;start_count_q<=0;job_remaining_q<=0;
        end else begin
            if (pair_commit&&write_ok) begin
                case (write_offset)
                    CTRL_OFFSET: begin
                        if (wstrb_q[0]) begin
                            if (wdata_q[1]) done_q<=0;
                            if (wdata_q[0]) begin
                                snapshot_a_q<=operand_a_q;snapshot_b_q<=operand_b_q;
                                busy_q<=1;done_q<=0;start_count_q<=start_count_q+32'd1;
                                job_remaining_q<=JOB_CYCLES;
                            end
                        end
                    end
                    A_OFFSET: for (lane=0;lane<4;lane=lane+1)
                        if (wstrb_q[lane]) operand_a_q[lane*8+:8]<=wdata_q[lane*8+:8];
                    B_OFFSET: for (lane=0;lane<4;lane=lane+1)
                        if (wstrb_q[lane]) operand_b_q[lane*8+:8]<=wdata_q[lane*8+:8];
                    default: ;
                endcase
            end
            if (busy_q) begin
                if (job_remaining_q==1) begin
                    result_q<=snapshot_a_q+snapshot_b_q;
                    busy_q<=0;done_q<=1;job_remaining_q<=0;
                end else job_remaining_q<=job_remaining_q-1'b1;
            end
            // A new completion wins over CLEAR_DONE on the same edge.
        end
    end
    // PROT is accepted without a protection policy in this bare-metal demo.
    // synthesis translate_off
    initial begin
        if (BASE_ADDR[1:0]!=0 || ({1'b0,BASE_ADDR}+33'h100)>33'h100000000 ||
            JOB_CYCLES<1 || AW_WAIT_CYCLES<0 || W_WAIT_CYCLES<0 || AR_WAIT_CYCLES<0 ||
            B_WAIT_CYCLES<0 || R_WAIT_CYCLES<0)
            $fatal(1,"axi_lite_ctrl invalid base, job count or wait parameter");
    end
    // synthesis translate_on
endmodule
