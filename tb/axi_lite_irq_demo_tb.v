`timescale 1ns/1ps
// Future unit self-check; this source has not been compiled or simulated.
module axi_lite_irq_demo_tb;
    reg clk = 0, rst_n = 0, test_pass = 0;
    always #5 clk = ~clk;
    reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg [3:0] wstrb = 0;
    reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    reg expected_pending = 0;
    reg [31:0] expected_set = 0, expected_clear = 0;
    integer k;
    axi_lite_irq_demo dut (
        .clk(clk), .rst_n(rst_n), .irq(irq),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );
    task require_state;
        begin
            if (irq !== expected_pending || dut.set_count !== expected_set || dut.clear_count !== expected_clear)
                $fatal(1, "IRQ demo changed/replayed a side effect level=%b set/clear=%0d/%0d", irq, dut.set_count, dut.clear_count);
        end
    endtask
    task send_aw;
        begin
            @(negedge clk); awvalid = 1;
            @(posedge clk); while (!awready) @(posedge clk);
            @(negedge clk); awvalid = 0;
        end
    endtask
    task send_w;
        begin
            @(negedge clk); wvalid = 1;
            @(posedge clk); while (!wready) @(posedge clk);
            @(negedge clk); wvalid = 0;
        end
    endtask
    task read_word(input [31:0] offset, input [31:0] value, input [1:0] response);
        begin
            @(negedge clk); araddr = 32'h30000000 + offset; arvalid = 1; rready = 0;
            @(posedge clk); while (!arready) @(posedge clk);
            @(negedge clk); arvalid = 0;
            repeat (12) begin
                if (!rvalid || rdata !== value || rresp !== response || arready)
                    $fatal(1, "IRQ demo held R payload/AR backpressure offset=%h", offset);
                @(negedge clk);
            end
            rready = 1; @(posedge clk); @(negedge clk); rready = 0;
            if (rvalid) $fatal(1, "IRQ demo R not consumed");
        end
    endtask
    task finish_write(input [31:0] offset, input [31:0] data, input [1:0] response);
        begin
            wait (bvalid);
            if (response == 0 && data[0]) begin
                if (offset == 8) begin expected_pending = 1; expected_set = expected_set + 1; end
                if (offset == 12) begin expected_pending = 0; expected_clear = expected_clear + 1; end
            end
            repeat (5) begin
                @(negedge clk);
                if (!bvalid || bresp !== response || awready || wready)
                    $fatal(1, "IRQ demo held B response/side-effect replay");
                require_state;
            end
            bready = 1; @(posedge clk); @(negedge clk); bready = 0;
            if (bvalid) $fatal(1, "IRQ demo B not consumed");
        end
    endtask
    task write_word(input [31:0] offset, input [31:0] data,
                    input [3:0] strobe, input integer order, input [1:0] response);
        begin
            @(negedge clk); awaddr = 32'h30000000 + offset; wdata = data; wstrb = strobe;
            if (order == 0) begin
                send_aw;
                repeat (3) begin @(negedge clk); require_state; if (bvalid) $fatal(1, "IRQ demo answered AW without W"); end
                send_w;
            end else if (order == 1) begin
                send_w;
                repeat (3) begin @(negedge clk); require_state; if (bvalid) $fatal(1, "IRQ demo answered W without AW"); end
                send_aw;
            end else begin fork send_aw; send_w; join end
            finish_write(offset, data, response);
        end
    endtask
    task check_readback;
        begin
            read_word(0, 32'h49525131, 0);
            read_word(4, {31'd0, expected_pending}, 0);
            read_word(16, expected_set, 0);
            read_word(20, expected_clear, 0);
        end
    endtask
    task assert_reset_state;
        begin
            #1;
            if (irq || rvalid || bvalid || arready || awready || wready || dut.set_count !== 0 || dut.clear_count !== 0)
                $fatal(1, "IRQ demo reset retained level/count/protocol state");
            expected_pending = 0; expected_set = 0; expected_clear = 0;
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        check_readback;
        write_word(8, 32'hfffffffe, 15, 0, 0); check_readback; // bit0=0 is a legal no-op.
        write_word(8, 1, 15, 1, 0); check_readback;
        repeat (3) read_word(4, 1, 0); // Reading PENDING never acknowledges it.
        write_word(8, 1, 15, 2, 0); check_readback; // Commands count even if level was already high.
        write_word(12, 0, 15, 0, 0); check_readback;
        write_word(8, 1, 0, 2, 2); write_word(8, 1, 1, 1, 2);
        write_word(12, 1, 14, 0, 2);
        write_word(0, 1, 15, 0, 2); write_word(4, 1, 15, 1, 2);
        write_word(16, 1, 15, 2, 2); write_word(20, 1, 15, 0, 2);
        write_word(9, 1, 15, 1, 2); write_word(13, 1, 15, 2, 2);
        write_word(24, 1, 15, 0, 2); write_word(32'hfffffffc, 1, 15, 1, 2);
        check_readback;
        read_word(8, 0, 2); read_word(12, 0, 2);
        read_word(1, 0, 2); read_word(5, 0, 2); read_word(24, 0, 2); read_word(32'hfffffffc, 0, 2);

        // A held read response must remain frozen while an independent write
        // changes the actual interrupt level and counter.
        fork
            read_word(4, 1, 0);
            write_word(12, 1, 15, 2, 0);
        join
        check_readback;
        write_word(12, 1, 15, 1, 0); check_readback;
        write_word(8, 1, 15, 0, 0);

        // Reset a half-write plus held R. The old AW cannot pair with a new W.
        @(negedge clk); awaddr = 32'h30000008; wdata = 1; wstrb = 15;
        send_aw;
        @(negedge clk); araddr = 32'h30000004; arvalid = 1;
        @(posedge clk); while (!arready) @(posedge clk);
        @(negedge clk); arvalid = 0; rst_n = 0; assert_reset_state;
        repeat (3) @(negedge clk); rst_n = 1;
        check_readback;
        send_w;
        repeat (4) begin @(negedge clk); if (bvalid) $fatal(1, "IRQ demo retained pre-reset AW"); require_state; end
        send_aw; finish_write(8, 1, 0);

        // A held B is also cancelled by reset, including its associated level.
        @(negedge clk); awaddr = 32'h3000000c; wdata = 1; wstrb = 15;
        fork send_aw; send_w; join
        wait (bvalid); @(negedge clk); rst_n = 0; assert_reset_state;
        repeat (3) @(negedge clk); rst_n = 1;
        check_readback;
        test_pass = 1;
        $display("AXI IRQ DEMO TESTS PASS: level and command counts, SET/CLEAR bit0, independent AW/W, no side effects on SLVERR, held R/B and reset");
        $stop;
    end
    initial begin #200000; $fatal(1, "AXI IRQ demo timeout"); end
endmodule
