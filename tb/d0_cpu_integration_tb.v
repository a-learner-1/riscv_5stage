`timescale 1ns/1ps
module d0_cpu_integration_tb;
    wire [1:0] done;reg test_pass=0;
    d0_cpu_integration_case fast(done[0]);
    d0_cpu_integration_case #(.ID(1),.DELAYED(1)) delayed_axi(done[1]);
    initial begin wait(&done);test_pass=1;$display("D0 CPU INTEGRATION TESTS PASS: real CPU/cache/synchronous RAM/AXI, STORE=2, subwords/limits, precise faults and accepted-reset retention");$stop;end
    initial begin #500000;$fatal(1,"D0 CPU integration timeout done=%b",done);end
endmodule
module d0_cpu_integration_case #(parameter integer ID=0,DELAYED=0)(output reg done=0);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    wire [31:0] pc,wb_pc,wb_data,tp,tc,tv;wire [4:0] wb_rd;
    wire retire,wb_we,trap,ifault,dfault;wire [7:0] gpio_out;
    wire [31:0] awaddr,wdata,araddr,rdata;wire [2:0] awprot,arprot;wire [3:0] wstrb;
    wire awv,awr,wv,wr,bv,br,arv,arr,rv,rr;wire [1:0] bresp,rresp;
    wire [31:0] da,dh,dm,df,de,dw,db;
    soc_axi_lite_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.DATA_FILE(""),.IMEM_WORDS(256),
        .DMEM_WORDS(64),.DMEM_BASE_ADDR(32'h10000),.ENABLE_D0_BRAM(1),.ENABLE_DCACHE(1),.DCACHE_SETS(4),
        .ENABLE_TRAPS(1),.SIM_CONSOLE_ECHO(0)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),.uart_tx(),.gpio_out(gpio_out),.gpio_oe(),
        .pc_x(pc),.instr_x(),.valid_x(),.wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),.retire_valid(retire),
        .cycle_count(),.instret_count(),.imem_fault(ifault),.imem_fault_pc(),.dmem_fault(dfault),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awv),.m_axi_awready(awr),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wv),.m_axi_wready(wr),
        .m_axi_bresp(bresp),.m_axi_bvalid(bv),.m_axi_bready(br),.m_axi_araddr(araddr),.m_axi_arprot(arprot),
        .m_axi_arvalid(arv),.m_axi_arready(arr),.m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rv),.m_axi_rready(rr),
        .trap_valid(trap),.trap_pc(tp),.trap_cause(tc),.trap_tval(tv),.irq_external(1'b0),
        .dcache_access_count(da),.dcache_hit_count(dh),.dcache_miss_count(dm),.dcache_refill_word_count(df),
        .dcache_error_count(de),.dcache_write_count(dw),.dcache_bypass_count(db),.perf_cycle_events(),
        .icache_access_count(),.icache_hit_count(),.icache_miss_count(),.icache_refill_word_count(),.icache_error_count(),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count());
    axi_lite_ram #(.WORDS(64),.BASE_ADDR(32'h30000000),.INIT_FILE(""),
        .AW_WAIT_CYCLES(DELAYED?3:0),.W_WAIT_CYCLES(DELAYED?1:0),.AR_WAIT_CYCLES(DELAYED?2:0),
        .B_WAIT_CYCLES(DELAYED?4:0),.R_WAIT_CYCLES(DELAYED?3:0)) axi_ram(
        .clk(clk),.rst_n(rst_n),.s_axi_awaddr(awaddr),.s_axi_awprot(awprot),.s_axi_awvalid(awv),.s_axi_awready(awr),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wv),.s_axi_wready(wr),.s_axi_bresp(bresp),.s_axi_bvalid(bv),.s_axi_bready(br),
        .s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arvalid(arv),.s_axi_arready(arr),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rv),.s_axi_rready(rr));
    integer cursor=0,terminal_pc=0,phase=0,cycle=0,ram_writes=0,axi_writes=0,axi_reads=0,stores=0,start=-1,store_pc=-1,i,fd;
    reg [31:0] expected[0:255];reg check_fixed[0:255];
    function [31:0] it(input integer imm,input [4:0] rs1,input [2:0] f3,input [4:0] rd,input [6:0] op);
        it={imm[11:0],rs1,f3,rd,op};
    endfunction
    function [31:0] st(input integer imm,input [4:0] rs2,input [4:0] rs1,input [2:0] f3);
        st={imm[11:5],rs2,rs1,f3,imm[4:0],7'h23};
    endfunction
    task emit(input [31:0] instruction);begin dut.u_imem.u_instr_mem.mem[cursor]=instruction;cursor=cursor+1;end endtask
    task value(input integer v);begin emit(it(v,0,0,2,'h13));end endtask
    task load(input integer offset,input [4:0] base,input [2:0] f3,input [4:0] rd,input [31:0] value);
        begin check_fixed[cursor]=1;expected[cursor]=value;emit(it(offset,base,f3,rd,3));end
    endtask
    task reset_program;
        begin @(negedge clk);rst_n=0;repeat(3) @(negedge clk);
            if(dut.dmem_rsp_valid||dut.bridge_rsp_valid||dut.g_d0_bram.ram_rsp_valid||awv||wv||arv||bv||rv)
                $fatal(1,"D0 shared reset failed to clear pending native/AXI responses");
            for(i=0;i<256;i=i+1) begin dut.u_imem.u_instr_mem.mem[i]=32'h00000013;check_fixed[i]=0;end
            cursor=0;emit({20'h00010,5'd1,7'h37});
        end
    endtask
    task finish_program;begin terminal_pc=cursor*4;emit(it(1,0,0,31,'h13));emit(32'h0000006f);end endtask
    task start_program;begin @(negedge clk);rst_n=1;end endtask
    task wait_terminal;begin wait(retire&&wb_pc==terminal_pc);repeat(3) @(negedge clk);end endtask
    always @(posedge clk) begin
        cycle=cycle+1;
        if(!rst_n) begin ram_writes=0;axi_writes=0;axi_reads=0;stores=0;start=-1;store_pc=-1;end
        else begin
            if(ifault||dfault) $fatal(1,"D0 CPU integration unexpected sticky fault");
            if(dut.g_d0_bram.ram_req_valid&&dut.axi_req_valid) $fatal(1,"D0 request reached local and AXI targets together");
            if(dut.g_d0_bram.u_ram.mem_we) ram_writes=ram_writes+1;
            if(awv&&awr) begin
                if(phase==1&&awaddr<32'h30000000) $fatal(1,"D0 RAM STORE leaked to AXI");axi_writes=axi_writes+1;
            end
            if(arv&&arr) begin
                if(phase==1&&araddr<32'h30000000) $fatal(1,"D0 RAM LOAD leaked to AXI");axi_reads=axi_reads+1;
            end
            if(phase==1&&dut.u_cpu.mem_start_x&&dut.u_cpu.is_store_x&&dut.u_cpu.mem_addr_x>=32'h10000&&dut.u_cpu.mem_addr_x<32'h10100) begin start=cycle;store_pc=pc;end
        end
        #1;
        if(rst_n&&retire) begin
            if(check_fixed[wb_pc>>2]&&(!wb_we||wb_data!==expected[wb_pc>>2])) $fatal(1,"D0 integrated readback pc=%h data=%h expected=%h",wb_pc,wb_data,expected[wb_pc>>2]);
            if(phase==1&&wb_pc==store_pc) begin
                if(cycle-start!=2) $fatal(1,"D0 integrated STORE latency=%0d expected2",cycle-start);
                stores=stores+1;$fwrite(fd,"%0d,%08h,%0d,%0d,%0d\n",ID,wb_pc,start,cycle,cycle-start);store_pc=-1;
            end
            if(phase==2&&wb_pc==8) $fatal(1,"D0 faulting instruction retired");
        end
        if(rst_n&&trap&&phase!=2) $fatal(1,"D0 unexpected trap pc=%h cause=%h",tp,tc);
    end
    task fault(input [31:0] instruction,input [31:0] cause,input [31:0] address);
        begin reset_program;phase=2;value('h77);emit(instruction);finish_program;start_program;
            wait(trap);@(negedge clk);
            if(tp!==8||tc!==cause||tv!==address||ram_writes||dut.g_d0_bram.u_ram.u_data_mem.mem[0]!==32'h04567e23)
                $fatal(1,"D0 precise fault or RAM suppression failed pc=%h cause=%h tval=%h",tp,tc,tv);
        end
    endtask
    initial begin
        fd=$fopen($sformatf("build/verification/d0_cpu_store_case_%0d.csv",ID),"w");if(!fd) $fatal(1,"Create build/verification");
        $fwrite(fd,"case_id,pc,launch,retire,total_cycles\n");
        reset_program;phase=1;value('h123);emit(st(0,2,1,2));load(0,1,2,3,'h123);
        value('h7e);emit(st(1,2,1,0));load(0,1,5,4,'h7e23);
        value('h456);emit(st(2,2,1,1));load(0,1,2,7,32'h04567e23);
        value('h5a);emit(st(255,2,1,0));load(255,1,4,8,'h5a);
        emit({20'h30000,5'd5,7'h37});value('h789);emit(st(32,2,5,2));load(32,5,2,9,'h789);
        load(0,1,2,10,32'h04567e23);emit({20'h20000,5'd6,7'h37});emit(st('h20,2,6,2));load('h20,6,2,11,'h89);
        load(16,1,2,12,0);load(16,1,2,13,0);finish_program;start_program;wait_terminal;
        if(da!==13||dh!==4||dm!==3||df!==12||de!==0||dw!==4||db!==2||ram_writes!=4||stores!=4||axi_writes!=1||axi_reads!=1||gpio_out!==8'h89)
            $fatal(1,"D0 cache/routing counter ledger a/h/m/f/e/w/b=%0d/%0d/%0d/%0d/%0d/%0d/%0d",da,dh,dm,df,de,dw,db);
        fault(it(256,1,2,3,3),5,32'h10100);fault(st(256,2,1,2),7,32'h10100);fault(it(1,1,2,3,3),4,32'h10001);
        // Cancel between the real BRAM commit and CPU response consumption.
        reset_program;phase=3;value('h66);emit(st(8,2,1,2));finish_program;start_program;
        wait(dut.g_d0_bram.u_ram.mem_we);@(posedge clk);#1;
        if(dut.g_d0_bram.u_ram.u_data_mem.mem[2]!==32'h66||retire&&wb_pc==8) $fatal(1,"D0 accepted write did not precede completion");
        reset_program;phase=4;load(8,1,2,3,'h66);finish_program;start_program;wait_terminal;
        if(ram_writes||de||df!==4) $fatal(1,"D0 reset replayed STORE or failed to refill retained RAM");
        $fclose(fd);done=1;$display("D0 CPU CASE %0d PASS STORE=2 byte/halfword/word, cache13=4hit+3miss+4write+2bypass, AXI errors and accepted-reset retention",ID);
    end
endmodule
