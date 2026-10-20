`timescale 1ns/1ps
module axi4_burst_reader_tb;
    reg clk=0,rst_n=0,test_pass=0;always #5 clk=~clk;
    localparam [31:0] BASE=32'h30001000;
    reg [31:0] awaddr=0,wdata=0,araddr=0;reg [2:0] awprot=0,arprot=0;reg [3:0] wstrb=15;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;wire [1:0] bresp,rresp;wire [31:0] rdata;
    wire [31:0] ma;wire [2:0] mp,ms;wire [7:0] ml;wire [1:0] mb;wire mav,mrr;
    reg may=0,mrv=0,mrl=0;reg [31:0] md=0;reg [1:0] mr=0;
    wire seed_valid;reg seed_ready=0,seed_error=0;wire [31:0] seed_addr,seed_wdata;wire [3:0] seed_wstrb;
    wire busy,done,error;integer ar_count=0,r_count=0,seed_count=0,commands=0,resets=0,tail_refusals=0,k;
    axi_lite_burst_reader dut(.clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awprot(awprot),.s_axi_awvalid(awvalid),.s_axi_awready(awready),.s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),.s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arvalid(arvalid),.s_axi_arready(arready),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .m_axi_araddr(ma),.m_axi_arprot(mp),.m_axi_arlen(ml),.m_axi_arsize(ms),.m_axi_arburst(mb),.m_axi_arvalid(mav),.m_axi_arready(may),.m_axi_rdata(md),.m_axi_rresp(mr),.m_axi_rlast(mrl),.m_axi_rvalid(mrv),.m_axi_rready(mrr),
        .seed_valid(seed_valid),.seed_ready(seed_ready),.seed_addr(seed_addr),.seed_wdata(seed_wdata),.seed_wstrb(seed_wstrb),.seed_error(seed_error),.busy(busy),.done(done),.error(error));
    // The mock intentionally malforms RLAST in two cases. Count by accepted
    // LEN independently, while still enforcing every AR/R holding contract.
    axi4_read_contract_monitor #(.CHECK_LAST(0)) monitor(.clk(clk),.rst_n(rst_n),.araddr(ma),.arprot(mp),.arlen(ml),.arsize(ms),.arburst(mb),.arvalid(mav),.arready(may),.rdata(md),.rresp(mr),.rlast(mrl),.rvalid(mrv),.rready(mrr),.accepted_bursts(),.completed_bursts(),.accepted_beats(),.reset_cancels());
    reg bh=0,rh=0,sh=0;reg [1:0] held_b;reg [33:0] held_r;reg [67:0] held_seed;
    always @(posedge clk) begin
        if(!rst_n) begin bh=0;rh=0;sh=0;ar_count=0;r_count=0;seed_count=0;end
        else if(!test_pass) begin
            if(bh&&(!bvalid||bresp!==held_b)) $fatal(1,"Reader CSR B changed under backpressure");
            if(rh&&(!rvalid||{rdata,rresp}!==held_r)) $fatal(1,"Reader CSR R changed under backpressure");
            if(sh&&(!seed_valid||{seed_addr,seed_wdata,seed_wstrb}!==held_seed)) $fatal(1,"Reader seed descriptor changed before handshake");
            bh=bvalid&&!bready;held_b=bresp;rh=rvalid&&!rready;held_r={rdata,rresp};
            sh=seed_valid&&!seed_ready;held_seed={seed_addr,seed_wdata,seed_wstrb};
            if(mav&&may) ar_count=ar_count+1;if(mrv&&mrr) r_count=r_count+1;
            if(seed_valid&&seed_ready) seed_count=seed_count+1;
        end
    end
    task drive_aw(input [31:0] a,input integer delay_cycles);
        begin repeat(delay_cycles) @(negedge clk);@(negedge clk);awaddr=a;awvalid=1;
            do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;awaddr=32'hdead0000;end
    endtask
    task tail_refusal(input bit w_first,input bit same_final_edge);
        integer n;
        begin start(32'h40000000,3);@(negedge clk);may=1;@(posedge clk);@(negedge clk);may=0;
            for(n=0;n<3;n=n+1) beat(n,3,-1,0);
            if(same_final_edge) begin
                if(w_first) fork drive_w(32'hdeadbeef,15,0);beat(3,3,-1,0);join
                else fork drive_aw(BASE+4,0);beat(3,3,-1,0);join
            end else begin
                if(w_first) drive_w(32'hdeadbeef,15,0);else drive_aw(BASE+4,0);
                beat(3,3,-1,0);
            end
            if(busy||!done||error) $fatal(1,"Tail-refusal setup did not complete original burst");
            if(w_first) drive_aw(BASE+4,0);else drive_w(32'hdeadbeef,15,0);
            wait(bvalid);#1;if(bresp!==2) $fatal(1,"Write accepted during busy escaped after final R");
            repeat(3) @(negedge clk);bready=1;@(posedge clk);@(negedge clk);bready=0;
            read_csr(4,32'h40000000,0);write_csr(0,2,15,0,0);tail_refusals=tail_refusals+1;
        end
    endtask
    task drive_w(input [31:0] value,input [3:0] mask,input integer delay_cycles);
        begin repeat(delay_cycles) @(negedge clk);@(negedge clk);wdata=value;wstrb=mask;wvalid=1;
            do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;wdata=0;wstrb=0;end
    endtask
    task write_csr(input [31:0] offset,input [31:0] value,input [3:0] mask,input integer order,input [1:0] expected_error);
        begin fork drive_aw(BASE+offset,order==2?3:0);drive_w(value,mask,order==1?3:0);join
            wait(bvalid);#1;if(bresp!==expected_error) $fatal(1,"CSR write response offset=%h value=%h got=%h expected=%h",offset,value,bresp,expected_error);
            repeat(3) @(negedge clk);bready=1;@(posedge clk);@(negedge clk);bready=0;
        end
    endtask
    task read_csr(input [31:0] offset,input [31:0] expected,input [1:0] expected_error);
        begin @(negedge clk);araddr=BASE+offset;arvalid=1;
            do @(posedge clk);while(!arready);@(negedge clk);arvalid=0;araddr=0;
            wait(rvalid);#1;if({rdata,rresp}!=={expected,expected_error}) $fatal(1,"CSR read offset=%h got=%h/%h expected=%h/%h",offset,rdata,rresp,expected,expected_error);
            repeat(3) @(negedge clk);rready=1;@(posedge clk);@(negedge clk);rready=0;
        end
    endtask
    task start(input [31:0] addr,input integer len);
        begin write_csr(4,addr,15,1,0);write_csr(8,len,15,2,0);write_csr(0,1,15,commands%3,0);
            wait(mav);#1;if({ma,mp,ml,ms,mb}!=={addr,3'd0,len[7:0],3'd2,2'd1}||!busy||done||error) $fatal(1,"Reader START descriptor/status invalid");
        end
    endtask
    task beat(input integer index,input integer len,input integer fault,input integer malformed);
        begin repeat(1+index%3) @(negedge clk);mrv=1;md=32'hf00d0000+index;mr=index==fault?2'b10:0;
            mrl=malformed==1?(index==1):malformed==2?0:(index==len);
            do @(posedge clk);while(!mrr);#1;
            if(index<len&&(!busy||done)) $fatal(1,"Reader completed before draining the accepted burst");
            @(negedge clk);mrv=0;
        end
    endtask
    task command(input integer len,input integer fault,input integer malformed);
        integer a0,r0,n;reg expected_error;
        begin a0=ar_count;r0=r_count;start(commands[0]?32'h40001000:32'h40000000,len);
            // Attempt all classes of side effect while AR is held. The
            // descriptor is still captured and no write may change it.
            write_csr(4,32'hdeadbeef,15,1,2);write_csr(0,2,15,2,2);write_csr(44,1,15,0,2);
            read_csr(4,commands[0]?32'h40001000:32'h40000000,0);
            @(negedge clk);may=1;@(posedge clk);@(negedge clk);may=0;
            for(n=0;n<=len;n=n+1) beat(n,len,fault,malformed);
            expected_error=fault>=0||malformed!=0;
            if(busy||!done||error!==expected_error||ar_count-a0!=1||r_count-r0!=len+1) $fatal(1,"Reader completion/error/drain ledger failed");
            read_csr(0,expected_error?6:2,0);read_csr(12,len+1,0);
            for(n=0;n<4;n=n+1) read_csr(16+4*n,n>len||n==fault?0:32'hf00d0000+n,0);
            read_csr(48,ar_count,0);read_csr(52,r_count,0);
            write_csr(0,2,15,0,0);read_csr(0,0,0);commands=commands+1;
        end
    endtask
    task reset_shared;
        begin @(negedge clk);rst_n=0;awvalid=0;wvalid=0;bready=0;arvalid=0;rready=0;may=0;mrv=0;seed_ready=0;#1;
            if(awready||wready||bvalid||arready||rvalid||mav||mrr||seed_valid) $fatal(1,"Reader shared reset leaked protocol");
            repeat(2) @(negedge clk);rst_n=1;resets=resets+1;
            repeat(3) begin @(negedge clk);if(bvalid||rvalid||mav||seed_valid||busy||done||error) $fatal(1,"Reader old operation escaped reset");end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        read_csr(56,32'h42525354,0);read_csr(60,1,0);read_csr(8,3,0);read_csr(40,15,0);
        write_csr(0,3,15,0,2);write_csr(8,1,15,1,2);write_csr(40,16,15,2,2);
        write_csr(56,0,15,0,2);write_csr(64,1,15,1,2);write_csr(5,1,15,2,2);write_csr(4,1,3,0,2);
        read_csr(64,0,2);read_csr(1,0,2);read_csr(4,32'h40000000,0);
        command(0,-1,0);command(3,-1,0);
        for(k=0;k<4;k=k+1) begin command(3,k,0);command(3,-1,0);end
        command(3,-1,1);command(3,-1,2);command(3,-1,0);
        tail_refusal(0,0);tail_refusal(1,0);tail_refusal(0,1);tail_refusal(1,1);
        // The native seed request is held; its CSR B cannot precede the
        // real handshake. Error and zero-strobe acceptance are distinct.
        write_csr(32,32'h40000004,15,0,0);write_csr(36,32'h12345678,15,1,0);write_csr(40,5,15,2,0);
        fork write_csr(44,1,15,0,0);begin wait(seed_valid);repeat(4) begin @(negedge clk);if(bvalid||{seed_addr,seed_wdata,seed_wstrb}!=={32'h40000004,32'h12345678,4'h5}) $fatal(1,"Seed side effect/descriptor was not deferred to acceptance");end seed_ready=1;@(posedge clk);@(negedge clk);seed_ready=0;end join
        read_csr(44,1,0);seed_error=1;
        fork write_csr(44,1,15,2,2);begin wait(seed_valid);@(negedge clk);seed_ready=1;@(posedge clk);@(negedge clk);seed_ready=0;end join
        seed_error=0;read_csr(44,1,0);write_csr(40,0,15,0,0);
        fork write_csr(44,1,15,1,0);begin wait(seed_valid);@(negedge clk);seed_ready=1;@(posedge clk);@(negedge clk);seed_ready=0;end join
        read_csr(44,2,0);if(seed_count!=3) $fatal(1,"Seed command handshake count failed");
        // Cancel an incomplete AW or W pair, a blocked native seed, an AR
        // still waiting for READY, then each partial burst before its tail.
        drive_aw(BASE+4,0);reset_shared;drive_w(32'hdeadbeef,15,0);reset_shared;
        fork begin drive_aw(BASE+44,0);drive_w(1,15,0);end begin wait(seed_valid);reset_shared;end join
        start(32'h40000000,3);reset_shared;
        for(k=0;k<4;k=k+1) begin start(32'h40000000,3);@(negedge clk);may=1;@(posedge clk);@(negedge clk);may=0;
            for(integer j=0;j<k;j=j+1) beat(j,3,-1,0);
            reset_shared;
        end
        command(3,-1,0);
        if(commands!=14||resets!=8||tail_refusals!=4) $fatal(1,"Reader coverage ledger failed commands=%0d resets=%0d",commands,resets);
        $display("AXI4 BURST READER PASS commands=%0d reset_cases=%0d busy_tail_refusals=%0d: independent CSR AW/W, real AR/R, all error positions drained, malformed LAST, seed acceptance and recovery",commands,resets,tail_refusals);
        test_pass=1;$stop;
    end
    initial begin #500000;$fatal(1,"Reader contract timeout");end
endmodule
