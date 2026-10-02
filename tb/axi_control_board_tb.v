`timescale 1ns/1ps
module axi_control_board_tb;
    wire [4:0] done;
    reg test_pass=0;
    axi_board_pass_case #(.RESET_BUSY(0)) normal(done[0]);
    axi_board_pass_case #(.RESET_BUSY(1)) reset_busy(done[1]);
    axi_board_software_fail_case software_fail(done[2]);
    axi_board_cpu_fault_case #(.INSTRUCTION_FAULT(0)) data_fault(done[3]);
    axi_board_cpu_fault_case #(.INSTRUCTION_FAULT(1)) fetch_fault(done[4]);
    initial begin
        wait(&done);test_pass=1;
        $display("PASS: AXI board: 50MHz physical UART results/PASS, LED heartbeat, KEY1 restart and busy cancellation, software FAIL, actual data/fetch fault LEDs and shared reset recovery");
        $stop;
    end
    initial begin #20000000;$fatal(1,"AXI board timeout done=%b",done);end
endmodule

// Decode board pins at the actual 50MHz/115200 rate. No CPU console hooks.
module axi_board_uart_checker #(parameter integer FIRST_FAIL=0)(
    input wire tx,rst_n,restart_allowed,
    output reg [31:0] boots=0
);
    localparam integer BIT_NS=434*20;
    localparam [55*8-1:0] PASS_MESSAGE=
        "AXI RESULTS 0000002A 00000001 80000000\015\012AXI CTRL PASS\015\012";
    localparam [24*8-1:0] FAIL_MESSAGE="AXI CTRL FAIL 00000002\015\012";
    integer bytes=0,bit_index,length;
    reg [7:0] value,expected;
    initial begin
        forever begin
            @(negedge tx);
            if(!rst_n || boots>=2 || (boots==1&&!restart_allowed))
                $fatal(1,"Unexpected UART frame during reset or outside one boot message");
            length=(FIRST_FAIL&&boots==0)?24:55;
            expected=(FIRST_FAIL&&boots==0)?FAIL_MESSAGE[(23-bytes)*8+:8]:
                PASS_MESSAGE[(54-bytes)*8+:8];
            #(BIT_NS/2);
            if(tx!==0) $fatal(1,"AXI board UART start bit");
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                #(BIT_NS);
                if(tx!==0&&tx!==1) $fatal(1,"Unknown AXI board UART data");
                value[bit_index]=tx;
            end
            #(BIT_NS);
            if(tx!==1||value!==expected)
                $fatal(1,"AXI board UART boot=%0d byte=%0d got=%h expected=%h",boots,bytes,value,expected);
            bytes=bytes+1;
            if(bytes==length) begin
                bytes=0;boots=boots+1;
                $display("AXI BOARD UART: %m boot=%0d verified %0d bytes",boots,length);
            end
        end
    end
endmodule

module axi_board_pass_case #(parameter integer RESET_BUSY=0)(output reg done=0);
    reg clk=0,key1_n=1,restart_allowed=0;
    wire tx;wire [7:0] led;wire [31:0] boots;
    reg [31:0] ctrl_write_addr=0,ctrl_write_data=0;
    integer start_writes=0,wait_cycles;
    reg old_phase;
    axi_control_board_top #(.DATA_FILE("programs/axi_control_board_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)) dut(.clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),
        .led(led),.uart_tx(tx),.uart_rx(1'b1));
    axi_board_uart_checker serial(tx,dut.cpu_rst_n,restart_allowed,boots);
    always #10 clk=~clk;
    always @(posedge clk) begin
        if(!dut.cpu_rst_n) begin start_writes=0;ctrl_write_addr=0;ctrl_write_data=0;end
        else if(!done) begin
            if(dut.imem_fault||dut.dmem_fault) $fatal(1,"AXI board unexpected fault");
            if(dut.u_soc.u_core.u_cpu.u_if_stage.u_instr_mem.en ||
               dut.u_soc.u_core.u_cpu.u_data_mem.re || dut.u_soc.u_core.u_cpu.u_data_mem.we)
                $fatal(1,"AXI board bypassed separate memories");
            if(dut.u_soc.ctrl_awvalid&&dut.u_soc.ctrl_awready) ctrl_write_addr=dut.u_soc.ctrl_awaddr;
            if(dut.u_soc.ctrl_wvalid&&dut.u_soc.ctrl_wready) ctrl_write_data=dut.u_soc.ctrl_wdata;
            if(dut.u_soc.ctrl_bvalid&&dut.u_soc.ctrl_bready) begin
                if(dut.u_soc.ctrl_bresp!==0) $fatal(1,"AXI board control response error");
                if(ctrl_write_addr==32'h30000000&&ctrl_write_data==1) start_writes=start_writes+1;
            end
            if(dut.u_soc.ctrl_start_count>3) $fatal(1,"AXI board duplicate START");
        end
    end
    task check_completed;
        begin
            wait(dut.u_soc.u_core.u_cpu.uart_busy===0);
            wait_cycles=0;
            while(led[1]!==1) begin
                @(posedge clk);#2;wait_cycles=wait_cycles+1;
                if(wait_cycles>1000) $fatal(1,"PASS LED not enabled");
            end
            if(start_writes!=3||dut.u_soc.ctrl_start_count!==3||dut.u_soc.ctrl_result!==32'h80000000||
               dut.u_soc.ctrl_busy||dut.u_soc.ctrl_done||led[7:1]!==7'b0000001||
               dut.gpio_oe!==7||dut.u_soc.u_ram.u_data_mem.mem[4095]!==0||
               dut.u_soc.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc)
                $fatal(1,"AXI board completed task counts, LEDs, tohost or RAM retention");
        end
    endtask
    task check_reset;
        begin
            #2;
            if(dut.cpu_rst_n!==0||led!==0||tx!==1||dut.u_soc.ctrl_busy||dut.u_soc.ctrl_done||
               dut.u_soc.ctrl_result!==0||dut.u_soc.ctrl_start_count!==0||
               dut.u_soc.u_ram.u_data_mem.mem[4094]!==32'h55aabbcc||
               dut.u_soc.axi_bvalid||dut.u_soc.axi_rvalid)
                $fatal(1,"AXI board shared reset/defaults/RAM retention");
        end
    endtask
    initial begin
        #2;dut.u_soc.u_ram.u_data_mem.mem[4094]=32'h55aabbcc;
        if(dut.cpu_rst_n!==0||led!==0||tx!==1) $fatal(1,"AXI board power-on defaults");
        repeat(15) @(posedge clk);#2;
        if(dut.cpu_rst_n!==0) $fatal(1,"AXI board power-on release too early");
        if(RESET_BUSY) begin
            wait(dut.u_soc.ctrl_busy);@(negedge clk);key1_n=0;
            check_reset;
            if(boots!==0) $fatal(1,"Busy-reset test already emitted a boot message");
            repeat(4) @(negedge clk);key1_n=1;
        end
        wait(boots==1);check_completed;
        old_phase=led[0];
        wait(led[0]!==old_phase);wait(led[0]===old_phase);
        if(led[7:1]!==7'b0000001) $fatal(1,"Heartbeat changed status LEDs");
        restart_allowed=1;@(negedge clk);key1_n=0;check_reset;
        repeat(4) @(negedge clk);key1_n=1;
        repeat(15) @(posedge clk);#2;
        if(dut.cpu_rst_n!==0) $fatal(1,"AXI board KEY1 hold released early");
        wait(boots==2);check_completed;
        repeat(100) @(posedge clk);
        $display("AXI BOARD case %0d PASS: two 55-byte boots, three jobs per boot, heartbeat, KEY1 reset and RAM retention",RESET_BUSY);
        done=1;
    end
endmodule

module axi_board_software_fail_case(output reg done=0);
    reg clk=0,key1_n=1,restart_allowed=0;
    wire tx;wire [7:0] led;wire [31:0] boots;
    axi_control_board_top #(.DATA_FILE("programs/axi_control_board_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)) dut(.clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),
        .led(led),.uart_tx(tx),.uart_rx(1'b1));
    axi_board_uart_checker #(.FIRST_FAIL(1)) serial(tx,dut.cpu_rst_n,restart_allowed,boots);
    always #10 clk=~clk;
    initial begin
        // Exact symbol address from this firmware's ELF/build_report.json.
        #2;dut.u_soc.u_ram.u_data_mem.mem[23]=0;
        wait(boots==1);wait(dut.u_soc.u_core.u_cpu.uart_busy===0);repeat(100) @(posedge clk);#2;
        if(led!==8'h04||dut.imem_fault||dut.dmem_fault||dut.u_soc.ctrl_start_count!==0||
           dut.u_soc.u_ram.u_data_mem.mem[4095]!==0)
            $fatal(1,"Software FAIL did not stay in its own visible state");
        restart_allowed=1;@(negedge clk);key1_n=0;#2;
        if(led!==0||tx!==1) $fatal(1,"Software FAIL KEY1 reset");
        dut.u_soc.u_ram.u_data_mem.mem[23]=32'h12345678;
        repeat(4) @(negedge clk);key1_n=1;
        wait(boots==2);wait(dut.u_soc.u_core.u_cpu.uart_busy===0);
        wait(led[1]===1);#2;
        if(dut.u_soc.ctrl_start_count!==3||dut.u_soc.ctrl_result!==32'h80000000||
           dut.imem_fault||dut.dmem_fault||led[7:1]!==7'b0000001)
            $fatal(1,"Software FAIL recovery did not complete real tasks");
        $display("AXI BOARD software FAIL PASS: real guard read error2, 24-byte FAIL and LED3; corrected RAM plus KEY1 recovers 55-byte PASS");
        done=1;
    end
endmodule

module axi_board_cpu_fault_case #(parameter integer INSTRUCTION_FAULT=0)(output reg done=0);
    reg clk=0,key1_n=1;
    wire tx;wire [7:0] led;wire [31:0] boots;
    reg [31:0] saved_rom[0:7];integer i;
    axi_control_board_top #(.DATA_FILE("programs/axi_control_board_sim_data.hex"),
        .RESET_HOLD_CYCLES(16)) dut(.clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),
        .led(led),.uart_tx(tx),.uart_rx(1'b1));
    axi_board_uart_checker serial(tx,dut.cpu_rst_n,1'b0,boots);
    always #10 clk=~clk;
    function [31:0] stype;
        input integer imm;input [4:0] rs2,rs1;input [2:0] f3;
        begin stype={imm[11:5],rs2,rs1,f3,imm[4:0],7'h23};end
    endfunction
    initial begin
        #2;
        for(i=0;i<8;i=i+1) saved_rom[i]=dut.u_soc.u_core.u_imem.u_instr_mem.mem[i];
        dut.u_soc.u_core.u_imem.u_instr_mem.mem[0]=32'h000140b7; // RAM end
        dut.u_soc.u_core.u_imem.u_instr_mem.mem[1]=32'h02a00113;
        dut.u_soc.u_core.u_imem.u_instr_mem.mem[2]=stype(-8,2,1,2); // retained marker
        dut.u_soc.u_core.u_imem.u_instr_mem.mem[3]=INSTRUCTION_FAULT?32'h000081b7:32'h400001b7;
        dut.u_soc.u_core.u_imem.u_instr_mem.mem[4]=INSTRUCTION_FAULT?32'h00018067:32'h0001a203;
        dut.u_soc.u_core.u_imem.u_instr_mem.mem[5]=32'h0000006f;
        if(INSTRUCTION_FAULT) wait(dut.imem_fault);else wait(dut.dmem_fault);
        repeat(20) @(posedge clk);#2;
        if(led!==(INSTRUCTION_FAULT?8'h80:8'h40)||tx!==1||boots!==0||
           dut.u_soc.u_ram.u_data_mem.mem[4094]!==42||dut.u_soc.ctrl_start_count!==0)
            $fatal(1,"Actual CPU fault LED/halt/older write");
        if(INSTRUCTION_FAULT&&dut.u_soc.imem_fault_pc!==32'h8000)
            $fatal(1,"Wrong instruction fault PC");
        @(negedge clk);key1_n=0;#2;
        if(dut.imem_fault||dut.dmem_fault||led!==0||tx!==1||dut.u_soc.ctrl_start_count!==0||
           dut.u_soc.u_ram.u_data_mem.mem[4094]!==42)
            $fatal(1,"CPU fault shared reset did not clear fault/retain RAM");
        for(i=0;i<8;i=i+1) dut.u_soc.u_core.u_imem.u_instr_mem.mem[i]=saved_rom[i];
        repeat(4) @(negedge clk);key1_n=1;
        wait(boots==1);wait(dut.u_soc.u_core.u_cpu.uart_busy===0);wait(led[1]===1);#2;
        if(dut.imem_fault||dut.dmem_fault||dut.u_soc.ctrl_start_count!==3||
           dut.u_soc.ctrl_result!==32'h80000000||dut.u_soc.u_ram.u_data_mem.mem[4094]!==42)
            $fatal(1,"CPU fault KEY1 recovery failed board self-test");
        $display("AXI BOARD fault case %0d PASS: real CPU fault LED=%h, no software UART, KEY1 clears fault, retains older RAM write and recovers tasks",INSTRUCTION_FAULT,
                 INSTRUCTION_FAULT?8'h80:8'h40);
        done=1;
    end
endmodule
