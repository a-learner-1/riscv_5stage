// Standalone legal endpoint fixture: execution-time samples, response hold,
// 32-bit carry, 64-bit wrap, and high-low-high retry without hierarchical force.
`timescale 1ns/1ps
module cpu5_coremark_timer_probe;
    reg clk=0,rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
    reg [31:0] req_addr=0,req_wdata=0;
    wire req_ready,rsp_valid,rsp_error;
    wire [31:0] rsp_rdata;
    wire [63:0] mtime;
    reg test_pass=0;
    reg [63:0] model=0;
    reg [31:0] expected_rsp=0;
    integer executions=0,responses=0,holds=0,carries=0,wraps=0;
    reg [31:0] h1,lo,h2;
    always #10 clk=~clk;
    cpu5_machine_endpoint #(.ENABLE_TIMER_DEVICE(1)) dut(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),
        .req_write(req_write),.req_addr(req_addr),.req_size(2'd2),
        .req_wdata(req_wdata),.req_wstrb(req_write?4'hf:4'h0),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),
        .irq_timer(),.irq_software(),.mtime_value(mtime),.mtimecmp_value());
    always @(posedge clk) if (rst_n) begin
        if (mtime!==model) $fatal(1,"timer probe pre-edge independent model");
        if (dut.endpoint_fire) begin
            if (!dut.access_legal) $fatal(1,"timer probe unexpected illegal request");
            expected_rsp=dut.write_q?0:dut.addr_q==32'h20000044 ? model[63:32]:model[31:0];
            if (dut.read_value!==expected_rsp) $fatal(1,"timer probe execution read value");
            executions=executions+1;
        end
        if (rsp_valid) begin
            if (rsp_error || rsp_rdata!==expected_rsp) $fatal(1,"timer probe response lost frozen execution value");
            if (rsp_ready) responses=responses+1;
            else holds=holds+1;
        end
        if (dut.timer_write_fire && dut.addr_q==32'h20000040) model={model[63:32],dut.wdata_q};
        else if (dut.timer_write_fire && dut.addr_q==32'h20000044) model={dut.wdata_q,model[31:0]};
        else begin
            if (model[31:0]==32'hffffffff) carries=carries+1;
            if (model==64'hffffffffffffffff) wraps=wraps+1;
            model=model+1;
        end
    end
    task access(input reg wr,input [31:0] addr,input [31:0] data,input integer hold_cycles,output reg[31:0] value);
        begin
            @(negedge clk); req_valid=1;req_write=wr;req_addr=addr;req_wdata=data;
            @(posedge clk); while(!req_ready) @(posedge clk);
            @(negedge clk); req_valid=0;
            wait(rsp_valid); value=rsp_rdata;
            repeat(hold_cycles) @(negedge clk);
            @(negedge clk);rsp_ready=1;
            @(negedge clk);rsp_ready=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        access(1,32'h20000044,32'h12345678,0,h1);
        access(1,32'h20000040,32'hfffffff3,0,h1);
        access(0,32'h20000044,0,0,h1);
        access(0,32'h20000040,0,3,lo);
        access(0,32'h20000044,0,0,h2);
        if(h1==h2) $fatal(1,"timer carry fixture did not reject incoherent high-low-high");
        access(0,32'h20000044,0,0,h1);
        access(0,32'h20000040,0,0,lo);
        access(0,32'h20000044,0,0,h2);
        if(h1!==h2 || h1!==32'h12345679) $fatal(1,"timer coherent retry wrong high word");
        access(1,32'h20000044,32'hffffffff,0,h1);
        access(1,32'h20000040,32'hfffffff8,0,h1);
        access(0,32'h20000040,0,20,lo);
        access(0,32'h20000044,0,0,h2);
        if(h2!==0 || carries<2 || wraps!=1 || holds<20 || executions!=responses)
            $fatal(1,"timer probe boundary/hold closure executions=%0d responses=%0d holds=%0d carries=%0d wraps=%0d",executions,responses,holds,carries,wraps);
        test_pass=1;
        $display("CPU5 COREMARK TIMER PROBE PASS executions=%0d responses=%0d holds=%0d carries=%0d wraps=%0d",executions,responses,holds,carries,wraps);
        $stop;
    end
    initial begin #100000;$fatal(1,"timer probe watchdog");end
endmodule

