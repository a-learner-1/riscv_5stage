`timescale 1ns/1ps
// Measurement-only fixtures. All production RTL is instantiated unchanged.
module cpu5_memory_ii_tb;
    wire [3:0] done;
    reg test_pass=0;
    cpu5_memory_stream #(.CASE_ID(0)) stream_fast(done[0]);
    cpu5_memory_stream #(.CASE_ID(1),.REQ_WAIT(2),.RSP_WAIT(3)) stream_wait(done[1]);
    cpu5_memory_cpu #(.CASE_ID(2)) cpu_illegal(done[2]);
    cpu5_memory_cpu #(.CASE_ID(3),.REQ_WAIT(2),.RSP_WAIT(3),.UNALIGNED(1)) cpu_unaligned(done[3]);
    initial begin wait(&done); test_pass=1; $display("CPU5 STAGE0.5 MEMORY II PASS cases=%b",done); $stop; end
    initial begin #10000000; $fatal(1,"memory measurement timeout done=%b",done); end
endmodule

module cpu5_memory_monitor #(
    parameter integer CASE_ID=0, BOUNDARY=0
)(input wire clk,rst_n,enable,
   input wire req_valid,req_ready,req_write,input wire [31:0] req_addr,
   input wire [1:0] req_size,input wire [31:0] req_wdata,input wire [3:0] req_wstrb,
   input wire rsp_valid,rsp_ready,input wire [31:0] rsp_rdata,input wire rsp_error,
   input wire [3:0] req_class,input wire [31:0] owner_pc,
   output integer requests=0,responses=0,simultaneous=0,req_holds=0,rsp_holds=0);
    integer fd,cycle=0,i,head=0,tail=0,index;
    reg [31:0] model[0:4095],q_addr[0:1023],q_data[0:1023],q_pc[0:1023];
    reg q_write[0:1023],q_error[0:1023];
    reg [1:0] q_size[0:1023];
    reg [3:0] q_strobe[0:1023],q_class[0:1023];
    reg legal,in_range,expected_error,held_req=0,held_rsp=0;
    reg [70:0] request_saved;
    reg [32:0] response_saved;
    reg [3:0] expected_strobe;
    initial begin
        fd=$fopen($sformatf("build/cpu5_s05_memory/case%0d_boundary%0d.csv",CASE_ID,BOUNDARY),"w");
        $fwrite(fd,"case,boundary,cycle,event,owner,write,addr,size,wstrb,data,error,class,pc\n");
        for(i=0;i<4096;i=i+1) model[i]=32'ha5000000 ^ (i*32'h10203);
    end
    always @(posedge clk) if(rst_n && enable) begin
        cycle=cycle+1;
        if(held_req && (!req_valid || request_saved!=={req_write,req_addr,req_size,req_wdata,req_wstrb}))
            $fatal(1,"request changed under backpressure case=%0d boundary=%0d",CASE_ID,BOUNDARY);
        if(held_rsp && (!rsp_valid || response_saved!=={rsp_error,rsp_rdata}))
            $fatal(1,"response changed under backpressure case=%0d boundary=%0d",CASE_ID,BOUNDARY);
        held_req=req_valid&&!req_ready; held_rsp=rsp_valid&&!rsp_ready;
        request_saved={req_write,req_addr,req_size,req_wdata,req_wstrb};
        response_saved={rsp_error,rsp_rdata};
        if(held_req) req_holds=req_holds+1;
        if(held_rsp) rsp_holds=rsp_holds+1;
        // Consume A first, then append B: the old response cannot acquire B's owner.
        if(rsp_valid&&rsp_ready) begin
            if(head==tail) $fatal(1,"unsolicited/duplicate response case=%0d boundary=%0d",CASE_ID,BOUNDARY);
            if(rsp_error!==q_error[head] || (!q_write[head] && rsp_rdata!==q_data[head]))
                $fatal(1,"scoreboard mismatch case=%0d boundary=%0d owner=%0d addr=%h got=%h/%b expected=%h/%b",CASE_ID,BOUNDARY,head,q_addr[head],rsp_rdata,rsp_error,q_data[head],q_error[head]);
            $fwrite(fd,"%0d,%0d,%0d,rsp,%0d,%0d,%08x,%0d,%x,%08x,%0d,%0d,%08x\n",CASE_ID,BOUNDARY,cycle,head,q_write[head],q_addr[head],q_size[head],q_strobe[head],rsp_rdata,rsp_error,q_class[head],q_pc[head]);
            responses=responses+1;head=head+1;
        end
        if(req_valid&&req_ready) begin
            if(tail!=head) $fatal(1,"more than one outstanding case=%0d boundary=%0d",CASE_ID,BOUNDARY);
            expected_strobe=req_size==0?(4'b1<<req_addr[1:0]):req_size==1?(4'b11<<req_addr[1:0]):4'b1111;
            legal=(req_size==0 || (req_size==1&&!req_addr[0]) || (req_size==2&&req_addr[1:0]==0)) && (!req_write || req_wstrb==expected_strobe);
            in_range=req_addr>=32'h10000&&req_addr<32'h14000;
            expected_error=!legal||!in_range;
            q_addr[tail]=req_addr;q_write[tail]=req_write;q_error[tail]=expected_error;
            q_size[tail]=req_size;q_strobe[tail]=req_wstrb;q_class[tail]=req_class;q_pc[tail]=owner_pc;
            q_data[tail]=0;
            if(legal&&in_range) begin
                index=(req_addr-32'h10000)/4;
                if(req_write) begin
                    if(req_wstrb[0]) model[index][7:0]=req_wdata[7:0];
                    if(req_wstrb[1]) model[index][15:8]=req_wdata[15:8];
                    if(req_wstrb[2]) model[index][23:16]=req_wdata[23:16];
                    if(req_wstrb[3]) model[index][31:24]=req_wdata[31:24];
                end else q_data[tail]=model[index];
            end
            $fwrite(fd,"%0d,%0d,%0d,req,%0d,%0d,%08x,%0d,%x,%08x,%0d,%0d,%08x\n",CASE_ID,BOUNDARY,cycle,tail,req_write,req_addr,req_size,req_wstrb,req_wdata,expected_error,req_class,owner_pc);
            requests=requests+1;tail=tail+1;
        end
        if(req_valid&&req_ready&&rsp_valid&&rsp_ready) simultaneous=simultaneous+1;
    end
endmodule

module cpu5_memory_chain #(
    parameter integer CASE_ID=0,REQ_WAIT=0,RSP_WAIT=0
)(input wire clk,rst_n,enable,
   input wire req_valid,output wire req_ready,input wire req_write,input wire [31:0] req_addr,
   input wire [1:0] req_size,input wire [31:0] req_wdata,input wire [3:0] req_wstrb,
   output wire rsp_valid,input wire rsp_ready,output wire [31:0] rsp_rdata,output wire rsp_error,
   input wire [31:0] owner_pc);
    wire bv,br,bw,sv,sr,se;
    wire [31:0] ba,bd,sd;
    wire [1:0] bz;
    wire [3:0] bs;
    wire rv,rr,rw,rs_valid,rs_ready,rs_error;
    wire [31:0] ra,rd,rs_data;
    wire [1:0] rz;
    wire [3:0] rstr;
    wire xv,xr,xw,xsv,xsr,xse;
    wire [31:0] xa,xd,xsd;
    wire [1:0] xz;
    wire [3:0] xs;
    wire [31:0] accesses,hits,misses,words,errors,writes,bypasses;
    integer i;
    data_cache #(.SETS(64),.LINE_WORDS(4),.MEM_WORDS(4096),.BASE_ADDR(32'h10000)) cache(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),
        .req_size(req_size),.req_wdata(req_wdata),.req_wstrb(req_wstrb),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),
        .mem_req_valid(bv),.mem_req_ready(br),.mem_req_write(bw),.mem_req_addr(ba),.mem_req_size(bz),.mem_req_wdata(bd),.mem_req_wstrb(bs),
        .mem_rsp_valid(sv),.mem_rsp_ready(sr),.mem_rsp_rdata(sd),.mem_rsp_error(se),
        .access_count(accesses),.hit_count(hits),.miss_count(misses),.refill_word_count(words),.error_count(errors),.write_count(writes),.bypass_count(bypasses));
    dmem_region_router router(
        .clk(clk),.rst_n(rst_n),.req_valid(bv),.req_ready(br),.req_write(bw),.req_addr(ba),.req_size(bz),.req_wdata(bd),.req_wstrb(bs),
        .rsp_valid(sv),.rsp_ready(sr),.rsp_rdata(sd),.rsp_error(se),
        .m0_req_valid(rv),.m0_req_ready(rr),.m0_req_write(rw),.m0_req_addr(ra),.m0_req_size(rz),.m0_req_wdata(rd),.m0_req_wstrb(rstr),
        .m0_rsp_valid(rs_valid),.m0_rsp_ready(rs_ready),.m0_rsp_rdata(rs_data),.m0_rsp_error(rs_error),
        .m1_req_valid(xv),.m1_req_ready(xr),.m1_req_write(xw),.m1_req_addr(xa),.m1_req_size(xz),.m1_req_wdata(xd),.m1_req_wstrb(xs),
        .m1_rsp_valid(xsv),.m1_rsp_ready(xsr),.m1_rsp_rdata(xsd),.m1_rsp_error(xse));
    soc_data_mem #(.WORDS(4096),.BASE_ADDR(32'h10000),.INIT_FILE(""),.REQ_WAIT_CYCLES(REQ_WAIT),.RSP_WAIT_CYCLES(RSP_WAIT)) ram(
        .clk(clk),.rst_n(rst_n),.req_valid(rv),.req_ready(rr),.req_write(rw),.req_addr(ra),.req_size(rz),.req_wdata(rd),.req_wstrb(rstr),
        .rsp_valid(rs_valid),.rsp_ready(rs_ready),.rsp_rdata(rs_data),.rsp_error(rs_error));
    // Native out-of-range error endpoint stands in for an AXI error response.
    // It is measurement infrastructure, not the production AXI bridge.
    soc_data_mem #(.WORDS(16),.BASE_ADDR(32'h40000),.INIT_FILE(""),.REQ_WAIT_CYCLES(REQ_WAIT),.RSP_WAIT_CYCLES(RSP_WAIT)) error_endpoint(
        .clk(clk),.rst_n(rst_n),.req_valid(xv),.req_ready(xr),.req_write(xw),.req_addr(xa),.req_size(xz),.req_wdata(xd),.req_wstrb(xs),
        .rsp_valid(xsv),.rsp_ready(xsr),.rsp_rdata(xsd),.rsp_error(xse));
    initial begin #1; for(i=0;i<4096;i=i+1) ram.u_data_mem.mem[i]=32'ha5000000 ^ (i*32'h10203); end
    wire [3:0] classification=!cache.request_ok?4'd4:!cache.in_range?4'd5:req_write?4'd3:(cache.hit0||cache.hit1)?4'd1:4'd2;
    cpu5_memory_monitor #(.CASE_ID(CASE_ID),.BOUNDARY(0)) upper(
        .clk(clk),.rst_n(rst_n),.enable(enable),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_size(req_size),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),.req_class(classification),.owner_pc(owner_pc),
        .requests(),.responses(),.simultaneous(),.req_holds(),.rsp_holds());
    cpu5_memory_monitor #(.CASE_ID(CASE_ID),.BOUNDARY(1)) backend(
        .clk(clk),.rst_n(rst_n),.enable(enable),.req_valid(bv),.req_ready(br),.req_write(bw),.req_addr(ba),.req_size(bz),.req_wdata(bd),.req_wstrb(bs),
        .rsp_valid(sv),.rsp_ready(sr),.rsp_rdata(sd),.rsp_error(se),.req_class(4'd0),.owner_pc(owner_pc),
        .requests(),.responses(),.simultaneous(),.req_holds(),.rsp_holds());
    cpu5_memory_monitor #(.CASE_ID(CASE_ID),.BOUNDARY(2)) bram(
        .clk(clk),.rst_n(rst_n),.enable(enable),.req_valid(rv),.req_ready(rr),.req_write(rw),.req_addr(ra),.req_size(rz),.req_wdata(rd),.req_wstrb(rstr),
        .rsp_valid(rs_valid),.rsp_ready(rs_ready),.rsp_rdata(rs_data),.rsp_error(rs_error),.req_class(4'd0),.owner_pc(owner_pc),
        .requests(),.responses(),.simultaneous(),.req_holds(),.rsp_holds());
    always @(posedge clk) if(rst_n&&enable) begin
        if(router.active && br) $fatal(1,"D0 router accepted request while active case=%0d",CASE_ID);
        if(sv&&sr&&bv&&br) $fatal(1,"D0 router accepted same-edge old response/new request case=%0d",CASE_ID);
        if(sv&&sr && (router.target_q ? (rv||rs_ready) : (xv||xsr))) $fatal(1,"D0 route ownership case=%0d",CASE_ID);
    end
endmodule

module cpu5_memory_stream #(
    parameter integer CASE_ID=0,REQ_WAIT=0,RSP_WAIT=0
)(output reg done=0);
    reg clk=0,rst_n=0,enable=1;
    reg req_valid=0,req_write=0,rsp_ready=1;
    reg [31:0] req_addr=0,req_wdata=0;
    reg [1:0] req_size=2;
    reg [3:0] req_wstrb=0;
    wire req_ready,rsp_valid,rsp_error;
    wire [31:0] rsp_rdata;
    reg wr[0:63]; reg [31:0] addr[0:63],data[0:63];
    reg [1:0] size[0:63]; reg [3:0] strobe[0:63];
    integer count=0,sent=0,received=0,cycle=0,i,metrics;
    cpu5_memory_chain #(.CASE_ID(CASE_ID),.REQ_WAIT(REQ_WAIT),.RSP_WAIT(RSP_WAIT)) chain(
        .clk(clk),.rst_n(rst_n),.enable(enable),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_size(req_size),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),.owner_pc(32'd0));
    always #5 clk=~clk;
    task add(input bit w,input [31:0] a,input [31:0] d,input [1:0] z,input [3:0] s);
        begin wr[count]=w;addr[count]=a;data[count]=d;size[count]=z;strobe[count]=s;count=count+1;end
    endtask
    initial begin
        add(0,32'h10000,0,2,0); // cold way0 fill
        add(0,32'h10004,0,2,0);add(0,32'h10008,0,2,0);add(0,32'h1000c,0,2,0);
        add(0,32'h10000,0,2,0);add(0,32'h10004,0,2,0); // distinct address/data streamed hits
        add(1,32'h10004,32'h12345678,2,15);add(0,32'h10004,0,2,0); // same-address SW/LW
        add(0,32'h10008,0,2,0);add(1,32'h1000c,32'h87654321,2,15);add(0,32'h10000,0,2,0);
        add(0,32'h10010,0,2,0);add(0,32'h10014,0,2,0); // other set / cross line
        add(0,32'h10400,0,2,0);add(0,32'h10000,0,2,0);add(0,32'h10404,0,2,0); // two ways
        add(0,32'h10800,0,2,0);add(0,32'h10400,0,2,0);add(0,32'h10000,0,2,0); // eviction
        add(1,32'h10c00,32'h0badcafe,2,15);add(0,32'h10c00,0,2,0); // no-write-allocate
        add(0,32'h10c04,0,2,0);add(1,32'h10c04,32'hfeeda55a,2,15);add(0,32'h10c04,0,2,0);
        add(0,32'h10002,0,2,0); // unaligned LW
        add(1,32'h10000,32'hbadbad00,2,3); // invalid store strobe
        add(0,32'h50000,0,2,0); // out-of-range routed error
        add(0,32'h10000,0,3,0); // unsupported size
        add(0,32'h10004,0,2,0);add(0,32'h10008,0,2,0); // data unchanged after errors
        repeat(4) @(negedge clk);rst_n=1;
        wait(received==count); repeat(3) @(negedge clk);
        if(sent!=count || chain.upper.requests!=count || chain.upper.responses!=count ||
           chain.backend.requests!=chain.backend.responses || chain.bram.requests!=chain.bram.responses)
            $fatal(1,"stream transaction count mismatch case=%0d",CASE_ID);
        $display("MEMORY STREAM PASS case=%0d req=%0d rsp=%0d simultaneous=%0d req_holds=%0d rsp_holds=%0d backend=%0d bram=%0d",CASE_ID,sent,received,chain.upper.simultaneous,chain.upper.req_holds,chain.upper.rsp_holds,chain.backend.requests,chain.bram.requests);
        metrics=$fopen($sformatf("build/cpu5_s05_memory/case%0d_metrics.csv",CASE_ID),"w");
        $fwrite(metrics,"boundary,requests,responses,simultaneous,req_holds,rsp_holds\n");
        $fwrite(metrics,"0,%0d,%0d,%0d,%0d,%0d\n",chain.upper.requests,chain.upper.responses,chain.upper.simultaneous,chain.upper.req_holds,chain.upper.rsp_holds);
        $fwrite(metrics,"1,%0d,%0d,%0d,%0d,%0d\n",chain.backend.requests,chain.backend.responses,chain.backend.simultaneous,chain.backend.req_holds,chain.backend.rsp_holds);
        $fwrite(metrics,"2,%0d,%0d,%0d,%0d,%0d\n",chain.bram.requests,chain.bram.responses,chain.bram.simultaneous,chain.bram.req_holds,chain.bram.rsp_holds);
        $fclose(metrics);
        enable=0;done=1;
    end
    always @(negedge clk) if(rst_n&&!done) begin
        cycle=cycle+1;
        // Backpressure is independent of request sequence: repeated 3-cycle holds.
        rsp_ready=(CASE_ID==0) || cycle%11>=3;
        req_valid=sent<count;
        if(sent<count) begin req_write=wr[sent];req_addr=addr[sent];req_wdata=data[sent];req_size=size[sent];req_wstrb=strobe[sent];end
    end
    always @(posedge clk) if(rst_n&&!done) begin
        if(req_valid&&req_ready) sent=sent+1;
        if(rsp_valid&&rsp_ready) received=received+1;
    end
endmodule

module cpu5_memory_cpu #(
    parameter integer CASE_ID=2,REQ_WAIT=0,RSP_WAIT=0,UNALIGNED=0
)(output reg done=0);
    localparam ROM=UNALIGNED?"build/cpu5_s05_memory/cpu_unaligned.hex":"build/cpu5_s05_memory/cpu_illegal.hex";
    reg clk=0,rst_n=0,enable=1;
    wire qv,qr,qw,sv,sr,se,fault,retire,we,iv,ir,isv,isr,ise;
    wire [31:0] qa,qd,sd,pc,instr,wp,wd,ia,isd;
    wire [1:0] qz;
    wire [3:0] qs;
    wire [4:0] wrd;
    wire valid;
    wire rv,rr,rsv,rsr,rse;
    wire [31:0] ra,rsd;
    reg [31:0] golden_pc[0:63],golden_rd[0:63],golden_value[0:63];
    integer retired=0,expected_retired,metrics,retire_fd,ifetch_fd,ifetch_cycle=0;
    reg [31:0] iowner_addr=0,refill_owner_addr=0;
    cpu_top #(.PROGRAM_FILE(ROM),.DATA_FILE(""),.IMEM_WORDS(256),.DMEM_WORDS(4096),.DMEM_BASE_ADDR(32'h10000),.EXTERNAL_IMEM(1),.EXTERNAL_DMEM(1),.ENABLE_BRANCH_PRED(1),.ENABLE_M(1),.UART_CLOCK_HZ(50000000),.SIM_CONSOLE_ECHO(0)) cpu(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.irq_external(1'b0),.uart_tx(),.gpio_out(),.gpio_oe(),
        .pc_x(pc),.instr_x(instr),.valid_x(valid),.wb_pc(wp),.wb_rd(wrd),.wb_data(wd),.wb_we(we),.retire_valid(retire),.dmem_fault(fault),
        .dmem_req_valid(qv),.dmem_req_ready(qr),.dmem_req_write(qw),.dmem_req_addr(qa),.dmem_req_size(qz),.dmem_req_wdata(qd),.dmem_req_wstrb(qs),
        .dmem_rsp_valid(sv),.dmem_rsp_ready(sr),.dmem_rsp_rdata(sd),.dmem_rsp_error(se),
        .imem_req_valid(iv),.imem_req_ready(ir),.imem_req_addr(ia),.imem_rsp_valid(isv),.imem_rsp_ready(isr),.imem_rsp_rdata(isd),.imem_rsp_error(ise),
        .cycle_count(),.instret_count(),.imem_fault(),.imem_fault_pc(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());
    instr_cache #(.SETS(64),.LINE_WORDS(4),.MEM_WORDS(256)) icache(
        .clk(clk),.rst_n(rst_n),.req_valid(iv),.req_ready(ir),.req_addr(ia),.rsp_valid(isv),.rsp_ready(isr),.rsp_rdata(isd),.rsp_error(ise),
        .mem_req_valid(rv),.mem_req_ready(rr),.mem_req_addr(ra),.mem_rsp_valid(rsv),.mem_rsp_ready(rsr),.mem_rsp_rdata(rsd),.mem_rsp_error(rse),
        .access_count(),.hit_count(),.miss_count(),.refill_word_count(),.error_count());
    soc_instr_mem #(.WORDS(256),.INIT_FILE(ROM)) rom(
        .clk(clk),.rst_n(rst_n),.req_valid(rv),.req_ready(rr),.req_addr(ra),.rsp_valid(rsv),.rsp_ready(rsr),.rsp_rdata(rsd),.rsp_error(rse));
    cpu5_memory_chain #(.CASE_ID(CASE_ID),.REQ_WAIT(REQ_WAIT),.RSP_WAIT(RSP_WAIT)) chain(
        .clk(clk),.rst_n(rst_n),.enable(enable),.req_valid(qv),.req_ready(qr),.req_write(qw),.req_addr(qa),.req_size(qz),.req_wdata(qd),.req_wstrb(qs),
        .rsp_valid(sv),.rsp_ready(sr),.rsp_rdata(sd),.rsp_error(se),.owner_pc(pc));
    always #5 clk=~clk;
    initial begin
        retire_fd=$fopen($sformatf("build/cpu5_s05_memory/case%0d_retirement.csv",CASE_ID),"w");
        $fwrite(retire_fd,"index,pc,write,rd,data\n");
        ifetch_fd=$fopen($sformatf("build/cpu5_s05_memory/case%0d_ifetch.csv",CASE_ID),"w");
        $fwrite(ifetch_fd,"cycle,event,addr,hit,pc,valid_x,stall_x\n");
        if(UNALIGNED) begin
            $readmemh("build/cpu5_s05_memory/cpu_unaligned_pc.hex",golden_pc);
            $readmemh("build/cpu5_s05_memory/cpu_unaligned_rd.hex",golden_rd);
            $readmemh("build/cpu5_s05_memory/cpu_unaligned_value.hex",golden_value);
            expected_retired=35;
        end else begin
            $readmemh("build/cpu5_s05_memory/cpu_illegal_pc.hex",golden_pc);
            $readmemh("build/cpu5_s05_memory/cpu_illegal_rd.hex",golden_rd);
            $readmemh("build/cpu5_s05_memory/cpu_illegal_value.hex",golden_value);
            expected_retired=36;
        end
        repeat(4) @(negedge clk);rst_n=1;
        wait(fault);repeat(5) @(negedge clk);
        if(retired!=expected_retired || chain.upper.requests!=26 || chain.upper.responses!=26 ||
           chain.backend.requests!=chain.backend.responses || chain.bram.requests!=chain.bram.responses)
            $fatal(1,"CPU fixture counts case=%0d retired=%0d expected=%0d req=%0d rsp=%0d",CASE_ID,retired,expected_retired,chain.upper.requests,chain.upper.responses);
        $display("MEMORY CPU PASS case=%0d retired=%0d req=%0d rsp=%0d simultaneous=%0d backend=%0d bram=%0d",CASE_ID,retired,chain.upper.requests,chain.upper.responses,chain.upper.simultaneous,chain.backend.requests,chain.bram.requests);
        metrics=$fopen($sformatf("build/cpu5_s05_memory/case%0d_metrics.csv",CASE_ID),"w");
        $fwrite(metrics,"boundary,requests,responses,simultaneous,req_holds,rsp_holds\n");
        $fwrite(metrics,"0,%0d,%0d,%0d,%0d,%0d\n",chain.upper.requests,chain.upper.responses,chain.upper.simultaneous,chain.upper.req_holds,chain.upper.rsp_holds);
        $fwrite(metrics,"1,%0d,%0d,%0d,%0d,%0d\n",chain.backend.requests,chain.backend.responses,chain.backend.simultaneous,chain.backend.req_holds,chain.backend.rsp_holds);
        $fwrite(metrics,"2,%0d,%0d,%0d,%0d,%0d\n",chain.bram.requests,chain.bram.responses,chain.bram.simultaneous,chain.bram.req_holds,chain.bram.rsp_holds);
        $fclose(metrics);$fclose(retire_fd);$fclose(ifetch_fd);
        enable=0;done=1;
    end
    always @(posedge clk) if(rst_n&&enable&&retire) begin
        if(retired>=expected_retired || wp!==golden_pc[retired] || we!==(golden_rd[retired]!=0) ||
           (we && (wrd!==golden_rd[retired][4:0] || wd!==golden_value[retired])))
            $fatal(1,"CPU retirement scoreboard case=%0d n=%0d pc=%h expectedpc=%h write=%b rd=%0d expectedrd=%0d data=%h expecteddata=%h",CASE_ID,retired,wp,golden_pc[retired],we,wrd,golden_rd[retired],wd,golden_value[retired]);
        $fwrite(retire_fd,"%0d,%08x,%0d,%0d,%08x\n",retired,wp,we,wrd,wd);
        retired=retired+1;
    end
    always @(posedge clk) if(rst_n&&enable) begin
        ifetch_cycle=ifetch_cycle+1;
        if(isv&&isr) $fwrite(ifetch_fd,"%0d,irsp,%08x,-1,%08x,%0d,%0d\n",ifetch_cycle,iowner_addr,pc,valid,cpu.stall_x);
        if(iv&&ir) begin
            $fwrite(ifetch_fd,"%0d,ireq,%08x,%0d,%08x,%0d,%0d\n",ifetch_cycle,ia,icache.hit0||icache.hit1,pc,valid,cpu.stall_x);
            iowner_addr=ia;
        end
        if(rsv&&rsr) $fwrite(ifetch_fd,"%0d,refillrsp,%08x,-1,%08x,%0d,%0d\n",ifetch_cycle,refill_owner_addr,pc,valid,cpu.stall_x);
        if(rv&&rr) begin
            $fwrite(ifetch_fd,"%0d,refillreq,%08x,-1,%08x,%0d,%0d\n",ifetch_cycle,ra,pc,valid,cpu.stall_x);
            refill_owner_addr=ra;
        end
    end
endmodule
