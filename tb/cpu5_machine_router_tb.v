`timescale 1ns/1ps
module cpu5_machine_router_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
    reg [31:0] req_addr=0,req_wdata=0;reg [1:0] req_size=2;reg [3:0] req_wstrb=0;
    wire req_ready,rsp_valid,rsp_error;wire [31:0] rsp_rdata;
    wire ext_req_valid,ext_req_write,ext_rsp_ready;wire [31:0] ext_req_addr,ext_req_wdata;
    wire [1:0] ext_req_size;wire [3:0] ext_req_wstrb;
    reg ext_req_ready=1,ext_rsp_valid=0,ext_rsp_error=0;reg [31:0] ext_rsp_rdata=0;
    wire irq_timer,irq_software;wire uart_tx;wire [7:0] gpio_out,gpio_oe;
    reg [63:0] cycle_count=0,instret_count=0;
    cpu5_machine_router #(.ENABLE_TIMER_DEVICE(1),.ENABLE_SOFTWARE_DEVICE(1),.UART_CLOCK_HZ(100),.UART_BAUD(10),.UART_RX_FIFO_DEPTH(4)) dut(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_wdata(req_wdata),.req_size(req_size),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),
        .ext_req_valid(ext_req_valid),.ext_req_ready(ext_req_ready),.ext_req_write(ext_req_write),
        .ext_req_addr(ext_req_addr),.ext_req_wdata(ext_req_wdata),.ext_req_size(ext_req_size),.ext_req_wstrb(ext_req_wstrb),
        .ext_rsp_valid(ext_rsp_valid),.ext_rsp_ready(ext_rsp_ready),.ext_rsp_rdata(ext_rsp_rdata),.ext_rsp_error(ext_rsp_error),
        .cycle_count(cycle_count),.instret_count(instret_count),.uart_rx(1'b1),.uart_tx(uart_tx),
        .gpio_in(8'h3c),.gpio_out(gpio_out),.gpio_oe(gpio_oe),.irq_timer(irq_timer),.irq_software(irq_software));
    integer accepts=0,responses=0,external_accepts=0,local_effects=0,gpio_effects=0,reset_drops=0,machine_effects=0;
    integer checks=0,timeout=0,fd;reg last_accept=0,last_response=0,test_pass=0;
    reg pending=0,pending_local=0,pending_machine=0;
    task tick;begin @(posedge clk);#2;end endtask
    task check(input cond,input [511:0] description);
        begin checks=checks+1;if(cond!==1'b1)$fatal(1,"MACHINE router oracle %0s",description);end
    endtask
    task launch(input [31:0] address,input write_op,input [31:0] data);
        begin @(negedge clk);req_addr=address;req_write=write_op;req_wdata=data;req_wstrb=write_op?15:0;req_valid=1;
            timeout=0;tick;while(!last_accept)begin tick;timeout=timeout+1;if(timeout>40)$fatal(1,"MACHINE router request timeout");end
            req_valid=0;end
    endtask
    task receive(input [31:0] data,input error);
        begin timeout=0;while(!rsp_valid)begin tick;timeout=timeout+1;if(timeout>40)$fatal(1,"MACHINE router response timeout");end
            repeat(5)begin check(rsp_valid&&rsp_rdata===data&&rsp_error===error,"held response route and snapshot");tick;end
            @(negedge clk);rsp_ready=1;tick;check(last_response,"response handshake");
            @(negedge clk);rsp_ready=0;ext_rsp_valid=0;ext_rsp_error=0;end
    endtask
    task reset_now;
        begin @(negedge clk);if(pending)reset_drops=reset_drops+1;
            rst_n=0;req_valid=0;ext_rsp_valid=0;rsp_ready=0;tick;tick;
            check(!rsp_valid&&!req_ready&&!ext_req_valid&&!ext_rsp_ready&&gpio_out==0,"reset canceled outstanding route");
            @(negedge clk);rst_n=1;tick;end
    endtask
    always @(posedge clk)begin
        cycle_count<=cycle_count+1;
        if(!rst_n)begin pending=0;pending_local=0;pending_machine=0;last_accept=0;last_response=0;end
        else begin
            last_accept=req_valid&&req_ready;last_response=rsp_valid&&rsp_ready;
            if(ext_rsp_valid&&ext_rsp_ready)check(pending&&!pending_local&&last_response,"external response qualification");
            if(last_response)begin
                check(pending,"response owns accepted transaction");pending=0;responses=responses+1;
            end
            if(last_accept)begin
                check(!pending,"no accepted route overwrite");pending=1;pending_local=(req_addr>=32'h20000000&&req_addr<32'h20000100);
                pending_machine=(req_addr>=32'h20000040&&req_addr<32'h20000054);
                accepts=accepts+1;if(!pending_local)external_accepts=external_accepts+1;
            end
            if(ext_req_valid&&ext_req_ready)check(last_accept&&!pending_local,"external request qualification");
            if(dut.u_normal.u_endpoint.endpoint_fire)begin
                check(pending&&pending_local&&!pending_machine,"local execution owns accepted transaction");local_effects=local_effects+1;
            end
            if(dut.u_machine_endpoint.endpoint_fire)begin
                check(pending&&pending_machine,"machine execution owns accepted transaction");machine_effects=machine_effects+1;
            end
            if(dut.u_normal.u_endpoint.gpio_write_fire)gpio_effects=gpio_effects+1;
        end
    end
    initial begin
        reset_now;
        // External A's response must survive live input changes to a local
        // address. A successful external response can accept external B.
        ext_req_ready=0;
        @(negedge clk);req_valid=1;req_addr='h10000;repeat(4)begin tick;check(ext_req_valid&&!req_ready&&ext_req_addr==='h10000,"held external request");end
        @(negedge clk);ext_req_ready=1;tick;check(last_accept,"external A accepted");
        @(negedge clk);req_addr='h20000020;req_valid=0;ext_rsp_valid=1;ext_rsp_rdata='h11223344;
        repeat(3)begin tick;check(rsp_valid&&rsp_rdata==='h11223344,"external response ignores live local address");end
        @(negedge clk);req_valid=1;req_addr='h10004;rsp_ready=1;tick;
        check(last_accept&&last_response,"external load turnover");
        @(negedge clk);req_valid=0;rsp_ready=0;ext_rsp_valid=0;tick;
        @(negedge clk);ext_rsp_valid=1;ext_rsp_rdata='h55667788;receive('h55667788,0);

        // A local write executes once after capture. A wrong-side external
        // response and changing live address cannot supply the local reply.
        launch('h20000020,1,'h5a);req_addr='h90000000;ext_rsp_valid=1;ext_rsp_rdata='hbad0bad0;ext_rsp_error=1;
        receive(0,0);check(gpio_out==='h5a&&gpio_effects==1,"local GPIO one execution");
        launch('h20000034,1,'h0f);req_addr='h10000;repeat(8)tick;
        check(gpio_out==='h55&&gpio_effects==2,"XOR held response never replayed");
        // Local -> external needs an empty edge at response consumption.
        @(negedge clk);req_valid=1;req_addr='h10008;req_write=0;req_wstrb=0;rsp_ready=1;
        #1;check(!req_ready&&!ext_req_valid,"local response prohibits turnover");tick;
        check(last_response&&!last_accept,"local boundary drains first");
        @(negedge clk);rsp_ready=0;tick;check(last_accept,"external request after local drain");
        @(negedge clk);req_valid=0;ext_rsp_valid=1;ext_rsp_error=0;ext_rsp_rdata='haabbccdd;
        // External -> local likewise waits, and the pending local read must
        // not steal or clear the external response data/error.
        req_valid=1;req_addr='h20000020;rsp_ready=1;#1;check(!req_ready,"external response cannot accept local request");
        check(rsp_rdata==='haabbccdd,"external data retained at local boundary");tick;
        check(last_response&&!last_accept,"external route consumed before local");
        @(negedge clk);rsp_ready=0;ext_rsp_valid=0;tick;check(last_accept,"local read accepted after external drain");
        @(negedge clk);req_valid=0;receive('h55,0);

        // Reset after capture suppresses the local effect; reset during an
        // external wait also prevents an old response from becoming a reply.
        launch('h20000034,1,'hff);reset_now;check(gpio_effects==2,"reset before endpoint fire has no write");
        launch('h90000000,0,0);reset_now;
        ext_rsp_valid=1;ext_rsp_rdata='hdeadbeef;repeat(3)begin tick;check(!rsp_valid&&!ext_rsp_ready,"old reset response not revived");end
        @(negedge clk);ext_rsp_valid=0;launch('h20000024,0,0);receive('h3c,0);
        // Machine responses retain their route and snapshot even when the
        // current request address selects the normal router or vice versa.
        launch('h20000050,1,1);req_addr='h90000000;ext_rsp_valid=1;ext_rsp_rdata='hbad0bad0;ext_rsp_error=1;
        receive(0,0);check(irq_software,"MSIP asserted through machine route");
        launch('h20000050,0,0);req_addr='h20000020;receive(1,0);
        check(irq_software,"MSIP read and response do not clear source");
        launch('h20000050,0,0);while(!rsp_valid)tick;
        @(negedge clk);req_valid=1;req_addr='h10010;rsp_ready=1;
        #1;check(!req_ready&&!ext_req_valid,"machine response prohibits turnover");tick;
        check(last_response&&!last_accept,"machine boundary drains first");
        @(negedge clk);rsp_ready=0;tick;check(last_accept,"normal request follows machine drain");
        @(negedge clk);req_valid=0;req_addr='h20000050;ext_rsp_valid=1;ext_rsp_rdata='habcdef01;ext_rsp_error=0;
        receive('habcdef01,0);
        launch('h20000024,0,0);req_addr='h20000040;receive('h3c,0);
        launch('h2000004c,1,0);receive(0,0);check(!irq_timer,"safe compare high before low");
        launch('h20000048,1,0);receive(0,0);check(irq_timer,"timer level asserted from bank");
        launch('h2000004c,1,'hffffffff);receive(0,0);check(!irq_timer,"timer level cleared through bank");
        launch('h20000050,1,1);reset_now;
        check(!irq_timer&&!irq_software&&machine_effects==6,"reset cancels captured machine write");
        launch('h20000050,1,1);while(!rsp_valid)tick;repeat(3)tick;
        check(irq_software,"held machine response keeps source");reset_now;
        repeat(3)tick;check(!rsp_valid&&!irq_software&&!irq_timer,"reset cancels held machine response");
        check(accepts==responses+reset_drops&&reset_drops==4,"reset transaction ledger closure");
        check(local_effects==5&&gpio_effects==2&&external_accepts==5&&machine_effects==7,"source and effect ledger closure");
        fd=$fopen("build/cpu5_s11_machine_router/summary.json","w");
        $fdisplay(fd,"{\"status\":\"PASS\",\"accepts\":%0d,\"responses\":%0d,\"reset_drops\":%0d,\"external_accepts\":%0d,\"local_effects\":%0d,\"gpio_effects\":%0d,\"machine_effects\":%0d,\"checks\":%0d}",accepts,responses,reset_drops,external_accepts,local_effects,gpio_effects,machine_effects,checks);$fclose(fd);
        test_pass=1;$display("CPU5 MACHINE ROUTER TEST PASS");$stop;
    end
    initial begin #20000;$fatal(1,"MACHINE router timeout");end
endmodule
