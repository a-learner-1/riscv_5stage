`timescale 1ns/1ps
module data_bus_adapter_tb;
    reg clk=0, rst_n=0, req_valid=0, req_write=0, req_mmio=1;
    reg req_access_ok=1, rsp_ready=0;
    reg [31:0] mmio_rdata=0, ram_rdata=32'h12345678;
    wire req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;
    integer accepted=0, completed=0, before_accept, before_complete, watchdog;
    reg test_pass=0;
    always #5 clk=~clk;
    data_bus_adapter #(.REQ_WAIT_CYCLES(3), .RSP_WAIT_CYCLES(4)) dut (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
        .req_write(req_write), .req_mmio(req_mmio), .req_access_ok(req_access_ok),
        .mmio_rdata(mmio_rdata), .ram_rdata(ram_rdata), .rsp_valid(rsp_valid),
        .rsp_ready(rsp_ready), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
    );
    always @(posedge clk) if (rst_n) begin
        if (req_valid && req_ready) accepted=accepted+1;
        if (rsp_valid && rsp_ready) completed=completed+1;
    end
    task tick; begin @(posedge clk); #1; end endtask
    task reset_endpoint;
        begin
            @(negedge clk); rst_n=0; req_valid=0; rsp_ready=0;
            #1;
            if (req_ready || rsp_valid) $fatal(1,"Adapter not quiescent during reset");
            repeat (2) tick;
            @(negedge clk); rst_n=1;
            repeat (6) begin
                tick;
                if (rsp_valid) $fatal(1,"Adapter returned a stale response after reset");
            end
        end
    endtask
    task accept_read;
        input [31:0] value;
        input legal;
        begin
            @(negedge clk);
            mmio_rdata=value; req_access_ok=legal; req_valid=1; rsp_ready=0;
            before_accept=accepted; watchdog=0;
            while (accepted==before_accept) begin
                tick; watchdog=watchdog+1;
                if (watchdog>8) $fatal(1,"Adapter did not accept request");
            end
            if (watchdog!=4 || req_ready || rsp_valid)
                $fatal(1,"Adapter request wait/response latency mismatch");
            @(negedge clk); req_valid=0;
        end
    endtask
    initial begin
        #12; rst_n=1;
        accept_read(32'h55,1);
        mmio_rdata=32'haa;
        wait (rsp_valid); #1;
        repeat (3) begin
            tick;
            if (!rsp_valid || req_ready || rsp_rdata!==32'h55 || rsp_error)
                $fatal(1,"Adapter lost snapshot under response backpressure");
        end
        @(negedge clk); rsp_ready=1;
        tick;
        if (completed!=1 || rsp_valid) $fatal(1,"Adapter response consumed incorrectly");
        accept_read(32'hdeadbeef,0);
        req_access_ok=1; mmio_rdata=0;
        wait (rsp_valid); #1;
        if (!rsp_error || rsp_rdata!==32'hdeadbeef)
            $fatal(1,"Adapter did not preserve error/data snapshot");
        reset_endpoint(); // Response already valid but not consumed.
        before_accept=accepted;
        @(negedge clk); req_valid=1;
        tick;
        if (accepted!=before_accept || req_ready) $fatal(1,"No request backpressure");
        reset_endpoint(); // Request not yet accepted.
        accept_read(32'h11,1);
        if (rsp_valid) $fatal(1,"Response wait not exercised");
        reset_endpoint(); // Request accepted, response not yet available.
        req_mmio=0;
        accept_read(0,1);
        wait (rsp_valid); #1;
        if (rsp_rdata!==32'h12345678 || rsp_error) $fatal(1,"RAM response after reset");
        before_complete=completed;
        @(negedge clk); rsp_ready=1;
        tick;
        if (completed!=before_complete+1 || rsp_valid) $fatal(1,"Recovery response count");
        $display("PASS: local data adapter snapshot/error hold, response backpressure and reset before/after acceptance");
        test_pass=1;
        $stop;
    end
    initial begin #10000; $fatal(1,"Adapter unit timeout"); end
endmodule
