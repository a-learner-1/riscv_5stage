`timescale 1ns/1ps

module rv32m_cpu_tb;
    reg test_pass = 0;
    wire [6:0] done;
    rv32m_cpu_case #(.PRED(0), .INJECT_IRQ(0)) plain(done[0]);
    rv32m_cpu_case #(.PRED(1), .INJECT_IRQ(0)) predicted(done[1]);
    rv32m_cpu_case #(.PRED(1), .INJECT_IRQ(1)) interrupted(done[2]);
    rv32m_disabled_case disabled(done[3]);
    rv32m_cpu_case #(.PRED(1), .INJECT_IRQ(2)) before_start(done[4]);
    rv32m_cpu_case #(.PRED(1), .INJECT_IRQ(3)) on_div_done(done[5]);
    rv32m_cpu_reset_case reset_active(done[6]);
    initial begin
        wait (&done);
        test_pass = 1;
        $display("RV32M CPU PASS: oracle trace, all 8 ops, dependencies, x0, exact retirement/store, branch squash, IRQ before/during/done, active reset, disabled-M traps and misa");
        $stop;
    end
    initial begin #2000000; $fatal(1, "RV32M CPU timeout done=%b", done); end
endmodule

// A real CPU reset cancels an in-flight divide. A replacement ROM uses the
// same destination and PC with different operands and a multiply; a stale
// completion must never retire or corrupt the restarted program.
module rv32m_cpu_reset_case(output reg done=0);
    reg clk=0,rst_n=0,phase=0,marker=0;
    always #5 clk=~clk;
    wire[31:0] wb_pc,wb_data;
    wire[4:0] wb_rd;
    wire wb_we,retire_valid,trap_valid;
    integer i,retired=0,m_retired=0;
    reg[4:0] seen=0;
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),
        .DMEM_WORDS(64),.ENABLE_M(1),.ENABLE_TRAPS(1),.SIM_CONSOLE_ECHO(0)) dut(
        .clk(clk),.rst_n(rst_n),.irq_external(1'b0),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),.retire_valid(retire_valid),
        .cycle_count(),.instret_count(),.imem_req_valid(),.imem_req_addr(),.imem_req_ready(1'b0),
        .imem_rsp_valid(1'b0),.imem_rsp_ready(),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),
        .imem_fault(),.imem_fault_pc(),.dmem_req_valid(),.dmem_req_write(),.dmem_req_addr(),
        .dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),.dmem_req_ready(1'b0),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),
        .dmem_fault(),.trap_valid(trap_valid),.trap_pc(),.trap_cause(),.trap_tval(),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),
        .bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());
    initial begin
        #1;for(i=0;i<256;i=i+1)dut.u_if_stage.u_instr_mem.mem[i]=32'h13;
        dut.u_if_stage.u_instr_mem.mem[0]=32'hff900093; // addi x1,x0,-7
        dut.u_if_stage.u_instr_mem.mem[1]=32'h00300113; // addi x2,x0,3
        dut.u_if_stage.u_instr_mem.mem[2]=32'h0220c1b3; // div x3,x1,x2
        dut.u_if_stage.u_instr_mem.mem[3]=32'h00118213; // addi x4,x3,1
        dut.u_if_stage.u_instr_mem.mem[4]=32'h00100293;
        dut.u_if_stage.u_instr_mem.mem[5]=32'h0000006f;
        repeat(4)@(negedge clk);rst_n=1;
        wait(dut.m_active);repeat(5)@(negedge clk);
        if(retire_valid && wb_pc==8) $fatal(1,"Reset DIV completed before cancellation stimulus");
        rst_n=0;#1;
        if(dut.m_active || dut.g_m.u_muldiv.busy || dut.g_m.u_muldiv.done || retire_valid)
            $fatal(1,"CPU reset retained active M state/completion");
        dut.u_if_stage.u_instr_mem.mem[0]=32'h00700093;
        dut.u_if_stage.u_instr_mem.mem[1]=32'h00600113;
        dut.u_if_stage.u_instr_mem.mem[2]=32'h022081b3; // mul x3,x1,x2 =42
        phase=1;
        repeat(4)@(negedge clk);rst_n=1;
        wait(marker);repeat(40)@(negedge clk);
        if(retired!=5 || m_retired!=1 || seen!==5'b11111 ||
            dut.u_regfile.regs[3]!==42 || dut.u_regfile.regs[4]!==43 || dut.u_regfile.regs[5]!==1)
            $fatal(1,"CPU reset/restart M result or exact retirement failed");
        done=1;$display("RV32M CPU RESET PASS: active DIV cancelled, restarted MUL retires once, no late result");
    end
    always @(posedge clk) if(rst_n && !done) begin
        #1;
        if(trap_valid) $fatal(1,"RV32M reset case unexpected trap");
        if(retire_valid && !phase && wb_pc>=8) $fatal(1,"Cancelled DIV retired before reset");
        if(retire_valid && phase && wb_pc<20) begin
            if(wb_pc[1:0]!=0 || seen[wb_pc/4] || !wb_we || wb_rd!==wb_pc/4+1 ||
                wb_data!==((wb_pc==0)?32'd7:(wb_pc==4)?32'd6:(wb_pc==8)?32'd42:(wb_pc==12)?32'd43:32'd1))
                $fatal(1,"RV32M reset stale/replayed retirement PC=%h rd=%0d data=%h",wb_pc,wb_rd,wb_data);
            seen[wb_pc/4]=1;retired=retired+1;
            if(wb_pc==8)m_retired=m_retired+1;
            if(wb_pc==16)marker=1;
        end
    end
endmodule

module rv32m_cpu_case #(parameter integer PRED=0, INJECT_IRQ=0)(output reg done=0);
    `include "build/rv32m/rv32m_cpu_meta.vh"
    localparam integer EXPECT_IRQ=(INJECT_IRQ!=0);
    localparam integer EXPECT_RESUME_PC=(INJECT_IRQ==2)?IRQ_PC:IRQ_PC+4;
    reg clk=0, rst_n=0, irq_external=0;
    always #5 clk=~clk;
    wire [31:0] pc_x,instr_x,wb_pc,wb_data,trap_pc,trap_cause,trap_tval;
    wire [4:0] wb_rd;
    wire valid_x,wb_we,retire_valid,trap_valid,imem_fault,dmem_fault;
    wire [63:0] instret_count;
    reg [31:0] program_words[0:2047];
    reg expected_valid[0:1799];
    reg [4:0] expected_rd[0:1799];
    reg [31:0] expected_data[0:1799];
    reg [3:0] expected_flags[0:1799];
    integer retired[0:1799];
    integer file_handle,scan,pc,rd,flags,index,i;
    reg [31:0] value;
    integer main_retired=0,m_retired=0,store_count=0,irq_count=0,handler_retired=0;
    integer m_stall_cycles=0,irq_residence=0;
    reg irq_armed=0,exact_done_pending=0,last_irq_pending=0,prestart_suppressed=0;

    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),
        .IMEM_WORDS(2048),.DMEM_WORDS(128),.ENABLE_M(1),.ENABLE_TRAPS(1),
        .ENABLE_EXTERNAL_IRQ(1),.ENABLE_BRANCH_PRED(PRED),.SIM_CONSOLE_ECHO(0)) dut(
        .clk(clk),.rst_n(rst_n),.irq_external(irq_external),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),.pc_x(pc_x),.instr_x(instr_x),.valid_x(valid_x),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(),.instret_count(instret_count),
        .imem_req_valid(),.imem_req_ready(1'b0),.imem_req_addr(),
        .imem_rsp_valid(1'b0),.imem_rsp_ready(),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),
        .imem_fault(imem_fault),.imem_fault_pc(),
        .dmem_req_valid(),.dmem_req_ready(1'b0),.dmem_req_write(),.dmem_req_addr(),
        .dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),.dmem_rsp_valid(1'b0),
        .dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(dmem_fault),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),
        .bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());

    initial begin
        for(i=0;i<1800;i=i+1) begin
            expected_valid[i]=0;expected_rd[i]=0;expected_data[i]=0;
            expected_flags[i]=0;retired[i]=0;
        end
        $readmemh("build/rv32m/rv32m_cpu_program.hex",program_words);
        file_handle=$fopen("build/rv32m/rv32m_cpu_trace.txt","r");
        if(!file_handle) $fatal(1,"Generate RV32M CPU oracle first");
        while(!$feof(file_handle)) begin
            scan=$fscanf(file_handle,"%h %h %h %h\n",pc,rd,value,flags);
            if(scan==4) begin
                if(pc/4>=1800 || expected_valid[pc/4]) $fatal(1,"Malformed CPU oracle PC");
                expected_valid[pc/4]=1;expected_rd[pc/4]=rd[4:0];
                expected_data[pc/4]=value;expected_flags[pc/4]=flags[3:0];
            end else if(!$feof(file_handle)) $fatal(1,"Malformed CPU oracle row");
        end
        $fclose(file_handle);
        #1;
        for(i=0;i<2048;i=i+1) dut.u_if_stage.u_instr_mem.mem[i]=program_words[i];
        repeat(4) @(negedge clk);rst_n=1;
        if(INJECT_IRQ==2) begin irq_external=1;irq_armed=1;end
    end

    // The pin is raised only after the first DIV has spent several clocks in
    // execution. Its result must retire once before the IRQ saves PC+4.
    always @(negedge clk) if(rst_n && (INJECT_IRQ==1 || INJECT_IRQ==3) && !irq_armed) begin
        if(valid_x && pc_x==IRQ_PC && dut.m_active) irq_residence=irq_residence+1;
        if(irq_residence==((INJECT_IRQ==3)?31:5)) begin irq_external=1;irq_armed=1;end
    end
    always @(posedge clk) if(rst_n && !done) begin
        if(INJECT_IRQ==2 && valid_x && pc_x==IRQ_PC && irq_count==0 &&
            dut.external_irq_sync && dut.csr_mstatus[3]) begin
            if(dut.m_start_x) $fatal(1,"RV32M launched despite interrupt pending before start");
            prestart_suppressed=1;
        end
        if(dut.mem_we_x) begin
            store_count=store_count+1;
            if(dut.mem_addr_x!==256) $fatal(1,"RV32M wrong-path/unexpected store address %h",dut.mem_addr_x);
        end
        if(dut.m_active) m_stall_cycles=m_stall_cycles+1;
        #1;
        if(INJECT_IRQ==3 && dut.m_active && dut.g_m.u_muldiv.done &&
            dut.external_irq_sync && !last_irq_pending) exact_done_pending=1;
        last_irq_pending=dut.external_irq_sync;
        if(imem_fault || dmem_fault) $fatal(1,"RV32M access fault BTB=%0d IRQ=%0d",PRED,INJECT_IRQ);
        if(retire_valid) begin
            if(wb_pc<HANDLER_PC) begin
                index=wb_pc/4;
                if(wb_pc[1:0]!=0 || index>=1800 || !expected_valid[index] || retired[index]!=0)
                    $fatal(1,"RV32M wrong-path/duplicate retirement BTB=%0d IRQ=%0d pc=%h",PRED,INJECT_IRQ,wb_pc);
                retired[index]=retired[index]+1;main_retired=main_retired+1;
                if(wb_we!==expected_flags[index][0] ||
                   (wb_we && (wb_rd!==expected_rd[index] || wb_data!==expected_data[index])))
                    $fatal(1,"RV32M result BTB=%0d IRQ=%0d pc=%h rd=%0d got=%h expected=%h write=%b/%b",
                        PRED,INJECT_IRQ,wb_pc,wb_rd,wb_data,expected_data[index],wb_we,expected_flags[index][0]);
                if(expected_flags[index][2]) m_retired=m_retired+1;
                if(expected_flags[index][1] && dut.u_data_mem.mem[64]!==expected_data[index])
                    $fatal(1,"RV32M store data mismatch PC=%h",wb_pc);
            end else begin
                if(!INJECT_IRQ || irq_count!=1 || wb_pc>HANDLER_PC+8)
                    $fatal(1,"RV32M unexpected handler retirement PC=%h",wb_pc);
                handler_retired=handler_retired+1;
                if(wb_pc==HANDLER_PC && (!wb_we || wb_rd!=26 || wb_data!==EXPECT_RESUME_PC))
                    $fatal(1,"RV32M handler observed wrong mepc %h",wb_data);
                if(wb_pc==HANDLER_PC+4 && (!wb_we || wb_rd!=27 || wb_data!==1))
                    $fatal(1,"RV32M handler marker wrong");
                if(wb_pc==HANDLER_PC+8 && wb_we) $fatal(1,"RV32M MRET wrote register");
            end
        end
        if(trap_valid) begin
            irq_count=irq_count+1;
            if(!INJECT_IRQ || !irq_armed || irq_count!=1 || trap_cause!==32'h8000000b ||
                trap_pc!==EXPECT_RESUME_PC || trap_tval!==0 ||
                retired[IRQ_PC/4]!=((INJECT_IRQ==2)?0:1) || dut.m_active)
                $fatal(1,"RV32M IRQ preempted incomplete DIV or wrong precise descriptor pc=%h cause=%h retired=%0d active=%b",
                    trap_pc,trap_cause,retired[IRQ_PC/4],dut.m_active);
            irq_external=0;
        end
        if(retire_valid && wb_pc==TERMINAL_PC) begin
            if(main_retired!=EXPECT_MAIN_RETIRED || m_retired!=EXPECT_M_OPS ||
                store_count!=EXPECT_STORES || irq_count!=EXPECT_IRQ ||
                handler_retired!=3*EXPECT_IRQ || m_stall_cycles==0 ||
                (INJECT_IRQ==2 && !prestart_suppressed) ||
                (INJECT_IRQ==3 && !exact_done_pending) ||
                // The established CPU counter consumes registered retire_valid
                // one edge later than the WB observation used by this oracle.
                instret_count+64'd1!==main_retired+handler_retired || dut.u_data_mem.mem[0]!==0)
                $fatal(1,"RV32M terminal counts BTB=%0d IRQ=%0d main/M/store/irq/handler=%0d/%0d/%0d/%0d/%0d instret=%0d",
                    PRED,INJECT_IRQ,main_retired,m_retired,store_count,irq_count,handler_retired,instret_count);
            for(i=0;i<1800;i=i+1)
                if(expected_valid[i] && retired[i]!=1) $fatal(1,"RV32M missing instruction PC=%h",i*4);
            done=1;
            $display("RV32M CPU CASE PASS BTB=%0d IRQ=%0d retired=%0d M=%0d stores=%0d M-active=%0d",
                PRED,INJECT_IRQ,main_retired,m_retired,store_count,m_stall_cycles);
        end
    end
endmodule

// The pre-existing RV32I configuration remains a real illegal-instruction
// environment: each funct3 faults, none retires, and misa.M remains clear.
module rv32m_disabled_case(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg[31:0] rom[0:255];
    wire[31:0] wb_pc,wb_data,trap_pc,trap_cause,trap_tval;
    wire[4:0] wb_rd;
    wire wb_we,retire_valid,trap_valid;
    integer i,faults=0,mret_count=0;
    reg[7:0] seen=0;
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),
        .DMEM_WORDS(64),.ENABLE_M(0),.ENABLE_TRAPS(1),.SIM_CONSOLE_ECHO(0)) dut(
        .clk(clk),.rst_n(rst_n),.irq_external(1'b0),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),.retire_valid(retire_valid),
        .cycle_count(),.instret_count(),
        .imem_req_valid(),.imem_req_addr(),.imem_req_ready(1'b0),.imem_rsp_valid(1'b0),
        .imem_rsp_ready(),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),.imem_fault(),.imem_fault_pc(),
        .dmem_req_valid(),.dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),
        .dmem_req_wstrb(),.dmem_req_ready(1'b0),.dmem_rsp_valid(1'b0),.dmem_rsp_ready(),
        .dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),
        .bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());
    initial begin
        for(i=0;i<256;i=i+1)rom[i]=32'h13;
        rom[0]=32'h20000093;    // addi x1,x0,512
        rom[1]=32'h30509073;    // csrw mtvec,x1
        rom[2]=32'h30102173;    // csrr x2,misa
        for(i=0;i<8;i=i+1)rom[3+i]=(1<<25)|(i<<12)|(3<<7)|32'h33;
        rom[11]=32'h00100213;rom[12]=32'h0000006f;
        rom[128]=32'h34102a73;  // csrr x20,mepc
        rom[129]=32'h004a0a13;  // addi x20,x20,4
        rom[130]=32'h341a1073;  // csrw mepc,x20
        rom[131]=32'h30200073;
        #1;for(i=0;i<256;i=i+1)dut.u_if_stage.u_instr_mem.mem[i]=rom[i];
        repeat(4)@(negedge clk);rst_n=1;
    end
    always @(posedge clk) if(rst_n && !done) begin
        #1;
        if(trap_valid) begin
            if(trap_cause!==2 || trap_pc<12 || trap_pc>40 || trap_tval!==rom[trap_pc/4] || seen[trap_pc/4-3])
                $fatal(1,"RV32M disabled wrong/repeated illegal trap pc=%h cause=%h tval=%h",trap_pc,trap_cause,trap_tval);
            seen[trap_pc/4-3]=1;faults=faults+1;
        end
        if(retire_valid) begin
            if(wb_pc>=12 && wb_pc<=40) $fatal(1,"Disabled M instruction retired");
            if(wb_pc==8 && (!wb_we || wb_rd!=2 || wb_data!==32'h40000100))
                $fatal(1,"Disabled M incorrectly advertised in misa %h",wb_data);
            if(wb_pc==524)mret_count=mret_count+1;
            if(wb_pc==44)begin
                if(faults!=8 || seen!==8'hff || mret_count!=8 || !wb_we || wb_rd!=4 || wb_data!==1)
                    $fatal(1,"Disabled M trap/return count wrong");
                done=1;$display("RV32M DISABLED PASS: 8 illegal traps, 8 MRET, misa.M=0");
            end
        end
    end
endmodule
