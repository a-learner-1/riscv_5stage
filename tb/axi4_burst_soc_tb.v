`timescale 1ns/1ps
`include "programs/axi_burst_demo_board_config.vh"
module axi4_burst_soc_tb;
    wire [1:0] done;reg test_pass=0;
    axi4_burst_firmware_case firmware(done[0]);
    axi4_burst_csr_trap_case csr_faults(done[1]);
    initial begin wait(&done);test_pass=1;$display("AXI4 BURST SOC PASS: identical hardware C image, physical UART, D0/cache, real 10 AR/34 R/12 seeds and precise illegal CSR load/store traps");$stop;end
    initial begin #20000000;
        $display("SoC timeout detail PC=%h tohost=%h status=%h checks=%h terminal pending/rsp/retired=%b/%b/%b terminal_pc=%h UART=%s",firmware.dut.pc_x,firmware.ram(`TOHOST_ADDR),firmware.ram(`AXI_BURST_DEMO_STATUS_ADDR),firmware.ram(`AXI_BURST_DEMO_CHECKS_ADDR),firmware.pending_terminal,firmware.terminal_response,firmware.terminal_retired,firmware.terminal_pc,firmware.console);
        $fatal(1,"AXI4 real SoC timeout done=%b",done);end
endmodule

module axi4_burst_firmware_case(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire tx,retire,trap,ifault,dfault;wire [7:0] gpio,oe;wire [31:0] wb_pc;
    // Hardware image/configuration is unmodified (115200 on the board).
    // Only this simulation instance accelerates the physical UART to 5M.
    soc_axi_burst_demo_top #(.PROGRAM_FILE("programs/axi_burst_demo_board.hex"),.DATA_FILE("programs/axi_burst_demo_board_data.hex"),.UART_CLOCK_HZ(50000000),.UART_BAUD(5000000)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(tx),.gpio_in(8'd0),.gpio_out(gpio),.gpio_oe(oe),
        .retire_valid(retire),.wb_pc(wb_pc),.trap_valid(trap),.imem_fault(ifault),.dmem_fault(dfault),.pc_x(),.instr_x(),.valid_x(),.wb_data(),.wb_rd(),.wb_we(),.cycle_count(),.instret_count(),.imem_fault_pc(),.trap_pc(),.trap_cause(),.trap_tval(),.burst_busy(),.burst_done(),.burst_error());
    axi4_read_contract_monitor monitor(.clk(clk),.rst_n(rst_n),.araddr(dut.burst_araddr),.arprot(dut.burst_arprot),.arlen(dut.burst_arlen),.arsize(dut.burst_arsize),.arburst(dut.burst_arburst),.arvalid(dut.burst_arvalid),.arready(dut.burst_arready),.rdata(dut.burst_rdata),.rresp(dut.burst_rresp),.rlast(dut.burst_rlast),.rvalid(dut.burst_rvalid),.rready(dut.burst_rready),.accepted_bursts(),.completed_bursts(),.accepted_beats(),.reset_cancels());
    reg [31:0] model0[0:1023],model1[0:1023];
    integer ars=0,rs=0,lasts=0,seeds=0,endpoint0=0,endpoint1=0,beat=0,len=0,target=-1,k,lane,index;
    reg active=0;reg [31:0] address,expected,terminal_pc=0;reg [1:0] expected_resp;
    reg pending_terminal=0,terminal_response=0,terminal_retired=0;
    string console="";reg [7:0] character;integer bit_index,fd;
    function [31:0] ram(input [31:0] a);
        ram=dut.u_core.g_d0_bram.u_ram.u_data_mem.mem[(a-32'h10000)>>2];
    endfunction
    always begin
        @(negedge tx);if(rst_n&&!done) begin
            #(300); // 1.5 bit times at 50 MHz / 5 MHz.
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin character[bit_index]=tx;#200;end
            if(tx!==1) $fatal(1,"Burst C UART stop bit invalid");
            console={console,character};
        end
    end
    always @(posedge clk) if(rst_n&&!done) begin
        if(trap||ifault||dfault) $fatal(1,"Real C demo encountered a CPU fault");
        if(dut.seed_valid&&dut.seed_ready) begin
            if(dut.seed_error) $fatal(1,"Real C legal seed failed");
            if(dut.seed_addr>=32'h40000000&&dut.seed_addr<32'h40001000) begin index=(dut.seed_addr-32'h40000000)>>2;
                for(lane=0;lane<4;lane=lane+1) if(dut.seed_wstrb[lane]) model0[index][lane*8+:8]=dut.seed_wdata[lane*8+:8];end
            else if(dut.seed_addr>=32'h40001000&&dut.seed_addr<32'h40002000) begin index=(dut.seed_addr-32'h40001000)>>2;
                for(lane=0;lane<4;lane=lane+1) if(dut.seed_wstrb[lane]) model1[index][lane*8+:8]=dut.seed_wdata[lane*8+:8];end
            else $fatal(1,"Real C seeded an unexpected region");seeds=seeds+1;
        end
        if(dut.burst_arvalid&&dut.burst_arready) begin
            if(active||dut.burst_arsize!=2||dut.burst_arburst!=1||(dut.burst_arlen!=0&&dut.burst_arlen!=3)) $fatal(1,"Real C did not issue one actual single/four-beat AXI AR");
            address=dut.burst_araddr;len=dut.burst_arlen;beat=0;active=1;ars=ars+1;
            if(address[1:0]!=0||({1'b0,address[11:0]}+4*(len+1))>4096) begin target=-1;expected_resp=2;end
            else if(address>=32'h40000000&&address+4*(len+1)<=32'h40001000) begin target=0;expected_resp=0;end
            else if(address>=32'h40001000&&address+4*(len+1)<=32'h40002000) begin target=1;expected_resp=0;end
            else begin target=-1;expected_resp=3;end
            $fwrite(fd,"AR,%0d,%08h,%0d,%0d,0,0,0\n",ars,address,len,target);
        end
        if(dut.buffer0_arvalid&&dut.buffer0_arready) begin if(target!=0) $fatal(1,"Wrong buffer0 AR");endpoint0=endpoint0+1;end
        if(dut.buffer1_arvalid&&dut.buffer1_arready) begin if(target!=1) $fatal(1,"Wrong buffer1 AR");endpoint1=endpoint1+1;end
        if((dut.buffer0_rready&&target!=0)||(dut.buffer1_rready&&target!=1)) $fatal(1,"Real SoC consumed an unselected buffer");
        if(dut.burst_rvalid&&dut.burst_rready) begin
            if(!active) $fatal(1,"Real C unsolicited R");
            expected=target==0?model0[((address-32'h40000000)>>2)+beat]:target==1?model1[((address-32'h40001000)>>2)+beat]:0;
            if({dut.burst_rdata,dut.burst_rresp,dut.burst_rlast}!=={expected,expected_resp,(beat==len)}) $fatal(1,"Real C R payload/response/last mismatch AR=%0d beat=%0d",ars,beat);
            $fwrite(fd,"R,%0d,%08h,%0d,%0d,%08h,%0d,%0d\n",ars,address,len,beat,dut.burst_rdata,dut.burst_rresp,dut.burst_rlast);
            rs=rs+1;if(dut.burst_rlast) begin lasts=lasts+1;active=0;end beat=beat+1;
        end
        if(dut.u_core.u_cpu.mem_req_fire&&dut.u_core.u_cpu.mem_req_write&&dut.u_core.u_cpu.mem_addr_x==`TOHOST_ADDR&&dut.u_core.u_cpu.mem_wdata_x!=0) begin
            if(pending_terminal||terminal_response||dut.u_core.u_cpu.mem_wdata_x!==1||dut.u_core.u_cpu.mem_size_x!==2||dut.u_core.u_cpu.mem_wstrb_x!==15) $fatal(1,"Real C terminal store invalid/repeated");
            // A ready D-cache accepts in the first EX cycle, before the
            // descriptor register is updated. Later acceptance uses its
            // captured PC. Match the CPU's public request selection rule.
            pending_terminal=1;terminal_pc=dut.u_core.u_cpu.mem_active?
                dut.u_core.u_cpu.mem_pc_q:dut.pc_x;
        end
        if(dut.u_core.u_cpu.mem_rsp_fire&&pending_terminal) begin if(dut.u_core.u_cpu.mem_rsp_error) $fatal(1,"Real C terminal store response failed");pending_terminal=0;terminal_response=1;end
        #1;if(retire&&terminal_response&&wb_pc==terminal_pc) terminal_retired=1;
    end
    initial begin
        fd=$fopen("build/verification/axi4_burst_soc_trace.csv","w");if(!fd) $fatal(1,"Create evidence directory");
        $fwrite(fd,"event,ar_sequence,address,arlen,beat_or_target,data,response,last\n");
        for(k=0;k<1024;k=k+1) begin model0[k]=0;model1[k]=0;end
        repeat(5) @(negedge clk);rst_n=1;wait(terminal_retired);@(negedge clk);
        if(ars!=10||rs!=34||lasts!=10||seeds!=12||endpoint0!=3||endpoint1!=4||active||pending_terminal||gpio!==2||oe!==7) $fatal(1,"Real C actual fabric/GPIO ledger did not close");
        if(ram(`TOHOST_ADDR)!==1||ram(`AXI_BURST_DEMO_STATUS_ADDR)!==1||ram(`AXI_BURST_DEMO_CHECKS_ADDR)!==10||ram(`AXI_BURST_DEMO_GUARD_ADDR)!==32'h13579bdf) $fatal(1,"Real C backing RAM status/checks/initialized guard invalid");
        if(ram(`AXI_BURST_DEMO_CHECKSUM_ADDR)!==(model1[16]^model1[17]^model1[19]^model0[17])) $fatal(1,"Real C checksum mismatch");
        for(k=0;k<4;k=k+1) begin
            if(ram(`AXI_BURST_DEMO_OBSERVED_ADDR+4*k)!==model1[16+k]||dut.u_buffer0.u_data_mem.mem[16+k]!==model0[16+k]||dut.u_buffer1.u_data_mem.mem[16+k]!==model1[16+k]) $fatal(1,"Real C final results/physical partial seed data mismatch");
        end
        for(k=0;k<32;k=k+1) if(ram(`AXI_BURST_DEMO_SCRATCH_ADDR+4*k)!==(32'h2468ace0^(k<<8)^k)) $fatal(1,"Real C D0/cache scratch corruption");
        if(!ram(`AXI_BURST_DEMO_DCACHE_WRITES_ADDR)||!ram(`AXI_BURST_DEMO_DCACHE_HITS_ADDR)||!ram(`AXI_BURST_DEMO_DCACHE_MISSES_ADDR)) $fatal(1,"D0 D-cache statistics were bypassed/zero");
        if(console.len()<27||console.substr(console.len()-27,console.len()-1)!=="AXI4 READ BURST DEMO PASS\015\012") $fatal(1,"Physical UART missing exact C success tail: %s",console);
        $fclose(fd);$display("%s",console);$display("AXI4 REAL C PASS: CPU accepted/responded/retired tohost; AR=10 R=34 LAST=10 seeds=12 endpoint_AR=3/4; UART simulation=5M hardware config remains115200");done=1;
    end
endmodule

module axi4_burst_csr_trap_case(output reg done=0);
    reg clk=0,rst_n=0;always #10 clk=~clk;
    wire retire,trap,dfault,ifault,wb_we;wire [31:0] wb_pc,wb_data,tp,tc,tv;wire [4:0] wb_rd;
    soc_axi_burst_demo_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.DATA_FILE(""),.IMEM_WORDS(256),.UART_BAUD(5000000)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.retire_valid(retire),.wb_pc(wb_pc),.wb_data(wb_data),.wb_rd(wb_rd),.wb_we(wb_we),.trap_valid(trap),.trap_pc(tp),.trap_cause(tc),.trap_tval(tv),.imem_fault(ifault),.dmem_fault(dfault),.uart_tx(),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),.cycle_count(),.instret_count(),.imem_fault_pc(),.burst_busy(),.burst_done(),.burst_error());
    integer pc_expected[0:14],count=0,traps=0,k;reg finishing=0;
    function [31:0] csr(input [11:0] addr,input [4:0] rs1,input [2:0] f3,input [4:0] rd);csr={addr,rs1,f3,rd,7'h73};endfunction
    always @(posedge clk) if(rst_n&&!done&&!finishing) begin
        #1;if(ifault||dfault) $fatal(1,"CSR fault recovery left sticky fault");
        if(trap) begin
            if(traps==0&&{tp,tc,tv}!=={32'd16,32'd5,32'h30001040}) $fatal(1,"Illegal CSR LOAD lost precise descriptor");
            if(traps==1&&{tp,tc,tv}!=={32'd24,32'd7,32'h30001038}) $fatal(1,"Read-only CSR STORE lost precise descriptor");
            if(traps>1) $fatal(1,"Repeated CSR trap");traps=traps+1;
        end
        if(retire) begin
            if(count>=15||wb_pc!==pc_expected[count]) $fatal(1,"CSR trap exact retirement mismatch seq=%0d pc=%h",count,wb_pc);count=count+1;
            if(wb_pc==32) begin
                if(traps!=2||count!=15||dut.u_core.u_cpu.u_regfile.regs[3]!==99||dut.u_core.u_cpu.u_regfile.regs[5]!==32'h42525354||!wb_we||wb_rd!=6||wb_data!==1) $fatal(1,"CSR precise traps changed destination/side effects");
                finishing=1;fork begin @(posedge clk);#2;if(dut.u_core.u_cpu.u_regfile.regs[6]!==1) $fatal(1,"CSR recovery terminal WB missing");$display("AXI4 CSR CPU TRAPS PASS: exact LOAD/STORE PC/cause/tval, 15 retirements, two MRET, no burst side effect");done=1;end join_none
            end
        end
        if(dut.burst_arvalid||dut.seed_valid) $fatal(1,"Invalid CSR request leaked a burst/seed side effect");
    end
    initial begin
        #1;for(k=0;k<256;k=k+1) dut.u_core.u_imem.u_instr_mem.mem[k]=32'h00000013;
        dut.u_core.u_imem.u_instr_mem.mem[0]=32'h08000093;dut.u_core.u_imem.u_instr_mem.mem[1]=csr('h305,1,1,0);
        dut.u_core.u_imem.u_instr_mem.mem[2]=32'h30001137;dut.u_core.u_imem.u_instr_mem.mem[3]=32'h06300193;
        dut.u_core.u_imem.u_instr_mem.mem[4]=32'h04012183;dut.u_core.u_imem.u_instr_mem.mem[5]=32'h00100213;
        dut.u_core.u_imem.u_instr_mem.mem[6]=32'h02412c23;dut.u_core.u_imem.u_instr_mem.mem[7]=32'h03812283;
        dut.u_core.u_imem.u_instr_mem.mem[8]=32'h00100313;dut.u_core.u_imem.u_instr_mem.mem[9]=32'h0000006f;
        dut.u_core.u_imem.u_instr_mem.mem[32]=csr('h341,0,2,10);dut.u_core.u_imem.u_instr_mem.mem[33]=32'h00450513;
        dut.u_core.u_imem.u_instr_mem.mem[34]=csr('h341,10,1,0);dut.u_core.u_imem.u_instr_mem.mem[35]=32'h30200073;
        pc_expected[0]=0;pc_expected[1]=4;pc_expected[2]=8;pc_expected[3]=12;pc_expected[4]=128;pc_expected[5]=132;pc_expected[6]=136;pc_expected[7]=140;
        pc_expected[8]=20;pc_expected[9]=128;pc_expected[10]=132;pc_expected[11]=136;pc_expected[12]=140;pc_expected[13]=28;pc_expected[14]=32;
        repeat(5) @(negedge clk);rst_n=1;
    end
endmodule
