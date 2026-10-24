`timescale 1ns/1ps
module cpu5_mmio_program_tb;
    wire [15:0] done;reg test_pass=0;genvar n;
    generate for(n=0;n<16;n=n+1)begin:g_cases
        cpu5_mmio_program_case #(.CASE_ID(n),.ID_MODE(n%2),.PRED((n/2)%2),.WAIT((n/4)%2),.FORWARD(n/8)) u(.done(done[n]));
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 MMIO PROGRAM PASS: 16 real IF cases, physical UART RX/TX, GPIO, counters, ordered external reads and precise traps");$stop;end
    initial begin #1600000;$fatal(1,"CPU5 MMIO program timeout done=%h",done);end
endmodule

`define CORE dut.g_alu.u_pipeline
`define EP dut.g_mmio.u_router.u_endpoint
module cpu5_mmio_program_case #(
    parameter CASE_ID=0,ID_MODE=0,PRED=0,WAIT=0,FORWARD=0,
    parameter BASE="build/cpu5_s10_mmio_program"
)(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    reg rx=1,started=0,quiesce=0,raw=0,raise_irq=0;
    wire tx,qv,qr,sv,sr,dqv,dqr,dqw,dsv,dsr,rv,we,tf;
    wire [31:0] qa,dqa,dqd,wpc,wdata,tpc,tc,tv;wire [4:0] wrd;wire [1:0] dz;wire [3:0] dst;
    wire [7:0] gout,goe;wire [63:0] cc,ic;
    reg ipending=0,dpending=0;reg [31:0] iaddr=0,drdata=0;
    integer idelay=0,ddelay=0,cycles=0,iq=0,ir=0,eq=0,er=0,cq=0,cr=0;
    integer events=0,retired=0,wb=0,irqs=0,traps=0,accepted=0,local_effects=0,tx_events=0,rx_pops=0,gpio_writes=0;
    integer drain=0,tx_frames=0,tx_physical=0,i,j,k,fd_event,fd_accept,fd_wb,fd_if,fd_d,fd_ext,fd_local,fd_cycle,fd_final,fd_metrics;
    integer stats_retire_cycle=0,stats_request_cycle=0;
    reg [7:0] tx_byte;
    reg [31:0] rom[0:255],ram[0:63],fixture[0:3];
    reg [63:0] cseq=0,eseq=0,last_present_seq=64'hffffffffffffffff;
    reg [31:0] cpc=0,caddr=0,cdata=0,epc=0,eaddr=0,edata=0;
    reg [3:0] cst=0,est=0;reg [1:0] csize=0,esize=0;reg cw=0,ew=0;
    reg [63:0] pre_seq,old_ic;reg [31:0] pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,pre_tval;
    reg fire_retire,fire_irq,fire_trap;
    reg [63:0] retire_seqs[0:511];reg [31:0] retire_pcs[0:511],retire_ins[0:511],retire_rds[0:511],retire_vals[0:511],retire_writes[0:511],retire_nexts[0:511];
    reg iheld=0,dheld=0,rheld=0;reg [31:0] held_i;reg [70:0] held_d;reg [32:0] held_r;
    string directory;
    assign qr=rst_n&&started&&!quiesce&&(!ipending||(sv&&sr))&&(!WAIT||cycles%7>=2);
    assign sv=ipending&&idelay==0;
    assign dqr=rst_n&&(!dpending||(dsv&&dsr))&&(!WAIT||cycles%5>=2);
    assign dsv=dpending&&ddelay==0;
    wire [31:0] status=`CORE.g_csr.u_csr.csr_mstatus,mtvec=`CORE.g_csr.u_csr.csr_mtvec;
    wire [31:0] scratch=`CORE.g_csr.u_csr.csr_mscratch,mepc=`CORE.g_csr.u_csr.csr_mepc;
    wire [31:0] mcause=`CORE.g_csr.u_csr.csr_mcause,mtval=`CORE.g_csr.u_csr.csr_mtval,mie=`CORE.g_csr.u_csr.csr_mie;
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(64),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(FORWARD),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),.ENABLE_MMIO(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_RV32M(1),.ENABLE_EXTERNAL_IRQ(1),
        .ENABLE_BRANCH_PRED(PRED),.BRANCH_RESOLVE_IN_ID(ID_MODE),.UART_CLOCK_HZ(1000000),.UART_BAUD(250000)) dut(
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(rv),.cycle_count(cc),.instret_count(ic),.uart_tx(tx),.uart_rx(rx),.gpio_in(8'ha5),.gpio_out(gout),.gpio_oe(goe),
        .dmem_req_valid(dqv),.dmem_req_ready(dqr),.dmem_req_write(dqw),.dmem_req_addr(dqa),.dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(dsv),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(drdata),.dmem_rsp_error(1'b0),.dmem_fault(),
        .imem_req_valid(qv),.imem_req_ready(qr),.imem_req_addr(qa),.imem_rsp_valid(sv),.imem_rsp_ready(sr),
        .imem_rsp_rdata(rom[iaddr>>2]),.imem_rsp_error(1'b0),.imem_fault(),.imem_fault_pc(),
        .trap_valid(tf),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(raw),.irq_software(1'b0),.irq_timer(1'b0),.perf_cycle_events());
    task send_byte(input [7:0] data);
        integer bit_number;
        begin
            @(negedge clk);rx=0;repeat(4)@(negedge clk);
            for(bit_number=0;bit_number<8;bit_number=bit_number+1)begin rx=data[bit_number];repeat(4)@(negedge clk);end
            rx=1;repeat(8)@(negedge clk);
        end
    endtask
    initial begin
        $readmemh({BASE,"/program.hex"},rom,0,255);$readmemh({BASE,"/ram_initial.hex"},ram,0,63);$readmemh({BASE,"/fixture.hex"},fixture,0,3);
        directory=$sformatf("%s/cases/case%0d",BASE,CASE_ID);
        fd_event=$fopen({directory,"/events.csv"},"w");fd_accept=$fopen({directory,"/accept.csv"},"w");fd_wb=$fopen({directory,"/wb.csv"},"w");
        fd_if=$fopen({directory,"/if.csv"},"w");fd_d=$fopen({directory,"/d.csv"},"w");fd_ext=$fopen({directory,"/external.csv"},"w");
        fd_local=$fopen({directory,"/local.csv"},"w");fd_cycle=$fopen({directory,"/cycles.csv"},"w");
        if(!fd_event||!fd_accept||!fd_wb||!fd_if||!fd_d||!fd_ext||!fd_local||!fd_cycle)$fatal(1,"MMIO program log open");
        $fwrite(fd_event,"kind,cycle,index,seq,pc,instr,rd,value,writes,nextpc,cause,tval,mstatus,mtvec,mscratch,mepc,mcause,mtval,mie,instret\n");
        $fwrite(fd_accept,"cycle,seq,pc,instr\n");$fwrite(fd_wb,"cycle,index,seq,pc,instr,rd,value,writes,nextpc\n");$fwrite(fd_if,"event,cycle,addr\n");
        $fwrite(fd_d,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");$fwrite(fd_ext,"event,cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error\n");
        $fwrite(fd_local,"cycle,seq,pc,addr,wdata,wstrb,size,is_write,rdata,error,tx,pop,gpio\n");
        $fwrite(fd_cycle,"cycle,raw,pending,arm,eligible,take,mstatus,mie\n");
        repeat(4)@(negedge clk);rst_n=1;
        send_byte(8'ha6);send_byte(8'h3c);repeat(8)@(negedge clk);started=1;
    end
    initial forever begin
        @(negedge tx);if(rst_n)begin
            repeat(6)@(negedge clk);
            for(integer bit_number=0;bit_number<8;bit_number=bit_number+1)begin tx_byte[bit_number]=tx;repeat(4)@(negedge clk);end
            if(tx!==1)$fatal(1,"MMIO physical TX stop bit case=%0d",CASE_ID);
            tx_physical=tx_byte;tx_frames=tx_frames+1;
        end
    end
    always @(negedge clk)if(rst_n)begin
        if(raise_irq)begin raw=1;raise_irq=0;end
    end
    task dtrace(input integer fd,input string action,input [63:0] seq,input [31:0] pc,addr,data,input [3:0] st,input [1:0] size,input wr,input [31:0] result,input error);
        $fwrite(fd,"%s,%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,%0d\n",action,cycles,seq,pc,addr,data,st,size,wr,result,error);
    endtask
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;
        if(cc!==cycles-1)$fatal(1,"MMIO independent cycle counter case=%0d",CASE_ID);
        $fwrite(fd_cycle,"%0d,%0d,%08h,%0d,%0d,%0d,%08h,%08h\n",cycles,raw,`CORE.irq_pending_sync,`CORE.irq_arm_q,`CORE.irq_eligible_now,`CORE.irq_take,status,mie);
        if(iheld&&(!qv||qa!==held_i))$fatal(1,"MMIO held IF changed");iheld=qv&&!qr;held_i=qa;
        if(sv&&sr)begin $fwrite(fd_if,"rsp,%0d,%08h\n",cycles,iaddr);ipending<=0;ir=ir+1;end
        if(ipending&&idelay>0)idelay<=idelay-1;
        if(qv&&qr)begin
            if(qa>=1024||qa[1:0]!=0||(ipending&&!(sv&&sr)))$fatal(1,"MMIO IF ownership");
            $fwrite(fd_if,"req,%0d,%08h\n",cycles,qa);iaddr<=qa;ipending<=1;idelay<=WAIT?iq%5:0;iq=iq+1;
        end
        if(dheld&&(!dqv||{dqw,dqa,dz,dqd,dst}!==held_d))$fatal(1,"MMIO external held descriptor changed");
        dheld=dqv&&!dqr;held_d={dqw,dqa,dz,dqd,dst};
        if(rheld&&(!dut.core_drsp_valid||{dut.core_drsp_error,dut.core_drsp_rdata}!==held_r))$fatal(1,"MMIO held response changed");
        rheld=dut.core_drsp_valid&&!dut.core_drsp_ready;held_r={dut.core_drsp_error,dut.core_drsp_rdata};
        if(dut.core_dreq_valid)begin
            if(dut.core_dreq_addr<32'h10000||dut.core_dreq_addr>=32'h10100)begin
                if(!`CORE.exmem_valid_q||`CORE.exmem_q.seq!==`CORE.ram_req_seq||`CORE.exmem_q.pc!==`CORE.ram_req_pc||`CORE.mem_fault)
                    $fatal(1,"MMIO first/held nonRAM presentation lacks oldest live MEM owner case=%0d pc=%h",CASE_ID,`CORE.ram_req_pc);
            end
            if(`CORE.ram_req_pc==fixture[2]+4||`CORE.ram_req_pc==fixture[2]+8)$fatal(1,"MMIO wrongpath request presented case=%0d",CASE_ID);
            if(last_present_seq!==`CORE.ram_req_seq)begin
                dtrace(fd_d,"present",`CORE.ram_req_seq,`CORE.ram_req_pc,dut.core_dreq_addr,dut.core_dreq_wdata,dut.core_dreq_wstrb,dut.core_dreq_size,dut.core_dreq_write,0,0);
                last_present_seq=`CORE.ram_req_seq;
            end
        end
        if(dut.core_drsp_valid&&dut.core_drsp_ready)begin
            dtrace(fd_d,"rsp",cseq,cpc,caddr,cdata,cst,csize,cw,dut.core_drsp_rdata,dut.core_drsp_error);cr=cr+1;
        end
        if(dut.core_dreq_valid&&dut.core_dreq_ready)begin
            dtrace(fd_d,"req",`CORE.ram_req_seq,`CORE.ram_req_pc,dut.core_dreq_addr,dut.core_dreq_wdata,dut.core_dreq_wstrb,dut.core_dreq_size,dut.core_dreq_write,0,0);
            cseq<=`CORE.ram_req_seq;cpc<=`CORE.ram_req_pc;caddr<=dut.core_dreq_addr;cdata<=dut.core_dreq_wdata;
            cst<=dut.core_dreq_wstrb;csize<=dut.core_dreq_size;cw<=dut.core_dreq_write;cq=cq+1;
        end
        if(dsv&&dsr)begin
            dtrace(fd_ext,"rsp",eseq,epc,eaddr,edata,est,esize,ew,drdata,0);dpending<=0;er=er+1;
        end
        if(dpending&&ddelay>0)ddelay<=ddelay-1;
        if(dqv&&dqr)begin
            if(dpending&&!(dsv&&dsr))$fatal(1,"MMIO external overwrite");
            dtrace(fd_ext,"req",`CORE.ram_req_seq,`CORE.ram_req_pc,dqa,dqd,dst,dz,dqw,0,0);
            if(dqa>=32'h10000&&dqa<32'h10100)begin
                j=(dqa-32'h10000)>>2;drdata<=ram[j];
                if(dqw)for(k=0;k<4;k=k+1)if(dst[k])ram[j][k*8+:8]=dqd[k*8+:8];
            end else if(dqa==32'h30000000&&!dqw)begin
                if(stats_request_cycle!=0)$fatal(1,"MMIO Stats request replay");stats_request_cycle=cycles;raise_irq=1;drdata<=32'h13579bdf;
            end else if(dqa==32'h90000000&&!dqw)drdata<=32'h2468ace0;
            else $fatal(1,"MMIO unknown unexpected external request addr=%h",dqa);
            eseq<=`CORE.ram_req_seq;epc<=`CORE.ram_req_pc;eaddr<=dqa;edata<=dqd;est<=dst;esize<=dz;ew<=dqw;
            dpending<=1;ddelay<=dqa==32'h30000000 ? 12 : WAIT?eq%6:0;eq=eq+1;
        end
        if(`EP.endpoint_fire)begin
            $fwrite(fd_local,"%0d,%016h,%08h,%08h,%08h,%01h,%0d,%0d,%08h,%0d,%0d,%0d,%0d\n",cycles,`CORE.ram_owner_seq,`CORE.exmem_q.pc,
                `EP.addr_q,`EP.wdata_q,`EP.wstrb_q,`EP.size_q,`EP.write_q,`EP.access_legal?`EP.read_value:32'd0,!`EP.access_legal,
                `EP.tx_fire,`EP.rx_read_fire&&`EP.addr_q==32'h20000018,`EP.gpio_write_fire);
            local_effects=local_effects+1;if(`EP.tx_fire)tx_events=tx_events+1;
            if(`EP.rx_read_fire&&`EP.addr_q==32'h20000018)rx_pops=rx_pops+1;if(`EP.gpio_write_fire)gpio_writes=gpio_writes+1;
        end
        if(dut.ifid_valid_q&&dut.ifid_ready)begin
            $fwrite(fd_accept,"%0d,%016h,%08h,%08h\n",cycles,dut.ifid_q.seq,dut.ifid_q.pc,dut.ifid_q.instr);accepted=accepted+1;
        end
        if(`CORE.wb_fire)begin
            if(wb>=retired||`CORE.memwb_q.seq!==retire_seqs[wb]||wpc!==retire_pcs[wb]||`CORE.memwb_q.instr!==retire_ins[wb]||
                wrd!==retire_rds[wb][4:0]||wdata!==retire_vals[wb]||we!==(retire_writes[wb]!=0)||`CORE.memwb_q.actual_next_pc!==retire_nexts[wb])$fatal(1,"MMIO physical WB ledger case=%0d",CASE_ID);
            $fwrite(fd_wb,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h\n",cycles,wb,retire_seqs[wb],wpc,retire_ins[wb],wrd,wdata,we,retire_nexts[wb]);wb=wb+1;
        end
        fire_retire=`CORE.retire_fire;fire_irq=`CORE.irq_take;fire_trap=`CORE.trap_fire;old_ic=ic;
        if(fire_irq)begin
            if(stats_retire_cycle==0||cycles!=stats_retire_cycle+1||`CORE.arch_next_pc_q!==fixture[1])$fatal(1,"MMIO IRQ precise next safe edge case=%0d",CASE_ID);
            raw<=0;
        end
        if(fire_retire||fire_irq||fire_trap)begin
            pre_seq=fire_irq?`CORE.irq_seq:`CORE.exmem_q.seq;pre_pc=fire_irq?`CORE.arch_next_pc_q:`CORE.exmem_q.pc;
            pre_instr=fire_irq?0:`CORE.exmem_q.instr;pre_rd=(fire_irq||fire_trap)?0:`CORE.exmem_q.rd;pre_value=(fire_irq||fire_trap)?0:`CORE.mem_result_value;
            pre_writes=(fire_irq||fire_trap)?0:(`CORE.exmem_q.writes_rd&&pre_rd!=0);
            pre_next=(fire_irq||fire_trap)?dut.alu_redirect_pc:`CORE.mem_actual_next_pc;pre_cause=fire_irq?`CORE.irq_cause:fire_trap?`CORE.halt_cause:0;
            pre_tval=fire_trap?`CORE.halt_tval:0;
        end
        #1;
        if(rv!==fire_retire||tf!==(fire_irq||fire_trap)||ic!==old_ic+(fire_retire?1:0))$fatal(1,"MMIO registered event/count");
        if(fire_retire||fire_irq||fire_trap)begin
            if(events>=512)$fatal(1,"MMIO event overflow");
            if(fire_irq)begin irqs=irqs+1;$fwrite(fd_event,"irq,");end
            else if(fire_trap)begin traps=traps+1;$fwrite(fd_event,"trap,");end
            else begin
                retire_seqs[retired]=pre_seq;retire_pcs[retired]=pre_pc;retire_ins[retired]=pre_instr;retire_rds[retired]=pre_rd;
                retire_vals[retired]=pre_value;retire_writes[retired]=pre_writes;retire_nexts[retired]=pre_next;retired=retired+1;$fwrite(fd_event,"retire,");
                if(pre_pc==fixture[0])stats_retire_cycle=cycles;if(pre_pc==fixture[3])quiesce<=1;
            end
            $fwrite(fd_event,"%0d,%0d,%016h,%08h,%08h,%0d,%08h,%0d,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%08h,%0d\n",
                cycles,events,pre_seq,pre_pc,pre_instr,pre_rd,pre_value,pre_writes,pre_next,pre_cause,pre_tval,status,mtvec,scratch,mepc,mcause,mtval,mie,ic);events=events+1;
        end
        if(quiesce&&!ipending&&!dpending&&!dut.ifid_valid_q&&!`CORE.idex_valid_q&&!`CORE.exmem_valid_q&&!`CORE.memwb_valid_q&&
            !`CORE.m_owner_valid&&!`CORE.ram_owner_valid&&!`EP.tx_busy&&tx_frames==1)drain=drain+1;else drain=0;
        if(drain==3)begin
            if(retired!=wb||iq!=ir||eq!=er||cq!=cr||irqs!=1||traps!=2||tx_events!=1||rx_pops!=2||gpio_writes!=5||tx_physical!=8'h51||gout!==8'h58||goe!==8'hff)$fatal(1,"MMIO closure case=%0d",CASE_ID);
            fd_final=$fopen({directory,"/actual_gpr_final.hex"},"w");$fwrite(fd_final,"00000000\n");for(i=1;i<32;i=i+1)$fwrite(fd_final,"%08h\n",`CORE.u_regfile.regs[i]);$fclose(fd_final);
            fd_final=$fopen({directory,"/actual_ram_final.hex"},"w");for(i=0;i<64;i=i+1)$fwrite(fd_final,"%08h\n",ram[i]);$fclose(fd_final);
            fd_metrics=$fopen({directory,"/metrics.json"},"w");
            $fwrite(fd_metrics,"{\"events\":%0d,\"retired\":%0d,\"wb_packets\":%0d,\"irqs\":%0d,\"sync_traps\":%0d,\"accepted\":%0d,\"d_requests\":%0d,\"d_responses\":%0d,\"requests\":%0d,\"responses\":%0d,\"local_effects\":%0d,\"tx_events\":%0d,\"rx_pops\":%0d,\"gpio_writes\":%0d,\"cycles\":%0d,\"tx_physical\":%0d,\"tx_frames\":%0d}\n",
                events,retired,wb,irqs,traps,accepted,cq,cr,iq,ir,local_effects,tx_events,rx_pops,gpio_writes,cycles,tx_physical,tx_frames);$fclose(fd_metrics);
            $fclose(fd_event);$fclose(fd_accept);$fclose(fd_wb);$fclose(fd_if);$fclose(fd_d);$fclose(fd_ext);$fclose(fd_local);$fclose(fd_cycle);done=1;
            $display("CPU5 MMIO PROGRAM CASE PASS case=%0d ID=%0d BP=%0d WAIT=%0d FWD=%0d retire=%0d local=%0d",CASE_ID,ID_MODE,PRED,WAIT,FORWARD,retired,local_effects);
        end
    end
endmodule
`undef CORE
`undef EP
