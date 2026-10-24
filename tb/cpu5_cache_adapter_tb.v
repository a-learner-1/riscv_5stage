`timescale 1ns/1ps
// Reuses the unchanged legacy I/D independent cache models through the new
// adapter boundary; adds dual-port concurrency and bypass response ledgers.
module cpu5_cache_adapter_tb;
wire [11:0] done;reg test_pass=0;
cpu5_cache_instruction_case #(.CASE_ID(0),.COMPANION(0),.WAIT_CYCLES(0)) i0(done[0]);
cpu5_cache_instruction_case #(.CASE_ID(1),.COMPANION(0),.WAIT_CYCLES(3)) i1(done[1]);
cpu5_cache_instruction_case #(.CASE_ID(2),.COMPANION(1),.WAIT_CYCLES(0)) i2(done[2]);
cpu5_cache_instruction_case #(.CASE_ID(3),.COMPANION(1),.WAIT_CYCLES(3)) i3(done[3]);
cpu5_cache_data_case #(.CASE_ID(4),.COMPANION(0),.WAIT_CYCLES(0)) d0(done[4]);
cpu5_cache_data_case #(.CASE_ID(5),.COMPANION(0),.WAIT_CYCLES(3)) d1(done[5]);
cpu5_cache_data_case #(.CASE_ID(6),.COMPANION(1),.WAIT_CYCLES(0)) d2(done[6]);
cpu5_cache_data_case #(.CASE_ID(7),.COMPANION(1),.WAIT_CYCLES(3)) d3(done[7]);
cpu5_cache_pair_case #(.MASK(0),.CASE_ID(8)) p0(done[8]);
cpu5_cache_pair_case #(.MASK(1),.CASE_ID(9)) p1(done[9]);
cpu5_cache_pair_case #(.MASK(2),.CASE_ID(10)) p2(done[10]);
cpu5_cache_pair_case #(.MASK(3),.CASE_ID(11)) p3(done[11]);
initial begin wait(&done);test_pass=1;$display("CPU5 CACHE ADAPTER TEST PASS");$stop;end
initial begin #3000000;$fatal(1,"CPU5 adapter timeout done=%b",done);end
endmodule

// Both channels of the same adapter are active concurrently. The RAM gold is
// maintained by the request generator independently of physical backend RAM.
module cpu5_cache_pair_case #(parameter integer MASK=0,CASE_ID=8)(output reg done=0);
    localparam [31:0] BASE=32'h10000;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg cpu_imem_req_valid=0,cpu_imem_rsp_ready=0;
    reg [31:0] cpu_imem_req_addr=0;
    wire cpu_imem_req_ready,cpu_imem_rsp_valid,cpu_imem_rsp_error;
    wire [31:0] cpu_imem_rsp_rdata;
    reg cpu_dmem_req_valid=0,cpu_dmem_req_write=0,cpu_dmem_rsp_ready=0;
    reg [31:0] cpu_dmem_req_addr=0,cpu_dmem_req_wdata=0;
    reg [1:0] cpu_dmem_req_size=2;reg [3:0] cpu_dmem_req_wstrb=0;
    wire cpu_dmem_req_ready,cpu_dmem_rsp_valid,cpu_dmem_rsp_error;
    wire [31:0] cpu_dmem_rsp_rdata;
    wire mem_imem_req_valid,mem_imem_rsp_ready;wire [31:0] mem_imem_req_addr;
    wire mem_imem_req_ready;
    reg mem_imem_rsp_valid=0,mem_imem_rsp_error=0;reg [31:0] mem_imem_rsp_rdata=0;
    wire mem_dmem_req_valid,mem_dmem_req_write,mem_dmem_rsp_ready,mem_dmem_req_ready;
    wire [31:0] mem_dmem_req_addr,mem_dmem_req_wdata;wire [1:0] mem_dmem_req_size;wire [3:0] mem_dmem_req_wstrb;
    reg mem_dmem_rsp_valid=0,mem_dmem_rsp_error=0;reg [31:0] mem_dmem_rsp_rdata=0;
    wire [31:0] icache_access_count,icache_hit_count,icache_miss_count,icache_refill_word_count,icache_error_count;
    wire [31:0] dcache_access_count,dcache_hit_count,dcache_miss_count,dcache_refill_word_count,dcache_error_count,dcache_write_count,dcache_bypass_count;
    cpu5_cache_adapter #(.ENABLE_ICACHE(MASK%2),.ENABLE_DCACHE(MASK/2),
        .ICACHE_SETS(4),.DCACHE_SETS(4),.IMEM_WORDS(2048),.DMEM_WORDS(512)) dut(.*);
    reg ipending=0,dpending=0,dblock=1,iback_owner=0,dback_owner=0;
    reg [31:0] ia=0,da=0,ddata=0,i_fault=32'hffffffff;
    reg dw=0;reg [3:0] ds=0;
    integer itime=0,dtime=0,cycle=0,i,j;
    reg [31:0] actual_ram[0:511],gold_ram[0:511];
    integer physical_io_reads=0,gold_io_reads=0;
    integer iback_requests=0,iback_responses=0,dback_requests=0,dback_responses=0;
    integer irequests=0,iresponses=0,drequests=0,dresponses=0,checks=0,summary_fd;
    integer held_i_request=0,held_d_request=0,held_i_response=0,held_d_response=0;
    reg [31:0] prev_i_addr=0;reg [70:0] prev_d_req=0;
    reg [32:0] prev_i_rsp=0,prev_d_rsp=0;
    reg ih=0,dh=0,irh=0,drh=0;
    reg idone=0,ddone=0;
    function [31:0] ivalue(input [31:0] a);begin ivalue=(a*32'h01010101)^32'hbada5678;end endfunction
    assign mem_imem_req_ready=rst_n&&!ipending&&!mem_imem_rsp_valid&&(cycle%5==0);
    assign mem_dmem_req_ready=rst_n&&!dblock&&!dpending&&!mem_dmem_rsp_valid&&(cycle%4==0);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin ipending<=0;dpending<=0;mem_imem_rsp_valid<=0;mem_dmem_rsp_valid<=0;cycle<=0;end
        else begin
            cycle<=cycle+1;
            if(mem_imem_rsp_valid&&mem_imem_rsp_ready)mem_imem_rsp_valid<=0;
            if(mem_dmem_rsp_valid&&mem_dmem_rsp_ready)mem_dmem_rsp_valid<=0;
            if(mem_imem_req_valid&&mem_imem_req_ready)begin ipending<=1;ia<=mem_imem_req_addr;itime<=2;end
            if(mem_dmem_req_valid&&mem_dmem_req_ready)begin
                dpending<=1;da<=mem_dmem_req_addr;dw<=mem_dmem_req_write;ddata<=mem_dmem_req_wdata;ds<=mem_dmem_req_wstrb;dtime<=3;
            end
            if(ipending)begin
                if(itime>0)itime<=itime-1;
                else begin ipending<=0;mem_imem_rsp_valid<=1;mem_imem_rsp_error<=ia==i_fault||ia>=8192||ia[1:0]!=0;
                    mem_imem_rsp_rdata<=(ia==i_fault||ia>=8192||ia[1:0]!=0)?0:ivalue(ia);end
            end
            if(dpending)begin
                if(dtime>0)dtime<=dtime-1;
                else begin
                    dpending<=0;mem_dmem_rsp_valid<=1;mem_dmem_rsp_error<=0;mem_dmem_rsp_rdata<=0;
                    if(da>=BASE&&da<BASE+2048)begin
                        if(dw)begin
                            if(ds[0])actual_ram[(da-BASE)/4][7:0]<=ddata[7:0];
                            if(ds[1])actual_ram[(da-BASE)/4][15:8]<=ddata[15:8];
                            if(ds[2])actual_ram[(da-BASE)/4][23:16]<=ddata[23:16];
                            if(ds[3])actual_ram[(da-BASE)/4][31:24]<=ddata[31:24];
                        end else mem_dmem_rsp_rdata<=actual_ram[(da-BASE)/4];
                    end else if(da==32'h30000000)begin
                        if(!dw)begin mem_dmem_rsp_rdata<=32'hcafe0000+physical_io_reads;physical_io_reads<=physical_io_reads+1;end
                    end else mem_dmem_rsp_error<=1;
                end
            end
        end
    end
    always @(posedge clk)if(rst_n)begin
        if(ih&&(!mem_imem_req_valid||mem_imem_req_addr!==prev_i_addr))$fatal(1,"CPU5 pair I held request metadata");
        if(dh&&(!mem_dmem_req_valid||{mem_dmem_req_write,mem_dmem_req_addr,mem_dmem_req_size,mem_dmem_req_wdata,mem_dmem_req_wstrb}!==prev_d_req))$fatal(1,"CPU5 pair D held request metadata");
        if(irh&&(!cpu_imem_rsp_valid||{cpu_imem_rsp_error,cpu_imem_rsp_rdata}!==prev_i_rsp))$fatal(1,"CPU5 pair I held response metadata");
        if(drh&&(!cpu_dmem_rsp_valid||{cpu_dmem_rsp_error,cpu_dmem_rsp_rdata}!==prev_d_rsp))$fatal(1,"CPU5 pair D held response metadata");
        ih=mem_imem_req_valid&&!mem_imem_req_ready;dh=mem_dmem_req_valid&&!mem_dmem_req_ready;
        irh=cpu_imem_rsp_valid&&!cpu_imem_rsp_ready;drh=cpu_dmem_rsp_valid&&!cpu_dmem_rsp_ready;
        if(ih)held_i_request=held_i_request+1;if(dh)held_d_request=held_d_request+1;
        if(irh)held_i_response=held_i_response+1;if(drh)held_d_response=held_d_response+1;
        prev_i_addr=mem_imem_req_addr;prev_d_req={mem_dmem_req_write,mem_dmem_req_addr,mem_dmem_req_size,mem_dmem_req_wdata,mem_dmem_req_wstrb};
        prev_i_rsp={cpu_imem_rsp_error,cpu_imem_rsp_rdata};prev_d_rsp={cpu_dmem_rsp_error,cpu_dmem_rsp_rdata};
        if(mem_imem_rsp_valid&&mem_imem_rsp_ready)begin if(!iback_owner)$fatal(1,"CPU5 pair I response owner");iback_owner=0;iback_responses=iback_responses+1;end
        if(mem_dmem_rsp_valid&&mem_dmem_rsp_ready)begin if(!dback_owner)$fatal(1,"CPU5 pair D response owner");dback_owner=0;dback_responses=dback_responses+1;end
        if(mem_imem_req_valid&&mem_imem_req_ready)begin if(iback_owner)$fatal(1,"CPU5 pair I owner overwritten");iback_owner=1;iback_requests=iback_requests+1;end
        if(mem_dmem_req_valid&&mem_dmem_req_ready)begin if(dback_owner)$fatal(1,"CPU5 pair D owner overwritten");dback_owner=1;dback_requests=dback_requests+1;end
        if(cpu_imem_req_valid&&cpu_imem_req_ready)irequests=irequests+1;
        if(cpu_dmem_req_valid&&cpu_dmem_req_ready)drequests=drequests+1;
        if(cpu_imem_rsp_valid&&cpu_imem_rsp_ready)iresponses=iresponses+1;
        if(cpu_dmem_rsp_valid&&cpu_dmem_rsp_ready)dresponses=dresponses+1;
    end
    task ifetch(input [31:0] addr,input error);
        integer t;reg [31:0] expected;
        begin
            expected=error?0:ivalue(addr);
            @(negedge clk);cpu_imem_req_valid=1;cpu_imem_req_addr=addr;cpu_imem_rsp_ready=0;t=0;
            @(posedge clk);while(!cpu_imem_req_ready)begin @(posedge clk);t=t+1;if(t>1000)$fatal(1,"CPU5 pair I admission timeout");end
            @(negedge clk);cpu_imem_req_valid=0;cpu_imem_req_addr=32'hdeadbeec;t=0;
            while(!cpu_imem_rsp_valid)begin @(negedge clk);t=t+1;if(t>1000)$fatal(1,"CPU5 pair I response timeout");end
            repeat(3)begin if(cpu_imem_rsp_error!==error||cpu_imem_rsp_rdata!==expected)$fatal(1,"CPU5 pair I architectural data/error");@(negedge clk);end
            cpu_imem_rsp_ready=1;@(posedge clk);@(negedge clk);cpu_imem_rsp_ready=0;checks=checks+1;
        end
    endtask
    task dtransfer(input wr,input [31:0] addr,input [1:0] size,input [31:0] value,input [3:0] strobe,input error);
        integer t,z;reg [31:0] expected;
        begin
            expected=0;
            if(!error)begin
                if(addr>=BASE&&addr<BASE+2048)begin
                    if(wr)for(z=0;z<4;z=z+1)if(strobe[z])gold_ram[(addr-BASE)/4][z*8+:8]=value[z*8+:8];
                    if(!wr)expected=gold_ram[(addr-BASE)/4];
                end else if(addr==32'h30000000&&!wr)begin expected=32'hcafe0000+gold_io_reads;gold_io_reads=gold_io_reads+1;end
            end
            @(negedge clk);cpu_dmem_req_valid=1;cpu_dmem_req_write=wr;cpu_dmem_req_addr=addr;cpu_dmem_req_size=size;cpu_dmem_req_wdata=value;cpu_dmem_req_wstrb=strobe;cpu_dmem_rsp_ready=0;t=0;
            @(posedge clk);while(!cpu_dmem_req_ready)begin @(posedge clk);t=t+1;if(t>1000)$fatal(1,"CPU5 pair D admission timeout");end
            @(negedge clk);cpu_dmem_req_valid=0;cpu_dmem_req_addr=32'hbadc0001;cpu_dmem_req_size=3;cpu_dmem_req_wdata=~value;cpu_dmem_req_wstrb=0;t=0;
            while(!cpu_dmem_rsp_valid)begin @(negedge clk);t=t+1;if(t>1000)$fatal(1,"CPU5 pair D response timeout");end
            repeat(4)begin if(cpu_dmem_rsp_error!==error||cpu_dmem_rsp_rdata!==expected)$fatal(1,"CPU5 pair D architectural data/error mask=%0d addr=%h got=%h expected=%h error=%b/%b",MASK,addr,cpu_dmem_rsp_rdata,expected,cpu_dmem_rsp_error,error);@(negedge clk);end
            cpu_dmem_rsp_ready=1;@(posedge clk);@(negedge clk);cpu_dmem_rsp_ready=0;checks=checks+1;
        end
    endtask
    initial begin
        for(i=0;i<512;i=i+1)begin actual_ram[i]=32'hdead0000+i;gold_ram[i]=32'hdead0000+i;end
        repeat(3)@(negedge clk);rst_n=1;
        fork
            begin
                for(integer n=0;n<16;n=n+1)ifetch((n%4)*4,0);
                ifetch(64,0);ifetch(128,0);ifetch(64,0);
                i_fault=2048;ifetch(2048,1);i_fault=32'hffffffff;ifetch(2048,0);idone=1;
            end
            begin
                dtransfer(0,BASE,2,0,0,0);
                dtransfer(1,BASE+1,0,32'h0000a500,2,0);dtransfer(0,BASE,2,0,0,0);
                dtransfer(1,BASE+2,1,32'h12340000,12,0);dtransfer(0,BASE,2,0,0,0);
                dtransfer(1,BASE+256,2,32'hacdc1234,15,0);dtransfer(0,BASE+256,2,0,0,0);
                dtransfer(0,BASE+64,2,0,0,0);dtransfer(0,BASE+128,2,0,0,0);dtransfer(0,BASE+64,2,0,0,0);
                dtransfer(0,32'h30000000,2,0,0,0);dtransfer(0,32'h30000000,2,0,0,0);
                dtransfer(1,32'h30000000,2,32'hcafe1234,15,0);dtransfer(0,32'h40000000,2,0,0,1);ddone=1;
            end
            begin repeat(60)@(negedge clk);if(iresponses==0)$fatal(1,"CPU5 adapter I stalled behind independent D");dblock=0;end
        join
        repeat(5)@(negedge clk);
        if(!idone||!ddone||irequests!=iresponses||drequests!=dresponses||iback_requests!=iback_responses||dback_requests!=dback_responses||iback_owner||dback_owner)$fatal(1,"CPU5 pair transaction ledger closure");
        for(j=0;j<512;j=j+1)if(actual_ram[j]!==gold_ram[j])$fatal(1,"CPU5 pair complete RAM comparison");
        if(physical_io_reads!=gold_io_reads||gold_io_reads!=2)$fatal(1,"CPU5 pair non-idempotent read replay");
        if(MASK%2==0&&(icache_access_count||icache_hit_count||icache_miss_count||icache_refill_word_count||icache_error_count))$fatal(1,"CPU5 disabled I counters nonzero");
        if(MASK/2==0&&(dcache_access_count||dcache_hit_count||dcache_miss_count||dcache_refill_word_count||dcache_error_count||dcache_write_count||dcache_bypass_count))$fatal(1,"CPU5 disabled D counters nonzero");
        if(MASK%2&&(!icache_hit_count||!icache_miss_count||icache_error_count!=1))$fatal(1,"CPU5 enabled I coverage");
        if(MASK/2&&(!dcache_hit_count||!dcache_miss_count||dcache_write_count!=3||dcache_bypass_count!=4||dcache_error_count!=1))$fatal(1,"CPU5 enabled D coverage");
        if(!held_i_request||!held_d_request||!held_i_response||!held_d_response)$fatal(1,"CPU5 pair backpressure coverage");
        summary_fd=$fopen($sformatf("build/cpu5_s13_cache_adapter/case%0d_summary.json",CASE_ID),"w");
        $fdisplay(summary_fd,"{\"status\":\"PASS\",\"case\":%0d,\"kind\":\"concurrent\",\"mask\":%0d,\"checks\":%0d,\"backend_requests\":%0d,\"backend_responses\":%0d,\"backend_reset_drops\":0,\"front_requests\":%0d,\"front_responses\":%0d,\"front_reset_drops\":0,\"held_i_request\":%0d,\"held_d_request\":%0d,\"held_i_response\":%0d,\"held_d_response\":%0d}",CASE_ID,MASK,checks,iback_requests+dback_requests,iback_responses+dback_responses,irequests+drequests,iresponses+dresponses,held_i_request,held_d_request,held_i_response,held_d_response);
        $fclose(summary_fd);done=1;
    end
endmodule

module cpu5_cache_guard_adapter_tb;
    cpu5_cache_adapter #(.ENABLE_ICACHE(2)) bad(
        .clk(1'b0),.rst_n(1'b0),
        .cpu_imem_req_valid(1'b0),.cpu_imem_req_addr(32'd0),.cpu_imem_rsp_ready(1'b0),
        .cpu_dmem_req_valid(1'b0),.cpu_dmem_req_write(1'b0),.cpu_dmem_req_addr(32'd0),.cpu_dmem_req_size(2'd0),.cpu_dmem_req_wdata(32'd0),.cpu_dmem_req_wstrb(4'd0),.cpu_dmem_rsp_ready(1'b0),
        .mem_imem_req_ready(1'b0),.mem_imem_rsp_valid(1'b0),.mem_imem_rsp_rdata(32'd0),.mem_imem_rsp_error(1'b0),
        .mem_dmem_req_ready(1'b0),.mem_dmem_rsp_valid(1'b0),.mem_dmem_rsp_rdata(32'd0),.mem_dmem_rsp_error(1'b0),
.cpu_imem_req_ready(),
.cpu_imem_rsp_valid(),
.cpu_imem_rsp_rdata(),
.cpu_imem_rsp_error(),
.cpu_dmem_req_ready(),
.cpu_dmem_rsp_valid(),
.cpu_dmem_rsp_rdata(),
.cpu_dmem_rsp_error(),
.mem_imem_req_valid(),
.mem_imem_req_addr(),
.mem_imem_rsp_ready(),
.mem_dmem_req_valid(),
.mem_dmem_req_write(),
.mem_dmem_req_addr(),
.mem_dmem_req_size(),
.mem_dmem_req_wdata(),
.mem_dmem_req_wstrb(),
.mem_dmem_rsp_ready(),
.icache_access_count(),
.icache_hit_count(),
.icache_miss_count(),
.icache_refill_word_count(),
.icache_error_count(),
.dcache_access_count(),
.dcache_hit_count(),
.dcache_miss_count(),
.dcache_refill_word_count(),
.dcache_error_count(),
.dcache_write_count(),
.dcache_bypass_count());
    initial begin #20;$fatal(1,"CPU5 adapter accepted non-boolean cache enable");end
endmodule
module cpu5_cache_guard_top_tb;
    cpu5_cached_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(512),.SKELETON_ONLY(0),.ENABLE_RAM(0),.ENABLE_DCACHE(1)) bad(
        .clk(1'b0),.rst_n(1'b0),.uart_rx(1'b1),.gpio_in(8'd0),
        .irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .imem_req_ready(1'b0),.imem_rsp_valid(1'b0),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),
        .dmem_req_ready(1'b0),.dmem_rsp_valid(1'b0),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),
.pc_x(),
.instr_x(),
.valid_x(),
.wb_pc(),
.wb_rd(),
.wb_data(),
.wb_we(),
.retire_valid(),
.cycle_count(),
.instret_count(),
.uart_tx(),
.gpio_out(),
.gpio_oe(),
.dmem_req_valid(),
.dmem_req_write(),
.dmem_req_addr(),
.dmem_req_size(),
.dmem_req_wdata(),
.dmem_req_wstrb(),
.dmem_rsp_ready(),
.dmem_fault(),
.imem_req_valid(),
.imem_req_addr(),
.imem_rsp_ready(),
.imem_fault(),
.imem_fault_pc(),
.trap_valid(),
.trap_pc(),
.trap_cause(),
.trap_tval(),
.bp_lookup_count(),
.bp_hit_count(),
.bp_taken_count(),
.bp_resolved_count(),
.bp_mispredict_count(),
.bp_direction_error_count(),
.bp_target_error_count(),
.perf_cycle_events(),
.icache_access_count(),
.icache_hit_count(),
.icache_miss_count(),
.icache_refill_word_count(),
.icache_error_count(),
.dcache_access_count(),
.dcache_hit_count(),
.dcache_miss_count(),
.dcache_refill_word_count(),
.dcache_error_count(),
.dcache_write_count(),
.dcache_bypass_count());
    initial begin #20;$fatal(1,"CPU5 cached top accepted D-cache without RAM");end
endmodule
module cpu5_cache_instruction_case #(parameter integer WAIT_CYCLES=0,CASE_ID=0,COMPANION=0)(output reg done=0);
    reg clk=0,rst_n=0,req_valid=0,rsp_ready=0,force_block=0;
    reg [31:0] req_addr=0,fault_addr=32'hffffffff;
    wire req_ready,rsp_valid,rsp_error,mreq_valid,mreq_ready,mrsp_ready;
    wire [31:0] rsp_rdata,mreq_addr,accesses,hits,misses,words,errors;
    reg mrsp_valid=0,mrsp_error=0,pending=0;
    reg [31:0] mrsp_data=0,saved_addr=0;
    integer delay=0,cycle=0,reads=0,checks=0,i,j;
    reg held_req=0,held_rsp=0;
    reg [31:0] held_addr=0,held_data=0;
    reg held_error=0;
    reg ref_valid[0:3][0:1];
    integer ref_tag[0:3][0:1],ref_lru[0:3];
    integer ref_access=0,ref_hit=0,ref_miss=0,ref_words=0,ref_error=0;
    reg [31:0] random_state=32'h45678abc;
    cpu5_cache_instruction_path #(.OTHER_CACHE(COMPANION),.SETS(4),.LINE_WORDS(4),.MEM_WORDS(2048)) dut (
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_rdata),.rsp_error(rsp_error),
        .mem_req_valid(mreq_valid),.mem_req_ready(mreq_ready),.mem_req_addr(mreq_addr),
        .mem_rsp_valid(mrsp_valid),.mem_rsp_ready(mrsp_ready),.mem_rsp_rdata(mrsp_data),.mem_rsp_error(mrsp_error),
        .access_count(accesses),.hit_count(hits),.miss_count(misses),.refill_word_count(words),.error_count(errors)
    );

    integer ledger_requests=0,ledger_responses=0,ledger_reset_drops=0;
    integer front_requests=0,front_responses=0,front_reset_drops=0;
    reg ledger_pending=0,front_pending=0;
    integer summary_fd;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            if(ledger_pending)ledger_reset_drops=ledger_reset_drops+1;
            if(front_pending)front_reset_drops=front_reset_drops+1;
            ledger_pending=0;front_pending=0;
        end else begin
            if(mrsp_valid&&mrsp_ready)begin
                if(!ledger_pending)$fatal(1,"CPU5 adapter backend response without owner");
                ledger_pending=0;ledger_responses=ledger_responses+1;
            end
            if(mreq_valid&&mreq_ready)begin
                if(ledger_pending)$fatal(1,"CPU5 adapter backend owner overwritten");
                ledger_pending=1;ledger_requests=ledger_requests+1;
            end
            if(rsp_valid&&rsp_ready)begin
                if(!front_pending)$fatal(1,"CPU5 adapter front response without owner");
                front_pending=0;front_responses=front_responses+1;
            end
            if(req_valid&&req_ready)begin
                if(front_pending)$fatal(1,"CPU5 adapter front owner overwritten");
                front_pending=1;front_requests=front_requests+1;
            end
        end
    end
    always #5 clk=~clk;
    function [31:0] memory_value(input [31:0] addr);
        memory_value=(addr*32'h01010101)^32'hbada5678;
    endfunction
    assign mreq_ready=rst_n && !force_block && !pending && !mrsp_valid &&
                      (WAIT_CYCLES==0 || cycle%(WAIT_CYCLES+1)==0);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin pending<=0;mrsp_valid<=0;delay<=0;reads<=0;cycle<=0;end
        else begin
            cycle<=cycle+1;
            if(mrsp_valid && mrsp_ready) mrsp_valid<=0;
            if(mreq_valid && mreq_ready) begin
                pending<=1;saved_addr<=mreq_addr;delay<=WAIT_CYCLES;reads<=reads+1;
            end
            if(pending) begin
                if(delay>0) delay<=delay-1;
                else begin
                    pending<=0;mrsp_valid<=1;mrsp_data<=memory_value(saved_addr);
                    mrsp_error<=saved_addr==fault_addr;
                end
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) begin held_req=0;held_rsp=0;end
        else begin
            if(held_req && (!mreq_valid || mreq_addr!==held_addr)) $fatal(1,"Cache backend request changed under stall");
            if(held_rsp && (!rsp_valid || rsp_rdata!==held_data || rsp_error!==held_error))
                $fatal(1,"Cache CPU response changed under stall");
            held_req=mreq_valid&&!mreq_ready;held_addr=mreq_addr;
            held_rsp=rsp_valid&&!rsp_ready;held_data=rsp_rdata;held_error=rsp_error;
        end
    end
    task reset_cache;
        begin
            @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;force_block=0;fault_addr=32'hffffffff;
            ref_access=0;ref_hit=0;ref_miss=0;ref_words=0;ref_error=0;
            for(i=0;i<4;i=i+1) begin ref_lru[i]=0;ref_valid[i][0]=0;ref_valid[i][1]=0;end
            repeat(3) @(negedge clk);
            if(req_ready||rsp_valid||mreq_valid||mrsp_ready||accesses||hits||misses||words||errors)
                $fatal(1,"Cache shared reset did not clear interfaces/counters");
            rst_n=1;
        end
    endtask
    task fetch(input [31:0] addr,input integer hold_cycles);
        integer set_index,tag,way,expected_reads,prior_reads,k;
        reg expected_error;
        begin
            // Independent two-way model: invalid-first allocation, then LRU.
            set_index=(addr/16)%4;tag=addr/64;way=-1;expected_reads=0;expected_error=0;
            ref_access=ref_access+1;
            if(addr%4!=0 || addr>=8192) begin expected_error=1;ref_error=ref_error+1;end
            else begin
                for(k=0;k<2;k=k+1) if(ref_valid[set_index][k] && ref_tag[set_index][k]==tag) way=k;
                if(way>=0) begin ref_hit=ref_hit+1;ref_lru[set_index]=1-way;end
                else begin
                    ref_miss=ref_miss+1;
                    way=!ref_valid[set_index][0]?0:!ref_valid[set_index][1]?1:ref_lru[set_index];
                    ref_valid[set_index][way]=0;
                    expected_reads=4;
                    if(fault_addr>=((addr/16)*16) && fault_addr<((addr/16)*16+16)) begin
                        expected_reads=(fault_addr%16)/4+1;expected_error=1;
                        ref_words=ref_words+expected_reads-1;ref_error=ref_error+1;
                    end else begin
                        ref_words=ref_words+4;ref_valid[set_index][way]=1;
                        ref_tag[set_index][way]=tag;ref_lru[set_index]=1-way;
                    end
                end
            end
            prior_reads=reads;
            @(negedge clk);req_valid=1;req_addr=addr;rsp_ready=0;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;
            wait(rsp_valid);#1;
            if(rsp_error!==expected_error || rsp_rdata!==(expected_error?32'd0:memory_value(addr)))
                $fatal(1,"Cache data/error %m addr=%h got=%h error=%b",addr,rsp_rdata,rsp_error);
            // Counter events are pipelined one clock, independent of hit reply.
            repeat(hold_cycles+2) @(negedge clk);
            if(reads-prior_reads!=expected_reads) $fatal(1,"Cache refill/LRU %m addr=%h reads=%0d expected=%0d",addr,reads-prior_reads,expected_reads);
            if(accesses!==ref_access || hits!==ref_hit || misses!==ref_miss || words!==ref_words || errors!==ref_error)
                $fatal(1,"Cache counters %m got=%0d/%0d/%0d/%0d/%0d expected=%0d/%0d/%0d/%0d/%0d",
                       accesses,hits,misses,words,errors,ref_access,ref_hit,ref_miss,ref_words,ref_error);
            @(negedge clk);rsp_ready=1;@(posedge clk);@(negedge clk);rsp_ready=0;
            checks=checks+1;
        end
    endtask
    initial begin
        reset_cache;
        // All word offsets, two resident tags, LRU hit update and eviction.
        fetch(0,3);fetch(4,0);fetch(8,0);fetch(12,0);
        fetch(64,0);fetch(0,0);fetch(128,0);fetch(0,0);fetch(64,0);
        fetch(16,0);fetch(28,0);fetch(8192,3);fetch(3,2);fetch(8188,0);
        // Fill failure after two successful words: do not expose a partial line.
        fault_addr=32'd200;fetch(192,4);fetch(64,0);
        fault_addr=32'hffffffff;fetch(192,0);fetch(196,0);
        for(j=0;j<4;j=j+1) begin
            fault_addr=1024+j*64+j*4;fetch(1024+j*64,2);
            fault_addr=32'hffffffff;fetch(1024+j*64+12,0);
        end
        // Long request-side stall while the backend address must remain stable.
        force_block=1;
        fork
            begin fetch(512,4);end
            begin repeat(20) @(negedge clk);force_block=0;end
        join
        for(j=0;j<160;j=j+1) begin
            random_state=(random_state<<1)^((random_state[31])?32'h04c11db7:0);
            fetch((random_state%256)*4,j%4);
        end
        // Shared reset cancels refill request, accepted backend work and reply.
        force_block=1;@(negedge clk);req_addr=4096;req_valid=1;
        @(posedge clk);@(negedge clk);req_valid=0;wait(mreq_valid);reset_cache;fetch(4096,0);
        @(negedge clk);req_addr=6144;req_valid=1;
        @(posedge clk);@(negedge clk);req_valid=0;wait(pending);reset_cache;fetch(6144,0);
        @(negedge clk);req_addr=16;req_valid=1;
        @(posedge clk);@(negedge clk);req_valid=0;wait(rsp_valid);reset_cache;fetch(16,0);
        // Once warm, response consumption and the next request overlap.
        fetch(20,0);fetch(24,0);fetch(28,0);
        @(negedge clk);rsp_ready=1;req_valid=1;req_addr=16;
        for(j=0;j<32;j=j+1) begin
            @(posedge clk);
            if(!req_ready || (j>0 && (!rsp_valid || rsp_error || rsp_rdata!==memory_value(16+((j-1)%4)*4))))
                $fatal(1,"Cache did not sustain one warm hit per clock");
            @(negedge clk);req_addr=16+((j+1)%4)*4;
        end
        req_valid=0;@(posedge clk);
        if(!rsp_valid || rsp_rdata!==memory_value(28)) $fatal(1,"Cache warm stream final response");
        #1;
        if(reads!=4 || hits!=35 || accesses!=36) $fatal(1,"Cache warm stream final counters");
        @(negedge clk);rsp_ready=0;
        // Alternating-way hits followed immediately by a same-set miss.
        // A pipelined LRU update must forward the most recent hit, not evict
        // the way that was just read on the previous clock.
        reset_cache;fetch(0,0);fetch(64,0);
        @(negedge clk);rsp_ready=1;req_valid=1;req_addr=0;
        @(posedge clk);if(!req_ready) $fatal(1,"LRU overlap first request");
        @(negedge clk);req_addr=64;
        @(posedge clk);
        if(!req_ready || !rsp_valid || rsp_error || rsp_rdata!==memory_value(0))
            $fatal(1,"LRU overlap first hit");
        @(negedge clk);req_addr=128;
        @(posedge clk);
        if(!req_ready || !rsp_valid || rsp_error || rsp_rdata!==memory_value(64))
            $fatal(1,"LRU overlap second hit");
        @(negedge clk);req_valid=0;
        wait(rsp_valid);#1;
        if(rsp_error || rsp_rdata!==memory_value(128) || reads!=12)
            $fatal(1,"LRU overlap replacement refill");
        @(posedge clk);@(negedge clk);req_valid=1;req_addr=64;
        @(posedge clk);if(!req_ready) $fatal(1,"LRU survivor request");
        @(negedge clk);req_valid=0;
        if(!rsp_valid || rsp_error || rsp_rdata!==memory_value(64) || reads!=12)
            $fatal(1,"LRU forwarding evicted the most recent way");
        @(posedge clk);@(negedge clk);rsp_ready=0;
        $display("CACHE case %m PASS: %0d modeled reads, two-way LRU, faults, reset, backpressure, one hit/clock",checks);

        if(ledger_requests!=ledger_responses+ledger_reset_drops||front_requests!=front_responses+front_reset_drops)
            $fatal(1,"CPU5 adapter ledger closure");
        summary_fd=$fopen($sformatf("build/cpu5_s13_cache_adapter/case%0d_summary.json",CASE_ID),"w");
        $fdisplay(summary_fd,"{\"status\":\"PASS\",\"case\":%0d,\"kind\":\"instruction\",\"checks\":%0d,\"backend_requests\":%0d,\"backend_responses\":%0d,\"backend_reset_drops\":%0d,\"front_requests\":%0d,\"front_responses\":%0d,\"front_reset_drops\":%0d}",CASE_ID,checks,ledger_requests,ledger_responses,ledger_reset_drops,front_requests,front_responses,front_reset_drops);
        $fclose(summary_fd);
        done=1;
    end
endmodule

module cpu5_cache_instruction_path #(
    parameter integer SETS = 64,
    parameter integer LINE_WORDS = 4,
    parameter integer MEM_WORDS = 8192
, parameter integer OTHER_CACHE=0
) (
    input wire clk, rst_n,
    input wire req_valid, output wire req_ready, input wire [31:0] req_addr,
    output wire rsp_valid, input wire rsp_ready,
    output wire [31:0] rsp_rdata, output wire rsp_error,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [31:0] mem_req_addr,
    input wire mem_rsp_valid, output wire mem_rsp_ready,
    input wire [31:0] mem_rsp_rdata, input wire mem_rsp_error,
    output wire [31:0] access_count, hit_count, miss_count,
    output wire [31:0] refill_word_count, error_count
);
cpu5_cache_adapter #(.ENABLE_ICACHE(1),.ENABLE_DCACHE(OTHER_CACHE),.ICACHE_SETS(SETS),.ICACHE_LINE_WORDS(LINE_WORDS),.IMEM_WORDS(MEM_WORDS)) u_adapter(
.clk(clk),
.rst_n(rst_n),
.cpu_imem_req_valid(req_valid),
.cpu_imem_req_ready(req_ready),
.cpu_imem_req_addr(req_addr),
.cpu_imem_rsp_valid(rsp_valid),
.cpu_imem_rsp_ready(rsp_ready),
.cpu_imem_rsp_rdata(rsp_rdata),
.cpu_imem_rsp_error(rsp_error),
.mem_imem_req_valid(mem_req_valid),
.mem_imem_req_ready(mem_req_ready),
.mem_imem_req_addr(mem_req_addr),
.mem_imem_rsp_valid(mem_rsp_valid),
.mem_imem_rsp_ready(mem_rsp_ready),
.mem_imem_rsp_rdata(mem_rsp_rdata),
.mem_imem_rsp_error(mem_rsp_error),
.icache_access_count(access_count),
.icache_hit_count(hit_count),
.icache_miss_count(miss_count),
.icache_refill_word_count(refill_word_count),
.icache_error_count(error_count),
.cpu_dmem_req_valid(1'b0),
.cpu_dmem_req_addr(32'd0),
.cpu_dmem_rsp_ready(1'b0),
.mem_dmem_req_ready(1'b0),
.mem_dmem_rsp_valid(1'b0),
.mem_dmem_rsp_rdata(32'd0),
.mem_dmem_rsp_error(1'b0),
.cpu_dmem_req_write(1'b0),
.cpu_dmem_req_size(2'd0),
.cpu_dmem_req_wdata(32'd0),
.cpu_dmem_req_wstrb(4'd0)
,
.cpu_dmem_req_ready(),
.cpu_dmem_rsp_valid(),
.cpu_dmem_rsp_rdata(),
.cpu_dmem_rsp_error(),
.mem_dmem_req_valid(),
.mem_dmem_req_write(),
.mem_dmem_req_addr(),
.mem_dmem_req_size(),
.mem_dmem_req_wdata(),
.mem_dmem_req_wstrb(),
.mem_dmem_rsp_ready(),
.dcache_access_count(),
.dcache_hit_count(),
.dcache_miss_count(),
.dcache_refill_word_count(),
.dcache_error_count(),
.dcache_write_count(),
.dcache_bypass_count());
endmodule
module cpu5_cache_data_case #(parameter integer WAIT_CYCLES=0,CASE_ID=0,COMPANION=0)(output reg done=0);
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
    cpu5_cache_data_path #(.OTHER_CACHE(COMPANION),.SETS(4),.LINE_WORDS(4),.MEM_WORDS(512),.BASE_ADDR(BASE)) dut(
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_size(req_size),.req_wdata(req_wdata),.req_wstrb(req_wstrb),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_rdata(rsp_data),.rsp_error(rsp_error),
        .mem_req_valid(mvalid),.mem_req_ready(mready),.mem_req_write(mwrite),.mem_req_addr(maddr),
        .mem_req_size(msize),.mem_req_wdata(mdata),.mem_req_wstrb(mstrobe),
        .mem_rsp_valid(mrsp_valid),.mem_rsp_ready(mrsp_ready),.mem_rsp_rdata(mrsp_data),.mem_rsp_error(mrsp_error),
        .access_count(accesses),.hit_count(hits),.miss_count(misses),.refill_word_count(words),
        .error_count(errors),.write_count(writes),.bypass_count(bypasses));

    integer ledger_requests=0,ledger_responses=0,ledger_reset_drops=0;
    integer front_requests=0,front_responses=0,front_reset_drops=0;
    reg ledger_pending=0,front_pending=0;
    integer summary_fd;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            if(ledger_pending)ledger_reset_drops=ledger_reset_drops+1;
            if(front_pending)front_reset_drops=front_reset_drops+1;
            ledger_pending=0;front_pending=0;
        end else begin
            if(mrsp_valid&&mrsp_ready)begin
                if(!ledger_pending)$fatal(1,"CPU5 adapter backend response without owner");
                ledger_pending=0;ledger_responses=ledger_responses+1;
            end
            if(mvalid&&mready)begin
                if(ledger_pending)$fatal(1,"CPU5 adapter backend owner overwritten");
                ledger_pending=1;ledger_requests=ledger_requests+1;
            end
            if(rsp_valid&&rsp_ready)begin
                if(!front_pending)$fatal(1,"CPU5 adapter front response without owner");
                front_pending=0;front_responses=front_responses+1;
            end
            if(req_valid&&req_ready)begin
                if(front_pending)$fatal(1,"CPU5 adapter front owner overwritten");
                front_pending=1;front_requests=front_requests+1;
            end
        end
    end
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

        if(ledger_requests!=ledger_responses+ledger_reset_drops||front_requests!=front_responses+front_reset_drops)
            $fatal(1,"CPU5 adapter ledger closure");
        summary_fd=$fopen($sformatf("build/cpu5_s13_cache_adapter/case%0d_summary.json",CASE_ID),"w");
        $fdisplay(summary_fd,"{\"status\":\"PASS\",\"case\":%0d,\"kind\":\"data\",\"checks\":%0d,\"backend_requests\":%0d,\"backend_responses\":%0d,\"backend_reset_drops\":%0d,\"front_requests\":%0d,\"front_responses\":%0d,\"front_reset_drops\":%0d}",CASE_ID,checks,ledger_requests,ledger_responses,ledger_reset_drops,front_requests,front_responses,front_reset_drops);
        $fclose(summary_fd);
        done=1;
    end
endmodule

module cpu5_cache_data_path #(
    parameter integer SETS=64, LINE_WORDS=4, MEM_WORDS=4096,
    parameter [31:0] BASE_ADDR=32'h00010000
, parameter integer OTHER_CACHE=0
) (
    input wire clk,rst_n,
    input wire req_valid, output wire req_ready,
    input wire req_write, input wire [31:0] req_addr,
    input wire [1:0] req_size, input wire [31:0] req_wdata,
    input wire [3:0] req_wstrb,
    output wire rsp_valid, input wire rsp_ready,
    output wire [31:0] rsp_rdata, output wire rsp_error,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire mem_req_write, output wire [31:0] mem_req_addr,
    output wire [1:0] mem_req_size, output wire [31:0] mem_req_wdata,
    output wire [3:0] mem_req_wstrb,
    input wire mem_rsp_valid, output wire mem_rsp_ready,
    input wire [31:0] mem_rsp_rdata, input wire mem_rsp_error,
    output wire [31:0] access_count,hit_count,miss_count,refill_word_count,
    output wire [31:0] error_count,write_count,bypass_count
);
cpu5_cache_adapter #(.ENABLE_ICACHE(OTHER_CACHE),.ENABLE_DCACHE(1),.DCACHE_SETS(SETS),.DCACHE_LINE_WORDS(LINE_WORDS),.DMEM_WORDS(MEM_WORDS),.DMEM_BASE_ADDR(BASE_ADDR)) u_adapter(
.clk(clk),
.rst_n(rst_n),
.cpu_dmem_req_valid(req_valid),
.cpu_dmem_req_ready(req_ready),
.cpu_dmem_req_addr(req_addr),
.cpu_dmem_rsp_valid(rsp_valid),
.cpu_dmem_rsp_ready(rsp_ready),
.cpu_dmem_rsp_rdata(rsp_rdata),
.cpu_dmem_rsp_error(rsp_error),
.mem_dmem_req_valid(mem_req_valid),
.mem_dmem_req_ready(mem_req_ready),
.mem_dmem_req_addr(mem_req_addr),
.mem_dmem_rsp_valid(mem_rsp_valid),
.mem_dmem_rsp_ready(mem_rsp_ready),
.mem_dmem_rsp_rdata(mem_rsp_rdata),
.mem_dmem_rsp_error(mem_rsp_error),
.dcache_access_count(access_count),
.dcache_hit_count(hit_count),
.dcache_miss_count(miss_count),
.dcache_refill_word_count(refill_word_count),
.dcache_error_count(error_count),
.cpu_dmem_req_write(req_write),
.cpu_dmem_req_size(req_size),
.cpu_dmem_req_wdata(req_wdata),
.cpu_dmem_req_wstrb(req_wstrb),
.mem_dmem_req_write(mem_req_write),
.mem_dmem_req_size(mem_req_size),
.mem_dmem_req_wdata(mem_req_wdata),
.mem_dmem_req_wstrb(mem_req_wstrb),
.dcache_write_count(write_count),
.dcache_bypass_count(bypass_count),
.cpu_imem_req_valid(1'b0),
.cpu_imem_req_addr(32'd0),
.cpu_imem_rsp_ready(1'b0),
.mem_imem_req_ready(1'b0),
.mem_imem_rsp_valid(1'b0),
.mem_imem_rsp_rdata(32'd0),
.mem_imem_rsp_error(1'b0)
,
.cpu_imem_req_ready(),
.cpu_imem_rsp_valid(),
.cpu_imem_rsp_rdata(),
.cpu_imem_rsp_error(),
.mem_imem_req_valid(),
.mem_imem_req_addr(),
.mem_imem_rsp_ready(),
.icache_access_count(),
.icache_hit_count(),
.icache_miss_count(),
.icache_refill_word_count(),
.icache_error_count());
endmodule
