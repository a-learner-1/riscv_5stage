`timescale 1ns/1ps
module soc_fault_tb;
    wire [2:0] done;
    reg test_pass=0;
    soc_fault_case #(.CASE_ID(0)) bad_load(done[0]);
    soc_fault_case #(.CASE_ID(1)) bad_store(done[1]);
    soc_fault_case #(.CASE_ID(2)) bad_fetch(done[2]);
    initial begin
        wait(&done); test_pass=1;
        $display("PASS: SoC faults: real ROM/RAM error responses, failed load/store suppression, older store before fetch fault, sticky stop and shared reset recovery");
        $stop;
    end
    initial begin #100000; $fatal(1,"SoC fault timeout done=%b",done); end
endmodule

module soc_fault_case #(parameter integer CASE_ID=0)(output reg done=0);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    wire imem_fault,dmem_fault,retire_valid,wb_we;
    wire [31:0] imem_fault_pc,wb_pc,wb_data;
    wire [4:0] wb_rd;
    integer retirements=0,errors=0,requests=0,held_retirements,held_requests;
    reg recovering=0, recovered=0;
    soc_top #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"), .DATA_FILE(""),
        .IMEM_WORDS(256), .DMEM_WORDS(16), .DMEM_BASE_ADDR(0),
        .SIM_CONSOLE_ECHO(0), .IMEM_RSP_WAIT_CYCLES(2),
        .DMEM_REQ_WAIT_CYCLES(2), .DMEM_RSP_WAIT_CYCLES(7)
    ) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(),.instret_count(),
        .imem_fault(imem_fault),.imem_fault_pc(imem_fault_pc),.dmem_fault(dmem_fault)
    );
    function [31:0] itype;
        input integer imm; input [4:0] rs1; input [2:0] f3; input [4:0] rd; input [6:0] op;
        begin itype={imm[11:0],rs1,f3,rd,op}; end
    endfunction
    function [31:0] stype;
        input integer imm; input [4:0] rs2,rs1;
        begin stype={imm[11:5],rs2,rs1,3'b010,imm[4:0],7'h23}; end
    endfunction
    function [31:0] jtype;
        input integer imm;
        begin jtype={imm[20],imm[10:1],imm[11],imm[19:12],5'd0,7'h6f}; end
    endfunction
    always @(posedge clk) begin
        if(!rst_n) begin retirements=0; errors=0; requests=0; end
        else if(!done) begin
            if(dut.dmem_req_valid && dut.dmem_req_ready) requests=requests+1;
            if(dut.dmem_rsp_valid && dut.dmem_rsp_ready && dut.dmem_rsp_error) errors=errors+1;
            if(dut.imem_rsp_valid && dut.imem_rsp_ready && dut.imem_rsp_error) errors=errors+1;
            if(dut.u_cpu.u_data_mem.re || dut.u_cpu.u_data_mem.we || dut.u_cpu.u_if_stage.u_instr_mem.en)
                $fatal(1,"SoC fault test used disabled internal CPU memory");
        end
        #1;
        if(rst_n && !done && retire_valid) begin
            retirements=retirements+1;
            if(!recovering) begin
                if(CASE_ID!=2 && wb_pc!=0 && wb_pc!=4 && wb_pc!=8)
                    $fatal(1,"SoC failed/younger instruction retired case=%0d pc=%h",CASE_ID,wb_pc);
                if(CASE_ID==2 && wb_pc!=0 && wb_pc!=4 && wb_pc!=1020)
                    $fatal(1,"SoC bad fetch retired invalid PC=%h",wb_pc);
            end else if(wb_we && wb_rd==4 && wb_data==99) recovered=1;
        end
    end
    initial begin
        #1;
        // General registers have no architectural reset value; seed the
        // destination to prove that an errored LOAD leaves it unchanged.
        dut.u_cpu.u_regfile.regs[3]=32'hfeedbeef;
        dut.u_imem.u_instr_mem.mem[0]=itype(42,0,0,1,7'h13);
        if(CASE_ID==2) begin
            dut.u_imem.u_instr_mem.mem[1]=jtype(1016); // PC4 -> last ROM word1020
            dut.u_imem.u_instr_mem.mem[255]=stype(0,1,0);
        end else begin
            dut.u_imem.u_instr_mem.mem[1]=stype(0,1,0);
            dut.u_imem.u_instr_mem.mem[2]=itype(64,0,0,2,7'h13);
            dut.u_imem.u_instr_mem.mem[3]=(CASE_ID==0) ? itype(0,2,2,3,7'h03) : stype(0,1,2);
            dut.u_imem.u_instr_mem.mem[4]=itype(99,0,0,4,7'h13);
            dut.u_imem.u_instr_mem.mem[5]=jtype(0);
        end
        repeat(4) @(negedge clk); rst_n=1;
        wait(imem_fault || dmem_fault);
        repeat(3) @(negedge clk);
        if(retirements!=3 || errors!=1 || dut.u_dmem.u_data_mem.mem[0]!==42)
            $fatal(1,"SoC fault effects case=%0d retired=%0d errors=%0d RAM=%h",CASE_ID,retirements,errors,dut.u_dmem.u_data_mem.mem[0]);
        if(CASE_ID==2) begin
            if(!imem_fault || dmem_fault || imem_fault_pc!==1024 || requests!=1)
                $fatal(1,"SoC fetch fault classification/older store");
        end else if(!dmem_fault || imem_fault || requests!=2 || dut.u_cpu.u_regfile.regs[3]!==32'hfeedbeef)
            $fatal(1,"SoC data fault classification or failed LOAD register write");
        held_retirements=retirements; held_requests=requests;
        repeat(8) @(negedge clk);
        if(retirements!=held_retirements || requests!=held_requests || !(imem_fault || dmem_fault))
            $fatal(1,"SoC fault did not remain stopped");
        rst_n=0; recovering=1;
        repeat(3) @(negedge clk);
        if(imem_fault || dmem_fault || dut.imem_rsp_valid || dut.dmem_rsp_valid ||
           dut.u_dmem.u_data_mem.mem[0]!==42)
            $fatal(1,"SoC shared reset did not cancel fault/response while retaining RAM");
        if(CASE_ID==2) begin
            dut.u_imem.u_instr_mem.mem[1]=32'h00000013;
            dut.u_imem.u_instr_mem.mem[2]=itype(99,0,0,4,7'h13);
            dut.u_imem.u_instr_mem.mem[3]=jtype(0);
        end else begin
            dut.u_imem.u_instr_mem.mem[3]=(CASE_ID==0) ? itype(0,0,2,3,7'h03) : stype(4,1,0);
        end
        rst_n=1;
        wait(recovered);
        @(negedge clk);
        if(imem_fault || dmem_fault) $fatal(1,"SoC fault recovery failed");
        if(CASE_ID==0 && dut.u_cpu.u_regfile.regs[3]!==42) $fatal(1,"SoC recovered LOAD failed");
        if(CASE_ID==1 && dut.u_dmem.u_data_mem.mem[1]!==42) $fatal(1,"SoC recovered STORE failed");
        $display("SOC fault case %0d PASS: exact failure, no younger retirement, sticky stop and shared reset recovery",CASE_ID);
        done=1;
    end
endmodule
