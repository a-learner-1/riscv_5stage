`timescale 1ns/1ps
// The same CPU instruction stream exercises local RAM, external RAM and
// blocking D-cache with and without endpoint waits. Absolute clocks may move
// after an MMIO change; each non-MMIO transaction's relative timings must not.
module mmio_stage_latency_tb;
    wire [5:0] done;
    reg test_pass=0;
    mmio_stage_latency_case #(.ID(0),.LOCAL(1)) local_fast(done[0]);
    mmio_stage_latency_case #(.ID(1),.LOCAL(1),.DELAYED(1)) local_wait(done[1]);
    mmio_stage_latency_case #(.ID(2)) external_fast(done[2]);
    mmio_stage_latency_case #(.ID(3),.DELAYED(1)) external_wait(done[3]);
    mmio_stage_latency_case #(.ID(4),.CACHE(1)) cache_fast(done[4]);
    mmio_stage_latency_case #(.ID(5),.CACHE(1),.DELAYED(1)) cache_wait(done[5]);
    initial begin wait(&done);test_pass=1;$display("MMIO STAGE LATENCY TESTS PASS: six CPU/local/external/cache fixtures, loads/stores/subwords and interleaved MMIO");$stop;end
    initial begin #1000000;$fatal(1,"MMIO stage latency timeout done=%b",done);end
endmodule

module mmio_stage_latency_case #(parameter integer ID=0,LOCAL=0,CACHE=0,DELAYED=0)(output reg done=0);
    localparam [31:0] BASE=32'h00010000;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] pc,insn,wb_pc,wb_data;
    wire [4:0] wb_rd;
    wire wb_we,retire,ifault,dfault;
    wire iqv,iqr,ipr,cv,cr,cw,sv,sr,se;
    wire [31:0] iqa,ca,cd,sd;
    wire [1:0] cz;
    wire [3:0] cs;
    reg ipv=0;reg [31:0] ipd=0;
    reg [31:0] rom[0:127],memory[0:127];
    wire bqv,bqr,bqw,bsv,bsr,bse;
    wire [31:0] bqa,bqd,bsd;
    wire [1:0] bqz;wire [3:0] bqs;
    reg pending=0,response_valid=0,pwrite=0;
    reg [31:0] paddr=0,pdata=0,response_data=0;
    reg [3:0] pstrobe=0;
    integer request_wait=0,response_wait=0,lane,i;
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),
        .DMEM_WORDS(128),.DMEM_BASE_ADDR(BASE),.EXTERNAL_IMEM(1),.EXTERNAL_DMEM(!LOCAL),
        .DMEM_REQ_WAIT_CYCLES(LOCAL&&DELAYED?3:0),.DMEM_RSP_WAIT_CYCLES(LOCAL&&DELAYED?4:0),
        .SIM_CONSOLE_ECHO(0)) cpu(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),.gpio_in(8'h3c),.gpio_out(),.gpio_oe(),
        .pc_x(pc),.instr_x(insn),.valid_x(),.wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),
        .wb_we(wb_we),.retire_valid(retire),.cycle_count(),.instret_count(),
        .imem_req_valid(iqv),.imem_req_ready(iqr),.imem_req_addr(iqa),
        .imem_rsp_valid(ipv),.imem_rsp_ready(ipr),.imem_rsp_rdata(ipd),.imem_rsp_error(1'b0),
        .imem_fault(ifault),.imem_fault_pc(),.dmem_req_valid(cv),.dmem_req_ready(cr),
        .dmem_req_write(cw),.dmem_req_addr(ca),.dmem_req_size(cz),.dmem_req_wdata(cd),.dmem_req_wstrb(cs),
        .dmem_rsp_valid(sv),.dmem_rsp_ready(sr),.dmem_rsp_rdata(sd),.dmem_rsp_error(se),.dmem_fault(dfault),
        .trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.irq_external(1'b0),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),
        .bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());
    assign iqr=rst_n&&(!ipv||ipr);
    always @(posedge clk) begin
        if(!rst_n) begin ipv<=0;ipd<=0;end
        else begin
            if(ipv&&ipr) ipv<=0;
            if(iqv&&iqr) begin
                if(iqa[1:0]||iqa>=512) $fatal(1,"Latency fixture bad instruction address");
                ipv<=1;ipd<=rom[iqa>>2];
            end
        end
    end
    generate if(CACHE) begin: cached
        data_cache #(.SETS(4),.LINE_WORDS(4),.MEM_WORDS(128),.BASE_ADDR(BASE)) cache(
            .clk(clk),.rst_n(rst_n),.req_valid(cv),.req_ready(cr),.req_write(cw),.req_addr(ca),
            .req_size(cz),.req_wdata(cd),.req_wstrb(cs),.rsp_valid(sv),.rsp_ready(sr),.rsp_rdata(sd),.rsp_error(se),
            .mem_req_valid(bqv),.mem_req_ready(bqr),.mem_req_write(bqw),.mem_req_addr(bqa),
            .mem_req_size(bqz),.mem_req_wdata(bqd),.mem_req_wstrb(bqs),.mem_rsp_valid(bsv),
            .mem_rsp_ready(bsr),.mem_rsp_rdata(bsd),.mem_rsp_error(bse),.access_count(),.hit_count(),
            .miss_count(),.refill_word_count(),.error_count(),.write_count(),.bypass_count());
    end else begin: direct
        assign bqv=cv,bqw=cw,bqa=ca,bqz=cz,bqd=cd,bqs=cs;
        assign cr=bqr,sv=bsv,sd=bsd,se=bse,bsr=sr;
    end endgenerate
    assign bqr=rst_n&&!pending&&!response_valid&&(!DELAYED||request_wait>=2);
    assign bsv=rst_n&&response_valid,bsd=response_data,bse=1'b0;
    always @(posedge clk) begin
        if(!rst_n) begin pending<=0;response_valid<=0;request_wait<=0;response_wait<=0;end
        else begin
            if(bqv&&!bqr) request_wait<=request_wait+1;else request_wait<=0;
            if(response_valid&&bsr) response_valid<=0;
            if(bqv&&bqr) begin
                if(bqa<BASE||bqa>=BASE+512) $fatal(1,"Latency fixture MMIO leaked to backend");
                pending<=1;paddr<=bqa;pdata<=bqd;pstrobe<=bqs;pwrite<=bqw;response_wait<=DELAYED?3:0;
            end
            if(pending) begin
                if(response_wait>0) response_wait<=response_wait-1;
                else begin
                    pending<=0;response_valid<=1;response_data<=pwrite?0:memory[(paddr-BASE)/4];
                    if(pwrite) for(lane=0;lane<4;lane=lane+1)
                        if(pstrobe[lane]) memory[(paddr-BASE)/4][lane*8+:8]<=pdata[lane*8+:8];
                end
            end
        end
    end
    function [31:0] it(input integer imm,input [4:0] rs1,input [2:0] f3,input [4:0] rd,input [6:0] op);
        it={imm[11:0],rs1,f3,rd,op};
    endfunction
    function [31:0] st(input integer imm,input [4:0] rs2,input [4:0] rs1,input [2:0] f3);
        st={imm[11:5],rs2,rs1,f3,imm[4:0],7'h23};
    endfunction
    integer cycle=0,fd,transactions=0,gpio_writes=0,start=-1,accept=-1,response=-1;
    reg active=0;reg [31:0] tpc,taddr,tdata,trsp;
    reg [1:0] tsize;reg [3:0] tstrb;reg twrite,tmmio;
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst_n&&!done) begin
            if(ifault||dfault) $fatal(1,"Latency fixture unexpected CPU fault id=%0d pc=%h",ID,pc);
            if(cpu.mmio_gpio_write_x) gpio_writes=gpio_writes+1;
            if(cpu.mem_start_x) begin
                if(active) $fatal(1,"Latency fixture overlapped data instructions");
                active=1;start=cycle;accept=-1;response=-1;tpc=pc;taddr=cpu.mem_addr_x;
                tdata=cpu.mem_wdata_x;tsize=cpu.mem_size_x;tstrb=cpu.mem_wstrb_x;
                twrite=cpu.mem_req_write;tmmio=cpu.mem_req_mmio;
            end
            if(cpu.mem_req_fire) begin
                if(!active||accept>=0||{cpu.mem_addr_x,cpu.mem_wdata_x,cpu.mem_size_x,cpu.mem_wstrb_x,cpu.mem_req_write,cpu.mem_req_mmio}!==
                    {taddr,tdata,tsize,tstrb,twrite,tmmio}) $fatal(1,"Latency descriptor changed before acceptance");
                accept=cycle;
            end
            if(cpu.mem_rsp_fire) begin
                if(!active||accept<0||response>=0||cpu.mem_rsp_error) $fatal(1,"Latency response ownership failed");
                response=cycle;trsp=cpu.mem_rsp_rdata;
            end
        end
        #1;
        if(rst_n&&!done&&retire) begin
            if(active&&wb_pc==tpc) begin
                if(response<0) $fatal(1,"Latency instruction retired before response");
                transactions=transactions+1;
                $fwrite(fd,"%0d,%0d,%08h,%08h,%0d,%0d,%0d,%h,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h\n",
                    ID,transactions,tpc,taddr,tmmio,twrite,tsize,tstrb,tdata,start,accept,response,cycle,
                    accept-start,response-accept,cycle-response,cycle-start,trsp);
                active=0;
            end
            case(wb_pc)
                12:if(!wb_we||wb_rd!=3||wb_data!==32'h123) $fatal(1,"Latency LW readback");
                24:if(!wb_we||wb_rd!=4||wb_data!==32'h7e23) $fatal(1,"Latency LHU readback");
                36:if(!wb_we||wb_rd!=6||wb_data!==32'h7e) $fatal(1,"Latency GPIO readback");
                48,68:if(!wb_we||wb_data!==32'h04567e23) $fatal(1,"Latency updated line readback");
                52,56,72:if(!wb_we||wb_data!==0) $fatal(1,"Latency cold/hit/adjacent zero readback");
                64,80:if(!wb_we||wb_data!==32'h456) $fatal(1,"Latency cold-write/adjacent readback");
                84:begin
                    if(active||transactions!=16||gpio_writes!=1||!wb_we||wb_rd!=31||wb_data!==1)
                        $fatal(1,"Latency fixture completion ledger id=%0d transactions=%0d gpio=%0d",ID,transactions,gpio_writes);
                    $fclose(fd);done=1;$display("MMIO STAGE LATENCY CASE %0d PASS local=%0d cache=%0d waits=%0d transactions=16",ID,LOCAL,CACHE,DELAYED);
                end
            endcase
        end
    end
    initial begin
        fd=$fopen($sformatf("build/verification/mmio_stage_latency_case_%0d.csv",ID),"w");
        if(!fd) $fatal(1,"Create build/verification before latency simulation");
        $fwrite(fd,"case_id,transaction,pc,addr,is_mmio,is_write,size,wstrb,wdata,launch,accept,response,retire,launch_to_accept,accept_to_response,response_to_retire,total_cycles,rdata\n");
        for(i=0;i<128;i=i+1) begin rom[i]=32'h00000013;memory[i]=0;end
        rom[0]={20'h00010,5'd1,7'h37};rom[1]=it('h123,0,0,2,'h13);
        rom[2]=st(0,2,1,2);rom[3]=it(0,1,2,3,3);
        rom[4]=it('h7e,0,0,2,'h13);rom[5]=st(1,2,1,0);rom[6]=it(0,1,5,4,3);
        rom[7]={20'h20000,5'd5,7'h37};rom[8]=st('h20,2,5,2);rom[9]=it('h20,5,2,6,3);
        rom[10]=it('h456,0,0,2,'h13);rom[11]=st(2,2,1,1);rom[12]=it(0,1,2,7,3);
        rom[13]=it(16,1,2,8,3);rom[14]=it(16,1,2,9,3);rom[15]=st(32,2,1,2);
        rom[16]=it(32,1,2,10,3);rom[17]=it(0,1,2,11,3);rom[18]=it(4,1,2,12,3);
        rom[19]=st(4,2,1,2);rom[20]=it(4,1,2,13,3);rom[21]=it(1,0,0,31,'h13);
        rom[22]=32'h0000006f;
        repeat(4) @(negedge clk);rst_n=1;
    end
endmodule
