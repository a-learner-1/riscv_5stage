`timescale 1ns/1ps
// Actual CPU exceptions with trap-handler MRET recovery. The instruction
// stream includes an older delayed STORE and forbidden wrong-path STORE.
module btb_rom_boundary_cpu_tb;
    wire [3:0] done;reg test_pass=0;
    btb_rom_boundary_cpu_case #(.ID(0),.PRED(0)) disabled(done[0]);
    btb_rom_boundary_cpu_case #(.ID(1)) local_predicted(done[1]);
    btb_rom_boundary_cpu_case #(.ID(2),.EXTERNAL(1)) external_predicted(done[2]);
    btb_rom_boundary_cpu_case #(.ID(3),.EXTERNAL(1),.DELAYED(1)) held_external(done[3]);
    initial begin wait(&done);test_pass=1;$display("BTB ROM BOUNDARY CPU TESTS PASS: exact retirement, misaligned JAL/no-link, out-of-ROM access fault, older STORE, squash and two MRET recoveries");$stop;end
    initial begin #100000;$fatal(1,"BTB ROM boundary CPU timeout done=%b",done);end
endmodule
module btb_rom_boundary_cpu_case #(parameter integer ID=0,PRED=1,EXTERNAL=0,DELAYED=0)(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    wire [31:0] pc,wb_pc,wb_data,trap_pc,trap_cause,trap_tval,iqa;
    wire [4:0] wb_rd;wire wb_we,retire,trap,ifault,dfault,iqv,iqr,ipr;
    reg ipv=0,ipe=0,ipending=0;reg [31:0] ipd=0,pending_addr=0;
    reg [31:0] rom[0:255];integer req_wait=0,rsp_wait=0;
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(64),
        .DMEM_BASE_ADDR(0),.ENABLE_TRAPS(1),.ENABLE_BRANCH_PRED(PRED),.EXTERNAL_IMEM(EXTERNAL),
        .DMEM_REQ_WAIT_CYCLES(2),.DMEM_RSP_WAIT_CYCLES(3),.SIM_CONSOLE_ECHO(0)) cpu(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),.gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .pc_x(pc),.instr_x(),.valid_x(),.wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),.retire_valid(retire),
        .cycle_count(),.instret_count(),.imem_req_valid(iqv),.imem_req_ready(iqr),.imem_req_addr(iqa),
        .imem_rsp_valid(ipv),.imem_rsp_ready(ipr),.imem_rsp_rdata(ipd),.imem_rsp_error(ipe),.imem_fault(ifault),.imem_fault_pc(),
        .dmem_req_valid(),.dmem_req_ready(1'b0),.dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(dfault),
        .trap_valid(trap),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),.irq_external(1'b0),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());
    assign iqr=rst_n&&!ipending&&!ipv&&(!DELAYED||req_wait>=2);
    always @(posedge clk) begin
        if(!rst_n) begin ipv<=0;ipe<=0;ipending<=0;req_wait<=0;rsp_wait<=0;end
        else begin
            if(iqv&&!iqr) req_wait<=req_wait+1;else req_wait<=0;
            if(ipv&&ipr) ipv<=0;
            if(iqv&&iqr) begin ipending<=1;pending_addr<=iqa;rsp_wait<=DELAYED?3:0;end
            if(ipending) begin
                if(rsp_wait>0) rsp_wait<=rsp_wait-1;
                else begin ipending<=0;ipv<=1;ipe<=pending_addr>=1024||pending_addr[1:0]!=0;
                    ipd<=pending_addr<1024&&pending_addr[1:0]==0?rom[pending_addr>>2]:32'h00000013;
                end
            end
        end
    end
    function [31:0] addi(input integer immediate,input [4:0] rs1,input [4:0] rd);
        addi={immediate[11:0],rs1,3'b000,rd,7'h13};
    endfunction
    function [31:0] store(input integer immediate,input [4:0] rs2);
        store={immediate[11:5],rs2,5'd0,3'b010,immediate[4:0],7'h23};
    endfunction
    function [31:0] csr(input [11:0] address,input [4:0] rs1,input [2:0] f3,input [4:0] rd);
        csr={address,rs1,f3,rd,7'h73};
    endfunction
    function [31:0] jal(input integer immediate,input [4:0] rd);
        jal={immediate[20],immediate[10:1],immediate[11],immediate[19:12],rd,7'h6f};
    endfunction
    integer expected_pc[0:16],retired=0,traps=0,mrets=0,ram_writes=0,k,fd;
    reg held_request=0,finishing=0;reg [31:0] held_addr=0;
    always @(posedge clk) begin
        if(rst_n&&!done&&!finishing) begin
            if(dfault) $fatal(1,"BTB boundary test left a sticky data fault");
            if(cpu.mem_we_x) ram_writes=ram_writes+1;
            if(held_request&&(!iqv||iqa!==held_addr)) $fatal(1,"BTB boundary held fetch address changed");
            held_request=iqv&&!iqr;held_addr=iqa;
        end
        #1;
        if(rst_n&&!done&&!finishing) begin
            if(trap) begin
                if(traps==0) begin
                    if(trap_pc!==24||trap_cause!==0||trap_tval!==30||ram_writes!=1)
                        $fatal(1,"BTB precise misaligned JAL descriptor/older STORE failed");
                end else if(traps==1) begin
                    if(trap_pc!==1024||trap_cause!==1||trap_tval!==1024)
                        $fatal(1,"BTB precise out-of-ROM fault descriptor failed");
                end else $fatal(1,"BTB boundary repeated trap");
                traps=traps+1;
            end
            if(retire) begin
                if(retired>=17||wb_pc!==expected_pc[retired]) $fatal(1,"BTB boundary retirement sequence id=%0d index=%0d got=%h expected=%h",ID,retired,wb_pc,expected_pc[retired]);
                $fwrite(fd,"%0d,%0d,%08h,%0d,%0d,%08h\n",ID,retired,wb_pc,wb_we&&wb_rd!=0,(wb_we&&wb_rd!=0)?wb_rd:0,(wb_we&&wb_rd!=0)?wb_data:0);
                retired=retired+1;
                if(wb_pc==768&&(!wb_we||wb_rd!=20||wb_data!==traps-1)) $fatal(1,"BTB trap handler mcause readback failed");
                if(wb_pc==776) mrets=mrets+1;
                if(wb_pc==52) begin
                    if(traps!=2||mrets!=2||ram_writes!=2||cpu.u_data_mem.mem[0]!==42||cpu.u_data_mem.mem[1]!==7||cpu.u_data_mem.mem[2]!==0||
                        cpu.u_regfile.regs[5]!==85||cpu.u_regfile.regs[6]!==36||!wb_we||wb_rd!=31||wb_data!==1)
                        $fatal(1,"BTB boundary architectural effects/link/squash ledger failed");
                    // WB outputs are registered here; the real regfile consumes
                    // them on the next edge. Stop scoring at the terminal PC
                    // and verify that final architectural write after it lands.
                    finishing=1;
                    fork begin
                        @(posedge clk);#2;
                        if(cpu.u_regfile.regs[31]!==1) $fatal(1,"Terminal WB did not reach the real regfile");
                        $fclose(fd);done=1;$display("BTB ROM CPU CASE PASS id=%0d pred=%0d external=%0d waits=%0d traps=2 mret=2 retired=17 RAM_writes=2",ID,PRED,EXTERNAL,DELAYED);
                    end join_none
                end
            end
        end
    end
    initial begin
        fd=$fopen($sformatf("build/verification/btb_rom_cpu_case_%0d.csv",ID),"w");if(!fd) $fatal(1,"Create build/verification before boundary tests");
        $fwrite(fd,"case_id,sequence,pc,write_enable,rd,data\n");
        #1;for(k=0;k<256;k=k+1) rom[k]=32'h00000013;
        rom[0]=addi(768,0,22);rom[1]=csr('h305,22,1,0);rom[2]=addi(28,0,21);rom[3]=addi(85,0,5);
        rom[4]=addi(42,0,1);rom[5]=store(0,1);rom[6]=jal(6,5);rom[7]=addi(44,0,21);
        rom[8]=jal(1024-32,6);rom[9]=store(8,1);rom[10]=addi(99,0,29);rom[11]=addi(7,0,2);
        rom[12]=store(4,2);rom[13]=addi(1,0,31);rom[14]=jal(0,0);
        rom[192]=csr('h342,0,2,20);rom[193]=csr('h341,21,1,0);rom[194]=32'h30200073;
        for(k=0;k<256;k=k+1) cpu.u_if_stage.u_instr_mem.mem[k]=rom[k];
        expected_pc[0]=0;expected_pc[1]=4;expected_pc[2]=8;expected_pc[3]=12;expected_pc[4]=16;expected_pc[5]=20;
        expected_pc[6]=768;expected_pc[7]=772;expected_pc[8]=776;expected_pc[9]=28;expected_pc[10]=32;
        expected_pc[11]=768;expected_pc[12]=772;expected_pc[13]=776;expected_pc[14]=44;expected_pc[15]=48;expected_pc[16]=52;
        repeat(4) @(negedge clk);rst_n=1;
    end
endmodule
