`timescale 1ns/1ps
module axi4_burst_fabric_tb;
    wire [2:0] done;reg test_pass=0;
    axi4_router_contract_case router_case(done[0]);
    axi4_ram_contract_case ram_case(done[1]);
    axi4_high_boundary_case high_address_case(done[2]);
    initial begin wait(&done);test_pass=1;$display("AXI4 BURST FABRIC PASS: real RAM seed/subwords/reset and router one-AR/four-R, descriptor rejection, locked route, errors, backpressure and recovery");$stop;end
    initial begin #500000;$fatal(1,"AXI4 fabric timeout done=%b",done);end
endmodule

// An exclusive endpoint end of 2^32 is legal. Arithmetic must retain that
// carry while distinguishing it from a transfer that actually wraps.
module axi4_high_boundary_case(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [31:0] araddr=0;reg [2:0] arprot=0,arsize=2;reg [7:0] arlen=0;reg [1:0] arburst=1;
    reg arvalid=0,rready=0;wire arready,rvalid,rlast;wire [31:0] rdata;wire [1:0] rresp;
    wire [31:0] da;wire [2:0] dp,ds;wire [7:0] dl;wire [1:0] db;wire dav,dar,drv,drr,drl;wire [31:0] dd;wire [1:0] dr;
    reg seed_valid=0;wire seed_ready,seed_error;reg [31:0] seed_addr=0,seed_wdata=0;reg [3:0] seed_wstrb=15;
    integer ar_count=0,k,reads=0;
    axi4_read_1x2 #(.M0_BASE_ADDR(32'hfffff000),.M0_SIZE_BYTES(4096),.M1_BASE_ADDR(32'h40000000),.M1_SIZE_BYTES(4096)) router(
        .clk(clk),.rst_n(rst_n),.s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arlen(arlen),.s_axi_arsize(arsize),.s_axi_arburst(arburst),.s_axi_arvalid(arvalid),.s_axi_arready(arready),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .m0_axi_araddr(da),.m0_axi_arprot(dp),.m0_axi_arlen(dl),.m0_axi_arsize(ds),.m0_axi_arburst(db),.m0_axi_arvalid(dav),.m0_axi_arready(dar),.m0_axi_rdata(dd),.m0_axi_rresp(dr),.m0_axi_rlast(drl),.m0_axi_rvalid(drv),.m0_axi_rready(drr),
        .m1_axi_araddr(),.m1_axi_arprot(),.m1_axi_arlen(),.m1_axi_arsize(),.m1_axi_arburst(),.m1_axi_arvalid(),.m1_axi_rready(),.m1_axi_arready(1'b1),.m1_axi_rdata(32'd0),.m1_axi_rresp(2'd0),.m1_axi_rlast(1'b0),.m1_axi_rvalid(1'b0));
    axi4_read_ram #(.BASE_ADDR(32'hfffff000),.WORDS(1024)) ram(
        .clk(clk),.rst_n(rst_n),.s_axi_araddr(da),.s_axi_arprot(dp),.s_axi_arlen(dl),.s_axi_arsize(ds),.s_axi_arburst(db),.s_axi_arvalid(dav),.s_axi_arready(dar),.s_axi_rdata(dd),.s_axi_rresp(dr),.s_axi_rlast(drl),.s_axi_rvalid(drv),.s_axi_rready(drr),
        .seed_valid(seed_valid),.seed_ready(seed_ready),.seed_addr(seed_addr),.seed_wdata(seed_wdata),.seed_wstrb(seed_wstrb),.seed_error(seed_error));
    axi4_read_contract_monitor monitor(.clk(clk),.rst_n(rst_n),.araddr(araddr),.arprot(arprot),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),.accepted_bursts(),.completed_bursts(),.accepted_beats(),.reset_cancels());
    always @(posedge clk) if(rst_n&&dav&&dar) ar_count=ar_count+1;
    task read_check(input [31:0] a,input [7:0] len,input [1:0] error);
        integer n,before_ar;reg [31:0] expected;
        begin before_ar=ar_count;@(negedge clk);araddr=a;arlen=len;arvalid=1;
            do @(posedge clk);while(!arready);
            @(negedge clk);arvalid=0;
            for(n=0;n<=len;n=n+1) begin wait(rvalid);#1;
                expected=error?0:32'hccdd0000+((a-32'hfffffff0)>>2)+n;
                if({rdata,rresp,rlast}!=={expected,error,(n==len)}) $fatal(1,"High exclusive-end transaction failed addr=%h beat=%0d got=%h/%h/%b",a,n,rdata,rresp,rlast);
                repeat(2) @(negedge clk);rready=1;@(posedge clk);@(negedge clk);rready=0;
            end
            if(ar_count-before_ar!=(error==0)) $fatal(1,"High boundary request incorrectly forwarded/rejected");reads=reads+1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(k=0;k<4;k=k+1) begin
            @(negedge clk);seed_valid=1;seed_addr=32'hfffffff0+4*k;seed_wdata=32'hccdd0000+k;
            do @(posedge clk);while(!seed_ready);
            if(seed_error) $fatal(1,"Highest legal seed rejected");@(negedge clk);seed_valid=0;
        end
        read_check(32'hfffffff0,3,0);read_check(32'hfffffffc,0,0);read_check(32'hfffffffc,3,2);
        read_check(32'hfffffff0,3,0);
        if(reads!=4||ar_count!=3) $fatal(1,"High-end coverage ledger failed");
        $display("AXI4 HIGH ADDRESS PASS: exclusive end 2^32 accepts final word/four words, real overflow returns four error beats, next burst recovers");done=1;
    end
endmodule

// Endpoint behavior is independent of router implementation. It injects
// per-beat errors through public R ports and never terminates early.
module axi4_contract_endpoint #(parameter integer ID=0)(
    input wire clk,rst_n,allow_ar,input integer error_beat,input wire [1:0] fault_response,input wire bad_last,
    input wire [31:0] araddr,input wire [7:0] arlen,input wire arvalid,output wire arready,
    output reg [31:0] rdata=0,output reg [1:0] rresp=0,output reg rlast=0,rvalid=0,input wire rready
);
    reg active=0;reg [31:0] addr_q;integer beat_q=0,len_q=0,gap_q=0;
    assign arready=rst_n&&allow_ar&&!active;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin active<=0;rvalid<=0;beat_q<=0;gap_q<=0;end
        else begin
            if(arvalid&&arready) begin active<=1;addr_q<=araddr;len_q<=arlen;beat_q<=0;gap_q<=2;end
            if(active&&!rvalid) begin
                if(gap_q>0) gap_q<=gap_q-1;
                else begin rvalid<=1;rdata<=(addr_q+4*beat_q)^(ID?32'hb4b40000:32'ha3a30000);
                    rresp<=beat_q==error_beat?fault_response:2'b00;rlast<=bad_last?(beat_q==1):(beat_q==len_q);end
            end
            if(rvalid&&rready) begin rvalid<=0;
                if(beat_q==len_q) active<=0;else begin beat_q<=beat_q+1;gap_q<=(beat_q%3);end
            end
        end
    end
endmodule

module axi4_router_contract_case(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    localparam [31:0] B0=32'h40000000,B1=32'h40000040;
    reg [31:0] araddr=0;reg [2:0] arprot=0,arsize=2;reg [7:0] arlen=0;reg [1:0] arburst=1;
    reg arvalid=0,rready=0;wire arready,rvalid,rlast;wire [31:0] rdata;wire [1:0] rresp;
    wire [31:0] ma[0:1],md[0:1],raw_data[0:1];wire [2:0] mp[0:1],ms[0:1];wire [7:0] ml[0:1];wire [1:0] mb[0:1],mr[0:1],raw_resp[0:1];
    wire [1:0] mav,may,mrv,mrr,mrl,raw_valid,raw_last;
    reg [1:0] allow_ar=0,noise=0,bad_last=0,fault_response=2;integer err0=-1,err1=-1,target=-1;
    integer up_ar=0,up_r=0,down0=0,down1=0,tests=0,resets=0,i;
    axi4_read_1x2 #(.M0_BASE_ADDR(B0),.M0_SIZE_BYTES(64),.M1_BASE_ADDR(B1),.M1_SIZE_BYTES(64)) dut(
        .clk(clk),.rst_n(rst_n),.s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arlen(arlen),.s_axi_arsize(arsize),.s_axi_arburst(arburst),.s_axi_arvalid(arvalid),.s_axi_arready(arready),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .m0_axi_araddr(ma[0]),.m0_axi_arprot(mp[0]),.m0_axi_arlen(ml[0]),.m0_axi_arsize(ms[0]),.m0_axi_arburst(mb[0]),.m0_axi_arvalid(mav[0]),.m0_axi_arready(may[0]),.m0_axi_rdata(md[0]),.m0_axi_rresp(mr[0]),.m0_axi_rlast(mrl[0]),.m0_axi_rvalid(mrv[0]),.m0_axi_rready(mrr[0]),
        .m1_axi_araddr(ma[1]),.m1_axi_arprot(mp[1]),.m1_axi_arlen(ml[1]),.m1_axi_arsize(ms[1]),.m1_axi_arburst(mb[1]),.m1_axi_arvalid(mav[1]),.m1_axi_arready(may[1]),.m1_axi_rdata(md[1]),.m1_axi_rresp(mr[1]),.m1_axi_rlast(mrl[1]),.m1_axi_rvalid(mrv[1]),.m1_axi_rready(mrr[1]));
    genvar g;generate for(g=0;g<2;g=g+1) begin:e
        axi4_contract_endpoint #(.ID(g)) endpoint(.clk(clk),.rst_n(rst_n),.allow_ar(allow_ar[g]),.error_beat(g?err1:err0),.fault_response(fault_response),.bad_last(bad_last[g]),.araddr(ma[g]),.arlen(ml[g]),.arvalid(mav[g]),.arready(may[g]),.rdata(raw_data[g]),.rresp(raw_resp[g]),.rlast(raw_last[g]),.rvalid(raw_valid[g]),.rready(mrr[g]));
        assign mrv[g]=noise[g]?1'b1:raw_valid[g];assign md[g]=noise[g]?32'hdeadf00d:raw_data[g];assign mr[g]=noise[g]?2'b11:raw_resp[g];assign mrl[g]=noise[g]?1'b1:raw_last[g];
    end endgenerate
    axi4_read_contract_monitor monitor(.clk(clk),.rst_n(rst_n),.araddr(araddr),.arprot(arprot),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),.accepted_bursts(),.completed_bursts(),.accepted_beats(),.reset_cancels());
    reg [1:0] held_m=0;reg [47:0] held_payload[0:1];
    always @(posedge clk) begin
        if(!rst_n) held_m=0;
        else if(!done) begin
            if(arvalid&&arready) up_ar=up_ar+1;
            if(rvalid&&rready) up_r=up_r+1;
            if(mav[0]&&may[0]) down0=down0+1;if(mav[1]&&may[1]) down1=down1+1;
            for(integer j=0;j<2;j=j+1) begin
                if(held_m[j]&&(!mav[j]||{ma[j],mp[j],ml[j],ms[j],mb[j]}!==held_payload[j])) $fatal(1,"Router downstream AR changed under stall");
                held_m[j]=mav[j]&&!may[j];held_payload[j]={ma[j],mp[j],ml[j],ms[j],mb[j]};
                if((mav[j]||mrr[j])&&target!=j) $fatal(1,"Router exposed/consumed unselected target %0d expected%0d",j,target);
            end
        end
    end
    task issue(input [31:0] a,input [7:0] len,input [2:0] sz,input [1:0] burst,input integer dest);
        begin @(negedge clk);target=dest;araddr=a;arlen=len;arsize=sz;arburst=burst;arprot=3'b101;arvalid=1;rready=0;
            do @(posedge clk);while(!arready);
            @(negedge clk);arvalid=0;araddr=dest==0?B1:B0;arprot=0;arlen=0;arsize=0;arburst=0;
        end
    endtask
    task transaction(input [31:0] a,input [7:0] len,input [2:0] sz,input [1:0] burst,input integer dest,input [1:0] local_error,input integer faultbeat,input bit malformed);
        integer n,ar_before,r_before,d0_before,d1_before;reg [1:0] expected_resp;reg [31:0] expected_data;
        begin ar_before=up_ar;r_before=up_r;d0_before=down0;d1_before=down1;
            noise=dest==0?2'b10:dest==1?2'b01:2'b11;allow_ar=0;err0=dest==0?faultbeat:-1;err1=dest==1?faultbeat:-1;bad_last=malformed?(dest==0?1:2):0;
            issue(a,len,sz,burst,dest);
            repeat(3) @(negedge clk);allow_ar=3;
            for(n=0;n<=len;n=n+1) begin
                wait(rvalid);#1;
                expected_resp=dest<0?local_error:n==faultbeat?fault_response:(malformed&&((n==1)!=(n==len)))?2'b10:0;
                expected_data=dest<0?0:(a+4*n)^(dest?32'hb4b40000:32'ha3a30000);
                if({rdata,rresp,rlast}!=={expected_data,expected_resp,(n==len)}) $fatal(1,"Router beat data/resp/last mismatch test=%0d beat=%0d got=%h/%h/%b want=%h/%h/%b",tests,n,rdata,rresp,rlast,expected_data,expected_resp,(n==len));
                repeat(2+n%2) begin @(negedge clk);if(arready) $fatal(1,"Router released route while current R held");end
                rready=1;@(posedge clk);@(negedge clk);rready=0;
            end
            #1;if(up_ar-ar_before!=1||up_r-r_before!=len+1||down0-d0_before!=(dest==0)||down1-d1_before!=(dest==1)) $fatal(1,"Router one-AR/LEN+1-R ledger failed");
            noise=0;target=-1;tests=tests+1;
        end
    endtask
    task cancel(input integer consumed,input bit after_endpoint);
        integer n;
        begin noise=0;allow_ar=after_endpoint?3:0;issue(B0,3,2,1,0);
            if(after_endpoint) begin
                for(n=0;n<consumed;n=n+1) begin wait(rvalid);@(negedge clk);rready=1;@(posedge clk);@(negedge clk);rready=0;end
                wait(rvalid);repeat(2) @(negedge clk);
            end else repeat(3) @(negedge clk);
            rst_n=0;#1;if(rvalid||arready||(|mav)||(|mrr)) $fatal(1,"Router reset did not mask public channels");
            repeat(2) @(negedge clk);target=-1;rst_n=1;allow_ar=3;resets=resets+1;
            repeat(3) begin @(negedge clk);if(rvalid) $fatal(1,"Old R escaped shared reset");end
            transaction(B1,3,2,1,1,0,-1,0);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        transaction(B0,0,2,1,0,0,-1,0);transaction(B1,3,2,1,1,0,-1,0);
        for(i=0;i<4;i=i+1) begin transaction(B0,3,2,1,0,0,i,0);transaction(B1,3,2,1,1,0,-1,0);end
        fault_response=3;
        for(i=0;i<4;i=i+1) begin transaction(B1,3,2,1,1,0,i,0);transaction(B0,3,2,1,0,0,-1,0);end
        fault_response=2;
        transaction(B0,3,2,1,0,0,-1,1);transaction(B1,0,2,1,1,0,-1,0);
        transaction(B0+48,3,2,1,0,0,-1,0);
        transaction(B0+52,3,2,1,-1,2,-1,0); // Cross region, not a 4 KiB crossing.
        transaction(B1+64,3,2,1,-1,3,-1,0);
        transaction(B0+2,3,2,1,-1,2,-1,0);transaction(B0,1,2,1,-1,2,-1,0);
        transaction(B0,255,2,1,-1,2,-1,0); // Exact LEN+1, not an 8-bit wrap.
        transaction(B0,3,1,1,-1,2,-1,0);transaction(B0,3,2,0,-1,2,-1,0);
        transaction(32'h40000ffc,3,2,1,-1,2,-1,0);transaction(32'hfffffffc,3,2,1,-1,2,-1,0);
        cancel(0,0);for(i=0;i<4;i=i+1) cancel(i,1);
        if(tests<27||resets!=5) $fatal(1,"Router coverage ledger insufficient tests=%0d resets=%0d",tests,resets);
        $display("AXI4 ROUTER CONTRACT PASS transactions=%0d resets=%0d AR=%0d R=%0d",tests,resets,up_ar,up_r);done=1;
    end
endmodule

module axi4_ram_contract_case(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    localparam [31:0] BASE=32'h40000000;
    reg [31:0] araddr=0;reg [2:0] arprot=0,arsize=2;reg [7:0] arlen=0;reg [1:0] arburst=1;
    reg arvalid=0,rready=0;wire arready,rvalid,rlast;wire [31:0] rdata;wire [1:0] rresp;
    reg seed_valid=0;wire seed_ready,seed_error;reg [31:0] seed_addr=0,seed_wdata=0;reg [3:0] seed_wstrb=0;
    reg [31:0] model[0:63];integer i,n,tests=0,seeds=0,resets=0;
    axi4_read_ram #(.WORDS(64),.BASE_ADDR(BASE)) dut(.*,.s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arlen(arlen),.s_axi_arsize(arsize),.s_axi_arburst(arburst),.s_axi_arvalid(arvalid),.s_axi_arready(arready),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
    axi4_read_contract_monitor monitor(.clk(clk),.rst_n(rst_n),.araddr(araddr),.arprot(arprot),.arlen(arlen),.arsize(arsize),.arburst(arburst),.arvalid(arvalid),.arready(arready),.rdata(rdata),.rresp(rresp),.rlast(rlast),.rvalid(rvalid),.rready(rready),.accepted_bursts(),.completed_bursts(),.accepted_beats(),.reset_cancels());
    task seed(input [31:0] a,input [31:0] data,input [3:0] mask,input bit bad);
        integer lane,index;
        begin @(negedge clk);seed_valid=1;seed_addr=a;seed_wdata=data;seed_wstrb=mask;
            do @(posedge clk);while(!seed_ready);
            if(seed_error!==bad) $fatal(1,"Seed legality mismatch addr=%h",a);
            if(!bad) begin index=(a-BASE)>>2;for(lane=0;lane<4;lane=lane+1) if(mask[lane]) model[index][lane*8+:8]=data[lane*8+:8];end
            seeds=seeds+1;@(negedge clk);seed_valid=0;
        end
    endtask
    task issue(input [31:0] a,input [7:0] len,input [2:0] sz,input [1:0] burst);
        begin @(negedge clk);araddr=a;arlen=len;arsize=sz;arburst=burst;arvalid=1;
            do @(posedge clk);while(!arready);
            @(negedge clk);arvalid=0;araddr=32'hdead0000;
        end
    endtask
    task read_check(input [31:0] a,input [7:0] len,input [2:0] sz,input [1:0] burst,input [1:0] err);
        integer beat;reg [31:0] expected;
        begin issue(a,len,sz,burst);
            for(beat=0;beat<=len;beat=beat+1) begin
                wait(rvalid);#1;expected=err?0:model[((a-BASE)>>2)+beat];
                if({rdata,rresp,rlast}!=={expected,err,(beat==len)}) $fatal(1,"RAM response mismatch beat=%0d addr=%h",beat,a);
                repeat(2+beat%2) @(negedge clk);rready=1;@(posedge clk);@(negedge clk);rready=0;
            end
            tests=tests+1;
        end
    endtask
    task reset_shared;
        begin @(negedge clk);rst_n=0;arvalid=0;rready=0;seed_valid=0;#1;
            if(rvalid||arready||seed_ready) $fatal(1,"RAM reset did not mask channels");
            repeat(2) @(negedge clk);rst_n=1;resets=resets+1;
            repeat(3) begin @(negedge clk);if(rvalid) $fatal(1,"RAM old R escaped reset");end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<64;i=i+1) seed(BASE+i*4,32'h01230000+i,15,0);
        seed(BASE,32'h89abcdef,15,0);seed(BASE,32'h00005500,2,0);seed(BASE,32'h76540000,12,0);seed(BASE,32'hdeadbeef,0,0);
        seed(BASE+1,32'hffffffff,15,1);seed(BASE+256,32'hffffffff,15,1);
        read_check(BASE,0,2,1,0);read_check(BASE,3,2,1,0);read_check(BASE+240,3,2,1,0);
        fork seed(BASE+4,32'h33445566,15,0);read_check(BASE,3,2,1,0);join
        read_check(BASE+244,3,2,1,3);read_check(BASE-4,0,2,1,3);
        read_check(BASE+2,3,2,1,2);read_check(BASE,1,2,1,2);read_check(BASE,3,1,1,2);read_check(BASE,3,2,2,2);
        read_check(32'h40000ffc,3,2,1,2);read_check(32'hfffffffc,3,2,1,2);
        // Hold a pending seed behind an active read, then cancel before it
        // handshakes. This must not change the physically seeded word.
        issue(BASE,3,2,1);wait(rvalid);@(negedge clk);seed_valid=1;seed_addr=BASE;seed_wdata=32'hffffffff;seed_wstrb=15;
        repeat(3) begin @(negedge clk);if(seed_ready) $fatal(1,"RAM accepted seed during burst");end
        reset_shared;read_check(BASE,3,2,1,0);
        for(n=0;n<4;n=n+1) begin
            issue(BASE,3,2,1);
            for(i=0;i<n;i=i+1) begin wait(rvalid);@(negedge clk);rready=1;@(posedge clk);@(negedge clk);rready=0;end
            wait(rvalid);reset_shared;read_check(BASE,3,2,1,0);
        end
        seed(BASE+8,32'hfeed7788,15,0);reset_shared;read_check(BASE+8,0,2,1,0);
        if(tests<18||seeds!=72||resets!=6) $fatal(1,"RAM coverage ledger insufficient tests=%0d seeds=%0d resets=%0d",tests,seeds,resets);
        $display("AXI4 RAM CONTRACT PASS reads=%0d seeds=%0d resets=%0d",tests,seeds,resets);done=1;
    end
endmodule
