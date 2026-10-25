`timescale 1ns/1ps
// Public native/AXI ledgers and independent byte-RAM gold. No force/deposit.
module cpu5_d0_backend_tb;
    bind soc_data_mem cpu5_d0_ram_monitor #(.WORDS(WORDS),.BASE_ADDR(BASE_ADDR)) auth_monitor(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_wdata(req_wdata),.req_size(req_size),.req_wstrb(req_wstrb),.mem_we(mem_we),.mem_re(mem_re));
    wire [5:0] done;reg test_pass=0;
    cpu5_d0_backend_case #(.CASE_ID(0),.D0(0),.WAIT_CYCLES(0)) c0(done[0]);
    cpu5_d0_backend_case #(.CASE_ID(1),.D0(0),.WAIT_CYCLES(3)) c1(done[1]);
    cpu5_d0_backend_case #(.CASE_ID(2),.D0(1),.WAIT_CYCLES(0)) c2(done[2]);
    cpu5_d0_backend_case #(.CASE_ID(3),.D0(1),.WAIT_CYCLES(3)) c3(done[3]);
    cpu5_d0_backend_case #(.CASE_ID(4),.D0(0),.WAIT_CYCLES(2),.BASE(32'hfffffff0),.WORDS(4)) c4(done[4]);
    cpu5_d0_backend_case #(.CASE_ID(5),.D0(1),.WAIT_CYCLES(2),.BASE(32'hfffffff0),.WORDS(4)) c5(done[5]);
    initial begin wait(&done);test_pass=1;$display("CPU5 D0 BACKEND TEST PASS");$stop;end
    initial begin #1000000;$fatal(1,"D0 backend global progress timeout done=%b",done);end
endmodule

module cpu5_d0_backend_case #(parameter CASE_ID=0,D0=0,WAIT_CYCLES=0,WORDS=16,
                             parameter [31:0] BASE=32'h10000)(output reg done=0);
    localparam [63:0] END_ADDR={32'd0,BASE}+64'd4*WORDS;
    localparam [31:0] IO=32'h30000000;
    reg clk=0,rst_n=0,qv=0,qw=0,rr=0,hold_response=0;
    reg [31:0] qa=0,qd=0;reg [1:0] qs=2;reg [3:0] qt=0;
    wire qr,rv,re;wire [31:0] rd;
    wire [31:0] awaddr,wdata,araddr,rdata;wire [2:0] awprot,arprot;
    wire [3:0] wstrb;wire awvalid,wvalid,bready,arvalid,rready,awready,wready,arready,bvalid,rvalid;
    wire [1:0] bresp,rresp;
    always #5 clk=~clk;
    cpu5_d0_backend #(.ENABLE_D0_BRAM(D0),.DMEM_WORDS(WORDS),.DMEM_BASE_ADDR(BASE),.DATA_FILE(""),
        .D0_REQ_WAIT_CYCLES(WAIT_CYCLES),.D0_RSP_WAIT_CYCLES(WAIT_CYCLES)) dut(
        .clk(clk),.rst_n(rst_n),.req_valid(qv),.req_ready(qr),.req_write(qw),.req_addr(qa),.req_size(qs),.req_wdata(qd),.req_wstrb(qt),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_rdata(rd),.rsp_error(re),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    reg [31:0] physical_axi[0:WORDS-1],gold[0:WORDS-1];
    reg [31:0] device=32'hcafef00d,device_gold=32'hcafef00d;
    reg av=0,wv=0,paired=0,rp=0;reg [31:0] aq=0,wq=0,rq=0;reg [3:0] tq=0;reg [1:0] bc=0,rc=0;
    integer adelay=0,wdelay=0,rdelay=0;
    integer accepted=0,responses=0,reset_drops=0,checks=0,invalids=0,errors=0,local_ops=0,local_writes=0;
    integer aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0,pairs=0,axi_reset_reads=0,axi_ram_writes=0,io_writes=0,side_reads=0;
    integer aw_holds=0,w_holds=0,ar_holds=0,cpu_holds=0,bubble_checks=0,native_holds=0;
    reg native_active=0,n_axi=0,n_write=0,n_error=0,aw_seen=0,w_seen=0,ar_seen=0;
    reg [31:0] n_addr=0,n_data=0,n_result=0;reg [3:0] n_strb=0;
    reg last_accept=0,last_rsp=0,ah=0,wh=0,rh=0,ch=0,qh=0;
    reg [34:0] saved_aw,saved_ar;reg [35:0] saved_w;reg [32:0] saved_rsp;reg [70:0] saved_req;
    integer i,lane,timeout,fd,sfd,before_a,before_r,before_req,before_axi;reg [31:0] pa,pd;
    reg [3:0] pt;
    function in_ram(input [31:0] address);
        in_ram=({32'd0,address}>={32'd0,BASE})&&({32'd0,address}<END_ADDR);
    endfunction
    function legal_shape(input wr,input [31:0] address,input [1:0] size,input [3:0] strb);
        reg aligned;reg [3:0] mask;
        begin aligned=size==0||(size==1&&!address[0])||(size==2&&address[1:0]==0);
            mask=size==0?(4'b0001<<address[1:0]):size==1?(4'b0011<<address[1:0]):4'b1111;
            legal_shape=aligned&&(!wr||strb==mask);end
    endfunction
    function [1:0] response_code(input [31:0] address);
        begin if(in_ram(address)||address==IO)response_code=0;
            else if(address==IO+4)response_code=1;
            else if(address==IO+8)response_code=2;else response_code=3;end
    endfunction
    wire af=awvalid&&awready,wf=wvalid&&wready,arf=arvalid&&arready;
    wire pair_now=(av||af)&&(wv||wf)&&!paired;
    assign awready=rst_n&&!av&&!paired&&adelay>=2+(CASE_ID%3==2?4:0);
    assign wready=rst_n&&!wv&&!paired&&wdelay>=2+(CASE_ID%3==1?4:0);
    assign arready=rst_n&&!rp&&rdelay>=3;
    assign bvalid=rst_n&&paired&&!hold_response;
    assign bresp=bc;
    assign rvalid=rst_n&&rp&&!hold_response;
    assign rresp=rc;
    assign rdata=rc==0?rq:32'hdeadbeef;
    task tick;begin @(posedge clk);#2;end endtask
    task reset_shared;
        begin @(negedge clk);
            if(native_active)reset_drops=reset_drops+1;
            if(rp)axi_reset_reads=axi_reset_reads+1;
            rst_n=0;qv=0;rr=0;hold_response=0;
            repeat(3)tick;
            if(qr||rv||awvalid||wvalid||arvalid||bready||rready)$fatal(1,"D0 backend reset leaked protocol");
            @(negedge clk);rst_n=1;tick;
        end
    endtask
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin av<=0;wv<=0;paired<=0;rp<=0;adelay<=0;wdelay<=0;rdelay<=0;bc<=0;rc<=0;end
        else begin
            if(awvalid&&!av)adelay<=adelay+1;
            if(wvalid&&!wv)wdelay<=wdelay+1;
            if(arvalid&&!rp)rdelay<=rdelay+1;
            if(af)begin av<=1;aq<=awaddr;end
            if(wf)begin wv<=1;wq<=wdata;tq<=wstrb;end
            if(pair_now)begin
                pa=av?aq:awaddr;pd=wv?wq:wdata;pt=wv?tq:wstrb;
                if(in_ram(pa))begin
                    for(lane=0;lane<4;lane=lane+1)if(pt[lane])physical_axi[(pa-BASE)>>2][8*lane+:8]<=pd[8*lane+:8];
                    axi_ram_writes=axi_ram_writes+1;
                end else if(pa>=IO&&pa<IO+16)begin
                    for(lane=0;lane<4;lane=lane+1)if(pt[lane])device[8*lane+:8]<=pd[8*lane+:8];
                    io_writes=io_writes+1;
                end
                paired<=1;bc<=response_code(pa);pairs=pairs+1;
            end
            if(bvalid&&bready)begin av<=0;wv<=0;paired<=0;adelay<=0;wdelay<=0;end
            if(arf)begin
                rp<=1;rc<=response_code(araddr);
                if(in_ram(araddr))rq<=physical_axi[(araddr-BASE)>>2];
                else begin rq<=device;if(araddr==IO)begin device<=device+1;side_reads=side_reads+1;end end
            end
            if(rvalid&&rready)begin rp<=0;rdelay<=0;end
        end
    end
    always @(posedge clk)begin
        last_accept=0;last_rsp=0;
        if(!rst_n)begin native_active=0;ah=0;wh=0;rh=0;ch=0;qh=0;aw_seen=0;w_seen=0;ar_seen=0;end
        else if(!done)begin
            if(ah&&(!awvalid||{awaddr,awprot}!==saved_aw))$fatal(1,"D0 backend held AW changed");
            if(wh&&(!wvalid||{wdata,wstrb}!==saved_w))$fatal(1,"D0 backend held W changed");
            if(rh&&(!arvalid||{araddr,arprot}!==saved_ar))$fatal(1,"D0 backend held AR changed");
            if(ch&&(!rv||{re,rd}!==saved_rsp))$fatal(1,"D0 backend held native response changed");
            if(qh&&(!qv||{qw,qa,qs,qd,qt}!==saved_req))$fatal(1,"D0 backend native master changed held request");
            ah=awvalid&&!awready;wh=wvalid&&!wready;rh=arvalid&&!arready;ch=rv&&!rr;qh=qv&&!qr;
            if(ah)begin saved_aw={awaddr,awprot};aw_holds=aw_holds+1;end
            if(wh)begin saved_w={wdata,wstrb};w_holds=w_holds+1;end
            if(rh)begin saved_ar={araddr,arprot};ar_holds=ar_holds+1;end
            if(ch)begin saved_rsp={re,rd};cpu_holds=cpu_holds+1;end
            if(qh)begin saved_req={qw,qa,qs,qd,qt};native_holds=native_holds+1;end
            if(qv&&qr)begin
                if(native_active)$fatal(1,"D0 backend accepted overlap or response-edge turnover");
                native_active=1;accepted=accepted+1;last_accept=1;aw_seen=0;w_seen=0;ar_seen=0;
                n_axi=legal_shape(qw,qa,qs,qt)&&(!D0||!in_ram(qa));n_write=qw;n_addr=qa;n_data=qd;n_strb=qt;
                if(D0&&in_ram(qa))begin local_ops=local_ops+1;if(qw&&legal_shape(qw,qa,qs,qt))local_writes=local_writes+1;end
                $fdisplay(fd,"native_req,%0t,%h,%h,%h,%0d",$time,qa,qd,qt,qw);
            end
            if(af)begin
                if(!native_active||!n_axi||!n_write||aw_seen||awprot!==0||awaddr!=={n_addr[31:2],2'b00})$fatal(1,"D0 backend AXI AW route/descriptor mismatch");
                aw_seen=1;aw_count=aw_count+1;$fdisplay(fd,"aw,%0t,%h,0,0,1",$time,awaddr);
            end
            if(wf)begin
                if(!native_active||!n_axi||!n_write||w_seen||wdata!==n_data||wstrb!==n_strb)$fatal(1,"D0 backend AXI W route/descriptor mismatch");
                w_seen=1;w_count=w_count+1;$fdisplay(fd,"w,%0t,0,%h,%h,1",$time,wdata,wstrb);
            end
            if(bvalid&&bready)begin
                if(!native_active||!aw_seen||!w_seen)$fatal(1,"D0 backend B has no paired owner");b_count=b_count+1;
            end
            if(arf)begin
                if(!native_active||!n_axi||n_write||ar_seen||arprot!==0||araddr!=={n_addr[31:2],2'b00})$fatal(1,"D0 backend AXI AR route/descriptor mismatch");
                ar_seen=1;ar_count=ar_count+1;$fdisplay(fd,"ar,%0t,%h,0,0,0",$time,araddr);
            end
            if(rvalid&&rready)begin if(!native_active||!ar_seen)$fatal(1,"D0 backend R has no owner");r_count=r_count+1;end
            if(rv)begin
                if(!native_active||re!==n_error||rd!==n_result)$fatal(1,"D0 backend architectural data/error case=%0d got=%h/%b expected=%h/%b addr=%h",CASE_ID,rd,re,n_result,n_error,n_addr);
                if(rr)begin responses=responses+1;last_rsp=1;native_active=0;if(re)errors=errors+1;end
            end
        end
    end
    task access(input wr,input [31:0] address,input [1:0] size,input [31:0] data,input [3:0] strobe,input cancel);
        reg legal,ram_target;integer before_n;
        begin
            legal=legal_shape(wr,address,size,strobe);ram_target=in_ram(address);before_n=accepted;before_axi=aw_count+ar_count;
            n_error=!legal||((!D0||!ram_target)&&response_code({address[31:2],2'b00})!=0);
            n_result=(!legal||wr||n_error)?0:ram_target?gold[(address-BASE)>>2]:device_gold;
            if(!legal)invalids=invalids+1;
            @(negedge clk);qv=1;qw=wr;qa=address;qs=size;qd=data;qt=strobe;rr=0;timeout=0;
            tick;while(!last_accept)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"D0 backend native accept progress");end
            if(timeout!=(D0&&ram_target?WAIT_CYCLES:0))$fatal(1,"D0 backend request wait parameter not propagated");
            @(negedge clk);qv=0;qa=ram_target?IO:BASE;qw=!wr;qs=3;qd=32'h5555aaaa;qt=0;
            timeout=0;while(!rv)begin tick;timeout=timeout+1;if(timeout>100)$fatal(1,"D0 backend response progress case=%0d",CASE_ID);end
            if(D0&&ram_target&&timeout!=WAIT_CYCLES)$fatal(1,"D0 backend response wait parameter not propagated");
            repeat(5)tick;
            if(accepted!=before_n+1||qr)$fatal(1,"D0 backend response ownership/hold");
            if(!legal&&aw_count+ar_count!=before_axi)$fatal(1,"D0 backend invalid shape escaped to AXI");
            if(legal&&(!D0||!ram_target)&&aw_count+ar_count!=before_axi+1)$fatal(1,"D0 backend expected AXI route was lost");
            if(legal&&wr&&ram_target)for(i=0;i<4;i=i+1)if(strobe[i])gold[(address-BASE)>>2][8*i+:8]=data[8*i+:8];
            if(legal&&wr&&!ram_target&&{address[31:2],2'b00}>=IO&&{address[31:2],2'b00}<IO+16)
                for(i=0;i<4;i=i+1)if(strobe[i])device_gold[8*i+:8]=data[8*i+:8];
            if(legal&&!wr&&!ram_target&&{address[31:2],2'b00}==IO)device_gold=device_gold+1;
            if(cancel)reset_shared;
            else begin
                // READY must remain low through the old response-consumption
                // edge. No unaccepted VALID is withdrawn by this master.
                @(negedge clk);qv=0;qa=IO;qw=0;qs=2;qd=0;qt=0;rr=1;
                @(posedge clk);if(qr)$fatal(1,"D0 backend response-edge turnover forbidden");bubble_checks=bubble_checks+1;
                @(negedge clk);qv=0;rr=0;tick;
            end
            checks=checks+1;
        end
    endtask
    initial begin
        fd=$fopen($sformatf("build/cpu5_s15_d0_backend/case%0d_trace.csv",CASE_ID),"w");
        $fdisplay(fd,"event,time,addr,data,strobe,write");
        for(i=0;i<WORDS;i=i+1)begin physical_axi[i]=0;gold[i]=0;end
        reset_shared;
        access(1,BASE,2,32'h11223344,15,0);
        access(1,BASE+1,0,32'h0000aa00,2,0);
        access(1,BASE+2,1,32'hbbcc0000,12,0);
        access(0,BASE,2,0,0,0);
        access(1,BASE+4*WORDS-1,0,32'hdd000000,8,0);
        access(1,BASE+4*WORDS-2,1,32'heeff0000,12,0);
        access(0,BASE+4*WORDS-4,2,0,0,0);
        access(1,BASE,3,32'hffffffff,15,0);
        access(1,BASE,2,32'hffffffff,0,0);
        access(1,BASE+1,0,32'hffffffff,1,0);
        access(1,BASE+1,1,32'hffffffff,6,0);
        access(0,BASE+2,2,0,0,0);
        access(0,BASE,3,0,0,0);
        access(0,BASE,2,0,0,0);
        access(0,BASE-1,0,0,0,0);
        access(0,END_ADDR[31:0],2,0,0,0);
        access(0,IO,2,0,0,0);access(0,IO,2,0,0,0);
        access(1,IO,2,32'h55667788,15,0);access(0,IO,2,0,0,0);
        access(0,IO+4,2,0,0,0);access(1,IO+8,2,32'habcd1201,15,0);
        access(0,IO,2,0,0,0);access(0,IO+8,2,0,0,0);access(0,IO+12,2,0,0,0);
        // Accepted completed write persists when its response is reset away.
        access(1,BASE,2,32'h76543210,15,1);access(0,BASE,2,0,0,0);
        // A young unaccepted write behind a held read response has no effect.
        n_error=0;n_result=gold[0];@(negedge clk);qv=1;qw=0;qa=BASE;qs=2;qt=0;rr=0;
        tick;while(!last_accept)tick;@(negedge clk);qv=0;while(!rv)tick;
        @(negedge clk);qv=1;qw=1;qa=BASE;qd=32'hffffffff;qt=15;qs=2;
        repeat(4)begin tick;if(qr)$fatal(1,"D0 backend queued write accepted under held response");end
        reset_shared;access(0,BASE,2,0,0,0);
        // Reset an accepted AXI AR while the legitimate registered R waits.
        before_a=ar_count;n_error=1;n_result=0;
        @(negedge clk);hold_response=1;qv=1;qw=0;qa=32'h40000000;qs=2;qt=0;rr=0;
        tick;while(!last_accept)tick;@(negedge clk);qv=0;
        while(ar_count==before_a)tick;repeat(4)tick;
        if(rv)$fatal(1,"D0 backend waiting-AXI-reset setup completed early");
        reset_shared;access(0,IO,2,0,0,0);
        for(i=0;i<WORDS;i=i+1)access(0,BASE+4*i,2,0,0,0);
        if(accepted!=responses+reset_drops||reset_drops!=3||ar_count!=r_count+axi_reset_reads||axi_reset_reads!=1||aw_count!=w_count||w_count!=b_count||pairs!=b_count)
            $fatal(1,"D0 backend final transaction closure");
        if(invalids!=6||bubble_checks!=checks-1||aw_holds==0||w_holds==0||ar_holds==0||cpu_holds==0||side_reads!=5)
            $fatal(1,"D0 backend coverage case=%0d checks=%0d invalid=%0d bubbles=%0d side=%0d",CASE_ID,checks,invalids,bubble_checks,side_reads);
        sfd=$fopen($sformatf("build/cpu5_s15_d0_backend/case%0d_summary.json",CASE_ID),"w");
        $fdisplay(sfd,"{\"status\":\"PASS\",\"case\":%0d,\"d0\":%0d,\"wait\":%0d,\"upper\":%0d,\"checks\":%0d,\"accepted\":%0d,\"responses\":%0d,\"reset_drops\":%0d,\"invalid\":%0d,\"errors\":%0d,\"local_ops\":%0d,\"local_writes\":%0d,\"aw\":%0d,\"w\":%0d,\"b\":%0d,\"ar\":%0d,\"r\":%0d,\"axi_reset_reads\":%0d,\"paired_writes\":%0d,\"axi_ram_writes\":%0d,\"io_writes\":%0d,\"side_reads\":%0d,\"aw_holds\":%0d,\"w_holds\":%0d,\"ar_holds\":%0d,\"cpu_holds\":%0d,\"native_holds\":%0d,\"bubble_checks\":%0d}",CASE_ID,D0,WAIT_CYCLES,BASE==32'hfffffff0,checks,accepted,responses,reset_drops,invalids,errors,local_ops,local_writes,aw_count,w_count,b_count,ar_count,r_count,axi_reset_reads,pairs,axi_ram_writes,io_writes,side_reads,aw_holds,w_holds,ar_holds,cpu_holds,native_holds,bubble_checks);
        $fclose(sfd);$fclose(fd);done=1;
    end
endmodule

// Bind only observes authorization; values are computed independently from
// the endpoint's public descriptor, not request_ok or its RAM helper outputs.
module cpu5_d0_ram_monitor #(parameter WORDS=16,parameter [31:0] BASE_ADDR=32'h10000)(
    input clk,rst_n,req_valid,req_ready,req_write,input [31:0] req_addr,req_wdata,
    input [1:0] req_size,input [3:0] req_wstrb,input mem_we,mem_re);
    wire aligned=req_size==0||(req_size==1&&!req_addr[0])||(req_size==2&&req_addr[1:0]==0);
    wire range_ok={32'd0,req_addr}>={32'd0,BASE_ADDR}&&{32'd0,req_addr}<({32'd0,BASE_ADDR}+64'd4*WORDS);
    wire [3:0] mask=req_size==0?(4'b0001<<req_addr[1:0]):req_size==1?(4'b0011<<req_addr[1:0]):4'b1111;
    wire legal=aligned&&range_ok&&(!req_write||req_wstrb==mask);
    always @(posedge clk)begin
        if(mem_we!==(rst_n&&req_valid&&req_ready&&req_write&&legal))$fatal(1,"D0 RAM physical write authorization mismatch");
        if(mem_re!==(rst_n&&req_valid&&req_ready&&!req_write&&legal))$fatal(1,"D0 RAM physical read authorization mismatch");
    end
endmodule
module cpu5_d0_backend_guard_tb;
    reg clk=0;always #5 clk=~clk;
    cpu5_d0_backend #(.ENABLE_D0_BRAM(2),.DMEM_WORDS(16)) dut(
        .clk(clk),.rst_n(1'b0),.req_valid(1'b0),.req_ready(),.req_write(1'b0),.req_addr(32'd0),.req_size(2'd2),.req_wdata(32'd0),.req_wstrb(4'd0),.rsp_valid(),.rsp_ready(1'b0),.rsp_rdata(),.rsp_error(),
        .m_axi_awaddr(),.m_axi_awprot(),.m_axi_awvalid(),.m_axi_awready(1'b0),.m_axi_wdata(),.m_axi_wstrb(),.m_axi_wvalid(),.m_axi_wready(1'b0),.m_axi_bresp(2'd0),.m_axi_bvalid(1'b0),.m_axi_bready(),.m_axi_araddr(),.m_axi_arprot(),.m_axi_arvalid(),.m_axi_arready(1'b0),.m_axi_rdata(32'd0),.m_axi_rresp(2'd0),.m_axi_rvalid(1'b0),.m_axi_rready());
    initial begin #20;$fatal(1,"D0 nonboolean guard was ignored");end
endmodule

module cpu5_d0_top_guard_tb;
    reg clk=0;always #5 clk=~clk;
    cpu5_d0_axi_lite_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.SKELETON_ONLY(0),.ENABLE_D0_BRAM(1),.ENABLE_RAM(0)) dut(
        .clk(clk),.rst_n(1'b0),.uart_rx(1'b1),.gpio_in(8'd0),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .imem_req_ready(1'b0),.imem_rsp_valid(1'b0),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),
        .m_axi_awready(1'b0),.m_axi_wready(1'b0),.m_axi_bvalid(1'b0),.m_axi_bresp(2'd0),.m_axi_arready(1'b0),.m_axi_rvalid(1'b0),.m_axi_rdata(32'd0),.m_axi_rresp(2'd0),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(),.cycle_count(),.instret_count(),.uart_tx(),.gpio_out(),.gpio_oe(),.dmem_fault(),.imem_req_valid(),.imem_req_addr(),.imem_rsp_ready(),.imem_fault(),.imem_fault_pc(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events(),.icache_access_count(),.icache_hit_count(),.icache_miss_count(),.icache_refill_word_count(),.icache_error_count(),.dcache_access_count(),.dcache_hit_count(),.dcache_miss_count(),.dcache_refill_word_count(),.dcache_error_count(),.dcache_write_count(),.dcache_bypass_count(),.m_axi_awaddr(),.m_axi_awprot(),.m_axi_awvalid(),.m_axi_wdata(),.m_axi_wstrb(),.m_axi_wvalid(),.m_axi_bready(),.m_axi_araddr(),.m_axi_arprot(),.m_axi_arvalid(),.m_axi_rready());
    initial begin #20;$fatal(1,"D0 active RAM guard was ignored");end
endmodule
