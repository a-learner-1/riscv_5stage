`timescale 1ns/1ps
module data_cache_tb;
    wire [1:0] done;
    reg test_pass=0;
    data_cache_case fast(done[0]);
    data_cache_case #(.WAIT_CYCLES(3)) delayed(done[1]);
    initial begin wait(&done);test_pass=1;$display("DATA CACHE UNIT TESTS PASS");$stop;end
    initial begin #3000000;$fatal(1,"Data cache timeout done=%b",done);end
endmodule

module data_cache_case #(parameter integer WAIT_CYCLES=0)(output reg done=0);
    localparam [31:0] BASE=32'h10000;
    reg clk=0,rst_n=0,req_valid=0,req_write=0,rsp_ready=0,force_block=0;
    reg [31:0] req_addr=0,req_wdata=0,fault_addr=32'hffffffff;
    reg [1:0] req_size=2;
    reg [3:0] req_wstrb=0;
    wire req_ready,rsp_valid,rsp_error,mvalid,mready,mwrite,mrsp_ready;
    wire [31:0] rsp_data,maddr,mdata,accesses,hits,misses,words,errors,writes,bypasses;
    wire [1:0] msize;
    wire [3:0] mstrobe;
    reg mrsp_valid=0,mrsp_error=0,pending=0,pwrite=0,commit_failed=0;
    reg [31:0] mrsp_data=0,paddr=0,pdata=0;
    reg [3:0] pstrobe=0;
    reg [31:0] ram[0:511];
    integer delay=0,cycle=0,backend_reads=0,backend_writes=0,io_reads=0,io_writes=0;
    integer i,j,k,checks=0;
    reg held_req=0,held_rsp=0;
    reg [70:0] saved_request;
    reg [32:0] saved_response;
    reg ref_valid[0:3][0:1];
    integer ref_tag[0:3][0:1],ref_lru[0:3];
    integer ref_access=0,ref_hit=0,ref_miss=0,ref_words=0,ref_error=0,ref_write=0,ref_bypass=0;
    reg [31:0] random_state=32'h7192abcd;
    data_cache #(.SETS(4),.LINE_WORDS(4),.MEM_WORDS(512),.BASE_ADDR(BASE)) dut(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_size(req_size),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_data),.rsp_error(rsp_error),
        .mem_req_valid(mvalid),.mem_req_ready(mready),.mem_req_write(mwrite),.mem_req_addr(maddr),
        .mem_req_size(msize),.mem_req_wdata(mdata),.mem_req_wstrb(mstrobe),
        .mem_rsp_valid(mrsp_valid),.mem_rsp_ready(mrsp_ready),.mem_rsp_rdata(mrsp_data),.mem_rsp_error(mrsp_error),
        .access_count(accesses),.hit_count(hits),.miss_count(misses),.refill_word_count(words),
        .error_count(errors),.write_count(writes),.bypass_count(bypasses));
    always #5 clk=~clk;
    assign mready=rst_n && !force_block && !pending && !mrsp_valid &&
        (WAIT_CYCLES==0 || cycle%(WAIT_CYCLES+1)==0);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending<=0;mrsp_valid<=0;delay<=0;cycle<=0;
            backend_reads<=0;backend_writes<=0;io_reads<=0;io_writes<=0;
        end else begin
            cycle<=cycle+1;
            if(mrsp_valid&&mrsp_ready) mrsp_valid<=0;
            if(mvalid&&mready) begin
                pending<=1;paddr<=maddr;pdata<=mdata;pstrobe<=mstrobe;pwrite<=mwrite;delay<=WAIT_CYCLES;
                if(mwrite) backend_writes<=backend_writes+1;else backend_reads<=backend_reads+1;
            end
            if(pending) begin
                if(delay>0) delay<=delay-1;
                else begin
                    pending<=0;mrsp_valid<=1;mrsp_data<=0;
                    mrsp_error<=((paddr&32'hfffffffc)==fault_addr) ||
                        !(paddr>=BASE&&paddr<BASE+2048 || (paddr&32'hfffffffc)==32'h30000000);
                    if(paddr>=BASE&&paddr<BASE+2048) begin
                        if(pwrite && ((paddr&32'hfffffffc)!=fault_addr || commit_failed)) begin
                            if(pstrobe[0]) ram[(paddr-BASE)/4][7:0]<=pdata[7:0];
                            if(pstrobe[1]) ram[(paddr-BASE)/4][15:8]<=pdata[15:8];
                            if(pstrobe[2]) ram[(paddr-BASE)/4][23:16]<=pdata[23:16];
                            if(pstrobe[3]) ram[(paddr-BASE)/4][31:24]<=pdata[31:24];
                        end
                        if(!pwrite) mrsp_data<=ram[(paddr-BASE)/4];
                    end else if((paddr&32'hfffffffc)==32'h30000000) begin
                        if(pwrite) io_writes<=io_writes+1;
                        else begin mrsp_data<=32'hcafe0000+io_reads;io_reads<=io_reads+1;end
                    end
                end
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin held_req=0;held_rsp=0;end
        else begin
            if(held_req&&(!mvalid||{mwrite,maddr,msize,mdata,mstrobe}!==saved_request))
                $fatal(1,"Data cache backend request changed under backpressure");
            if(held_rsp&&(!rsp_valid||{rsp_error,rsp_data}!==saved_response))
                $fatal(1,"Data cache response changed under backpressure");
            held_req=mvalid&&!mready;saved_request={mwrite,maddr,msize,mdata,mstrobe};
            held_rsp=rsp_valid&&!rsp_ready;saved_response={rsp_error,rsp_data};
        end
    end
    task reset_cache;
        begin
            @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;force_block=0;fault_addr=32'hffffffff;
            ref_access=0;ref_hit=0;ref_miss=0;ref_words=0;ref_error=0;ref_write=0;ref_bypass=0;
            for(i=0;i<4;i=i+1) begin ref_valid[i][0]=0;ref_valid[i][1]=0;ref_lru[i]=0;end
            repeat(3) @(negedge clk);
            if(req_ready||rsp_valid||mvalid||mrsp_ready||accesses||hits||misses||words||errors||writes||bypasses)
                $fatal(1,"Data cache shared reset did not clear protocol/counters");
            rst_n=1;
        end
    endtask
    task transfer(input bit wr,input [31:0] addr,input [1:0] size,input [31:0] value,
                  input [3:0] strobe,input integer hold_cycles);
        integer set_index,tag,way,expected_reads,expected_writes,prior_reads,prior_writes,beat,t;
        reg legal,cached,expected_error;
        reg [31:0] expected_data,line_base;
        begin
            set_index=((addr-BASE)/16)%4;tag=(addr-BASE)/64;way=-1;
            expected_reads=0;expected_writes=0;expected_error=0;expected_data=0;
            line_base=addr&32'hfffffff0;
            legal=(size==0 || size==1&&!addr[0] || size==2&&addr[1:0]==0) &&
                (!wr || strobe==(size==0?(1<<addr[1:0]):size==1?(3<<addr[1:0]):15));
            cached=addr>=BASE&&addr<BASE+2048;
            ref_access=ref_access+1;
            if(!legal) expected_error=1;
            else if(!cached) begin
                ref_bypass=ref_bypass+1;
                if(wr) expected_writes=1;else expected_reads=1;
                expected_error=((addr&32'hfffffffc)==fault_addr)||((addr&32'hfffffffc)!=32'h30000000);
                if(!wr&&!expected_error) expected_data=32'hcafe0000+io_reads;
            end else begin
                for(t=0;t<2;t=t+1) if(ref_valid[set_index][t]&&ref_tag[set_index][t]==tag) way=t;
                if(wr) begin
                    ref_write=ref_write+1;expected_writes=1;expected_error=(addr&32'hfffffffc)==fault_addr;
                    if(way>=0) begin
                        if(expected_error) ref_valid[set_index][way]=0;
                        else ref_lru[set_index]=1-way;
                    end
                end else if(way>=0) begin
                    ref_hit=ref_hit+1;ref_lru[set_index]=1-way;expected_data=ram[(addr-BASE)/4];
                end else begin
                    ref_miss=ref_miss+1;
                    way=!ref_valid[set_index][0]?0:!ref_valid[set_index][1]?1:ref_lru[set_index];
                    ref_valid[set_index][way]=0;
                    for(beat=0;beat<4&&!expected_error;beat=beat+1) begin
                        expected_reads=expected_reads+1;
                        if(line_base+beat*4==fault_addr) expected_error=1;
                        else ref_words=ref_words+1;
                    end
                    if(!expected_error) begin
                        ref_valid[set_index][way]=1;ref_tag[set_index][way]=tag;ref_lru[set_index]=1-way;
                        expected_data=ram[(addr-BASE)/4];
                    end
                end
            end
            if(expected_error) begin ref_error=ref_error+1;expected_data=0;end
            prior_reads=backend_reads;prior_writes=backend_writes;
            @(negedge clk);req_valid=1;req_write=wr;req_addr=addr;req_size=size;
            req_wdata=value;req_wstrb=strobe;rsp_ready=0;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;
            // Upstream metadata changes immediately after acceptance.
            req_addr=32'hdeadbeef;req_wdata=32'h5555aaaa;req_write=!wr;req_size=3;req_wstrb=0;
            t=0;
            while(!rsp_valid) begin
                @(negedge clk);t=t+1;
                if(t>1000) $fatal(1,"Data cache request timeout addr=%h",addr);
            end
            repeat(hold_cycles+1) begin
                if(rsp_error!==expected_error||rsp_data!==expected_data)
                    $fatal(1,"Data cache %m wr=%b addr=%h size=%d got=%h err=%b expected=%h err=%b",wr,addr,size,rsp_data,rsp_error,expected_data,expected_error);
                @(negedge clk);
            end
            if(backend_reads-prior_reads!=expected_reads||backend_writes-prior_writes!=expected_writes)
                $fatal(1,"Data cache backend count %m addr=%h read=%0d/%0d write=%0d/%0d",addr,backend_reads-prior_reads,expected_reads,backend_writes-prior_writes,expected_writes);
            rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;
            repeat(2) @(negedge clk);
            if(accesses!==ref_access||hits!==ref_hit||misses!==ref_miss||words!==ref_words||
               errors!==ref_error||writes!==ref_write||bypasses!==ref_bypass)
                $fatal(1,"Data cache counters differ from independent model %m a/h/m/w/e/wr/io=%0d/%0d/%0d/%0d/%0d/%0d/%0d",accesses,hits,misses,words,errors,writes,bypasses);
            checks=checks+1;
        end
    endtask
    task load(input [31:0] addr);begin transfer(0,addr,2,0,0,checks%4);end endtask
    task store(input [31:0] addr,input [1:0] size,input [31:0] value);
        reg [3:0] strobe;
        begin strobe=size==0?(1<<addr[1:0]):size==1?(3<<addr[1:0]):15;transfer(1,addr,size,value,strobe,3);end
    endtask
    initial begin
        for(i=0;i<512;i=i+1) ram[i]=32'habcd0000+i;
        reset_cache;
        // Invalid-first allocation and true LRU: A/B/A/C/A/B.
        load(BASE);load(BASE+64);load(BASE);load(BASE+128);load(BASE);load(BASE+64);
        for(j=0;j<4;j=j+1) load(BASE+j*4);
        // Write miss must not allocate; subsequent load fetches a full line.
        store(BASE+256,2,32'h11223344);load(BASE+256);
        for(j=0;j<4;j=j+1) begin
            store(BASE+256+j,0,32'h000000a0<<(j*8));
            transfer(0,BASE+256+j,0,0,0,2);
        end
        store(BASE+256,1,32'h0000beef);store(BASE+258,1,32'hface0000);load(BASE+256);
        transfer(0,BASE+257,1,0,0,2);transfer(0,BASE+258,2,0,0,2);
        transfer(0,BASE,3,0,0,2);transfer(1,BASE,2,1,3,2);
        // Non-idempotent reads must reach the device once on every access.
        load(32'h30000000);load(32'h30000000);store(32'h30000000,2,32'h98765432);
        if(io_reads!=2||io_writes!=1) $fatal(1,"Data cache duplicated/cached I/O accesses");
        load(32'h10010000);load(BASE+2048);load(BASE-4);
        // Every refill error beat must discard the victim and preserve the other way.
        for(j=0;j<4;j=j+1) begin
            reset_cache;load(BASE);load(BASE+64);load(BASE);
            fault_addr=BASE+128+j*4;load(BASE+128);load(BASE);
            fault_addr=32'hffffffff;load(BASE+128);load(BASE+128+12);
        end
        // A backend may report failure after a partial write. Drop the cached
        // copy even in that case; a later load must see backing RAM.
        reset_cache;load(BASE);fault_addr=BASE;commit_failed=1;
        store(BASE,2,32'h76543210);fault_addr=32'hffffffff;commit_failed=0;load(BASE);
        // Reproducible mixed loads/stores with all sizes and conflicts.
        for(j=0;j<240;j=j+1) begin
            random_state=(random_state>>1)^((random_state&1)?32'hd0000001:0);
            if(random_state[1:0]==0) store(BASE+((random_state>>4)%256)*4,2,random_state);
            else if(random_state[1:0]==1) store(BASE+((random_state>>4)%1024),0,random_state<<(8*((random_state>>4)%4)));
            else load(BASE+((random_state>>4)%256)*4);
        end
        // Shared reset while request is blocked, refill is pending, or a CPU
        // response is held. RAM writes that completed before reset remain.
        for(k=0;k<3;k=k+1) begin
            reset_cache;force_block=(k==0);
            @(negedge clk);req_valid=1;req_write=0;req_addr=BASE+512;req_size=2;req_wstrb=0;
            @(posedge clk);@(negedge clk);req_valid=0;
            if(k==0) begin repeat(5) @(negedge clk);if(!mvalid||mready) $fatal(1,"Blocked request setup");end
            if(k==1) begin wait(mrsp_ready);@(negedge clk);end
            if(k==2) begin wait(rsp_valid);repeat(4) @(negedge clk);end
            reset_cache;load(BASE+512);load(BASE);
        end
        $display("DATA CACHE %m PASS: %0d independently modeled requests, LRU, 240 random, byte/halfword writes, MMIO, all refill faults, partial write error and reset",checks);
        done=1;
    end
endmodule
