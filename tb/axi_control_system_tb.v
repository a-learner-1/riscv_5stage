`timescale 1ns/1ps
module axi_control_system_tb;
    wire [8:0] done;
    reg test_pass=0;
    axi_control_c_case #(.WAIT_MODE(0)) c_fast(done[0]);
    axi_control_c_case #(.WAIT_MODE(1)) c_aw_first(done[1]);
    axi_control_c_case #(.WAIT_MODE(2)) c_w_first(done[2]);
    axi_control_fault_case #(.KIND(0)) miss_load(done[3]);
    axi_control_fault_case #(.KIND(1)) miss_store(done[4]);
    axi_control_fault_case #(.KIND(2)) ctrl_ro_write(done[5]);
    axi_control_fault_case #(.KIND(3)) ctrl_bad_read(done[6]);
    axi_control_directed_case #(.RESET_JOB(0)) directed(done[7]);
    axi_control_directed_case #(.RESET_JOB(1)) reset_busy(done[8]);
    initial begin
        wait(&done);test_pass=1;
        $display("PASS: AXI control system: real C config/start/poll/result, RAM/control routing, three jobs, wrong-path START suppression, DECERR/SLVERR and shared reset");
        $stop;
    end
    initial begin #2000000;$fatal(1,"AXI control system timeout done=%h",done);end
endmodule

module axi_control_c_case #(parameter integer WAIT_MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    wire [63:0] cycles,retired;
    wire imem_fault,dmem_fault,busy,job_done;wire [31:0] result,start_count;
    integer busy_status_reads=0,completed_status_reads=0,result_reads=0,start_writes=0;
    soc_axi_control_top #(
        .IMEM_REQ_WAIT_CYCLES(WAIT_MODE?1:0),.IMEM_RSP_WAIT_CYCLES(WAIT_MODE?2:0),
        .RAM_AW_WAIT_CYCLES(WAIT_MODE==2?5:0),.RAM_W_WAIT_CYCLES(WAIT_MODE==1?5:0),
        .RAM_AR_WAIT_CYCLES(WAIT_MODE?2:0),.RAM_B_WAIT_CYCLES(WAIT_MODE?2:0),.RAM_R_WAIT_CYCLES(WAIT_MODE?3:0),
        .CTRL_AW_WAIT_CYCLES(WAIT_MODE==2?6:0),.CTRL_W_WAIT_CYCLES(WAIT_MODE==1?6:0),
        .CTRL_AR_WAIT_CYCLES(WAIT_MODE?3:0),.CTRL_B_WAIT_CYCLES(WAIT_MODE?2:0),.CTRL_R_WAIT_CYCLES(WAIT_MODE?3:0)
    ) dut (.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.uart_tx(),.gpio_out(),.gpio_oe(),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(),
        .cycle_count(cycles),.instret_count(retired),.imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault),
        .ctrl_busy(busy),.ctrl_done(job_done),.ctrl_result(result),.ctrl_start_count(start_count));
    axi_control_route_monitor monitor(clk,rst_n,
        dut.axi_awaddr,
        dut.axi_awprot,
        dut.axi_awvalid,
        dut.axi_awready,
        dut.axi_wdata,
        dut.axi_wstrb,
        dut.axi_wvalid,
        dut.axi_wready,
        dut.axi_bresp,
        dut.axi_bvalid,
        dut.axi_bready,
        dut.axi_araddr,
        dut.axi_arprot,
        dut.axi_arvalid,
        dut.axi_arready,
        dut.axi_rdata,
        dut.axi_rresp,
        dut.axi_rvalid,
        dut.axi_rready,
        dut.ram_awaddr,
        dut.ram_awprot,
        dut.ram_awvalid,
        dut.ram_awready,
        dut.ram_wdata,
        dut.ram_wstrb,
        dut.ram_wvalid,
        dut.ram_wready,
        dut.ram_bresp,
        dut.ram_bvalid,
        dut.ram_bready,
        dut.ram_araddr,
        dut.ram_arprot,
        dut.ram_arvalid,
        dut.ram_arready,
        dut.ram_rdata,
        dut.ram_rresp,
        dut.ram_rvalid,
        dut.ram_rready,
        dut.ctrl_awaddr,
        dut.ctrl_awprot,
        dut.ctrl_awvalid,
        dut.ctrl_awready,
        dut.ctrl_wdata,
        dut.ctrl_wstrb,
        dut.ctrl_wvalid,
        dut.ctrl_wready,
        dut.ctrl_bresp,
        dut.ctrl_bvalid,
        dut.ctrl_bready,
        dut.ctrl_araddr,
        dut.ctrl_arprot,
        dut.ctrl_arvalid,
        dut.ctrl_arready,
        dut.ctrl_rdata,
        dut.ctrl_rresp,
        dut.ctrl_rvalid,
        dut.ctrl_rready);
    reg [31:0] read_addr=0,write_addr=0,write_data=0;
    always @(posedge clk) if(rst_n&&!done) begin
        if(imem_fault||dmem_fault) $fatal(1,"Control C unexpected CPU fault");
        if(dut.u_core.u_cpu.u_if_stage.u_instr_mem.en || dut.u_core.u_cpu.u_data_mem.re || dut.u_core.u_cpu.u_data_mem.we)
            $fatal(1,"Control C used CPU internal memory");
        if(dut.ctrl_arvalid&&dut.ctrl_arready) read_addr=dut.ctrl_araddr;
        if(dut.ctrl_awvalid&&dut.ctrl_awready) write_addr=dut.ctrl_awaddr;
        if(dut.ctrl_wvalid&&dut.ctrl_wready) write_data=dut.ctrl_wdata;
        if(dut.ctrl_rvalid&&dut.ctrl_rready) begin
            if(read_addr==32'h30000004) begin
                if(dut.ctrl_rdata[0]) busy_status_reads=busy_status_reads+1;
                if(dut.ctrl_rdata[1]) completed_status_reads=completed_status_reads+1;
            end
            if(read_addr==32'h30000010) result_reads=result_reads+1;
        end
        if(dut.ctrl_bvalid&&dut.ctrl_bready && write_addr==32'h30000000 && write_data==1)
            start_writes=start_writes+1;
    end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        wait(dut.u_ram.u_data_mem.mem[4095]!==0);
        if(dut.u_ram.u_data_mem.mem[4095]!==1) $fatal(1,"Control C failed tohost=%h",dut.u_ram.u_data_mem.mem[4095]);
        wait(dut.u_core.u_cpu.mem_active===0);@(posedge clk);#1;
        if(start_count!==3 || result!==32'h80000000 || busy || job_done ||
           busy_status_reads<3 || completed_status_reads<3 || result_reads!=6 || start_writes!=3)
            $fatal(1,"Control C task counts/result/status mode=%0d starts=%0d writes=%0d result=%h polls=%0d/%0d reads=%0d",
                WAIT_MODE,start_count,start_writes,result,busy_status_reads,completed_status_reads,result_reads);
        if(monitor.ram_writes==0||monitor.ram_reads==0||monitor.ctrl_writes!=12||monitor.ctrl_reads==0)
            $fatal(1,"Control C missing RAM/control transactions");
        $display("CONTROL C case %0d PASS: tohost=1 jobs=3 result=80000000 busy-polls=%0d done-polls=%0d retired=%0d cycles=%0d RAM W/R=%0d/%0d CTRL W/R=%0d/%0d",
            WAIT_MODE,busy_status_reads,completed_status_reads,retired,cycles,monitor.ram_writes,monitor.ram_reads,monitor.ctrl_writes,monitor.ctrl_reads);
        done=1;
    end
endmodule

module axi_control_directed_case #(parameter integer RESET_JOB=0)(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    wire imem_fault,dmem_fault,retire_valid,busy,job_done;wire [31:0] pc,wb_data,result,start_count;
    integer start_aw=0,seen_wrong=0;
    soc_axi_control_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.DATA_FILE(""),.IMEM_WORDS(256),
        .CTRL_JOB_CYCLES(256),.RAM_AW_WAIT_CYCLES(3),.CTRL_W_WAIT_CYCLES(4)
    ) dut (.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.uart_tx(),.gpio_out(),.gpio_oe(),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(pc),.wb_rd(),.wb_data(wb_data),.wb_we(),.retire_valid(retire_valid),
        .cycle_count(),.instret_count(),.imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault),
        .ctrl_busy(busy),.ctrl_done(job_done),.ctrl_result(result),.ctrl_start_count(start_count));
    function [31:0] itype;
        input integer imm;input [4:0] rs1;input [2:0] f3;input [4:0] rd;input [6:0] op;
        begin itype={imm[11:0],rs1,f3,rd,op};end
    endfunction
    function [31:0] stype;
        input integer imm;input [4:0] rs2,rs1;input [2:0] f3;
        begin stype={imm[11:5],rs2,rs1,f3,imm[4:0],7'h23};end
    endfunction
    function [31:0] btype;
        input integer imm;input [4:0] rs2,rs1;
        begin btype={imm[12],imm[10:5],rs2,rs1,3'b000,imm[4:1],imm[11],7'h63};end
    endfunction
    always @(posedge clk) begin
        if(!rst_n) start_aw=0;
        else if(!done) begin
            if(imem_fault||dmem_fault) $fatal(1,"Control directed CPU fault");
            if(dut.ctrl_awvalid&&dut.ctrl_awready&&dut.ctrl_awaddr==32'h30000000) start_aw=start_aw+1;
        end
        #1;
        if(rst_n&&!done&&retire_valid&&(pc==28||pc==36)) $fatal(1,"Wrong-path START instruction retired");
    end
    initial begin
        #1;
        dut.u_core.u_imem.u_instr_mem.mem[0]=32'h300000b7;
        dut.u_core.u_imem.u_instr_mem.mem[1]=itype(17,0,0,2,7'h13);
        dut.u_core.u_imem.u_instr_mem.mem[2]=stype(8,2,1,2);
        dut.u_core.u_imem.u_instr_mem.mem[3]=itype(25,0,0,2,7'h13);
        dut.u_core.u_imem.u_instr_mem.mem[4]=stype(12,2,1,2);
        dut.u_core.u_imem.u_instr_mem.mem[5]=itype(1,0,0,3,7'h13);
        dut.u_core.u_imem.u_instr_mem.mem[6]=btype(8,3,3);
        dut.u_core.u_imem.u_instr_mem.mem[7]=stype(0,3,1,2);
        dut.u_core.u_imem.u_instr_mem.mem[8]=32'h0080006f;
        dut.u_core.u_imem.u_instr_mem.mem[9]=stype(0,3,1,2);
        dut.u_core.u_imem.u_instr_mem.mem[10]=32'h00010237;
        dut.u_core.u_imem.u_instr_mem.mem[11]=stype(0,3,4,2);
        dut.u_core.u_imem.u_instr_mem.mem[12]=stype(0,3,1,2);
        dut.u_core.u_imem.u_instr_mem.mem[13]=itype(4,1,2,5,7'h03);
        dut.u_core.u_imem.u_instr_mem.mem[14]=itype(2,5,7,5,7'h13);
        dut.u_core.u_imem.u_instr_mem.mem[15]=btype(-8,0,5);
        dut.u_core.u_imem.u_instr_mem.mem[16]=itype(16,1,2,6,7'h03);
        dut.u_core.u_imem.u_instr_mem.mem[17]=stype(4,6,4,2);
        dut.u_core.u_imem.u_instr_mem.mem[18]=itype(20,1,2,7,7'h03);
        dut.u_core.u_imem.u_instr_mem.mem[19]=itype(16,1,2,0,7'h03);
        dut.u_core.u_imem.u_instr_mem.mem[20]=itype(77,0,0,8,7'h13);
        dut.u_core.u_imem.u_instr_mem.mem[21]=32'h0000006f;
        repeat(4) @(negedge clk);rst_n=1;
        if(RESET_JOB) begin
            wait(busy);@(negedge clk);rst_n=0;repeat(4) @(negedge clk);
            if(busy||job_done||result!==0||start_count!==0||dut.u_ram.u_data_mem.mem[0]!==1||dut.u_ram.u_data_mem.mem[1]!==0)
                $fatal(1,"Shared reset failed task cancellation/RAM retention");
            rst_n=1;
        end
        wait(retire_valid&&pc==80);#1;
        if(start_count!==1||start_aw!=1||result!==42||busy||!job_done||wb_data!==77||
           dut.u_ram.u_data_mem.mem[0]!==1||dut.u_ram.u_data_mem.mem[1]!==42)
            $fatal(1,"Control directed wrong-path/routing/reset result");
        $display("CONTROL directed case %0d PASS: branch/JAL suppress two wrong-path STARTs, one job=42, RAM result and shared-reset retention",RESET_JOB);
        done=1;
    end
endmodule

module axi_control_fault_case #(parameter integer KIND=0)(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    wire fault,ifault,rv;wire [31:0] pc,wb_data;
    integer retired=0,ram_writes=0,ctrl_requests=0,seen_error=0;
    reg recovering=0;
    reg [31:0] recovery_write_addr=0,recovery_write_data=0,recovery_read_addr=0;
    reg [31:0] recovery_next_pc=0,recovery_done_test=0;
    reg [15:0] recovery_seen=0;
    integer recovery_ctrl_writes=0,recovery_start_writes=0,recovery_result_reads=0;
    integer recovery_count_reads=0,recovery_ram_writes=0,recovery_ram_reads=0;
    soc_axi_control_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.DATA_FILE(""),.IMEM_WORDS(256),
        .RAM_W_WAIT_CYCLES(3),.CTRL_AW_WAIT_CYCLES(4),.CTRL_R_WAIT_CYCLES(3)
    ) dut (.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.uart_tx(),.gpio_out(),.gpio_oe(),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(pc),.wb_rd(),.wb_data(wb_data),.wb_we(),.retire_valid(rv),
        .cycle_count(),.instret_count(),.imem_fault(ifault),.imem_fault_pc(),.dmem_fault(fault),
        .ctrl_busy(),.ctrl_done(),.ctrl_result(),.ctrl_start_count());
    always @(posedge clk) begin
        if(rst_n&&!done) begin
            if(ifault) $fatal(1,"Control fault case instruction error");
            if(!recovering) begin
                if(dut.u_ram.u_data_mem.we) ram_writes=ram_writes+1;
                if((dut.ctrl_awvalid&&dut.ctrl_awready)||(dut.ctrl_arvalid&&dut.ctrl_arready)) ctrl_requests=ctrl_requests+1;
                if(dut.axi_bvalid&&dut.axi_bready&&dut.axi_bresp!=0) begin
                    if(dut.axi_bresp !== (KIND<2?2'b11:2'b10)) $fatal(1,"Control fault write response code");
                    seen_error=seen_error+1;
                end
                if(dut.axi_rvalid&&dut.axi_rready&&dut.axi_rresp!=0) begin
                    if(dut.axi_rresp !== (KIND<2?2'b11:2'b10) || dut.axi_rdata!==0) $fatal(1,"Control fault read response code/data");
                    seen_error=seen_error+1;
                end
            end else begin
                if(fault || (dut.axi_bvalid&&dut.axi_bready&&dut.axi_bresp!=0) ||
                   (dut.axi_rvalid&&dut.axi_rready&&dut.axi_rresp!=0))
                    $fatal(1,"Control fault case %0d failed legal recovery",KIND);
                if(dut.ram_awvalid&&dut.ram_awready&&dut.ram_awaddr!==32'h10004)
                    $fatal(1,"Recovery unexpectedly rewrote retained RAM word");
                if(dut.u_ram.u_data_mem.we) recovery_ram_writes=recovery_ram_writes+1;
                if(dut.ram_arvalid&&dut.ram_arready) begin
                    if(dut.ram_araddr!==32'h10000) $fatal(1,"Recovery RAM read address");
                    recovery_ram_reads=recovery_ram_reads+1;
                end
                if(dut.ctrl_awvalid&&dut.ctrl_awready) recovery_write_addr=dut.ctrl_awaddr;
                if(dut.ctrl_wvalid&&dut.ctrl_wready) recovery_write_data=dut.ctrl_wdata;
                if(dut.ctrl_bvalid&&dut.ctrl_bready) begin
                    recovery_ctrl_writes=recovery_ctrl_writes+1;
                    if(recovery_write_addr==32'h30000000) begin
                        if(recovery_write_data!==1) $fatal(1,"Recovery START payload");
                        recovery_start_writes=recovery_start_writes+1;
                    end
                end
                if(dut.ctrl_arvalid&&dut.ctrl_arready) recovery_read_addr=dut.ctrl_araddr;
                if(dut.ctrl_rvalid&&dut.ctrl_rready) begin
                    if(recovery_read_addr==32'h30000010) begin
                        if(dut.ctrl_rdata!==42) $fatal(1,"Recovery device RESULT readback");
                        recovery_result_reads=recovery_result_reads+1;
                    end
                    if(recovery_read_addr==32'h30000014) begin
                        if(dut.ctrl_rdata!==1) $fatal(1,"Recovery device START_COUNT readback");
                        recovery_count_reads=recovery_count_reads+1;
                    end
                end
            end
        end
        #1;
        if(rst_n&&!done&&rv) begin
            if(!recovering) begin
                if(pc>=16) $fatal(1,"Control fault failed/younger instruction retired");
                retired=retired+1;
            end else begin
                if(pc!==recovery_next_pc || pc>60 || pc[1:0]!=0)
                    $fatal(1,"Recovery retirement sequence kind=%0d pc=%h expected=%h",KIND,pc,recovery_next_pc);
                recovery_seen[pc>>2]=1;
                case(pc)
                    16:if(wb_data!==25) $fatal(1,"Old failed PC16 instruction leaked through reset");
                    32:if(wb_data!==1&&wb_data!==2) $fatal(1,"Recovery STATUS readback");
                    36:begin
                        if(wb_data!==0&&wb_data!==2) $fatal(1,"Recovery DONE test");
                        recovery_done_test=wb_data;
                    end
                    44:if(wb_data!==42) $fatal(1,"Recovery CPU RESULT load");
                    52:if(wb_data!==42) $fatal(1,"Recovery CPU retained RAM load");
                    56:if(wb_data!==1) $fatal(1,"Recovery CPU START_COUNT load");
                    60:if(wb_data!==77) $fatal(1,"Recovery completion marker");
                endcase
                recovery_next_pc=(pc==40&&recovery_done_test==0)?32:pc+4;
            end
        end
    end
    initial begin
        #1;
        dut.u_core.u_imem.u_instr_mem.mem[0]=32'h000100b7;
        dut.u_core.u_imem.u_instr_mem.mem[1]=32'h02a00113;
        dut.u_core.u_imem.u_instr_mem.mem[2]=32'h0020a023;
        dut.u_core.u_imem.u_instr_mem.mem[3]=KIND<2?32'h400001b7:32'h300001b7;
        case(KIND)
            0:dut.u_core.u_imem.u_instr_mem.mem[4]=32'h0001a203; // lw unmapped
            1:dut.u_core.u_imem.u_instr_mem.mem[4]=32'h0021a023; // sw unmapped
            2:dut.u_core.u_imem.u_instr_mem.mem[4]=32'h0021a223; // sw RO STATUS
            3:dut.u_core.u_imem.u_instr_mem.mem[4]=32'h0fc1a203; // lw unknown register
        endcase
        dut.u_core.u_imem.u_instr_mem.mem[5]=32'h00700293;
        dut.u_core.u_imem.u_instr_mem.mem[6]=32'h0000006f;
        repeat(4) @(negedge clk);rst_n=1;wait(fault);repeat(8) @(negedge clk);
        if(retired!=4||ram_writes!=1||seen_error!=1||dut.u_ram.u_data_mem.mem[0]!==42||
           dut.ctrl_start_count!==0||dut.ctrl_busy||dut.ctrl_done||ctrl_requests!=(KIND<2?0:1))
            $fatal(1,"Control CPU fault precise side effects/route");
        if(dut.u_core.dmem_req_valid||dut.axi_awvalid||dut.axi_wvalid||dut.axi_arvalid||rv)
            $fatal(1,"Control CPU fault did not halt");
        // Reset every endpoint together. Replace only this test's ROM while
        // reset is asserted; the old RAM word is deliberately never rewritten.
        @(negedge clk);rst_n=0;recovering=1;
        dut.u_core.u_imem.u_instr_mem.mem[0]=32'h000100b7;  // lui x1,RAM
        dut.u_core.u_imem.u_instr_mem.mem[1]=32'h300001b7;  // lui x3,CTRL
        dut.u_core.u_imem.u_instr_mem.mem[2]=32'h01100113;  // A=17
        dut.u_core.u_imem.u_instr_mem.mem[3]=32'h0021a423;  // sw A,+8(CTRL)
        dut.u_core.u_imem.u_instr_mem.mem[4]=32'h01900113;  // B=25 (new legal PC16)
        dut.u_core.u_imem.u_instr_mem.mem[5]=32'h0021a623;  // sw B,+12(CTRL)
        dut.u_core.u_imem.u_instr_mem.mem[6]=32'h00100113;  // command=START
        dut.u_core.u_imem.u_instr_mem.mem[7]=32'h0021a023;  // sw START,CTRL
        dut.u_core.u_imem.u_instr_mem.mem[8]=32'h0041a203;  // lw STATUS
        dut.u_core.u_imem.u_instr_mem.mem[9]=32'h00227213;  // andi DONE,2
        dut.u_core.u_imem.u_instr_mem.mem[10]=32'hfe020ce3; // beq DONE,x0,-8
        dut.u_core.u_imem.u_instr_mem.mem[11]=32'h0101a283; // lw RESULT=42
        dut.u_core.u_imem.u_instr_mem.mem[12]=32'h0050a223; // sw RESULT,RAM+4
        dut.u_core.u_imem.u_instr_mem.mem[13]=32'h0000a303; // lw retained RAM=42
        dut.u_core.u_imem.u_instr_mem.mem[14]=32'h0141a383; // lw START_COUNT=1
        dut.u_core.u_imem.u_instr_mem.mem[15]=32'h04d00413; // addi x8,77 marker
        dut.u_core.u_imem.u_instr_mem.mem[16]=32'h0000006f; // terminal loop
        repeat(4) @(negedge clk);
        if(fault||ifault||dut.ctrl_busy||dut.ctrl_done||dut.ctrl_start_count!==0||
           dut.ctrl_result!==0||dut.u_ram.u_data_mem.mem[0]!==42||dut.u_ram.u_data_mem.mem[1]!==0||
           dut.axi_bvalid||dut.axi_rvalid)
            $fatal(1,"Control fault shared reset did not clear state/preserve RAM kind=%0d",KIND);
        rst_n=1;
        wait(rv&&pc==60);@(negedge clk);
        if(fault||ifault||recovery_seen!==16'hffff||recovery_ctrl_writes!=3||recovery_start_writes!=1||
           recovery_result_reads!=1||recovery_count_reads!=1||recovery_ram_writes!=1||recovery_ram_reads!=1||
           dut.ctrl_start_count!==1||dut.ctrl_result!==42||dut.ctrl_busy||!dut.ctrl_done||
           dut.u_ram.u_data_mem.mem[0]!==42||dut.u_ram.u_data_mem.mem[1]!==42||
           retired!=4||ram_writes!=1||seen_error!=1)
            $fatal(1,"Control fault recovery accounting/state kind=%0d",KIND);
        $display("CONTROL fault case %0d PASS: precise DECERR/SLVERR at PC16; shared reset clears fault, retains RAM, and recovers one legal job/result=42",KIND);
        done=1;
    end
endmodule

module axi_control_route_monitor(
    input wire clk,rst_n,
    input wire [31:0] axi_awaddr,
    input wire [2:0] axi_awprot,
    input wire  axi_awvalid,
    input wire  axi_awready,
    input wire [31:0] axi_wdata,
    input wire [3:0] axi_wstrb,
    input wire  axi_wvalid,
    input wire  axi_wready,
    input wire [1:0] axi_bresp,
    input wire  axi_bvalid,
    input wire  axi_bready,
    input wire [31:0] axi_araddr,
    input wire [2:0] axi_arprot,
    input wire  axi_arvalid,
    input wire  axi_arready,
    input wire [31:0] axi_rdata,
    input wire [1:0] axi_rresp,
    input wire  axi_rvalid,
    input wire  axi_rready,
    input wire [31:0] ram_awaddr,
    input wire [2:0] ram_awprot,
    input wire  ram_awvalid,
    input wire  ram_awready,
    input wire [31:0] ram_wdata,
    input wire [3:0] ram_wstrb,
    input wire  ram_wvalid,
    input wire  ram_wready,
    input wire [1:0] ram_bresp,
    input wire  ram_bvalid,
    input wire  ram_bready,
    input wire [31:0] ram_araddr,
    input wire [2:0] ram_arprot,
    input wire  ram_arvalid,
    input wire  ram_arready,
    input wire [31:0] ram_rdata,
    input wire [1:0] ram_rresp,
    input wire  ram_rvalid,
    input wire  ram_rready,
    input wire [31:0] ctrl_awaddr,
    input wire [2:0] ctrl_awprot,
    input wire  ctrl_awvalid,
    input wire  ctrl_awready,
    input wire [31:0] ctrl_wdata,
    input wire [3:0] ctrl_wstrb,
    input wire  ctrl_wvalid,
    input wire  ctrl_wready,
    input wire [1:0] ctrl_bresp,
    input wire  ctrl_bvalid,
    input wire  ctrl_bready,
    input wire [31:0] ctrl_araddr,
    input wire [2:0] ctrl_arprot,
    input wire  ctrl_arvalid,
    input wire  ctrl_arready,
    input wire [31:0] ctrl_rdata,
    input wire [1:0] ctrl_rresp,
    input wire  ctrl_rvalid,
    input wire  ctrl_rready
);
    integer ram_writes=0,ram_reads=0,ctrl_writes=0,ctrl_reads=0;
    integer write_target=2,read_target=2;
    reg [31:0] expected_write_addr,expected_read_addr,expected_wdata;
    reg [3:0] expected_wstrb;
    reg saw=0,sw=0,sar=0,maw=0,mw=0,mar=0;
    function integer route;
        input [31:0] addr;
        begin
            if(addr>=32'h10000&&addr<32'h14000) route=0;
            else if(addr>=32'h30000000&&addr<32'h30000100) route=1;
            else route=2;
        end
    endfunction
    always @(posedge clk) begin
        if(!rst_n) begin
            saw=0;sw=0;sar=0;maw=0;mw=0;mar=0;
            ram_writes=0;ram_reads=0;ctrl_writes=0;ctrl_reads=0;
        end else begin
            if(axi_awvalid&&axi_awready) begin
                if(saw) $fatal(1,"Duplicate upstream write address");
                saw=1;expected_write_addr=axi_awaddr;write_target=route(axi_awaddr);
            end
            if(axi_wvalid&&axi_wready) begin
                if(sw) $fatal(1,"Duplicate upstream write data");
                sw=1;expected_wdata=axi_wdata;expected_wstrb=axi_wstrb;
            end
            if(ram_awvalid&&ram_awready) begin
                if(!saw||write_target!=0||maw||ram_awaddr!==expected_write_addr) $fatal(1,"RAM AW wrong route/address");
                maw=1;
            end
            if(ctrl_awvalid&&ctrl_awready) begin
                if(!saw||write_target!=1||maw||ctrl_awaddr!==expected_write_addr) $fatal(1,"CTRL AW wrong route/address");
                maw=1;
            end
            if(ram_wvalid&&ram_wready) begin
                if(!sw||write_target!=0||mw||ram_wdata!==expected_wdata||ram_wstrb!==expected_wstrb) $fatal(1,"RAM W wrong route/payload");
                mw=1;ram_writes=ram_writes+1;
            end
            if(ctrl_wvalid&&ctrl_wready) begin
                if(!sw||write_target!=1||mw||ctrl_wdata!==expected_wdata||ctrl_wstrb!==expected_wstrb) $fatal(1,"CTRL W wrong route/payload");
                mw=1;ctrl_writes=ctrl_writes+1;
            end
            if(axi_bvalid&&axi_bready) begin
                if(!saw||!sw||!maw||!mw) $fatal(1,"Write completed without exactly one selected slave pair");
                saw=0;sw=0;maw=0;mw=0;
            end
            if(axi_arvalid&&axi_arready) begin
                if(sar) $fatal(1,"Duplicate upstream read address");
                sar=1;expected_read_addr=axi_araddr;read_target=route(axi_araddr);
            end
            if(ram_arvalid&&ram_arready) begin
                if(!sar||read_target!=0||mar||ram_araddr!==expected_read_addr) $fatal(1,"RAM AR wrong route/address");
                mar=1;ram_reads=ram_reads+1;
            end
            if(ctrl_arvalid&&ctrl_arready) begin
                if(!sar||read_target!=1||mar||ctrl_araddr!==expected_read_addr) $fatal(1,"CTRL AR wrong route/address");
                mar=1;ctrl_reads=ctrl_reads+1;
            end
            if(axi_rvalid&&axi_rready) begin
                if(!sar||!mar) $fatal(1,"Read completed without one selected slave address");
                sar=0;mar=0;
            end
            if((ram_awvalid&&ctrl_awvalid)||(ram_wvalid&&ctrl_wvalid)||(ram_arvalid&&ctrl_arvalid))
                $fatal(1,"Router broadcast a request");
        end
    end
endmodule
