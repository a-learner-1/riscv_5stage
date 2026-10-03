`timescale 1ns/1ps
`include "programs/timer_irq_board_symbols.vh"
// Physical 50 MHz / 115200 UART. The hardware instruction image is used;
// only the initialized heartbeat period in RAM is shortened for simulation.
module timer_irq_board_tb;
    wire [2:0] done;
    reg test_pass=0;
    timer_irq_board_case normal(done[0]);
    timer_irq_board_case #(.RESET_HANDLER(1)) reset_handler(done[1]);
    timer_irq_board_case #(.FIRST_FAIL(1)) software_fail(done[2]);
    initial begin
        wait(&done); test_pass=1;
        $display("TIMER IRQ BOARD TESTS PASS: physical UART, exact IRQ/MRET and x1..x31, masked pending, 2048 checksum steps, heartbeat, KEY1 ISR cancellation/restart and real FAIL recovery");
        $stop;
    end
    initial begin #20000000; $fatal(1,"Timer IRQ board timeout done=%b",done); end
endmodule

module timer_irq_board_uart_checker #(parameter integer FIRST_FAIL=0)(
    input wire tx,rst_n,restart_allowed, output reg [31:0] boots=0
);
    localparam integer BIT_NS=434*20;
    localparam [16*8-1:0] PASS_MESSAGE="TIMER IRQ PASS\015\012";
    localparam [25*8-1:0] FAIL_MESSAGE="TIMER IRQ FAIL 00000001\015\012";
    integer bytes=0,bit_index,length;
    reg [7:0] value,expected;
    initial forever begin
        @(negedge tx);
        if(!rst_n||boots>=2||(boots==1&&!restart_allowed))
            $fatal(1,"Unexpected timer IRQ board UART frame");
        length=(FIRST_FAIL&&boots==0)?25:16;
        expected=(FIRST_FAIL&&boots==0)?FAIL_MESSAGE[(24-bytes)*8+:8]:PASS_MESSAGE[(15-bytes)*8+:8];
        #(BIT_NS/2);
        if(tx!==0) $fatal(1,"Timer board UART start bit");
        for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
            #(BIT_NS);
            if(tx!==0&&tx!==1) $fatal(1,"Unknown timer board UART data");
            value[bit_index]=tx;
        end
        #(BIT_NS);
        if(tx!==1||value!==expected)
            $fatal(1,"Timer board UART %m boot=%0d byte=%0d got=%h expected=%h",boots,bytes,value,expected);
        bytes=bytes+1;
        if(bytes==length) begin
            bytes=0;boots=boots+1;
            $display("TIMER BOARD UART %m boot=%0d bytes=%0d",boots,length);
        end
    end
endmodule

