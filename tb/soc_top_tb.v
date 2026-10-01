`timescale 1ns/1ps
module soc_top_tb;
    wire [3:0] done;
    reg test_pass=0;
    soc_c_case #(.WAIT_MODE(0)) c_fast(done[0]);
    soc_c_case #(.WAIT_MODE(1)) c_wait(done[1]);
    soc_directed_case #(.WAIT_MODE(0)) directed_fast(done[2]);
    soc_directed_case #(.WAIT_MODE(1)) directed_wait(done[3]);
    initial begin
        wait(&done);
        test_pass=1;
        $display("PASS: SoC integration: existing C HEX, default counters, delayed real memory endpoints, subwords, forwarding, branch/JAL/JALR, precise retirement and wrong-path MMIO suppression");
        $stop;
    end
    initial begin #200000; $fatal(1,"SoC integration timeout done=%b",done); end
endmodule

module soc_c_case #(parameter integer WAIT_MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] pc_x,instr_x;
    wire [63:0] cycle_count,instret_count;
    wire imem_fault,dmem_fault;
    integer overlap=0;
    soc_top #(
        .PROGRAM_FILE("programs/c_demo.hex"), .DATA_FILE("programs/c_demo_data.hex"),
        .SIM_CONSOLE_ECHO(0),
        .IMEM_REQ_WAIT_CYCLES(WAIT_MODE ? 2 : 0),
        .IMEM_RSP_WAIT_CYCLES(WAIT_MODE ? 3 : 0),
        .DMEM_REQ_WAIT_CYCLES(WAIT_MODE ? 3 : 0),
        .DMEM_RSP_WAIT_CYCLES(WAIT_MODE ? 5 : 0)
    ) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .pc_x(pc_x),.instr_x(instr_x),.valid_x(),
        .wb_pc(),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(),
        .cycle_count(cycle_count),.instret_count(instret_count),
        .imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault)
    );
    always @(posedge clk) if(rst_n && !done) begin
        if(dut.u_cpu.u_if_stage.u_instr_mem.en || dut.u_cpu.u_data_mem.re || dut.u_cpu.u_data_mem.we)
            $fatal(1,"SoC C case used CPU internal memory");
        if(imem_fault || dmem_fault) $fatal(1,"SoC C fault pc=%h instruction=%h",pc_x,instr_x);
        if((dut.imem_req_valid || dut.imem_rsp_valid) &&
           (dut.dmem_req_valid || dut.dmem_rsp_valid)) overlap=overlap+1;
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait(dut.u_dmem.u_data_mem.mem[4095] !== 0);
        if(dut.u_dmem.u_data_mem.mem[4095] !== 1)
            $fatal(1,"SoC C tohost failure mode=%0d code=%h",WAIT_MODE,dut.u_dmem.u_data_mem.mem[4095]);
        wait(dut.u_cpu.mem_active === 0);
        @(posedge clk); #1;
        if(dut.u_dmem.u_data_mem.mem[0] !== 32'h12345678 || instret_count !== 155)
            $fatal(1,"SoC C initialized data/counters mode=%0d data=%h instret=%0d",WAIT_MODE,dut.u_dmem.u_data_mem.mem[0],instret_count);
        if(WAIT_MODE == 0 && cycle_count !== 216)
            $fatal(1,"SoC default C cycle count changed got=%0d expected=216",cycle_count);
        if(overlap == 0) $fatal(1,"SoC C instruction/data overlap not exercised");
        $display("SOC C case %0d PASS: tohost=1 initialized data=12345678 retired=%0d cycles=%0d overlap=%0d",WAIT_MODE,instret_count,cycle_count,overlap);
        done=1;
    end
endmodule

module soc_directed_case #(parameter integer WAIT_MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] wb_pc,wb_data;
    wire [4:0] wb_rd;
    wire wb_we,retire_valid,imem_fault,dmem_fault;
    wire [7:0] gpio_out,gpio_oe;
    integer retired=0,requests=0,responses=0,mmio_writes=0,overlap=0;
    integer seen[0:36];
    integer i;
    soc_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"), .DATA_FILE(""),
        .IMEM_WORDS(256),.DMEM_WORDS(64),.DMEM_BASE_ADDR(32'd0),
        .SIM_CONSOLE_ECHO(0), .IMEM_REQ_WAIT_CYCLES(WAIT_MODE ? 2 : 0),
        .IMEM_RSP_WAIT_CYCLES(WAIT_MODE ? 4 : 0),
        .DMEM_REQ_WAIT_CYCLES(WAIT_MODE ? 3 : 0),
        .DMEM_RSP_WAIT_CYCLES(WAIT_MODE ? 7 : 0)
    ) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(gpio_out),.gpio_oe(gpio_oe),
        .pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(),.instret_count(),
        .imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault)
    );
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
    function [31:0] jtype;
        input integer imm;input [4:0] rd;
        begin jtype={imm[20],imm[10:1],imm[11],imm[19:12],rd,7'h6f};end
    endfunction
    initial begin
        #1;
        for(i=0;i<37;i=i+1) seen[i]=0;
        dut.u_imem.u_instr_mem.mem[0]=itype(0,0,0,1,7'h13);
        dut.u_imem.u_instr_mem.mem[1]={20'h80ff8,5'd2,7'h37};
        dut.u_imem.u_instr_mem.mem[2]=itype(-255,2,0,2,7'h13);
        dut.u_imem.u_instr_mem.mem[3]=stype(0,2,1,2);
        dut.u_imem.u_instr_mem.mem[4]=itype(2,1,0,3,7'h03);
        dut.u_imem.u_instr_mem.mem[5]=itype(2,3,0,4,7'h13);
        dut.u_imem.u_instr_mem.mem[6]=itype(2,1,4,5,7'h03);
        dut.u_imem.u_instr_mem.mem[7]=itype(2,1,1,6,7'h03);
        dut.u_imem.u_instr_mem.mem[8]=itype(2,1,5,7,7'h03);
        dut.u_imem.u_instr_mem.mem[9]=itype(0,1,2,8,7'h03);
        dut.u_imem.u_instr_mem.mem[10]=itype(102,0,0,9,7'h13);
        dut.u_imem.u_instr_mem.mem[11]=stype(1,9,1,0);
        dut.u_imem.u_instr_mem.mem[12]=itype(-1348,0,0,9,7'h13);
        dut.u_imem.u_instr_mem.mem[13]=stype(2,9,1,1);
        dut.u_imem.u_instr_mem.mem[14]=itype(0,1,2,10,7'h03);
        dut.u_imem.u_instr_mem.mem[15]=itype(16,0,0,11,7'h13);
        dut.u_imem.u_instr_mem.mem[16]=stype(4,11,1,2);
        dut.u_imem.u_instr_mem.mem[17]=itype(4,1,2,12,7'h03);
        dut.u_imem.u_instr_mem.mem[18]=stype(0,10,12,2);
        dut.u_imem.u_instr_mem.mem[19]=itype(16,1,2,13,7'h03);
        dut.u_imem.u_instr_mem.mem[20]=itype(0,1,2,0,7'h03);
        dut.u_imem.u_instr_mem.mem[21]={20'h20000,5'd14,7'h37};
        dut.u_imem.u_instr_mem.mem[22]=btype(12,10,13);
        dut.u_imem.u_instr_mem.mem[23]=stype(52,9,14,2);
        dut.u_imem.u_instr_mem.mem[24]=stype(20,9,1,2);
        dut.u_imem.u_instr_mem.mem[25]=jtype(12,15);
        dut.u_imem.u_instr_mem.mem[26]=stype(16,9,14,2);
        dut.u_imem.u_instr_mem.mem[27]=stype(24,9,1,2);
        dut.u_imem.u_instr_mem.mem[28]=itype(128,0,0,17,7'h13);
        dut.u_imem.u_instr_mem.mem[29]=itype(0,17,0,18,7'h67);
        dut.u_imem.u_instr_mem.mem[30]=stype(52,9,14,2);
        dut.u_imem.u_instr_mem.mem[31]=stype(24,9,1,2);
        dut.u_imem.u_instr_mem.mem[32]=itype(1,0,0,19,7'h13);
        dut.u_imem.u_instr_mem.mem[33]=stype(40,19,14,2);
        dut.u_imem.u_instr_mem.mem[34]=stype(52,19,14,2);
        dut.u_imem.u_instr_mem.mem[35]=stype(28,4,1,2);
        dut.u_imem.u_instr_mem.mem[36]=itype(42,0,0,16,7'h13);
        dut.u_imem.u_instr_mem.mem[37]=jtype(0,0);
        repeat(4) @(negedge clk);rst_n=1;
    end
    always @(posedge clk) begin
        if(rst_n && !done) begin
            if(dut.u_cpu.u_if_stage.u_instr_mem.en || dut.u_cpu.u_data_mem.re || dut.u_cpu.u_data_mem.we)
                $fatal(1,"SoC directed used CPU internal memory");
            if(imem_fault || dmem_fault) $fatal(1,"SoC directed unexpected fault");
            if(dut.dmem_req_valid && dut.dmem_req_ready) requests=requests+1;
            if(dut.dmem_rsp_valid && dut.dmem_rsp_ready) responses=responses+1;
            if((dut.imem_req_valid || dut.imem_rsp_valid) &&
               (dut.dmem_req_valid || dut.dmem_rsp_valid)) overlap=overlap+1;
            if(dut.u_cpu.mem_req_fire && dut.u_cpu.mem_req_mmio) begin
                if(dut.u_cpu.pc_x != 132 && dut.u_cpu.pc_x != 136)
                    $fatal(1,"SoC wrong-path MMIO side effect pc=%h",dut.u_cpu.pc_x);
                mmio_writes=mmio_writes+1;
            end
        end
        #1;
        if(rst_n && !done && retire_valid) begin
            if(wb_pc[1:0] != 0 || wb_pc > 144 || wb_pc == 92 || wb_pc == 96 ||
               wb_pc == 104 || wb_pc == 108 || wb_pc == 120 || wb_pc == 124)
                $fatal(1,"SoC unexpected/wrong-path retirement pc=%h",wb_pc);
            seen[wb_pc[7:2]]=seen[wb_pc[7:2]]+1;
            if(seen[wb_pc[7:2]] != 1) $fatal(1,"SoC duplicate retirement pc=%h",wb_pc);
            retired=retired+1;
            case(wb_pc)
                16: if(!wb_we || wb_rd!=3 || wb_data!==32'hffffffff) $fatal(1,"SoC LB");
                20: if(!wb_we || wb_rd!=4 || wb_data!==1) $fatal(1,"SoC load-use");
                24: if(wb_data!==255) $fatal(1,"SoC LBU");
                28: if(wb_data!==32'hffff80ff) $fatal(1,"SoC LH");
                32: if(wb_data!==32'h000080ff) $fatal(1,"SoC LHU");
                36: if(wb_data!==32'h80ff7f01) $fatal(1,"SoC LW");
                56,76: if(wb_data!==32'hfabc6601) $fatal(1,"SoC subword writes/store forwarding");
                68: if(wb_data!==16) $fatal(1,"SoC loaded store address");
                80: if(wb_we) $fatal(1,"SoC LW x0");
                100: if(!wb_we || wb_rd!=15 || wb_data!==104) $fatal(1,"SoC JAL link");
                116: if(!wb_we || wb_rd!=18 || wb_data!==120) $fatal(1,"SoC JALR link");
                144: begin
                    if(wb_data!==42 || retired!=31 || requests!=15 || responses!=15)
                        $fatal(1,"SoC directed counts retired=%0d req=%0d rsp=%0d",retired,requests,responses);
                    for(i=0;i<37;i=i+1)
                        if(i!=23 && i!=24 && i!=26 && i!=27 && i!=30 && i!=31 && seen[i]!=1)
                            $fatal(1,"SoC directed skipped PC %0d",i*4);
                    if(dut.u_dmem.u_data_mem.mem[0]!==32'hfabc6601 || dut.u_dmem.u_data_mem.mem[1]!==16 ||
                       dut.u_dmem.u_data_mem.mem[4]!==32'hfabc6601 || dut.u_dmem.u_data_mem.mem[5]!==0 ||
                       dut.u_dmem.u_data_mem.mem[6]!==0 || dut.u_dmem.u_data_mem.mem[7]!==1)
                        $fatal(1,"SoC directed final RAM/wrong-path store");
                    if(mmio_writes!=2 || gpio_out!==1 || gpio_oe!==1 || overlap==0)
                        $fatal(1,"SoC directed MMIO/overlap writes=%0d overlap=%0d",mmio_writes,overlap);
                    $display("SOC directed case %0d PASS: 31 unique retirements, 15 RAM transactions, two GPIO writes, overlap=%0d",WAIT_MODE,overlap);
                    done=1;
                end
                default:;
            endcase
        end
    end
endmodule
