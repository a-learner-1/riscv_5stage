`timescale 1ns/1ps
`include "programs/timer_irq_symbols.vh"
// New C workload only. Real initialized AXI RAM and UART bits, no testbench
// timer/CSR forcing. Each ISR must restore all 31 integer registers, preserve
// the exact interrupted PC and finish all 2048 foreground checksum updates.
module timer_irq_c_tb;
    wire [2:0] done;
    reg test_pass=0;
    timer_irq_c_case #(.MODE(0)) fast(done[0]);
    timer_irq_c_case #(.MODE(1)) aw_first(done[1]);
    timer_irq_c_case #(.MODE(2)) w_first(done[2]);
    initial begin wait(&done);test_pass=1;
        $display("PASS: timer IRQ real C/AXI: three exact IRQ/MRET and full register restoration, masked pending, 2048 uninterrupted checksum/work updates, RAM logs and UART16");$stop;end
    initial begin #30000000;$fatal(1,"Timer IRQ C timeout done=%b",done);end
endmodule
module timer_irq_c_case #(parameter integer MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] awaddr,wdata,araddr,rdata;
    wire [2:0] awprot,arprot;
    wire [3:0] wstrb;
    wire [1:0] bresp,rresp;
    wire awvalid,awready,wvalid,wready,bvalid,bready,arvalid,arready,rvalid,rready,tx;
    wire trap_valid,retire_valid,imem_fault,dmem_fault;
    wire [31:0] trap_pc,trap_cause,trap_tval,wb_pc;
    wire [63:0] cycles,instret;
    integer traps=0,mrets=0,bytes=0,entries=0,handler_entries=0;
    integer aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0,requests=0,responses=0;
    integer work_writes=0,checksum_writes=0,overlap=0;
    integer i,j,bit_index;
    reg [31:0] pcs[0:2],statuses[0:2],saved_regs[0:31];
    reg [31:0] buffered_addr,buffered_data,rolling_checksum=32'h13579bdf;
    reg [3:0] buffered_strobe;
    reg got_aw=0,got_w=0,in_isr=0,in_work=0;
    reg [7:0] received;
    reg [63:0] when_now,when_previous=0;
    localparam [16*8-1:0] MESSAGE="TIMER IRQ PASS\015\012";
    soc_axi_lite_top #(.PROGRAM_FILE("programs/timer_irq.hex"),.DATA_FILE("programs/timer_irq_data.hex"),
        .ENABLE_TRAPS(1),.ENABLE_TIMER_IRQ(1),.SIM_CONSOLE_ECHO(0),
        .UART_CLOCK_HZ(100000000),.UART_BAUD(5000000),
        .IMEM_REQ_WAIT_CYCLES(MODE?2:0),.IMEM_RSP_WAIT_CYCLES(MODE?3:0),
        .MMIO_REQ_WAIT_CYCLES(MODE?1:0),.MMIO_RSP_WAIT_CYCLES(MODE?2:0)
    ) dut(.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(tx),.gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(wb_pc),.wb_rd(),.wb_data(),.wb_we(),
        .retire_valid(retire_valid),.cycle_count(cycles),.instret_count(instret),
        .imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .icache_access_count(),.icache_hit_count(),.icache_miss_count(),
        .icache_refill_word_count(),.icache_error_count(),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval));
    axi_lite_ram #(.INIT_FILE("programs/timer_irq_data.hex"),
        .AW_WAIT_CYCLES(MODE==2?5:0),.W_WAIT_CYCLES(MODE==1?5:0),
        .B_WAIT_CYCLES(MODE?4:0),.AR_WAIT_CYCLES(MODE?3:0),.R_WAIT_CYCLES(MODE?6:0)
    ) ram(.clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awprot(awprot),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
    always @(posedge clk)if(rst_n&&!done)begin
        if(awvalid&&awready)begin
            if(got_aw)$fatal(1,"Timer C repeated AW");got_aw=1;buffered_addr=awaddr;aw_count=aw_count+1;end
        if(wvalid&&wready)begin
            if(got_w)$fatal(1,"Timer C repeated W");got_w=1;buffered_data=wdata;buffered_strobe=wstrb;w_count=w_count+1;end
        if(bvalid&&bready)begin
            if(!got_aw||!got_w||bresp!==0)$fatal(1,"Timer C B without successful AW/W");
            if(in_work&&buffered_addr==`TIMER_IRQ_CHECKSUM)begin
                rolling_checksum=(rolling_checksum<<5)^(rolling_checksum>>2)^checksum_writes;
                if(buffered_strobe!==4'hf||buffered_data!==rolling_checksum)$fatal(1,"Timer C replay/lost checksum step mode=%0d step=%0d data=%h expected=%h",MODE,checksum_writes,buffered_data,rolling_checksum);
                checksum_writes=checksum_writes+1;
            end
            if(in_work&&buffered_addr==`TIMER_IRQ_WORK)begin
                work_writes=work_writes+1;
                if(buffered_strobe!==4'hf||buffered_data!==work_writes)$fatal(1,"Timer C replay/lost foreground work update");
            end
            got_aw=0;got_w=0;b_count=b_count+1;
        end
        if(arvalid&&arready)ar_count=ar_count+1;
        if(rvalid&&rready)begin if(rresp!==0)$fatal(1,"Timer C AXI read error");r_count=r_count+1;end
        if(dut.dmem_req_valid&&dut.dmem_req_ready)requests=requests+1;
        if(dut.dmem_rsp_valid&&dut.dmem_rsp_ready)responses=responses+1;
        if(dut.u_cpu.u_data_mem.re||dut.u_cpu.u_data_mem.we||dut.u_cpu.u_if_stage.u_instr_mem.en)$fatal(1,"Timer C used inactive internal memory");
        if(imem_fault||dmem_fault)$fatal(1,"Timer C unexpected access fault");
        if(dut.u_cpu.mem_active&&dut.u_cpu.timer_mtip)overlap=overlap+1;
        #1;
        if(trap_valid)begin
            if(in_isr||traps>=3||trap_cause!==32'h80000007||trap_tval!==0||trap_pc[1:0]!=0||
               dut.u_cpu.csr_mstatus!==32'h1880||dut.u_cpu.csr_mie!==128||!dut.u_cpu.timer_mtip)
                $fatal(1,"Timer C wrong/nested IRQ mode=%0d slot=%0d PC=%h cause=%h",MODE,traps,trap_pc,trap_cause);
            if(requests!=responses||dut.u_cpu.mem_active)$fatal(1,"Timer C IRQ preempted AXI transaction");
            if(traps==0&&trap_pc!==`TIMER_IRQ_WORK_BEGIN)$fatal(1,"Timer C first IRQ did not preserve first work PC got=%h",trap_pc);
            if(ram.u_data_mem.mem[(`TIMER_IRQ_MASK_CHECKS-32'h10000)/4]!==2)$fatal(1,"Timer C IRQ before both masked-pending checks");
            if(retire_valid&&wb_pc==trap_pc)$fatal(1,"Timer C interrupted instruction retired at entry");
            pcs[traps]=trap_pc;statuses[traps]=dut.u_cpu.csr_mstatus;
            for(j=1;j<32;j=j+1)saved_regs[j]=dut.u_cpu.u_regfile.regs[j];
            if(saved_regs[2][3:0]!=0||saved_regs[2]<32'h10080||saved_regs[2]>32'h13fe0)$fatal(1,"Timer C invalid ISR stack");
            traps=traps+1;in_isr=1;
        end
        if(retire_valid)begin
            if(wb_pc==`TIMER_IRQ_ENTRY)begin if(!in_isr)$fatal(1,"Timer C handler entry without IRQ");entries=entries+1;end
            if(wb_pc==`TIMER_IRQ_HANDLER)handler_entries=handler_entries+1;
            if(wb_pc==`TIMER_IRQ_MRET)begin
                if(!in_isr||dut.u_cpu.csr_mepc!==pcs[traps-1]||dut.u_cpu.csr_mstatus!==32'h1888)$fatal(1,"Timer C MRET did not return same PC/restore MIE");
                for(j=1;j<32;j=j+1)if(dut.u_cpu.u_regfile.regs[j]!==saved_regs[j])$fatal(1,"Timer C ISR corrupted x%0d mode=%0d got=%h expected=%h",j,MODE,dut.u_cpu.u_regfile.regs[j],saved_regs[j]);
                mrets=mrets+1;in_isr=0;
            end
            if(wb_pc==`TIMER_IRQ_WORK_BEGIN)in_work=1;
            if(wb_pc==`TIMER_IRQ_WORK_END)in_work=0;
        end
    end
    initial begin forever begin
        @(negedge tx);if(!rst_n||bytes>=16)$fatal(1,"Timer C unexpected UART frame");
        #100;if(tx!==0)$fatal(1,"Timer C bad UART start");
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin #200;received[bit_index]=tx;end
        #200;if(tx!==1||received!==MESSAGE[(15-bytes)*8+:8])$fatal(1,"Timer C UART mode=%0d byte=%0d got=%h",MODE,bytes,received);
        bytes=bytes+1;
    end end
    initial begin
        // The ISA does not specify reset contents of general registers. Seed
        // distinct legal values during reset so full ISR restoration cannot
        // pass merely because both an unused register and its copy were X.
        #1;for(i=1;i<32;i=i+1)dut.u_cpu.u_regfile.regs[i]=32'h51a70000+i*32'h01010101;
        repeat(4)@(negedge clk);rst_n=1;
        wait(ram.u_data_mem.mem[4095]!==0);
        if(ram.u_data_mem.mem[4095]!==1)$fatal(1,"Timer C tohost mode=%0d value=%h",MODE,ram.u_data_mem.mem[4095]);
        wait(dut.u_cpu.mem_active===0);repeat(3)@(negedge clk);
        if(traps!=3||mrets!=3||entries!=3||handler_entries!=3||in_isr||bytes!=16||
           checksum_writes!=2048||work_writes!=2048||rolling_checksum!==`TIMER_IRQ_EXPECT_CHECKSUM||overlap==0)
            $fatal(1,"Timer C final counts mode=%0d IRQ/MRET=%0d/%0d entry=%0d/%0d UART=%0d work=%0d checksum=%0d overlap=%0d",MODE,traps,mrets,entries,handler_entries,bytes,work_writes,checksum_writes,overlap);
        if(requests!=responses||aw_count!=w_count||aw_count!=b_count||ar_count!=r_count||requests!=aw_count+ar_count||got_aw||got_w)
            $fatal(1,"Timer C AXI transaction count mismatch");
        if(ram.u_data_mem.mem[(`TIMER_IRQ_COUNT-32'h10000)/4]!==3||
           ram.u_data_mem.mem[(`TIMER_IRQ_CHECKSUM-32'h10000)/4]!==`TIMER_IRQ_EXPECT_CHECKSUM||
           ram.u_data_mem.mem[(`TIMER_IRQ_WORK-32'h10000)/4]!==2048||
           ram.u_data_mem.mem[(`TIMER_IRQ_MASK_CHECKS-32'h10000)/4]!==2||
           ram.u_data_mem.mem[(`TIMER_IRQ_FAIL_CODE-32'h10000)/4]!==0||
           ram.u_data_mem.mem[(`TIMER_IRQ_GUARD-32'h10000)/4]!==32'h12345678||
           dut.u_cpu.csr_mie!==0||dut.u_cpu.timer_mtip||dut.u_cpu.csr_mstatus!==32'h1880)
            $fatal(1,"Timer C final software/CSR state mismatch");
        for(i=0;i<3;i=i+1)begin
            if(ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+i*4]!==32'h80000007||
               ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+i*4+1]!==pcs[i]||
               ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+i*4+2]!==0||
               ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+i*4+3]!==statuses[i])$fatal(1,"Timer C software IRQ log mismatch slot=%0d",i);
            when_now={ram.u_data_mem.mem[(`TIMER_IRQ_WHEN-32'h10000)/4+i*2+1],ram.u_data_mem.mem[(`TIMER_IRQ_WHEN-32'h10000)/4+i*2]};
            if(i!=0&&when_now<when_previous+`TIMER_IRQ_PERIOD)$fatal(1,"Timer C deadline/rearm elapsed ticks too short");
            when_previous=when_now;
        end
        $display("Timer C case %0d PASS: three precise IRQ/MRET, restored x1..x31, checksum=%h work=2048, masked checks/RAM logs/UART16; AXI W/R=%0d/%0d cycles=%0d retired=%0d",MODE,rolling_checksum,aw_count,ar_count,cycles,instret);
        done=1;
    end
endmodule
