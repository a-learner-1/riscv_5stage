// New board configuration only: physical 50 MHz / 115200 UART is not sped up.
// The program is the hardware binary. Only blink_cycles in the sim RAM image
// changes from 25000000 to 2000 so a full heartbeat period is observable.
`timescale 1ns/1ps
`include "programs/trap_board_symbols.vh"
module trap_board_tb;
    wire [2:0] done;
    reg test_pass=0;
    trap_board_pass_case #(.RESET_HANDLER(0)) normal(done[0]);
    trap_board_pass_case #(.RESET_HANDLER(1)) reset_handler(done[1]);
    trap_board_software_fail_case software_fail(done[2]);
    initial begin
        wait(&done);test_pass=1;
        $display("PASS: trap board physical UART PASS/FAIL, four precise traps/MRET and FENCE per boot, heartbeat, KEY1 handler cancellation/restart and retained AXI RAM");
        $stop;
    end
    initial begin #10000000;$fatal(1,"Trap board timeout done=%b",done);end
endmodule

module trap_board_uart_checker #(parameter integer FIRST_FAIL=0)(
    input wire tx,rst_n,restart_allowed,
    output reg [31:0] boots=0
);
    localparam integer BIT_NS=434*20;
    localparam [17*8-1:0] PASS_MESSAGE="TRAP BOARD PASS\015\012";
    localparam [26*8-1:0] FAIL_MESSAGE="TRAP BOARD FAIL 00000001\015\012";
    integer bytes=0,bit_index,length;
    reg [7:0] value,expected;
    initial begin
        forever begin
            @(negedge tx);
            if(!rst_n || boots>=2 || (boots==1&&!restart_allowed))
                $fatal(1,"Unexpected trap board UART frame during reset/outside one boot message");
            length=(FIRST_FAIL&&boots==0)?26:17;
            expected=(FIRST_FAIL&&boots==0)?FAIL_MESSAGE[(25-bytes)*8+:8]:
                PASS_MESSAGE[(16-bytes)*8+:8];
            #(BIT_NS/2);
            if(tx!==0) $fatal(1,"Trap board UART start bit");
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                #(BIT_NS);
                if(tx!==0&&tx!==1) $fatal(1,"Unknown trap board UART data");
                value[bit_index]=tx;
            end
            #(BIT_NS);
            if(tx!==1||value!==expected)
                $fatal(1,"Trap board UART boot=%0d byte=%0d got=%h expected=%h",boots,bytes,value,expected);
            bytes=bytes+1;
            if(bytes==length) begin
                bytes=0;boots=boots+1;
                $display("TRAP BOARD UART: %m boot=%0d verified %0d bytes",boots,length);
            end
        end
    end
endmodule

