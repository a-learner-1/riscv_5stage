`timescale 1ns/1ps
// Hand-authored native requests, independent byte RAM and tag/LRU gold. The
// slave observes AXI handshakes only; no bridge/cache state drives expectations.
module cpu5_axi_bridge_tb;
    wire [5:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<6;n=n+1)begin:g
        cpu5_axi_cache_bridge_case #(.CASE_ID(n),.CACHE(n/3),.ORDER(n%3)) c(done[n]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 AXI CACHE BRIDGE REFERENCE PASS");$stop;end
    initial begin #1000000;$fatal(1,"CPU5 AXI cache integration progress timeout done=%b",done);end
endmodule

module cpu5_axi_cache_bridge_case #(parameter CASE_ID=0,CACHE=0,ORDER=0)(output reg done=0);
    localparam [31:0] BASE=32'h10000;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg qv=0,qw=0,rr=0;reg [31:0] qa=0,qd=0;reg [1:0] qs=2;reg [3:0] qt=0;
    wire qr,rv,re;wire [31:0] rd;
    wire bv,br,bw,sv,sr,se;wire [31:0] ba,bd,sd;wire [1:0] bs;wire [3:0] bt;
    wire [31:0] awaddr,wdata,araddr;wire [2:0] awprot,arprot;wire [3:0] wstrb;
    wire awvalid,wvalid,bready,arvalid,rready,awready,wready,arready,bvalid,rvalid;
    wire [31:0] rdata;wire [1:0] bresp,rresp;
    wire [31:0] dac,dhc,dmc,drc,dec,dwc,dbc;
    cpu5_cache_adapter #(.ENABLE_DCACHE(CACHE),.DCACHE_SETS(2),.DCACHE_LINE_WORDS(4),.DMEM_WORDS(64),.IMEM_WORDS(256)) cache(
        .clk(clk),.rst_n(rst_n),.cpu_imem_req_valid(1'b0),.cpu_imem_req_ready(),.cpu_imem_req_addr(32'd0),
        .cpu_imem_rsp_valid(),.cpu_imem_rsp_ready(1'b1),.cpu_imem_rsp_rdata(),.cpu_imem_rsp_error(),
        .mem_imem_req_valid(),.mem_imem_req_ready(1'b0),.mem_imem_req_addr(),.mem_imem_rsp_valid(1'b0),.mem_imem_rsp_ready(),.mem_imem_rsp_rdata(32'd0),.mem_imem_rsp_error(1'b0),
        .cpu_dmem_req_valid(qv),.cpu_dmem_req_ready(qr),.cpu_dmem_req_write(qw),.cpu_dmem_req_addr(qa),.cpu_dmem_req_size(qs),.cpu_dmem_req_wdata(qd),.cpu_dmem_req_wstrb(qt),
        .cpu_dmem_rsp_valid(rv),.cpu_dmem_rsp_ready(rr),.cpu_dmem_rsp_rdata(rd),.cpu_dmem_rsp_error(re),
        .mem_dmem_req_valid(bv),.mem_dmem_req_ready(br),.mem_dmem_req_write(bw),.mem_dmem_req_addr(ba),.mem_dmem_req_size(bs),.mem_dmem_req_wdata(bd),.mem_dmem_req_wstrb(bt),
        .mem_dmem_rsp_valid(sv),.mem_dmem_rsp_ready(sr),.mem_dmem_rsp_rdata(sd),.mem_dmem_rsp_error(se),
        .icache_access_count(),.icache_hit_count(),.icache_miss_count(),.icache_refill_word_count(),.icache_error_count(),
        .dcache_access_count(dac),.dcache_hit_count(dhc),.dcache_miss_count(dmc),.dcache_refill_word_count(drc),.dcache_error_count(dec),.dcache_write_count(dwc),.dcache_bypass_count(dbc));
    dmem_axi_lite_bridge bridge(.clk(clk),.rst_n(rst_n),.req_valid(bv),.req_ready(br),.req_write(bw),.req_addr(ba),.req_size(bs),.req_wdata(bd),.req_wstrb(bt),
        .rsp_valid(sv),.rsp_ready(sr),.rsp_rdata(sd),.rsp_error(se),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),.m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    reg [31:0] mem[0:63],gold[0:63];
    reg av=0,wv=0,paired=0,rp=0,hold_response=0;
    reg [31:0] a_q=0,w_q=0,r_q=0;reg [3:0] t_q=0;reg [1:0] rcode_q=0;
    reg [1:0] inject_code=0;reg [31:0] fault_addr=32'hffffffff;
    integer aa=0,wa=0,ra=0,aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0,pairs=0,side_reads=0;
    integer front_req=0,front_rsp=0,front_drop=0,back_req=0,back_rsp=0,back_drop=0,read_drop=0;
    integer exp_total=0,exp_head=0,op=0,checks=0,invalids=0,errors=0,cpu_holds=0,aw_holds=0,w_holds=0,ar_holds=0,early_b=0,early_r=0;
    reg [31:0] exp_a[0:1023],exp_d[0:1023],exp_r[0:1023];reg [3:0] exp_t[0:1023];reg [1:0] exp_s[0:1023];reg exp_w[0:1023],exp_e[0:1023];
    reg [1:0] v0=0,v1=0,lru=0;reg [31:0] tag0[0:1],tag1[0:1];
    reg ah=0,wh=0,rh=0,ch=0;reg [34:0] aqsave,arsave;reg [35:0] wsave;reg [32:0] csave;
    integer fd,sfd,i,j,timeout;reg last_q=0,last_r=0;integer before_a,before_w,before_r,before_back;
    wire af=awvalid&&awready,wf=wvalid&&wready,arf=arvalid&&arready;
    wire pair_now=(av||af)&&(wv||wf)&&!paired;
    wire [31:0] pair_addr=av?a_q:awaddr,pair_data=wv?w_q:wdata;
    wire [3:0] pair_strb=wv?t_q:wstrb;
    wire [31:0] ar_word=(araddr>=BASE&&araddr<BASE+256)?mem[(araddr-BASE)>>2]:32'he0000000+side_reads;
    assign awready=rst_n&&!av&&!paired&&aa>=(2+(ORDER==1?4:0));
    assign wready=rst_n&&!wv&&!paired&&wa>=(2+(ORDER==0?4:0));
    assign arready=rst_n&&!rp&&ra>=3;
    // Responses appear only after the required request channel handshakes.
    // The original bridge is already ready then; long holds are not claimed.
    assign bvalid=rst_n&&!hold_response&&paired;
    assign bresp=inject_code;
    assign rvalid=rst_n&&!hold_response&&rp;
    assign rresp=rp?rcode_q:((araddr==fault_addr)?inject_code:2'd0);
    assign rdata=(rresp!=0)?32'hbad0e770:(rp?r_q:ar_word);
    task tick;begin @(posedge clk);#2;end endtask
    task reset_joint;
        begin
            @(negedge clk);
            if(front_req>front_rsp+front_drop)front_drop=front_drop+1;
            if(back_req>back_rsp+back_drop)begin back_drop=back_drop+1;exp_head=back_req;end
            if(rp)read_drop=read_drop+1;
            exp_total=back_req;rst_n=0;qv=0;rr=0;hold_response=0;v0=0;v1=0;lru=0;
            repeat(3)tick;@(negedge clk);rst_n=1;tick;
        end
    endtask
    task append_backend(input bit wr,input [31:0] addr,input [1:0] size,input [31:0] data,input [3:0] strobe,input bit err,input [31:0] response);
        begin exp_w[exp_total]=wr;exp_a[exp_total]=addr;exp_s[exp_total]=size;exp_d[exp_total]=data;exp_t[exp_total]=strobe;exp_e[exp_total]=err;exp_r[exp_total]=response;exp_total=exp_total+1;end
    endtask
    task access(input bit wr,input [31:0] addr,input [1:0] size,input [31:0] data,input [3:0] strobe,input [1:0] code,input integer fault_word);
        integer setid,tag,way,beat,nbeat,oldback,oldfront,k;
        bit legal,inram,hit,err;reg [31:0] result,beataddr;
        begin
            op=op+1;oldback=back_req;oldfront=front_rsp;
            legal=(size==0||(size==1&&!addr[0])||(size==2&&addr[1:0]==0))&&(!wr||strobe==(size==0?(1<<addr[1:0]):size==1?(3<<addr[1:0]):15));
            inram=addr>=BASE&&addr<BASE+256;setid=((addr-BASE)>>4)&1;tag=(addr-BASE)>>5;
            hit=inram&&((v0[setid]&&tag0[setid]==tag)||(v1[setid]&&tag1[setid]==tag));
            way=(v0[setid]&&tag0[setid]==tag)?0:1;
            if(!hit)way=!v0[setid]?0:!v1[setid]?1:lru[setid];
            err=!legal||code!=0;result=(!wr&&legal&&!err)?(inram?gold[(addr-BASE)>>2]:32'he0000000+side_reads):0;
            inject_code=code;fault_addr=wr?32'hffffffff:((CACHE&&inram&&!hit)?((addr&32'hfffffff0)+fault_word*4):(addr&32'hfffffffc));
            if(code==0)fault_addr=32'hffffffff;
            nbeat=(!legal)?(CACHE?0:1):(CACHE&&inram&&!wr?(hit?0:(code==0?4:fault_word+1)):1);
            for(beat=0;beat<nbeat;beat=beat+1)begin
                beataddr=(CACHE&&legal&&inram&&!wr&&!hit)?((addr&32'hfffffff0)+beat*4):addr;
                append_backend(wr,beataddr,(CACHE&&legal&&inram&&!wr&&!hit)?2'd2:size,data,(CACHE&&legal&&inram&&!wr&&!hit)?4'd0:strobe,
                    !legal||(code!=0&&(wr||((beataddr&32'hfffffffc)==fault_addr))),
                    (!legal||wr||(code!=0&&(beataddr&32'hfffffffc)==fault_addr))?0:(inram?gold[(beataddr-BASE)>>2]:result));
            end
            if(wr&&legal&&inram)for(k=0;k<4;k=k+1)if(strobe[k])gold[(addr-BASE)>>2][k*8+:8]=data[k*8+:8];
            @(negedge clk);qv=1;qw=wr;qa=addr;qs=size;qd=data;qt=strobe;rr=0;timeout=0;
            tick;while(!last_q)begin tick;timeout=timeout+1;if(timeout>200)$fatal(1,"AXI Cache native admission progress case=%0d op=%0d",CASE_ID,op);end
            @(negedge clk);qv=0;timeout=0;
            while(!rv)begin tick;timeout=timeout+1;if(timeout>300)$fatal(1,"AXI Cache native completion progress case=%0d op=%0d",CASE_ID,op);end
            if(re!==err||rd!==result)$fatal(1,"AXI Cache architectural data/error case=%0d op=%0d addr=%h got=%b/%h expected=%b/%h",CASE_ID,op,addr,re,rd,err,result);
            repeat(5)begin tick;if(!rv||re!==err||rd!==result)$fatal(1,"AXI Cache CPU response hold");end
            @(negedge clk);rr=1;tick;while(!last_r)tick;@(negedge clk);rr=0;repeat(2)tick;
            if(front_rsp!=oldfront+1||back_req!=oldback+nbeat||exp_head!=exp_total)$fatal(1,"AXI Cache native/backend exact ledger case=%0d op=%0d",CASE_ID,op);
            if(CACHE&&legal&&inram)begin
                if(wr)begin
                    if(hit)begin if(way) v1[setid]=!err;else v0[setid]=!err;if(!err)lru[setid]=!way;end
                end else if(hit)lru[setid]=!way;
                else begin if(way)begin v1[setid]=!err;tag1[setid]=tag;end else begin v0[setid]=!err;tag0[setid]=tag;end if(!err)lru[setid]=!way;end
            end
            if(!legal)invalids=invalids+1;if(err)errors=errors+1;checks=checks+1;
            for(k=0;k<64;k=k+1)if(mem[k]!==gold[k])$fatal(1,"AXI Cache complete RAM oracle case=%0d op=%0d word=%0d",CASE_ID,op,k);
            inject_code=0;fault_addr=32'hffffffff;
        end
    endtask
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin av=0;wv=0;paired=0;rp=0;aa=0;wa=0;ra=0;ah=0;wh=0;rh=0;ch=0;last_q=0;last_r=0;end
        else begin
            last_q=qv&&qr;last_r=rv&&rr;
            if(last_q)front_req=front_req+1;if(last_r)front_rsp=front_rsp+1;
            if(ah&&(!awvalid||{awaddr,awprot}!==aqsave))$fatal(1,"AXI Cache AW held descriptor");
            if(wh&&(!wvalid||{wdata,wstrb}!==wsave))$fatal(1,"AXI Cache W held descriptor");
            if(rh&&(!arvalid||{araddr,arprot}!==arsave))$fatal(1,"AXI Cache AR held descriptor");
            if(ch&&(!rv||{re,rd}!==csave))$fatal(1,"AXI Cache CPU held descriptor");
            ah=awvalid&&!awready;wh=wvalid&&!wready;rh=arvalid&&!arready;ch=rv&&!rr;
            if(ah)begin aqsave={awaddr,awprot};aw_holds=aw_holds+1;end
            if(wh)begin wsave={wdata,wstrb};w_holds=w_holds+1;end
            if(rh)begin arsave={araddr,arprot};ar_holds=ar_holds+1;end
            if(ch)begin csave={re,rd};cpu_holds=cpu_holds+1;end
            if(bv&&br)begin
                if(back_req>=exp_total||bw!==exp_w[back_req]||ba!==exp_a[back_req]||bs!==exp_s[back_req]||bd!==exp_d[back_req]||bt!==exp_t[back_req])
                    $fatal(1,"AXI Cache native backend descriptor case=%0d index=%0d addr=%h/%h",CASE_ID,back_req,ba,exp_a[back_req]);
                $fdisplay(fd,"native_req,%0t,%0d,%08h,%08h,%0d,%h",$time,back_req,ba,bd,bs,bt);back_req=back_req+1;
            end
            if(sv&&sr)begin
                if(exp_head>=back_req||se!==exp_e[exp_head]||sd!==exp_r[exp_head])$fatal(1,"AXI Cache native backend response case=%0d index=%0d data=%h/%h error=%b/%b",CASE_ID,exp_head,sd,exp_r[exp_head],se,exp_e[exp_head]);
                $fdisplay(fd,"native_rsp,%0t,%0d,%08h,%08h,%0d,%h",$time,exp_head,exp_a[exp_head],sd,se,0);exp_head=exp_head+1;back_rsp=back_rsp+1;
            end
            if(awvalid)aa=aa+1;else aa=0;if(wvalid)wa=wa+1;else wa=0;if(arvalid)ra=ra+1;else ra=0;
            if(af)begin if(av||rp||awaddr[1:0]!=0||awprot!=0)$fatal(1,"AXI Cache AW ownership/alignment");a_q=awaddr;av=1;aw_count=aw_count+1;end
            if(wf)begin if(wv||rp)$fatal(1,"AXI Cache W ownership");w_q=wdata;t_q=wstrb;wv=1;w_count=w_count+1;end
            // av/wv update above represents the separately captured request
            // halves. Pair once, including when the second half just arrived.
            if(av&&wv&&!paired)begin
                if(a_q<BASE||a_q>=BASE+256)$fatal(1,"AXI Cache unexpected external write");
                for(j=0;j<4;j=j+1)if(t_q[j])mem[(a_q-BASE)>>2][j*8+:8]=w_q[j*8+:8];
                paired=1;pairs=pairs+1;
            end
            if(bvalid&&!bready)early_b=early_b+1;
            if(bvalid&&bready)begin if(!paired)$fatal(1,"AXI Cache B without write pair");b_count=b_count+1;av=0;wv=0;paired=0;end
            if(arf)begin
                if(rp||av||wv||araddr[1:0]!=0||arprot!=0)$fatal(1,"AXI Cache AR ownership/alignment");
                r_q=ar_word;rcode_q=(araddr==fault_addr)?inject_code:0;rp=1;ar_count=ar_count+1;
                if(araddr<BASE||araddr>=BASE+256)side_reads=side_reads+1;
            end
            if(rvalid&&!rready)early_r=early_r+1;
            if(rvalid&&rready)begin if(!rp)$fatal(1,"AXI Cache R without AR");rp=0;r_count=r_count+1;end
        end
    end
    initial begin
        fd=$fopen($sformatf("build/cpu5_s14_axi_bridge/cache%0d_trace.csv",CASE_ID),"w");
        for(i=0;i<64;i=i+1)begin mem[i]=32'ha0000000^i;gold[i]=32'ha0000000^i;end
        reset_joint;
        access(0,BASE,2,0,0,0,0);access(0,BASE+4,2,0,0,0,0);
        access(1,BASE+1,0,32'h0000aa00,2,0,0);access(0,BASE,2,0,0,0,0);
        access(1,BASE+2,1,32'hbeef0000,12,0,0);access(0,BASE+3,0,0,0,0,0);
        access(1,BASE+128,2,32'h11223344,15,0,0);access(0,BASE+128,2,0,0,0,0);
        access(0,BASE+32,2,0,0,0,0);access(0,BASE,2,0,0,0,0);access(0,BASE+64,2,0,0,0,0);access(0,BASE,2,0,0,0,0);access(0,BASE+32,2,0,0,0,0);
        access(0,32'h30000000,2,0,0,0,0);access(0,32'h30000000,2,0,0,0,0);
        for(i=1;i<4;i=i+1)begin
            reset_joint;access(0,BASE,2,0,0,0,0);access(1,BASE,2,32'h12345678+i,15,i,0);access(0,BASE,2,0,0,0,0);
        end
        for(i=0;i<4;i=i+1)begin reset_joint;access(0,BASE+12,2,0,0,(i%3)+1,i);access(0,BASE+12,2,0,0,0,0);end
        access(0,BASE+1,1,0,0,0,0);access(0,BASE,3,0,0,0,0);access(1,BASE,2,32'hffffffff,1,0,0);
        // Cancel an accepted cached refill/uncached read while its real AXI
        // response is delayed. Shared reset drops protocol, never RAM writes.
        reset_joint;hold_response=1;before_a=ar_count;
        append_backend(0,BASE,2,0,0,0,gold[0]);
        @(negedge clk);qv=1;qw=0;qa=BASE;qs=2;qd=0;qt=0;rr=0;tick;while(!last_q)tick;
        @(negedge clk);qv=0;while(ar_count==before_a)tick;repeat(4)tick;
        if(rv)$fatal(1,"AXI Cache reset fixture response was not held");reset_joint;
        access(0,BASE,2,0,0,0,0);
        if(front_req!=front_rsp+front_drop||back_req!=back_rsp+back_drop||ar_count!=r_count+read_drop||aw_count!=w_count||w_count!=b_count||pairs!=b_count||front_drop!=1||back_drop!=1||read_drop!=1)
            $fatal(1,"AXI Cache final closure case=%0d front=%0d/%0d/%0d native=%0d/%0d/%0d AXI=%0d/%0d",CASE_ID,front_req,front_rsp,front_drop,back_req,back_rsp,back_drop,ar_count,r_count);
        if(checks!=36||invalids!=3||errors!=10||side_reads!=2||aw_holds==0||w_holds==0||ar_holds==0||cpu_holds==0)$fatal(1,"AXI Cache coverage case=%0d checks=%0d errors=%0d",CASE_ID,checks,errors);
        sfd=$fopen($sformatf("build/cpu5_s14_axi_bridge/cache%0d_summary.json",CASE_ID),"w");
        $fdisplay(sfd,"{\"status\":\"PASS\",\"case\":%0d,\"cache\":%0d,\"order\":%0d,\"checks\":%0d,\"front_requests\":%0d,\"front_responses\":%0d,\"front_reset_drops\":%0d,\"backend_requests\":%0d,\"backend_responses\":%0d,\"backend_reset_drops\":%0d,\"aw\":%0d,\"w\":%0d,\"b\":%0d,\"ar\":%0d,\"r\":%0d,\"axi_read_reset_drops\":%0d,\"physical_writes\":%0d,\"errors\":%0d,\"invalid\":%0d,\"side_reads\":%0d,\"early_b_hold\":%0d,\"early_r_hold\":%0d,\"aw_stalls\":%0d,\"w_stalls\":%0d,\"ar_stalls\":%0d,\"cpu_rsp_stalls\":%0d}",CASE_ID,CACHE,ORDER,checks,front_req,front_rsp,front_drop,back_req,back_rsp,back_drop,aw_count,w_count,b_count,ar_count,r_count,read_drop,pairs,errors,invalids,side_reads,early_b,early_r,aw_holds,w_holds,ar_holds,cpu_holds);
        $fclose(sfd);$fclose(fd);done=1;
    end
endmodule

module cpu5_axi_bridge_guard_tb;
    reg clk=0;always #5 clk=~clk;
    cpu5_axi_lite_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.EXTERNAL_DMEM(0)) dut(
        .clk(clk),.rst_n(1'b0),.uart_rx(1'b1),.gpio_in(8'd0),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .imem_req_ready(1'b0),.imem_rsp_valid(1'b0),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),
        .m_axi_awready(1'b0),.m_axi_wready(1'b0),.m_axi_bvalid(1'b0),.m_axi_bresp(2'd0),.m_axi_arready(1'b0),.m_axi_rvalid(1'b0),.m_axi_rdata(32'd0),.m_axi_rresp(2'd0),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(),.cycle_count(),.instret_count(),.uart_tx(),.gpio_out(),.gpio_oe(),.dmem_fault(),.imem_req_valid(),.imem_req_addr(),.imem_rsp_ready(),.imem_fault(),.imem_fault_pc(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events(),.icache_access_count(),.icache_hit_count(),.icache_miss_count(),.icache_refill_word_count(),.icache_error_count(),.dcache_access_count(),.dcache_hit_count(),.dcache_miss_count(),.dcache_refill_word_count(),.dcache_error_count(),.dcache_write_count(),.dcache_bypass_count(),.m_axi_awaddr(),.m_axi_awprot(),.m_axi_awvalid(),.m_axi_wdata(),.m_axi_wstrb(),.m_axi_wvalid(),.m_axi_bready(),.m_axi_araddr(),.m_axi_arprot(),.m_axi_arvalid(),.m_axi_rready());
    initial begin #20;$fatal(1,"CPU5 AXI external-data guard was ignored");end
endmodule
