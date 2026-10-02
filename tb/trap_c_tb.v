`timescale 1ns/1ps
`include "programs/trap_demo_symbols.vh"
module trap_c_tb;
    wire [2:0] done;
    reg test_pass=0;
    trap_c_case #(.MODE(0)) fast(done[0]);
    trap_c_case #(.MODE(1)) aw_first(done[1]);
    trap_c_case #(.MODE(2)) w_first(done[2]);
    initial begin
        wait(&done); test_pass=1;
        $display("PASS: real trap C firmware over AXI RAM, full register save/restore, four exact traps/MRET, CSR/FENCE and physical UART");
        $stop;
    end
    initial begin #2000000; $fatal(1,"Trap C timeout done=%b",done); end
endmodule

module trap_c_case #(parameter integer MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] awaddr,wdata,araddr,rdata;
    wire [2:0] awprot,arprot;
    wire [3:0] wstrb;
    wire [1:0] bresp,rresp;
    wire awvalid,awready,wvalid,wready,bvalid,bready;
    wire arvalid,arready,rvalid,rready,tx;
    wire trap_valid,retire_valid,imem_fault,dmem_fault;
    wire [31:0] trap_pc,trap_cause,trap_tval,wb_pc;
    wire [63:0] cycles,instret;
    integer traps=0,mrets=0,fences=0,bytes=0;
    integer aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0,requests=0,responses=0;
    integer i,bit_index;
    reg [31:0] expected_pc,expected_cause,expected_tval;
    reg [7:0] received;
    localparam [42*8-1:0] MESSAGE="TRAP PASS FENCE CSR ECALL EBREAK ILLEGAL\015\012";
    soc_axi_lite_top #(
        .PROGRAM_FILE("programs/trap_demo.hex"),.DATA_FILE("programs/trap_demo_data.hex"),
        .ENABLE_TRAPS(1),.SIM_CONSOLE_ECHO(0),.UART_CLOCK_HZ(100000000),.UART_BAUD(5000000),
        .IMEM_REQ_WAIT_CYCLES(MODE?2:0),.IMEM_RSP_WAIT_CYCLES(MODE?3:0),
        .MMIO_REQ_WAIT_CYCLES(MODE?1:0),.MMIO_RSP_WAIT_CYCLES(MODE?2:0)
    ) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(tx),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),
        .wb_pc(wb_pc),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(retire_valid),
        .cycle_count(cycles),.instret_count(instret),
        .imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault),
        .m_axi_awaddr(awaddr),.m_axi_awprot(awprot),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_araddr(araddr),.m_axi_arprot(arprot),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval)
    );
    axi_lite_ram #(
        .INIT_FILE("programs/trap_demo_data.hex"),
        .AW_WAIT_CYCLES(MODE==2?5:0),.W_WAIT_CYCLES(MODE==1?5:0),
        .B_WAIT_CYCLES(MODE?4:0),.AR_WAIT_CYCLES(MODE?3:0),.R_WAIT_CYCLES(MODE?6:0)
    ) ram (
        .clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awprot(awprot),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(arprot),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready)
    );
    task expected;
        input integer slot;
        begin
            case(slot)
                0:begin expected_pc=`TRAP_DEMO_ECALL; expected_cause=11;expected_tval=0;end
                1:begin expected_pc=`TRAP_DEMO_EBREAK;expected_cause=3;expected_tval=`TRAP_DEMO_EBREAK;end
                2:begin expected_pc=`TRAP_DEMO_ILLEGAL;expected_cause=2;expected_tval=32'hffffffff;end
                3:begin expected_pc=`TRAP_DEMO_BADCSR;expected_cause=2;expected_tval=32'h77702073;end
                default:$fatal(1,"Trap C extra exception");
            endcase
        end
    endtask
    always @(posedge clk) if(rst_n && !done) begin
        if(awvalid&&awready) aw_count=aw_count+1;
        if(wvalid&&wready) w_count=w_count+1;
        if(bvalid&&bready) b_count=b_count+1;
        if(arvalid&&arready) ar_count=ar_count+1;
        if(rvalid&&rready) r_count=r_count+1;
        if(dut.dmem_req_valid&&dut.dmem_req_ready) requests=requests+1;
        if(dut.dmem_rsp_valid&&dut.dmem_rsp_ready) responses=responses+1;
        if(dut.u_cpu.u_data_mem.re || dut.u_cpu.u_data_mem.we || dut.u_cpu.u_if_stage.u_instr_mem.en)
            $fatal(1,"Trap C used CPU internal RAM/ROM");
        if(imem_fault || dmem_fault) $fatal(1,"Unexpected C access fault");
        #1;
        if(trap_valid) begin
            expected(traps);
            if(trap_pc!==expected_pc || trap_cause!==expected_cause || trap_tval!==expected_tval || retire_valid)
                $fatal(1,"Trap C descriptor/suppression mode=%0d slot=%0d pc=%h cause=%h tval=%h",MODE,traps,trap_pc,trap_cause,trap_tval);
            traps=traps+1;
        end
        if(retire_valid) begin
            if(wb_pc==`TRAP_DEMO_ECALL || wb_pc==`TRAP_DEMO_EBREAK ||
               wb_pc==`TRAP_DEMO_ILLEGAL || wb_pc==`TRAP_DEMO_BADCSR)
                $fatal(1,"Trap C faulting instruction retired");
            if(dut.u_imem.u_instr_mem.mem[wb_pc[31:2]]==32'h30200073) mrets=mrets+1;
            if(dut.u_imem.u_instr_mem.mem[wb_pc[31:2]][6:0]==7'h0f) begin
                if(requests!=responses) $fatal(1,"FENCE retired before old AXI completion");
                fences=fences+1;
            end
        end
    end
    initial begin
        forever begin
            @(negedge tx);
            if(!rst_n || bytes>=42) $fatal(1,"Unexpected trap C UART frame");
            #100;
            if(tx!==0) $fatal(1,"Trap C UART start bit");
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                #200; received[bit_index]=tx;
            end
            #200;
            if(tx!==1 || received!==MESSAGE[(41-bytes)*8+:8])
                $fatal(1,"Trap C UART mode=%0d byte=%0d got=%h",MODE,bytes,received);
            bytes=bytes+1;
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        wait(ram.u_data_mem.mem[4095]!==0);
        if(ram.u_data_mem.mem[4095]!==1) $fatal(1,"Trap C tohost mode=%0d value=%h",MODE,ram.u_data_mem.mem[4095]);
        wait(dut.u_cpu.mem_active===0);
        repeat(2) @(negedge clk);
        if(traps!=4 || mrets!=4 || fences!=1 || bytes!=42 || requests!=responses ||
           aw_count!=w_count || aw_count!=b_count || ar_count!=r_count || requests!=aw_count+ar_count)
            $fatal(1,"Trap C count mismatch traps=%0d MRET=%0d FENCE=%0d bytes=%0d req/rsp=%0d/%0d",traps,mrets,fences,bytes,requests,responses);
        if(ram.u_data_mem.mem[(`TRAP_DEMO_COUNT-32'h10000)/4]!==4 ||
           ram.u_data_mem.mem[(`TRAP_DEMO_RESUMED-32'h10000)/4]!==4 ||
           ram.u_data_mem.mem[(`TRAP_DEMO_GUARD-32'h10000)/4]!==32'h89abcdef)
            $fatal(1,"Trap C saved data/continuation mismatch");
        for(i=0;i<4;i=i+1) begin
            expected(i);
            if(ram.u_data_mem.mem[(`TRAP_DEMO_LOG-32'h10000)/4+i*4]!==expected_cause ||
               ram.u_data_mem.mem[(`TRAP_DEMO_LOG-32'h10000)/4+i*4+1]!==expected_pc ||
               ram.u_data_mem.mem[(`TRAP_DEMO_LOG-32'h10000)/4+i*4+2]!==expected_tval ||
               (ram.u_data_mem.mem[(`TRAP_DEMO_LOG-32'h10000)/4+i*4+3]&32'h1888)!==32'h1880)
                $fatal(1,"Trap C software log mismatch slot=%0d",i);
        end
        $display("Trap C case %0d PASS: 4 precise exceptions/MRET, CSR6/FENCE, RAM logs, UART42, AXI W/R=%0d/%0d cycles=%0d retired=%0d",MODE,aw_count,ar_count,cycles,instret);
        done=1;
    end
endmodule