module timer_irq_board_case #(parameter integer RESET_HANDLER=0,FIRST_FAIL=0)(output reg done=0);
    reg clk=0,key1_n=1,restart_allowed=0,in_isr=0,in_work=0;
    wire tx; wire [7:0] led; wire [31:0] boots;
    integer traps=0,mrets=0,work_writes=0,checksum_writes=0,requests=0,responses=0;
    integer i,j,slot,wait_cycles;
    reg old_phase,got_aw=0,got_w=0;
    reg [31:0] pcs[0:2],saved_regs[0:31],buffered_addr,buffered_data;
    reg [3:0] buffered_strobe;
    reg [31:0] rolling_checksum=32'h13579bdf;
    reg [63:0] when_now,when_previous;
    timer_irq_board_top #(.DATA_FILE("programs/timer_irq_board_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)) dut(.clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),
        .led(led),.uart_tx(tx),.uart_rx(1'b1));
    timer_irq_board_uart_checker #(.FIRST_FAIL(FIRST_FAIL)) serial(tx,dut.cpu_rst_n,restart_allowed,boots);
    always #10 clk=~clk;

    always @(posedge clk) begin
        if(!dut.cpu_rst_n) begin
            traps=0;mrets=0;work_writes=0;checksum_writes=0;requests=0;responses=0;
            in_isr=0;in_work=0;got_aw=0;got_w=0;rolling_checksum=32'h13579bdf;
        end else if(!done) begin
            if(dut.imem_fault||dut.dmem_fault) $fatal(1,"Timer board unexpected access fault");
            if(dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en||dut.u_soc.u_cpu.u_data_mem.re||dut.u_soc.u_cpu.u_data_mem.we)
                $fatal(1,"Timer board used inactive internal ROM/RAM");
            if(dut.u_soc.dmem_req_valid&&dut.u_soc.dmem_req_ready) requests=requests+1;
            if(dut.u_soc.dmem_rsp_valid&&dut.u_soc.dmem_rsp_ready) responses=responses+1;
            if(dut.awvalid&&dut.awready) begin
                if(got_aw) $fatal(1,"Timer board duplicate AW");
                got_aw=1;buffered_addr=dut.awaddr;
            end
            if(dut.wvalid&&dut.wready) begin
                if(got_w) $fatal(1,"Timer board duplicate W");
                got_w=1;buffered_data=dut.wdata;buffered_strobe=dut.wstrb;
            end
            if(dut.bvalid&&dut.bready) begin
                if(!got_aw||!got_w||dut.bresp!==0) $fatal(1,"Timer board invalid write response");
                if(in_work&&buffered_addr==`TIMER_IRQ_CHECKSUM) begin
                    rolling_checksum=(rolling_checksum<<5)^(rolling_checksum>>2)^checksum_writes;
                    if(buffered_strobe!==4'hf||buffered_data!==rolling_checksum)
                        $fatal(1,"Timer board lost/replayed checksum step %0d",checksum_writes);
                    checksum_writes=checksum_writes+1;
                end
                if(in_work&&buffered_addr==`TIMER_IRQ_WORK) begin
                    work_writes=work_writes+1;
                    if(buffered_strobe!==4'hf||buffered_data!==work_writes)
                        $fatal(1,"Timer board lost/replayed foreground update");
                end
                got_aw=0;got_w=0;
            end
            #1;
            if(dut.trap_valid) begin
                if(in_isr||traps>=3||dut.trap_cause!==32'h80000007||dut.trap_tval!==0||dut.trap_pc[1:0]!=0||
                   dut.u_soc.u_cpu.csr_mstatus!==32'h1880||dut.u_soc.u_cpu.csr_mie!==128||!dut.u_soc.u_cpu.timer_mtip)
                    $fatal(1,"Timer board wrong/nested interrupt PC=%h cause=%h",dut.trap_pc,dut.trap_cause);
                if(requests!=responses||dut.u_soc.u_cpu.mem_active)
                    $fatal(1,"Timer board IRQ interrupted outstanding memory transaction");
                if(traps==0&&dut.trap_pc!==`TIMER_IRQ_WORK_BEGIN)
                    $fatal(1,"Timer board first IRQ skipped foreground PC");
                if(dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_MASK_CHECKS-32'h10000)/4]!==2)
                    $fatal(1,"Timer board IRQ occurred before masked checks completed");
                if(dut.u_soc.retire_valid&&dut.u_soc.wb_pc==dut.trap_pc)
                    $fatal(1,"Timer board interrupted instruction retired at entry");
                pcs[traps]=dut.trap_pc;
                for(j=1;j<32;j=j+1) saved_regs[j]=dut.u_soc.u_cpu.u_regfile.regs[j];
                traps=traps+1;in_isr=1;
            end
            if(dut.u_soc.retire_valid) begin
                if(dut.u_soc.wb_pc==`TIMER_IRQ_MRET) begin
                    if(!in_isr||dut.u_soc.u_cpu.csr_mepc!==pcs[traps-1]||dut.u_soc.u_cpu.csr_mstatus!==32'h1888)
                        $fatal(1,"Timer board MRET did not resume same PC/restore MIE");
                    for(j=1;j<32;j=j+1)
                        if(dut.u_soc.u_cpu.u_regfile.regs[j]!==saved_regs[j])
                            $fatal(1,"Timer board ISR corrupted x%0d",j);
                    mrets=mrets+1;in_isr=0;
                end
                if(dut.u_soc.wb_pc==`TIMER_IRQ_WORK_BEGIN) in_work=1;
                if(dut.u_soc.wb_pc==`TIMER_IRQ_WORK_END) in_work=0;
            end
        end
    end

    task check_completed;
        begin
            wait(dut.u_soc.u_cpu.uart_busy===0);
            wait_cycles=0;
            while(led[1]!==1) begin
                @(posedge clk);#2;wait_cycles=wait_cycles+1;
                if(wait_cycles>1000) $fatal(1,"Timer board PASS LED timeout");
            end
            if(traps!=3||mrets!=3||in_isr||work_writes!=2048||checksum_writes!=2048||
               rolling_checksum!==`TIMER_IRQ_EXPECT_CHECKSUM||led[7:1]!==7'b0000001||dut.gpio_oe!==7||
               dut.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc||dut.u_ram.u_data_mem.mem[4095]!==0||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_COUNT-32'h10000)/4]!==3||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_CHECKSUM-32'h10000)/4]!==`TIMER_IRQ_EXPECT_CHECKSUM||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_WORK-32'h10000)/4]!==2048||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_MASK_CHECKS-32'h10000)/4]!==2||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_FAIL_CODE-32'h10000)/4]!==0||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_GUARD-32'h10000)/4]!==32'h12345678||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_BLINK_CYCLES-32'h10000)/4]!==2000||
               dut.u_soc.u_cpu.csr_mie!==0||dut.u_soc.u_cpu.timer_mtip||dut.u_soc.u_cpu.csr_mstatus!==32'h1880)
                $fatal(1,"Timer board final software/register/LED state mismatch %m IRQ/MRET=%0d/%0d work=%0d checksum=%0d",traps,mrets,work_writes,checksum_writes);
            when_previous=0;
            for(slot=0;slot<3;slot=slot+1) begin
                if(dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+slot*4]!==32'h80000007||
                   dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+slot*4+1]!==pcs[slot]||
                   dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+slot*4+2]!==0||
                   dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_LOG-32'h10000)/4+slot*4+3]!==32'h1880)
                    $fatal(1,"Timer board wrong software IRQ log slot=%0d",slot);
                when_now={dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_WHEN-32'h10000)/4+slot*2+1],
                          dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_WHEN-32'h10000)/4+slot*2]};
                if(slot!=0&&when_now<when_previous+`TIMER_IRQ_PERIOD)
                    $fatal(1,"Timer board rearm period too short");
                when_previous=when_now;
            end
        end
    endtask

    task check_reset;
        begin
            #2;
            if(dut.cpu_rst_n!==0||led!==0||tx!==1||dut.trap_valid||dut.imem_fault||dut.dmem_fault||
               dut.u_soc.u_cpu.mem_active||dut.u_soc.u_cpu.csr_mstatus!==32'h1800||
               dut.u_soc.u_cpu.csr_mtvec!==0||dut.u_soc.u_cpu.csr_mie!==0||dut.u_soc.u_cpu.timer_mtip||
               dut.u_soc.u_cpu.timer_mtime!==0||dut.u_soc.u_cpu.timer_mtimecmp!==64'hffffffffffffffff||
               dut.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc||
               dut.awvalid||dut.wvalid||dut.arvalid||dut.bvalid||dut.rvalid)
                $fatal(1,"Timer board shared reset/CSR/timer defaults/RAM retention");
        end
    endtask

    initial begin
        #2;
        for(i=1;i<32;i=i+1) dut.u_soc.u_cpu.u_regfile.regs[i]=32'h51a70000+i*32'h01010101;
        dut.u_ram.u_data_mem.mem[4094]=32'h55aabbcc;
        if(FIRST_FAIL) dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_GUARD-32'h10000)/4]=0;
        if(dut.cpu_rst_n!==0||led!==0||tx!==1) $fatal(1,"Timer board power-up defaults");
        repeat(15) @(posedge clk);#2;
        if(dut.cpu_rst_n!==0) $fatal(1,"Timer board power-up released too early");
        if(RESET_HANDLER) begin
            wait(dut.trap_valid);
            wait(dut.u_soc.valid_x&&dut.u_soc.pc_x==`TIMER_IRQ_ENTRY+12);
            @(negedge clk);
            if(traps!=1||mrets!=0||boots!==0) $fatal(1,"ISR reset did not cancel first real interrupt");
            key1_n=0;check_reset;
            repeat(4) @(negedge clk);key1_n=1;
        end
        wait(boots==1);
        if(FIRST_FAIL) begin
            wait(dut.u_soc.u_cpu.uart_busy===0);repeat(100) @(posedge clk);#2;
            if(led!==4||dut.gpio_oe!==7||traps!=0||mrets!=0||dut.u_soc.u_cpu.csr_mie!==0||
               dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_FAIL_CODE-32'h10000)/4]!==1||dut.u_ram.u_data_mem.mem[4095]!==0)
                $fatal(1,"Timer board real guard failure did not halt with UART/LED3");
            dut.u_ram.u_data_mem.mem[(`TIMER_IRQ_GUARD-32'h10000)/4]=32'h12345678;
        end else begin
            check_completed;
            old_phase=led[0];wait(led[0]!==old_phase);wait(led[0]===old_phase);
            if(led[7:1]!==7'b0000001) $fatal(1,"Timer board heartbeat changed status LEDs");
        end
        restart_allowed=1;@(negedge clk);key1_n=0;check_reset;
        repeat(4) @(negedge clk);key1_n=1;
        repeat(15) @(posedge clk);#2;
        if(dut.cpu_rst_n!==0) $fatal(1,"Timer board KEY1 hold released too early");
        wait(boots==2);check_completed;
        repeat(100) @(posedge clk);
        $display("TIMER BOARD case %m PASS: reset_handler=%0d first_fail=%0d, three IRQ/MRET, x1..x31, exact checksum, physical UART and KEY1 restart",RESET_HANDLER,FIRST_FAIL);
        done=1;
    end
endmodule