module trap_board_pass_case #(parameter integer RESET_HANDLER=0)(output reg done=0);
    reg clk=0,key1_n=1,restart_allowed=0;
    wire tx;wire [7:0] led;wire [31:0] boots;
    integer traps=0,mrets=0,fences=0,requests=0,responses=0;
    integer slot,wait_cycles;
    reg old_phase;
    reg [31:0] expected_pc,expected_cause,expected_tval;
    trap_board_top #(.DATA_FILE("programs/trap_board_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)) dut(.clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),
        .led(led),.uart_tx(tx),.uart_rx(1'b1));
    trap_board_uart_checker serial(tx,dut.cpu_rst_n,restart_allowed,boots);
    always #10 clk=~clk;
    task expected;
        input integer index;
        begin
            case(index)
                0:begin expected_pc=`TRAP_BOARD_ECALL;expected_cause=11;expected_tval=0;end
                1:begin expected_pc=`TRAP_BOARD_EBREAK;expected_cause=3;expected_tval=`TRAP_BOARD_EBREAK;end
                2:begin expected_pc=`TRAP_BOARD_ILLEGAL;expected_cause=2;expected_tval=32'hffffffff;end
                3:begin expected_pc=`TRAP_BOARD_BADCSR;expected_cause=2;expected_tval=32'h77702073;end
                default:$fatal(1,"Trap board extra exception");
            endcase
        end
    endtask
    always @(posedge clk) begin
        if(!dut.cpu_rst_n) begin traps=0;mrets=0;fences=0;requests=0;responses=0;end
        else if(!done) begin
            if(dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en ||
               dut.u_soc.u_cpu.u_data_mem.re || dut.u_soc.u_cpu.u_data_mem.we)
                $fatal(1,"Trap board used CPU internal ROM/RAM");
            if(dut.imem_fault||dut.dmem_fault) $fatal(1,"Trap board unexpected access fault");
            if(dut.u_soc.dmem_req_valid&&dut.u_soc.dmem_req_ready) requests=requests+1;
            if(dut.u_soc.dmem_rsp_valid&&dut.u_soc.dmem_rsp_ready) responses=responses+1;
            #1;
            if(dut.trap_valid) begin
                expected(traps);
                if(dut.trap_pc!==expected_pc || dut.trap_cause!==expected_cause ||
                   dut.trap_tval!==expected_tval || dut.u_soc.retire_valid)
                    $fatal(1,"Trap board descriptor/retirement slot=%0d PC=%h cause=%h tval=%h",traps,dut.trap_pc,dut.trap_cause,dut.trap_tval);
                traps=traps+1;
            end
            if(dut.u_soc.retire_valid) begin
                if(dut.u_soc.wb_pc==`TRAP_BOARD_ECALL || dut.u_soc.wb_pc==`TRAP_BOARD_EBREAK ||
                   dut.u_soc.wb_pc==`TRAP_BOARD_ILLEGAL || dut.u_soc.wb_pc==`TRAP_BOARD_BADCSR)
                    $fatal(1,"Trap board faulting instruction retired");
                if(dut.u_soc.u_imem.u_instr_mem.mem[dut.u_soc.wb_pc[31:2]]==32'h30200073)
                    mrets=mrets+1;
                if(dut.u_soc.u_imem.u_instr_mem.mem[dut.u_soc.wb_pc[31:2]][6:0]==7'h0f) begin
                    if(requests!=responses) $fatal(1,"Trap board FENCE before previous AXI completion");
                    fences=fences+1;
                end
            end
        end
    end
    task check_completed;
        begin
            wait(dut.u_soc.u_cpu.uart_busy===0);
            wait_cycles=0;
            while(led[1]!==1) begin
                @(posedge clk);#2;wait_cycles=wait_cycles+1;
                if(wait_cycles>1000) $fatal(1,"Trap board PASS LED not enabled");
            end
            if(traps!=4||mrets!=4||fences!=1||led[7:1]!==7'b0000001||dut.gpio_oe!==7||
               dut.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc||
               dut.u_ram.u_data_mem.mem[4095]!==0||
               dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_RAM_GUARD-32'h10000)/4]!==32'h12345678||
               dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_BLINK_CYCLES-32'h10000)/4]!==2000||
               dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_COUNT-32'h10000)/4]!==4||
               dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_RESUMED-32'h10000)/4]!==4||
               dut.u_soc.u_cpu.csr_mscratch!==18||
               (dut.u_soc.u_cpu.csr_mstatus&32'h1888)!==32'h1888)
                $fatal(1,"Trap board completed counts/logs/status/retained RAM");
            for(slot=0;slot<4;slot=slot+1) begin
                expected(slot);
                if(dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_LOG-32'h10000)/4+slot*4]!==expected_cause||
                   dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_LOG-32'h10000)/4+slot*4+1]!==expected_pc||
                   dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_LOG-32'h10000)/4+slot*4+2]!==expected_tval||
                   (dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_LOG-32'h10000)/4+slot*4+3]&32'h1888)!==32'h1880)
                    $fatal(1,"Trap board software trap log slot=%0d",slot);
            end
        end
    endtask
    task check_reset;
        begin
            #2;
            if(dut.cpu_rst_n!==0||led!==0||tx!==1||dut.trap_valid||
               dut.imem_fault||dut.dmem_fault||dut.u_soc.u_cpu.mem_active||
               dut.u_soc.u_cpu.csr_mstatus!==32'h1800||dut.u_soc.u_cpu.csr_mtvec!==0||
               dut.u_soc.u_cpu.csr_mepc!==0||dut.u_soc.u_cpu.csr_mcause!==0||
               dut.u_soc.u_cpu.csr_mtval!==0||dut.u_soc.u_cpu.csr_mscratch!==0||
               dut.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc||
               dut.awvalid||dut.wvalid||dut.arvalid||dut.bvalid||dut.rvalid)
                $fatal(1,"Trap board shared reset/CSR/protocol defaults/RAM retention");
        end
    endtask
    initial begin
        #2;dut.u_ram.u_data_mem.mem[4094]=32'h55aabbcc;
        if(dut.cpu_rst_n!==0||led!==0||tx!==1) $fatal(1,"Trap board power-on defaults");
        repeat(15) @(posedge clk);#2;
        if(dut.cpu_rst_n!==0) $fatal(1,"Trap board power-on release too early");
        if(RESET_HANDLER) begin
            wait(dut.trap_valid);
            wait(dut.u_soc.valid_x&&dut.u_soc.pc_x==`TRAP_BOARD_ENTRY+12);
            @(negedge clk);
            if(traps!=1||mrets!=0||boots!==0) $fatal(1,"Handler reset did not interrupt first real exception");
            key1_n=0;check_reset;
            repeat(4) @(negedge clk);key1_n=1;
        end
        wait(boots==1);check_completed;
        old_phase=led[0];
        wait(led[0]!==old_phase);wait(led[0]===old_phase);
        if(led[7:1]!==7'b0000001) $fatal(1,"Trap board heartbeat changed status LEDs");
        restart_allowed=1;@(negedge clk);key1_n=0;check_reset;
        repeat(4) @(negedge clk);key1_n=1;
        repeat(15) @(posedge clk);#2;
        if(dut.cpu_rst_n!==0) $fatal(1,"Trap board KEY1 hold released too early");
        wait(boots==2);check_completed;
        repeat(100) @(posedge clk);
        $display("TRAP BOARD case %0d PASS: two UART17 boots, 4 traps/4 MRET/1 FENCE each, log/CSR checks, full heartbeat, KEY1 restart and RAM retention",RESET_HANDLER);
        done=1;
    end
endmodule

module trap_board_software_fail_case(output reg done=0);
    reg clk=0,key1_n=1,restart_allowed=0;
    wire tx;wire [7:0] led;wire [31:0] boots;
    trap_board_top #(.DATA_FILE("programs/trap_board_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)) dut(.clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),
        .led(led),.uart_tx(tx),.uart_rx(1'b1));
    trap_board_uart_checker #(.FIRST_FAIL(1)) serial(tx,dut.cpu_rst_n,restart_allowed,boots);
    always #10 clk=~clk;
    initial begin
        #2;dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_RAM_GUARD-32'h10000)/4]=0;
        dut.u_ram.u_data_mem.mem[4094]=32'h55aabbcc;
        wait(boots==1);wait(dut.u_soc.u_cpu.uart_busy===0);
        repeat(100) @(posedge clk);#2;
        if(led!==8'h04||dut.imem_fault||dut.dmem_fault||dut.gpio_oe!==7||
           dut.u_ram.u_data_mem.mem[4095]!==0||
           dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_COUNT-32'h10000)/4]!==0)
            $fatal(1,"Real guard failure did not halt with FAIL/LED3 before traps");
        restart_allowed=1;@(negedge clk);key1_n=0;#2;
        if(dut.cpu_rst_n!==0||led!==0||tx!==1||dut.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc)
            $fatal(1,"Software FAIL KEY1 reset/retention");
        dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_RAM_GUARD-32'h10000)/4]=32'h12345678;
        repeat(4) @(negedge clk);key1_n=1;
        wait(boots==2);wait(dut.u_soc.u_cpu.uart_busy===0);wait(led[1]===1);#2;
        if(dut.imem_fault||dut.dmem_fault||led[7:1]!==7'b0000001||
           dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_COUNT-32'h10000)/4]!==4||
           dut.u_ram.u_data_mem.mem[(`TRAP_BOARD_RESUMED-32'h10000)/4]!==4||
           dut.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc)
            $fatal(1,"Software FAIL correction/KEY1 did not restore real trap PASS");
        $display("TRAP BOARD software FAIL PASS: real RAM guard read, UART26 FAIL and LED3; corrected retained RAM plus KEY1 recovers UART17 and four exceptions");
        done=1;
    end
endmodule
