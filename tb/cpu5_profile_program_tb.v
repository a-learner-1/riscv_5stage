`timescale 1ns/1ps
module cpu5_profile_program_tb #(parameter CACHE_GROUP=0);
    wire [15:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<16;n=n+1)begin:g_cases
        cpu5_profile_program_case #(.CASE_ID(CACHE_GROUP*16+n),.ID_MODE(n%2),.PRED((n/2)%2),.WAIT((n/4)%2),.FORWARD((n/8)%2),.ICACHE((CACHE_GROUP%4)%2),.DCACHE((CACHE_GROUP%4)/2),.AXI_MODE((CACHE_GROUP%12)/4),.D0(CACHE_GROUP/12)) u(.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 PROFILE PROGRAM PASS: one of twenty-four 16-case groups, real AXI RAM, cached ordering, prioritized IRQs, illegal FENCE.I");$stop;end
    initial begin #1600000;$fatal(1,"CPU5 AXI program timeout done=%h",done);end
endmodule

`define CORE dut.u_cached.u_cpu.g_alu.u_pipeline
`define EP dut.u_cached.u_cpu.g_machine.u_router.u_normal.u_endpoint
`define MEP dut.u_cached.u_cpu.g_machine.u_router.u_machine_endpoint
module cpu5_profile_program_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,FORWARD=0,ICACHE=0,DCACHE=0,AXI_MODE=0,D0=0,
    parameter BASE="build/cpu5_s16_profile_program"
)(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    reg rx=1,started=0,quiesce=0,raw=0,raise_irq=0;
    wire tx,qv,qr,sv,sr,dqv,dqr,dqw,dsv,dsr,rv,we,tf;
    wire [31:0] qa,dqa,dqd,wpc,wdata,tpc,tc,tv;wire [4:0] wrd;wire [1:0] dz;wire [3:0] dst;
    wire [7:0] gout,goe;wire [63:0] cc,ic;
    reg ipending=0,dpending=0;reg [31:0] iaddr=0;wire [31:0] drdata;
    integer idelay=0,ddelay=0,cycles=0,iq=0,ir=0,eq=0,er=0,cq=0,cr=0;
    integer events=0,retired=0,wb=0,irqs=0,traps=0,accepted=0,device_effects=0,timer_writes=0,software_writes=0,normal_effects=0,gpio_writes=0;
    integer drain=0,i,j,k,fd_event,fd_accept,fd_wb,fd_if,fd_d,fd_ext,fd_local,fd_cycle,fd_fence,fd_final,fd_metrics,fd_backend,fd_frontif,fd_cache,fd_axi,fd_route,fd_axi_native,fd_profile,fd_stats;
    integer enable_first_cycle=0,enable_priority_cycle=0,last_mret_cycle=0,priority_set_cycle=0;
    reg [31:0] rom[0:255],fixture[0:5];
    reg [63:0] cseq=0,eseq=0,last_present_seq=64'hffffffffffffffff;
    reg [31:0] cpc=0,caddr=0,cdata=0,epc=0,eaddr=0,edata=0;
    reg [3:0] cst=0,est=0;reg [1:0] csize=0,esize=0;reg cw=0,ew=0;
    reg [63:0] pre_seq,old_ic;reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,pre_tval;
    reg fire_retire,fire_irq,fire_trap;
    reg [63:0] retire_seqs[0:511];reg [31:0] retire_pcs[0:511],retire_ins[0:511],retire_rds[0:511],retire_vals[0:511],retire_writes[0:511],retire_nexts[0:511];
    reg iheld=0,dheld=0,rheld=0;reg [31:0] held_i;reg [70:0] held_d;reg [32:0] held_r;
    reg front_ipending=0;reg [31:0] front_iaddr=0;integer front_iq=0,front_ir=0,front_icancel=0,front_dq=0,front_dr=0;
    wire [31:0] ia,ih,im,ifill,ie,da,dh,dm,dfill,de,dw,db;
    wire [9:0] profile_events;
    reg stats_arvalid=0,stats_rready=0,profile_reader_done=0;
    reg [31:0] stats_araddr=0;
    wire stats_arready,stats_rvalid;wire [31:0] stats_rdata;wire [1:0] stats_rresp;
    integer profile_word;
    axi_lite_cpu5_stats #(.ENABLE_ICACHE(ICACHE),.ENABLE_DCACHE(DCACHE),.ENABLE_BRANCH_PRED(PRED),
        .BTB_ENTRIES(64),.ICACHE_SETS(2),.DCACHE_SETS(2),.DATA_BACKEND_ID(D0)) u_stats(
        .clk(clk),.rst_n(rst_n),.cycle_count(cc),.instret_count(ic),.perf_cycle_events(profile_events),
        .icache_access_count(ia),.icache_hit_count(ih),.icache_miss_count(im),.icache_refill_word_count(ifill),.icache_error_count(ie),
        .dcache_access_count(da),.dcache_hit_count(dh),.dcache_miss_count(dm),.dcache_refill_word_count(dfill),.dcache_error_count(de),.dcache_write_count(dw),.dcache_bypass_count(db),
        .bp_lookup_count(dut.u_cached.u_cpu.bp_lookup_count),.bp_hit_count(dut.u_cached.u_cpu.bp_hit_count),.bp_taken_count(dut.u_cached.u_cpu.bp_taken_count),
        .bp_resolved_count(dut.u_cached.u_cpu.bp_resolved_count),.bp_mispredict_count(dut.u_cached.u_cpu.bp_mispredict_count),
        .bp_direction_error_count(dut.u_cached.u_cpu.bp_direction_error_count),.bp_target_error_count(dut.u_cached.u_cpu.bp_target_error_count),
        .s_axi_awaddr(32'd0),.s_axi_awprot(3'd0),.s_axi_awvalid(1'b0),.s_axi_awready(),
        .s_axi_wdata(32'd0),.s_axi_wstrb(4'd0),.s_axi_wvalid(1'b0),.s_axi_wready(),
        .s_axi_bresp(),.s_axi_bvalid(),.s_axi_bready(1'b1),
        .s_axi_araddr(stats_araddr),.s_axi_arprot(3'd0),.s_axi_arvalid(stats_arvalid),.s_axi_arready(stats_arready),
        .s_axi_rdata(stats_rdata),.s_axi_rresp(stats_rresp),.s_axi_rvalid(stats_rvalid),.s_axi_rready(stats_rready));
    // A separate AXI observation master isolates snapshot timing from the
    // unchanged architectural workload. CPU-issued Stats reads are tested in
    // the separate system smoke, not claimed by this matrix.
    task read_profile_word(input [31:0] offset);
        reg [31:0] held_value;reg [1:0] held_response;
        begin
            @(negedge clk);stats_araddr=32'h30000000+offset;stats_arvalid=1;stats_rready=0;
            while(!stats_arready)@(negedge clk);
            @(posedge clk);#2;
            if(!stats_rvalid||stats_rresp!==0)$fatal(1,"CPU5 profile observation read failed case=%0d offset=%h",CASE_ID,offset);
            held_value=stats_rdata;held_response=stats_rresp;
            @(negedge clk);stats_arvalid=0;
            repeat(2)begin @(negedge clk);if(!stats_rvalid||stats_rdata!==held_value||stats_rresp!==held_response)$fatal(1,"CPU5 profile snapshot response hold");end
            stats_rready=1;@(negedge clk);stats_rready=0;
        end
    endtask
    initial begin
        wait(started);repeat(4)@(negedge clk);read_profile_word(0);
        wait(`CORE.ram_owner_valid && `CORE.ram_owner_state!=3);read_profile_word(0);
        wait(quiesce);read_profile_word(4);
        read_profile_word('h18);
        for(profile_word=0;profile_word<4;profile_word=profile_word+1)begin
            read_profile_word('h40+profile_word*4);read_profile_word('h80+profile_word*4);
        end
        for(profile_word=0;profile_word<10;profile_word=profile_word+1)begin
            read_profile_word((profile_word<6?'h100:'h180)+(profile_word<6?profile_word:profile_word-6)*8);
            read_profile_word((profile_word<6?'h104:'h184)+(profile_word<6?profile_word:profile_word-6)*8);
            read_profile_word((profile_word<6?'h140:'h1c0)+(profile_word<6?profile_word:profile_word-6)*8);
            read_profile_word((profile_word<6?'h144:'h1c4)+(profile_word<6?profile_word:profile_word-6)*8);
        end
        repeat(7)@(negedge clk);
        read_profile_word('h40);read_profile_word('h80);read_profile_word('h100);read_profile_word('h140);
        read_profile_word('h180);read_profile_word('h1c0);read_profile_word('h19c);read_profile_word('h1dc);
        profile_reader_done=1;
    end
    reg apending=0;reg [63:0] aseq=0;reg [31:0] apc=0,aaddr=0,adata=0;reg [3:0] ast=0;reg [1:0] asize=0;reg awrite=0;
    wire lqv,lqr,lwrite,lsv,lsr,lerror,lwe,lre;wire [31:0] laddr,lwdata,lrdata;wire [1:0] lsize;wire [3:0] lwstrb;
    wire [31:0] ram_snapshot[0:63];genvar rindex;
    generate if(D0)begin:g_local_observe
        assign lqv=dut.u_backend.g_d0.ram_req_valid;assign lqr=dut.u_backend.g_d0.ram_req_ready;
        assign lwrite=dut.u_backend.g_d0.ram_req_write;assign laddr=dut.u_backend.g_d0.ram_req_addr;
        assign lsize=dut.u_backend.g_d0.ram_req_size;assign lwdata=dut.u_backend.g_d0.ram_req_wdata;assign lwstrb=dut.u_backend.g_d0.ram_req_wstrb;
        assign lsv=dut.u_backend.g_d0.ram_rsp_valid;assign lsr=dut.u_backend.g_d0.ram_rsp_ready;
        assign lrdata=dut.u_backend.g_d0.ram_rsp_rdata;assign lerror=dut.u_backend.g_d0.ram_rsp_error;
        assign lwe=dut.u_backend.g_d0.u_ram.mem_we;assign lre=dut.u_backend.g_d0.u_ram.mem_re;
        for(rindex=0;rindex<64;rindex=rindex+1)begin:g_words
            assign ram_snapshot[rindex]=dut.u_backend.g_d0.u_ram.u_data_mem.mem[rindex];
        end
    end else begin:g_external_observe
        assign lqv=0;assign lqr=0;assign lwrite=0;assign laddr=0;assign lsize=0;assign lwdata=0;assign lwstrb=0;
        assign lsv=0;assign lsr=0;assign lrdata=0;assign lerror=0;assign lwe=0;assign lre=0;
        for(rindex=0;rindex<64;rindex=rindex+1)begin:g_words
            assign ram_snapshot[rindex]=u_ram.u_data_mem.mem[rindex];
        end
    end endgenerate
    string directory;
    assign qr=rst_n&&started&&!quiesce&&(!ipending||(sv&&sr))&&(!WAIT||cycles%7>=2);
    assign sv=ipending&&idelay==0;
    wire [31:0] awaddr,axi_wdata,araddr,rdata;wire [3:0] wstrb;wire [2:0] awprot,arprot;
    wire awvalid,awready,wvalid,wready,bvalid,bready,arvalid,arready,rvalid,rready;wire [1:0] bresp,rresp;
    assign dqv=dut.native_dmem_req_valid;assign dqr=dut.native_dmem_req_ready;
    assign dqw=dut.native_dmem_req_write;assign dqa=dut.native_dmem_req_addr;assign dz=dut.native_dmem_req_size;
    assign dqd=dut.native_dmem_req_wdata;assign dst=dut.native_dmem_req_wstrb;
    assign dsv=dut.native_dmem_rsp_valid;assign dsr=dut.native_dmem_rsp_ready;assign drdata=dut.native_dmem_rsp_rdata;
    wire [31:0] status=`CORE.g_csr.u_csr.csr_mstatus,mtvec=`CORE.g_csr.u_csr.csr_mtvec;
    wire [31:0] scratch=`CORE.g_csr.u_csr.csr_mscratch,mepc=`CORE.g_csr.u_csr.csr_mepc;
    wire [31:0] mcause=`CORE.g_csr.u_csr.csr_mcause,mtval=`CORE.g_csr.u_csr.csr_mtval,mie=`CORE.g_csr.u_csr.csr_mie;
    cpu5_d0_axi_lite_top #(.ENABLE_D0_BRAM(D0),.D0_REQ_WAIT_CYCLES(WAIT?2:0),.D0_RSP_WAIT_CYCLES(WAIT?3:0),.DATA_FILE({BASE,"/ram_initial.hex"}),.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(64),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(FORWARD),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),.ENABLE_MMIO(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.ENABLE_EXTERNAL_IRQ(1),
        .ENABLE_TIMER_IRQ(1),.ENABLE_SOFTWARE_IRQ(1),.ENABLE_TIMER_DEVICE(1),.ENABLE_SOFTWARE_DEVICE(1),
        .ENABLE_FENCE(1),.ENABLE_ICACHE(ICACHE),.ENABLE_DCACHE(DCACHE),.ICACHE_SETS(2),.DCACHE_SETS(2),.ENABLE_BRANCH_PRED(PRED),.BRANCH_RESOLVE_IN_ID(ID_MODE),.UART_CLOCK_HZ(1000000),.UART_BAUD(250000)) dut(
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(rv),.cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(rx),.gpio_in(8'ha5),.gpio_out(gout),.gpio_oe(goe),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(axi_wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready),.dmem_fault(),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),.imem_rsp_valid(sv),.imem_rsp_ready(sr),
        .imem_rsp_rdata(rom[iaddr>>2]),.imem_rsp_error(1'b0),.imem_fault(),.imem_fault_pc(),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .icache_access_count(ia),.icache_hit_count(ih),.icache_miss_count(im),.icache_refill_word_count(ifill),.icache_error_count(ie),
        .dcache_access_count(da),.dcache_hit_count(dh),.dcache_miss_count(dm),.dcache_refill_word_count(dfill),.dcache_error_count(de),.dcache_write_count(dw),.dcache_bypass_count(db),
        .irq_external(raw),.irq_software(1'b0),.irq_timer(1'b0),.perf_cycle_events(profile_events));
    axi_lite_ram #(.WORDS(64),.BASE_ADDR(32'h10000),.INIT_FILE({BASE,"/ram_initial.hex"}),
        .AW_WAIT_CYCLES(AXI_MODE==2?3:0),.W_WAIT_CYCLES(AXI_MODE==1?3:0),
        .AR_WAIT_CYCLES(WAIT?3:0),.B_WAIT_CYCLES(WAIT?4:0),.R_WAIT_CYCLES(WAIT?6:0)) u_ram(
        .clk(clk),.rst_n(rst_n),.s_axi_awaddr(awaddr),.s_axi_awprot(awprot),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(axi_wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
    initial begin
        $readmemh({BASE,"/program.hex"},rom,0,255);$readmemh({BASE,"/fixture.hex"},fixture,0,5);
        directory=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_event=$fopen({directory,"/events.csv"},"w");fd_accept=$fopen({directory,"/accept.csv"},"w");fd_wb=$fopen({directory,"/wb.csv"},"w");
        fd_if=$fopen({directory,"/if.csv"},"w");fd_d=$fopen({directory,"/d.csv"},"w");fd_ext=$fopen({directory,"/external.csv"},"w");
        fd_backend=$fopen({directory,"/backend.csv"},"w");fd_frontif=$fopen({directory,"/front_if.csv"},"w");
        fd_axi=$fopen({directory,"/axi.csv"},"w");
        fd_profile=$fopen({directory,"/profile.csv"},"w");fd_stats=$fopen({directory,"/stats.csv"},"w");
        $fwrite(fd_stats,"cycle,arvalid,arready,araddr,rvalid,rready,rdata,rresp\n");
        $fwrite(fd_profile,"cycle,count_pre,events_pre,id_valid,id_instr,id_seq,id_error,ex_valid,ex_instr,ex_seq,ex_error,mem_valid,mem_instr,mem_seq,mem_addr,mem_error,mem_ready,wb_valid,wb_instr,wb_seq,id_enable,ex_enable,mem_enable,wb_ready,flush,flush_fire,kill_id,kill_ex,kill_mem,mem_fault,trap,mret,irq,redirect,id_move,id_ready,ex_move,retire,d_valid,d_seq,d_state,d_killed,d_store,d_addr,d_complete,d_complete_seq,d_complete_killed,d_complete_error,d_complete_addr,d_rsp_valid,d_rsp_error,d_issue,m_valid,m_seq,m_killed,m_state,m_done,m_complete,m_complete_seq,m_complete_killed,m_issue,m_op,id_raw,ex_stall,ex_ram_fault,ex_ram_out,ex_addr,ex_target_fault,known_ex_fault,csr_serial,branch_stall,count_post,events_post\n");
        fd_route=$fopen({directory,"/route.csv"},"w");fd_axi_native=$fopen({directory,"/axi_native.csv"},"w");
        $fwrite(fd_route,"cycle,qv,qr,write,addr,size,wdata,wstrb,sv,sr,rdata,error,local_qv,local_qr,local_write,local_addr,local_size,local_wdata,local_wstrb,local_sv,local_sr,local_rdata,local_error,local_we,local_re\n");
        $fwrite(fd_axi_native,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
        $fwrite(fd_axi,"cycle,awvalid,awready,awaddr,awprot,wvalid,wready,wdata,wstrb,bvalid,bready,bresp,arvalid,arready,araddr,arprot,rvalid,rready,rdata,rresp,commit,commitaddr,commitdata,commitstrb,physical_we\n");
        fd_fence=$fopen({directory,"/fence.csv"},"w");
        fd_local=$fopen({directory,"/local.csv"},"w");fd_cycle=$fopen({directory,"/cycles.csv"},"w");
        if(!fd_event||!fd_accept||!fd_wb||!fd_if||!fd_d||!fd_ext||!fd_local||!fd_cycle||!fd_fence)$fatal(1,"AXI program log open");
        $fwrite(fd_event,"kind,cycle,index,seq,pc,instr,rd,value,writes,nextpc,cause,tval,mstatus,mtvec,mscratch,mepc,mcause,mtval,mie,instret\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");$fwrite(fd_wb,"cycle,index,seq,pc,instr,rd,value,writes,nextpc\n");$fwrite(fd_if,"event,cycle,addr\n");
        $fwrite(fd_d,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");$fwrite(fd_ext,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
        $fwrite(fd_local,"target,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error,timer_write,software_write,gpio\n");
        $fwrite(fd_cycle,"cycle,raw,device_timer,device_software,pending,arm,eligible,take,mstatus,mie,mtime_lo,mtime_hi,cmp_lo,cmp_hi,msip\n");
        $fwrite(fd_backend,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
        $fwrite(fd_frontif,"event,cycle,addr,rdata,error\n");
        $fwrite(fd_fence,"cycle,mem_valid,mem_fence,mem_pc,mem_seq,owner_valid,owner_killed,owner_state,ex_valid,ex_pc,ex_move,d_issue,m_issue,retire,wb,if_pending\n");
        repeat(4)@(negedge clk);rst_n=1;
        repeat(4)@(negedge clk);started=1;
    end
    always @(negedge clk)if(rst_n)begin
        if(raise_irq)begin raw=1;raise_irq=0;end
    end
    task dtrace(input integer fd,input string action,input [63:0] seq,input [31:0] pc,addr,data,input [3:0] st,input [1:0] size,input wr,input [31:0] result,input error);
        $fwrite(fd,"%s,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,%0d\n",action,cycles,seq,pc,addr,data,st,size,wr,result,error);
    endtask
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        $fwrite(fd_profile,"%0d,%016h,%03h,%0d,%08h,%016h,%0d,%0d,%08h,%016h,%0d,%0d,%08h,%016h,%08h,%0d,%0d,%0d,%08h,%016h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%016h,%0d,%0d,%0d,%08h,%0d,%016h,%0d,%0d,%08h,%0d,%0d,%0d,%0d,%016h,%0d,%0d,%0d,%0d,%016h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%0d,",cycles,cc,profile_events,`CORE.in_valid,`CORE.in_valid?`CORE.in_instr:0,`CORE.in_valid?`CORE.in_seq:0,`CORE.in_fetch_error,`CORE.idex_valid_q,`CORE.idex_valid_q?`CORE.idex_q.instr:0,`CORE.idex_q.seq,`CORE.idex_q.exception_valid,`CORE.exmem_valid_q,`CORE.exmem_valid_q?`CORE.exmem_q.instr:0,`CORE.exmem_q.seq,`CORE.exmem_q.mem_addr,`CORE.exmem_q.exception_valid,`CORE.mem_result_ready,`CORE.memwb_valid_q,`CORE.memwb_q.instr,`CORE.memwb_q.seq,`CORE.id_enable,`CORE.ex_enable,`CORE.mem_enable,`CORE.wb_ready,`CORE.flush_valid,`CORE.flush_fire,`CORE.kill_input,`CORE.kill_ex,`CORE.kill_mem,`CORE.mem_fault,`CORE.trap_fire,`CORE.mret_fire,`CORE.irq_take,`CORE.redirect_valid,`CORE.id_move,`CORE.in_ready,`CORE.ex_move,`CORE.retire_fire,`CORE.ram_owner_valid,`CORE.ram_owner_seq,`CORE.ram_owner_state,`CORE.ram_owner_killed,`CORE.ram_owner_store,`CORE.g_ram.u_owner.addr_q,`CORE.ram_completion_valid,`CORE.ram_completion_seq,`CORE.ram_completion_killed,`CORE.ram_completion_error,`CORE.ram_completion_addr,dut.u_cached.u_cpu.core_drsp_valid,dut.u_cached.u_cpu.core_drsp_error,`CORE.ram_issue_fire,`CORE.m_owner_valid,`CORE.m_owner_seq,`CORE.m_owner_killed,`CORE.g_m.u_owner.state_q,`CORE.m_unit_done,`CORE.m_completion_valid,`CORE.m_completion_seq,`CORE.m_completion_killed,`CORE.m_issue_fire,`CORE.m_completion_op,`CORE.id_raw_wait,`CORE.ex_source_stall,`CORE.ex_ram_fault,`CORE.ram_ex_out_of_range,`CORE.ram_ex_addr,`CORE.ex_target_fault,`CORE.known_ex_fault,`CORE.csr_serial_wait,`CORE.id_branch_stall);
        $fwrite(fd_stats,"%0d,%0d,%0d,%08h,%0d,%0d,%08h,%0d\n",cycles,stats_arvalid,stats_arready,stats_araddr,stats_rvalid,stats_rready,stats_rdata,stats_rresp);
        $fwrite(fd_axi,"%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%01h,%0d,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%0d,%0d,%08h,%08h,%01h,%0d\n",cycles,awvalid,awready,awaddr,awprot,wvalid,wready,axi_wdata,wstrb,bvalid,bready,bresp,arvalid,arready,araddr,arprot,rvalid,rready,rdata,rresp,u_ram.write_commit,u_ram.awaddr_q,u_ram.wdata_q,u_ram.wstrb_q,u_ram.u_data_mem.we);
        $fwrite(fd_route,"%0d,%0d,%0d,%0d,%08h,%0d,%08h,%01h,%0d,%0d,%08h,%0d,%0d,%0d,%0d,%08h,%0d,%08h,%01h,%0d,%0d,%08h,%0d,%0d,%0d\n",cycles,dqv,dqr,dqv?dqw:0,dqv?dqa:0,dqv?dz:0,dqv?dqd:0,dqv?dst:0,dsv,dsr,dsv?drdata:0,dsv?dut.native_dmem_rsp_error:0,lqv,lqr,lqv?lwrite:0,lqv?laddr:0,lqv?lsize:0,lqv?lwdata:0,lqv?lwstrb:0,lsv,lsr,lsv?lrdata:0,lsv?lerror:0,lwe,lre);
        if(dut.u_backend.axi_rsp_valid&&dut.u_backend.axi_rsp_ready)begin
            if(!apending)$fatal(1,"D0 AXI native response without owner");
            dtrace(fd_axi_native,"rsp",aseq,apc,aaddr,adata,ast,asize,awrite,dut.u_backend.axi_rsp_rdata,dut.u_backend.axi_rsp_error);apending=0;
        end
        if(dut.u_backend.axi_req_valid&&dut.u_backend.axi_req_ready)begin
            if(apending)$fatal(1,"D0 AXI native overwrite");
            dtrace(fd_axi_native,"req",`CORE.ram_req_seq,`CORE.ram_req_pc,dut.u_backend.axi_req_addr,dut.u_backend.axi_req_wdata,dut.u_backend.axi_req_wstrb,dut.u_backend.axi_req_size,dut.u_backend.axi_req_write,0,0);
            apending=1;aseq=`CORE.ram_req_seq;apc=`CORE.ram_req_pc;aaddr=dut.u_backend.axi_req_addr;adata=dut.u_backend.axi_req_wdata;ast=dut.u_backend.axi_req_wstrb;asize=dut.u_backend.axi_req_size;awrite=dut.u_backend.axi_req_write;
        end
        if(cc!==cycles-1)$fatal(1,"AXI independent cycle counter case=%0d",CASE_ID);
        $fwrite(fd_cycle,"%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%08h,%08h,%08h,%08h,%08h,%0d\n",cycles,raw,dut.u_cached.u_cpu.machine_timer_irq,dut.u_cached.u_cpu.machine_software_irq,`CORE.irq_pending_sync,`CORE.irq_arm_q,`CORE.irq_eligible_now,`CORE.irq_take,status,mie,`MEP.mtime_value[31:0],`MEP.mtime_value[63:32],`MEP.mtimecmp_value[31:0],`MEP.mtimecmp_value[63:32],`MEP.software_msip);
        $fwrite(fd_fence,"%0d,%0d,%0d,%08h,%016h,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d\n",cycles,`CORE.exmem_valid_q,`CORE.exmem_q.fence_op,`CORE.exmem_q.pc,`CORE.exmem_q.seq,`CORE.ram_owner_valid,`CORE.ram_owner_killed,`CORE.ram_owner_state,`CORE.idex_valid_q,`CORE.idex_q.pc,`CORE.ex_move,`CORE.ram_issue_fire,`CORE.m_issue_fire,`CORE.retire_fire,`CORE.wb_fire,ipending);
        if(`CORE.exmem_valid_q&&`CORE.exmem_q.fence_op&&!`CORE.mem_fault)begin
            if(`CORE.ex_move||`CORE.ram_issue_fire||`CORE.m_issue_fire)$fatal(1,"AXI barrier younger action case=%0d",CASE_ID);
            if(`CORE.retire_fire&&`CORE.ram_owner_valid)$fatal(1,"AXI retired before preedge D owner idle case=%0d",CASE_ID);
        end
        if(iheld&&(!qv||qa!==held_i))$fatal(1,"AXI held IF changed");iheld=qv&&!qr;held_i=qa;
        if(sv&&sr)begin $fwrite(fd_if,"rsp,%0d,%08h\n",cycles,iaddr);ipending<=0;ir=ir+1;end
        if(ipending&&idelay>0)idelay<=idelay-1;
        if(qv&&qr)begin
            if(qa>=1024||qa[1:0]!=0||(ipending&&!(sv&&sr)))$fatal(1,"AXI IF ownership");
            $fwrite(fd_if,"req,%0d,%08h\n",cycles,qa);iaddr<=qa;ipending<=1;idelay<=WAIT?iq%5:0;iq=iq+1;
        end
        if(dheld&&(!dqv||{dqw,dqa,dz,dqd,dst}!==held_d))$fatal(1,"AXI external held descriptor changed");
        dheld=dqv&&!dqr;held_d={dqw,dqa,dz,dqd,dst};
        if(rheld&&(!dut.u_cached.u_cpu.core_drsp_valid||{dut.u_cached.u_cpu.core_drsp_error,dut.u_cached.u_cpu.core_drsp_rdata}!==held_r))$fatal(1,"AXI held response changed");
        rheld=dut.u_cached.u_cpu.core_drsp_valid&&!dut.u_cached.u_cpu.core_drsp_ready;held_r={dut.u_cached.u_cpu.core_drsp_error,dut.u_cached.u_cpu.core_drsp_rdata};
        if(dut.u_cached.u_cpu.core_dreq_valid)begin
            if(dut.u_cached.u_cpu.core_dreq_addr<32'h10000||dut.u_cached.u_cpu.core_dreq_addr>=32'h10100)begin
                if(!`CORE.exmem_valid_q||`CORE.exmem_q.seq!==`CORE.ram_req_seq||`CORE.exmem_q.pc!==`CORE.ram_req_pc||`CORE.mem_fault)
                    $fatal(1,"AXI first/held nonRAM presentation lacks oldest live MEM owner case=%0d pc=%h",CASE_ID,`CORE.ram_req_pc);
            end
            if(`CORE.ram_req_pc==fixture[4]+4||`CORE.ram_req_pc==fixture[4]+8)$fatal(1,"AXI wrongpath request presented case=%0d",CASE_ID);
            if(last_present_seq!==`CORE.ram_req_seq)begin
                dtrace(fd_d,"present",`CORE.ram_req_seq,`CORE.ram_req_pc,dut.u_cached.u_cpu.core_dreq_addr,dut.u_cached.u_cpu.core_dreq_wdata,dut.u_cached.u_cpu.core_dreq_wstrb,dut.u_cached.u_cpu.core_dreq_size,dut.u_cached.u_cpu.core_dreq_write,0,0);
                last_present_seq=`CORE.ram_req_seq;
            end
        end
        if(dut.u_cached.u_cpu.core_drsp_valid&&dut.u_cached.u_cpu.core_drsp_ready)begin
            dtrace(fd_d,"rsp",cseq,cpc,caddr,cdata,cst,csize,cw,dut.u_cached.u_cpu.core_drsp_rdata,dut.u_cached.u_cpu.core_drsp_error);cr=cr+1;
        end
        if(dut.u_cached.u_cpu.core_dreq_valid&&dut.u_cached.u_cpu.core_dreq_ready)begin
            dtrace(fd_d,"req",`CORE.ram_req_seq,`CORE.ram_req_pc,dut.u_cached.u_cpu.core_dreq_addr,dut.u_cached.u_cpu.core_dreq_wdata,dut.u_cached.u_cpu.core_dreq_wstrb,dut.u_cached.u_cpu.core_dreq_size,dut.u_cached.u_cpu.core_dreq_write,0,0);
            cseq<=`CORE.ram_req_seq;cpc<=`CORE.ram_req_pc;caddr<=dut.u_cached.u_cpu.core_dreq_addr;cdata<=dut.u_cached.u_cpu.core_dreq_wdata;
            cst<=dut.u_cached.u_cpu.core_dreq_wstrb;csize<=dut.u_cached.u_cpu.core_dreq_size;cw<=dut.u_cached.u_cpu.core_dreq_write;cq=cq+1;
        end
        if(dut.u_cached.cpu_imem_rsp_valid&&dut.u_cached.cpu_imem_rsp_ready)begin
            if(!front_ipending)$fatal(1,"AXI front IF response without owner");
            $fwrite(fd_frontif,"rsp,%0d,%08h,%08h,%0d\n",cycles,front_iaddr,dut.u_cached.cpu_imem_rsp_rdata,dut.u_cached.cpu_imem_rsp_error);front_ipending=0;front_ir=front_ir+1;
        end
        if(dut.u_cached.cpu_imem_req_valid&&dut.u_cached.cpu_imem_req_ready)begin
            if(front_ipending)$fatal(1,"AXI front IF overwrite");front_iaddr=dut.u_cached.cpu_imem_req_addr;front_ipending=1;front_iq=front_iq+1;
            $fwrite(fd_frontif,"req,%0d,%08h,00000000,0\n",cycles,front_iaddr);
        end
        if(dut.u_cached.cpu_dmem_rsp_valid&&dut.u_cached.cpu_dmem_rsp_ready)begin
            dtrace(fd_ext,"rsp",cseq,cpc,caddr,cdata,cst,csize,cw,dut.u_cached.cpu_dmem_rsp_rdata,dut.u_cached.cpu_dmem_rsp_error);front_dr=front_dr+1;
        end
        if(dut.u_cached.cpu_dmem_req_valid&&dut.u_cached.cpu_dmem_req_ready)begin
            dtrace(fd_ext,"req",`CORE.ram_req_seq,`CORE.ram_req_pc,dut.u_cached.cpu_dmem_req_addr,dut.u_cached.cpu_dmem_req_wdata,dut.u_cached.cpu_dmem_req_wstrb,dut.u_cached.cpu_dmem_req_size,dut.u_cached.cpu_dmem_req_write,0,0);front_dq=front_dq+1;
        end
        if(dsv&&dsr)begin
            dtrace(fd_backend,"rsp",eseq,epc,eaddr,edata,est,esize,ew,drdata,dut.native_dmem_rsp_error);dpending<=0;er=er+1;
        end
        if(dqv&&dqr)begin
            if(dpending)$fatal(1,"AXI external overwrite");
            dtrace(fd_backend,"req",`CORE.ram_req_seq,`CORE.ram_req_pc,dqa,dqd,dst,dz,dqw,0,0);
            if(dqa>=32'h20000000&&dqa<32'h20000100)$fatal(1,"D0 local device leaked to external backend addr=%h",dqa);
            eseq<=`CORE.ram_req_seq;epc<=`CORE.ram_req_pc;eaddr<=dqa;edata<=dqd;est<=dst;esize<=dz;ew<=dqw;
            dpending<=1;eq=eq+1;
        end
        if(`MEP.endpoint_fire)begin
            $fwrite(fd_local,"machine,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,%0d,%0d,%0d,0\n",cycles,`CORE.ram_owner_seq,`CORE.exmem_q.pc,
                `MEP.addr_q,`MEP.wdata_q,`MEP.wstrb_q,`MEP.size_q,`MEP.write_q,`MEP.access_legal?`MEP.read_value:32'd0,!`MEP.access_legal,
                `MEP.timer_write_fire,`MEP.software_write_fire);
            device_effects=device_effects+1;if(`MEP.timer_write_fire)timer_writes=timer_writes+1;
            if(`MEP.software_write_fire)software_writes=software_writes+1;
            if(`MEP.software_write_fire&&`CORE.exmem_q.pc==fixture[2])begin raise_irq=1;priority_set_cycle=cycles;end
        end
        if(`EP.endpoint_fire)begin
            $fwrite(fd_local,"normal,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,%0d,0,0,%0d\n",cycles,`CORE.ram_owner_seq,`CORE.exmem_q.pc,
                `EP.addr_q,`EP.wdata_q,`EP.wstrb_q,`EP.size_q,`EP.write_q,`EP.access_legal?`EP.read_value:32'd0,!`EP.access_legal,`EP.gpio_write_fire);
            normal_effects=normal_effects+1;if(`EP.gpio_write_fire)gpio_writes=gpio_writes+1;
        end
        if(dut.u_cached.u_cpu.ifid_valid_q&&dut.u_cached.u_cpu.ifid_ready)begin
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.u_cached.u_cpu.ifid_q.seq,dut.u_cached.u_cpu.ifid_q.pc,dut.u_cached.u_cpu.ifid_q.instr);accepted=accepted+1;
        end
        if(`CORE.wb_fire)begin
            if(wb>=retired||`CORE.memwb_q.seq!==retire_seqs[wb]||wpc!==retire_pcs[wb]||`CORE.memwb_q.instr!==retire_ins[wb]||
                wrd!==retire_rds[wb][4:0]||wdata!==retire_vals[wb]||we!==(retire_writes[wb]!=0)||`CORE.memwb_q.actual_next_pc!==retire_nexts[wb])$fatal(1,"AXI physical WB ledger case=%0d",CASE_ID);
            $fwrite(fd_wb,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h\n",cycles,wb,retire_seqs[wb],wpc,retire_ins[wb],wrd,wdata,we,retire_nexts[wb]);wb=wb+1;
        end
        fire_retire=`CORE.retire_fire;fire_irq=`CORE.irq_take;fire_trap=`CORE.trap_fire;old_ic=ic;
        if(fire_irq)begin
            if(irqs==0)begin
                if(`CORE.arch_next_pc_q!==fixture[0]||`CORE.irq_cause!==32'h80000003||cycles!=enable_first_cycle+1)$fatal(1,"AXI first software IRQ boundary case=%0d",CASE_ID);
            end else begin
                if(`CORE.arch_next_pc_q!==fixture[1]||`CORE.irq_cause!==(irqs==1?32'h8000000b:irqs==2?32'h80000003:32'h80000007))$fatal(1,"AXI prioritized IRQ boundary case=%0d",CASE_ID);
                if(irqs==1&&cycles!=enable_priority_cycle+1)$fatal(1,"AXI priority enable latency");
                if(irqs>=2&&cycles!=last_mret_cycle+1)$fatal(1,"AXI pending source did not follow MRET immediately");
            end
            if(irqs==1)raw<=0;
        end
        if(fire_retire||fire_irq||fire_trap)begin
            pre_seq=fire_irq?`CORE.irq_seq:`CORE.exmem_q.seq;pre_pc=fire_irq?`CORE.arch_next_pc_q:`CORE.exmem_q.pc;
            pre_instr=fire_irq?0:`CORE.exmem_q.instr;pre_rd=(fire_irq||fire_trap)?0:`CORE.exmem_q.rd;pre_value=(fire_irq||fire_trap)?0:`CORE.mem_result_value;
            pre_writes=(fire_irq||fire_trap)?0:(`CORE.exmem_q.writes_rd&&pre_rd!=0);
            pre_next=(fire_irq||fire_trap)?dut.u_cached.u_cpu.alu_redirect_pc:`CORE.mem_actual_next_pc;pre_cause=fire_irq?`CORE.irq_cause:fire_trap?`CORE.halt_cause:0;
            pre_tval=fire_trap?`CORE.halt_tval:0;
        end
        #1;
        $fwrite(fd_profile,"%016h,%03h\n",cc,profile_events);
        if(rv!==fire_retire||tf!==(fire_irq||fire_trap)||ic!==old_ic+(fire_retire?1:0))$fatal(1,"AXI registered event/count");
        if(fire_retire||fire_irq||fire_trap)begin
            if(events>=512)$fatal(1,"AXI event overflow");
            if(fire_irq)begin irqs=irqs+1;$fwrite(fd_event,"irq,");end
            else if(fire_trap)begin traps=traps+1;$fwrite(fd_event,"trap,");end
            else begin
                retire_seqs[retired]=pre_seq;retire_pcs[retired]=pre_pc;retire_ins[retired]=pre_instr;retire_rds[retired]=pre_rd;
                retire_vals[retired]=pre_value;retire_writes[retired]=pre_writes;retire_nexts[retired]=pre_next;retired=retired+1;$fwrite(fd_event,"retire,");
                if(pre_pc==fixture[0]-4)enable_first_cycle=cycles;if(pre_pc==fixture[1]-4)enable_priority_cycle=cycles;
                if(pre_instr==32'h30200073)last_mret_cycle=cycles;if(pre_pc==fixture[3])quiesce<=1;
            end
            $fwrite(fd_event,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%0d\n",
                cycles,events,pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,pre_tval,status,mtvec,scratch,mepc,mcause,mtval,mie,ic);events=events+1;
        end
        if(quiesce&&!ipending&&!dpending&&!dut.u_cached.u_cpu.ifid_valid_q&&!`CORE.idex_valid_q&&!`CORE.exmem_valid_q&&!`CORE.memwb_valid_q&&
            !`CORE.m_owner_valid&&!`CORE.ram_owner_valid)drain=drain+1;else drain=0;
        if(drain>=3 && profile_reader_done)begin
            if(retired!=wb||iq!=ir||eq!=er||cq!=cr||irqs!=4||traps!=3||apending||gpio_writes!=1||gout!==8'h77||dut.u_cached.u_cpu.machine_timer_irq||dut.u_cached.u_cpu.machine_software_irq)$fatal(1,"AXI closure case=%0d",CASE_ID);
            if(front_ipending)begin front_icancel=1;$fwrite(fd_frontif,"cancel,%0d,%08h,00000000,0\n",cycles,front_iaddr);end
            fd_cache=$fopen({directory,"/cache_metrics.json"},"w");
            $fwrite(fd_cache,"{\"d0\":%0d,\"wait\":%0d,\"icache\":%0d,\"dcache\":%0d,\"front_i_requests\":%0d,\"front_i_responses\":%0d,\"front_i_reset_canceled\":%0d,\"front_d_requests\":%0d,\"front_d_responses\":%0d,\"backend_d_requests\":%0d,\"backend_d_responses\":%0d,\"icache_access_count\":%0d,\"icache_hit_count\":%0d,\"icache_miss_count\":%0d,\"icache_refill_word_count\":%0d,\"icache_error_count\":%0d,\"dcache_access_count\":%0d,\"dcache_hit_count\":%0d,\"dcache_miss_count\":%0d,\"dcache_refill_word_count\":%0d,\"dcache_error_count\":%0d,\"dcache_write_count\":%0d,\"dcache_bypass_count\":%0d,\"backend_if_held_reset\":%0d}\n",D0,WAIT,ICACHE,DCACHE,front_iq,front_ir,front_icancel,front_dq,front_dr,eq,er,ia,ih,im,ifill,ie,da,dh,dm,dfill,de,dw,db,qv&&!qr);$fclose(fd_cache);
            fd_final=$fopen({directory,"/actual_gpr_final.hex"},"w");$fwrite(fd_final,"00000000\n");for(i=1;i<32;i=i+1)$fwrite(fd_final,"%08h\n",`CORE.u_regfile.regs[i]);$fclose(fd_final);
            fd_final=$fopen({directory,"/actual_ram_final.hex"},"w");for(i=0;i<64;i=i+1)$fwrite(fd_final,"%08h\n",ram_snapshot[i]);$fclose(fd_final);
            fd_final=$fopen({directory,"/actual_axi_ram_final.hex"},"w");for(i=0;i<64;i=i+1)$fwrite(fd_final,"%08h\n",u_ram.u_data_mem.mem[i]);$fclose(fd_final);
            if(D0)begin fd_final=$fopen({directory,"/actual_d0_ram_final.hex"},"w");for(i=0;i<64;i=i+1)$fwrite(fd_final,"%08h\n",ram_snapshot[i]);$fclose(fd_final);end
            fd_metrics=$fopen({directory,"/metrics.json"},"w");
            $fwrite(fd_metrics,"{\"events\":%0d,\"retired\":%0d,\"wb_packets\":%0d,\"irqs\":%0d,\"sync_traps\":%0d,\"accepted\":%0d,\"d_requests\":%0d,\"d_responses\":%0d,\"requests\":%0d,\"responses\":%0d,\"device_effects\":%0d,\"timer_writes\":%0d,\"software_writes\":%0d,\"normal_effects\":%0d,\"gpio_writes\":%0d,\"cycles\":%0d}\n",
                events,retired,wb,irqs,traps,accepted,cq,cr,iq,ir,device_effects,timer_writes,software_writes,normal_effects,gpio_writes,cycles);$fclose(fd_metrics);
            $fclose(fd_event);$fclose(fd_accept);$fclose(fd_wb);$fclose(fd_if);$fclose(fd_d);$fclose(fd_ext);$fclose(fd_local);$fclose(fd_cycle);$fclose(fd_fence);$fclose(fd_backend);$fclose(fd_frontif);$fclose(fd_axi);$fclose(fd_route);$fclose(fd_axi_native);$fclose(fd_profile);$fclose(fd_stats);done=1;rst_n=0;
            $display("CPU5 PROFILE PROGRAM CASE PASS case=%0d ID=%0d BP=%0d WAIT=%0d FWD=%0d retire=%0d local=%0d",CASE_ID,ID_MODE,PRED,WAIT,FORWARD,retired,device_effects);
        end
    end
endmodule
`undef CORE
`undef EP
`undef MEP
