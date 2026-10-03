`timescale 1ns/1ps
module axi_lite_cpu_tb;
    wire [6:0] done;
    reg test_pass=0;
    axi_c_case #(.WAIT_MODE(0)) c_fast(done[0]);
    axi_c_case #(.WAIT_MODE(1)) c_wait(done[1]);
    axi_directed_case #(.WAIT_MODE(0)) directed_fast(done[2]);
    axi_directed_case #(.WAIT_MODE(1)) directed_wait(done[3]);
    axi_c_case #(.WAIT_MODE(2)) c_w_first(done[4]);
    axi_fault_case #(.BAD_STORE(0)) bad_load(done[5]);
    axi_fault_case #(.BAD_STORE(1)) bad_store(done[6]);
    initial begin
        wait(&done);
        test_pass=1;
        $display("PASS: AXI CPU integration: existing C HEX over AXI RAM, independent AW/W waits, subwords, forwarding, redirects, exact transactions, bus faults and reset recovery");
        $stop;
    end
    initial begin #500000; $fatal(1,"AXI CPU integration timeout done=%b",done); end
endmodule

module axi_c_case #(parameter integer WAIT_MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] pc_x,instr_x;
    wire [63:0] cycle_count,instret_count;
    wire imem_fault,dmem_fault;
    integer overlap=0;
    axi_cpu_system #(
        .PROGRAM_FILE("programs/c_demo.hex"), .DATA_FILE("programs/c_demo_data.hex"),
        .SIM_CONSOLE_ECHO(0),
        .IMEM_REQ_WAIT_CYCLES(WAIT_MODE ? 2 : 0),
        .IMEM_RSP_WAIT_CYCLES(WAIT_MODE ? 3 : 0),
         .AW_WAIT_CYCLES(WAIT_MODE == 2 ? 5 : 0),
        .W_WAIT_CYCLES(WAIT_MODE == 1 ? 5 : 0),
        .AR_WAIT_CYCLES(WAIT_MODE ? 3 : 0),
        .B_WAIT_CYCLES(WAIT_MODE ? 4 : 0), .R_WAIT_CYCLES(WAIT_MODE ? 6 : 0)
    ) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),
        .gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .pc_x(pc_x),.instr_x(instr_x),.valid_x(),
        .wb_pc(),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(),
        .cycle_count(cycle_count),.instret_count(instret_count),
        .imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(dmem_fault)
    );
    always @(posedge clk) if(rst_n && !done) begin
        if(dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en || dut.u_soc.u_cpu.u_data_mem.re || dut.u_soc.u_cpu.u_data_mem.we)
            $fatal(1,"SoC C case used CPU internal memory");
        if(imem_fault || dmem_fault) $fatal(1,"SoC C fault pc=%h instruction=%h",pc_x,instr_x);
        if((dut.u_soc.imem_req_valid || dut.u_soc.imem_rsp_valid) &&
           (dut.u_soc.dmem_req_valid || dut.u_soc.dmem_rsp_valid)) overlap=overlap+1;
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        wait(dut.u_dmem.u_data_mem.mem[4095] !== 0);
        if(dut.u_dmem.u_data_mem.mem[4095] !== 1)
            $fatal(1,"SoC C tohost failure mode=%0d code=%h",WAIT_MODE,dut.u_dmem.u_data_mem.mem[4095]);
        wait(dut.u_soc.u_cpu.mem_active === 0);
        @(posedge clk); #1;
        if(dut.u_dmem.u_data_mem.mem[0] !== 32'h12345678 || instret_count !== 155)
            $fatal(1,"SoC C initialized data/counters mode=%0d data=%h instret=%0d",WAIT_MODE,dut.u_dmem.u_data_mem.mem[0],instret_count);
        if(overlap == 0) $fatal(1,"SoC C instruction/data overlap not exercised");
        $display("AXI C case %0d PASS: tohost=1 initialized data=12345678 retired=%0d cycles=%0d overlap=%0d",WAIT_MODE,instret_count,cycle_count,overlap);
        if(dut.req_count != 37 || dut.rsp_count != 37 || dut.aw_count != 24 ||
           dut.w_count != 24 || dut.b_count != 24 || dut.ar_count != 13 || dut.r_count != 13)
            $fatal(1,"AXI C missing/duplicate transactions");
        $display("AXI C channels: mode=%0d AW=%0d W=%0d B=%0d AR=%0d R=%0d",WAIT_MODE,dut.aw_count,dut.w_count,dut.b_count,dut.ar_count,dut.r_count);
        done=1;
    end
endmodule

module axi_directed_case #(parameter integer WAIT_MODE=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire [31:0] wb_pc,wb_data;
    wire [4:0] wb_rd;
    wire wb_we,retire_valid,imem_fault,dmem_fault;
    wire [7:0] gpio_out,gpio_oe;
    integer retired=0,requests=0,responses=0,mmio_writes=0,overlap=0;
    integer seen[0:36];
    integer i;
    axi_cpu_system #(
        .PROGRAM_FILE("programs/data_handshake_blank.hex"), .DATA_FILE(""),
        .IMEM_WORDS(256),.DMEM_WORDS(64),.DMEM_BASE_ADDR(32'd0),
        .SIM_CONSOLE_ECHO(0), .IMEM_REQ_WAIT_CYCLES(WAIT_MODE ? 2 : 0),
        .IMEM_RSP_WAIT_CYCLES(WAIT_MODE ? 4 : 0),
         .AW_WAIT_CYCLES(WAIT_MODE ? 5 : 0),
        .W_WAIT_CYCLES(0), .AR_WAIT_CYCLES(WAIT_MODE ? 3 : 0),
        .B_WAIT_CYCLES(WAIT_MODE ? 4 : 0), .R_WAIT_CYCLES(WAIT_MODE ? 6 : 0)
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
        dut.u_soc.u_imem.u_instr_mem.mem[0]=itype(0,0,0,1,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[1]={20'h80ff8,5'd2,7'h37};
        dut.u_soc.u_imem.u_instr_mem.mem[2]=itype(-255,2,0,2,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[3]=stype(0,2,1,2);
        dut.u_soc.u_imem.u_instr_mem.mem[4]=itype(2,1,0,3,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[5]=itype(2,3,0,4,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[6]=itype(2,1,4,5,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[7]=itype(2,1,1,6,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[8]=itype(2,1,5,7,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[9]=itype(0,1,2,8,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[10]=itype(102,0,0,9,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[11]=stype(1,9,1,0);
        dut.u_soc.u_imem.u_instr_mem.mem[12]=itype(-1348,0,0,9,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[13]=stype(2,9,1,1);
        dut.u_soc.u_imem.u_instr_mem.mem[14]=itype(0,1,2,10,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[15]=itype(16,0,0,11,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[16]=stype(4,11,1,2);
        dut.u_soc.u_imem.u_instr_mem.mem[17]=itype(4,1,2,12,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[18]=stype(0,10,12,2);
        dut.u_soc.u_imem.u_instr_mem.mem[19]=itype(16,1,2,13,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[20]=itype(0,1,2,0,7'h03);
        dut.u_soc.u_imem.u_instr_mem.mem[21]={20'h20000,5'd14,7'h37};
        dut.u_soc.u_imem.u_instr_mem.mem[22]=btype(12,10,13);
        dut.u_soc.u_imem.u_instr_mem.mem[23]=stype(52,9,14,2);
        dut.u_soc.u_imem.u_instr_mem.mem[24]=stype(20,9,1,2);
        dut.u_soc.u_imem.u_instr_mem.mem[25]=jtype(12,15);
        dut.u_soc.u_imem.u_instr_mem.mem[26]=stype(16,9,14,2);
        dut.u_soc.u_imem.u_instr_mem.mem[27]=stype(24,9,1,2);
        dut.u_soc.u_imem.u_instr_mem.mem[28]=itype(128,0,0,17,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[29]=itype(0,17,0,18,7'h67);
        dut.u_soc.u_imem.u_instr_mem.mem[30]=stype(52,9,14,2);
        dut.u_soc.u_imem.u_instr_mem.mem[31]=stype(24,9,1,2);
        dut.u_soc.u_imem.u_instr_mem.mem[32]=itype(1,0,0,19,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[33]=stype(40,19,14,2);
        dut.u_soc.u_imem.u_instr_mem.mem[34]=stype(52,19,14,2);
        dut.u_soc.u_imem.u_instr_mem.mem[35]=stype(28,4,1,2);
        dut.u_soc.u_imem.u_instr_mem.mem[36]=itype(42,0,0,16,7'h13);
        dut.u_soc.u_imem.u_instr_mem.mem[37]=jtype(0,0);
        repeat(4) @(negedge clk);rst_n=1;
    end
    always @(posedge clk) begin
        if(rst_n && !done) begin
            if(dut.u_soc.u_cpu.u_if_stage.u_instr_mem.en || dut.u_soc.u_cpu.u_data_mem.re || dut.u_soc.u_cpu.u_data_mem.we)
                $fatal(1,"SoC directed used CPU internal memory");
            if(imem_fault || dmem_fault) $fatal(1,"SoC directed unexpected fault");
            if(dut.u_soc.dmem_req_valid && dut.u_soc.dmem_req_ready) requests=requests+1;
            if(dut.u_soc.dmem_rsp_valid && dut.u_soc.dmem_rsp_ready) responses=responses+1;
            if((dut.u_soc.imem_req_valid || dut.u_soc.imem_rsp_valid) &&
               (dut.u_soc.dmem_req_valid || dut.u_soc.dmem_rsp_valid)) overlap=overlap+1;
            if(dut.u_soc.u_cpu.mem_req_fire && dut.u_soc.u_cpu.mem_req_mmio) begin
                if(dut.u_soc.u_cpu.pc_x != 132 && dut.u_soc.u_cpu.pc_x != 136)
                    $fatal(1,"SoC wrong-path MMIO side effect pc=%h",dut.u_soc.u_cpu.pc_x);
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
                    $display("AXI directed case %0d PASS: 31 unique retirements, 15 RAM transactions, two GPIO writes, overlap=%0d",WAIT_MODE,overlap);
                    if(dut.req_count != 15 || dut.rsp_count != 15 || dut.aw_count != 6 || dut.ar_count != 9)
                        $fatal(1,"AXI directed channel counts req=%0d rsp=%0d AW=%0d AR=%0d",dut.req_count,dut.rsp_count,dut.aw_count,dut.ar_count);
                    done=1;
                end
                default:;
            endcase
        end
    end
endmodule

module axi_cpu_system #(
    parameter PROGRAM_FILE="programs/c_demo.hex", DATA_FILE="programs/c_demo_data.hex",
    parameter integer IMEM_WORDS=8192, DMEM_WORDS=4096,
    parameter [31:0] DMEM_BASE_ADDR=32'h00010000,
    parameter integer SIM_CONSOLE_ECHO=0,
    parameter integer IMEM_REQ_WAIT_CYCLES=0, IMEM_RSP_WAIT_CYCLES=0,
    parameter integer AW_WAIT_CYCLES=0, W_WAIT_CYCLES=0, AR_WAIT_CYCLES=0,
    parameter integer B_WAIT_CYCLES=0, R_WAIT_CYCLES=0
) (
    input wire clk,rst_n,uart_rx, input wire [7:0] gpio_in,
    output wire uart_tx, output wire [7:0] gpio_out,gpio_oe,
    output wire [31:0] pc_x,instr_x, output wire valid_x,
    output wire [31:0] wb_pc,wb_data, output wire [4:0] wb_rd,
    output wire wb_we,retire_valid, output wire [63:0] cycle_count,instret_count,
    output wire imem_fault,dmem_fault, output wire [31:0] imem_fault_pc
);
    wire [31:0] awaddr,wdata,araddr,rdata;
    wire [2:0] awprot,arprot;
    wire [3:0] wstrb;
    wire [1:0] bresp,rresp;
    wire awvalid,awready,wvalid,wready,bvalid,bready,arvalid,arready,rvalid,rready;
    soc_axi_lite_top #(
        .PROGRAM_FILE(PROGRAM_FILE),.DATA_FILE(DATA_FILE),
        .IMEM_WORDS(IMEM_WORDS),.DMEM_WORDS(DMEM_WORDS),.DMEM_BASE_ADDR(DMEM_BASE_ADDR),
        .SIM_CONSOLE_ECHO(SIM_CONSOLE_ECHO),
        .IMEM_REQ_WAIT_CYCLES(IMEM_REQ_WAIT_CYCLES),.IMEM_RSP_WAIT_CYCLES(IMEM_RSP_WAIT_CYCLES)
    ) u_soc (
        .clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .gpio_in(gpio_in),.gpio_out(gpio_out),.gpio_oe(gpio_oe),
        .pc_x(pc_x),.instr_x(instr_x),.valid_x(valid_x),
        .wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(cycle_count),.instret_count(instret_count),
        .imem_fault(imem_fault),.imem_fault_pc(imem_fault_pc),.dmem_fault(dmem_fault),
        .m_axi_awaddr(awaddr),
        .m_axi_awprot(awprot),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .m_axi_araddr(araddr),
        .m_axi_arprot(arprot),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready),
        .icache_access_count(),.icache_hit_count(),.icache_miss_count(),
        .icache_refill_word_count(),.icache_error_count(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval()
    );
    axi_lite_ram #(.WORDS(DMEM_WORDS),.BASE_ADDR(DMEM_BASE_ADDR),.INIT_FILE(DATA_FILE),
        .AW_WAIT_CYCLES(AW_WAIT_CYCLES),.W_WAIT_CYCLES(W_WAIT_CYCLES),
        .AR_WAIT_CYCLES(AR_WAIT_CYCLES),.B_WAIT_CYCLES(B_WAIT_CYCLES),.R_WAIT_CYCLES(R_WAIT_CYCLES)
    ) u_dmem (.clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),
        .s_axi_awprot(awprot),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arprot(arprot),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready)
    );

    // Scoreboard at public handshakes: each CPU request must become exactly
    // one corresponding AXI transaction. Expected payload comes from CPU.
    integer req_count=0,rsp_count=0,aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0;
    reg pending=0,is_write=0,seen_aw=0,seen_w=0,seen_b=0,seen_ar=0,seen_r=0;
    reg [31:0] expect_addr,expect_data;
    reg [3:0] expect_strb;
    reg hold_aw=0,hold_w=0,hold_ar=0,hold_b=0,hold_r=0,hold_cpu=0;
    reg [34:0] last_aw,last_ar;
    reg [35:0] last_w;
    reg [1:0] last_b;
    reg [33:0] last_r;
    reg [32:0] last_cpu;
    always @(posedge clk) begin
        if(!rst_n) begin
            req_count=0;rsp_count=0;aw_count=0;w_count=0;b_count=0;ar_count=0;r_count=0;
            pending=0;seen_aw=0;seen_w=0;seen_b=0;seen_ar=0;seen_r=0;
            hold_aw=0;hold_w=0;hold_ar=0;hold_b=0;hold_r=0;hold_cpu=0;
        end else begin
            if(hold_aw && (!awvalid || {awaddr,awprot} !== last_aw)) $fatal(1,"AXI AW unstable");
            if(hold_w && (!wvalid || {wdata,wstrb} !== last_w)) $fatal(1,"AXI W unstable");
            if(hold_ar && (!arvalid || {araddr,arprot} !== last_ar)) $fatal(1,"AXI AR unstable");
            if(hold_b && (!bvalid || bresp !== last_b)) $fatal(1,"AXI B unstable");
            if(hold_r && (!rvalid || {rdata,rresp} !== last_r)) $fatal(1,"AXI R unstable");
            if(hold_cpu && (!u_soc.dmem_rsp_valid || {u_soc.dmem_rsp_rdata,u_soc.dmem_rsp_error} !== last_cpu)) $fatal(1,"AXI CPU response unstable");
            hold_aw=awvalid&&!awready;last_aw={awaddr,awprot};
            hold_w=wvalid&&!wready;last_w={wdata,wstrb};
            hold_ar=arvalid&&!arready;last_ar={araddr,arprot};
            hold_b=bvalid&&!bready;last_b=bresp;
            hold_r=rvalid&&!rready;last_r={rdata,rresp};
            hold_cpu=u_soc.dmem_rsp_valid&&!u_soc.dmem_rsp_ready;
            last_cpu={u_soc.dmem_rsp_rdata,u_soc.dmem_rsp_error};
            if(u_soc.dmem_req_valid && u_soc.dmem_req_ready) begin
                if(pending) $fatal(1,"AXI accepted overlapping CPU requests");
                pending=1;is_write=u_soc.dmem_req_write;
                expect_addr={u_soc.dmem_req_addr[31:2],2'b00};
                expect_data=u_soc.dmem_req_wdata;expect_strb=u_soc.dmem_req_wstrb;
                seen_aw=0;seen_w=0;seen_b=0;seen_ar=0;seen_r=0;req_count=req_count+1;
            end
            if(awvalid&&awready) begin
                if(!pending||!is_write||seen_aw||awaddr!==expect_addr||awprot!==0) $fatal(1,"AXI AW duplicate/payload");
                seen_aw=1;aw_count=aw_count+1;
            end
            if(wvalid&&wready) begin
                if(!pending||!is_write||seen_w||wdata!==expect_data||wstrb!==expect_strb) $fatal(1,"AXI W duplicate/payload");
                seen_w=1;w_count=w_count+1;
            end
            if(bvalid&&bready) begin
                if(!pending||!is_write||!seen_aw||!seen_w||seen_b) $fatal(1,"AXI B missing pair/duplicate");
                seen_b=1;b_count=b_count+1;
            end
            if(arvalid&&arready) begin
                if(!pending||is_write||seen_ar||araddr!==expect_addr||arprot!==0) $fatal(1,"AXI AR duplicate/payload");
                seen_ar=1;ar_count=ar_count+1;
            end
            if(rvalid&&rready) begin
                if(!pending||is_write||!seen_ar||seen_r) $fatal(1,"AXI R missing address/duplicate");
                seen_r=1;r_count=r_count+1;
            end
            if(u_soc.dmem_rsp_valid&&u_soc.dmem_rsp_ready) begin
                if(!pending || (is_write?!seen_b:!seen_r)) $fatal(1,"CPU response before AXI completion");
                pending=0;rsp_count=rsp_count+1;
            end
        end
    end
endmodule

module axi_fault_case #(parameter integer BAD_STORE=0)(output reg done=0);
    reg clk=0,rst_n=0,phase=0;
    always #5 clk=~clk;
    wire fault,imem_fault,retire_valid,wb_we; wire [31:0] wb_pc,wb_data;
    integer retired=0;
    axi_cpu_system #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.DATA_FILE(""),
        .IMEM_WORDS(256),.DMEM_WORDS(64),.DMEM_BASE_ADDR(32'h10000),
        .AW_WAIT_CYCLES(BAD_STORE?4:0),.W_WAIT_CYCLES(BAD_STORE?0:4),
        .AR_WAIT_CYCLES(3),.B_WAIT_CYCLES(4),.R_WAIT_CYCLES(5)
    ) dut (.clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.gpio_in(8'd0),
        .uart_tx(),.gpio_out(),.gpio_oe(),.pc_x(),.instr_x(),.valid_x(),
        .retire_valid(retire_valid),.wb_pc(wb_pc),.wb_data(wb_data),.wb_we(wb_we),.wb_rd(),
        .cycle_count(),.instret_count(),.imem_fault(imem_fault),.imem_fault_pc(),.dmem_fault(fault));
    always @(posedge clk) begin
        if(!rst_n) retired=0;
        if(rst_n && imem_fault) $fatal(1,"Unexpected instruction fault in AXI data test");
        #1;
        if(rst_n && retire_valid && !done) begin
            if(!phase && wb_pc>=12) $fatal(1,"AXI fault retired failed/younger instruction");
            retired=retired+1;
            if(phase && wb_pc==12 && (!wb_we || wb_data!==42)) $fatal(1,"AXI reset recovered load");
        end
    end
    initial begin
        #1;
        dut.u_soc.u_imem.u_instr_mem.mem[0]=32'h000100b7; // lui x1,0x10
        dut.u_soc.u_imem.u_instr_mem.mem[1]=32'h02a00113; // addi x2,x0,42
        dut.u_soc.u_imem.u_instr_mem.mem[2]=32'h0020a023; // sw x2,0(x1)
        dut.u_soc.u_imem.u_instr_mem.mem[3]=BAD_STORE?32'h1020a023:32'h1000a183;
        dut.u_soc.u_imem.u_instr_mem.mem[4]=32'h00700213; // addi x4,x0,7
        dut.u_soc.u_imem.u_instr_mem.mem[5]=32'h0000006f;
        repeat(4) @(negedge clk);rst_n=1;
        wait(fault);repeat(8) @(negedge clk);
        if(retired!=3 || dut.u_dmem.u_data_mem.mem[0]!==42 || dut.req_count!=2 || dut.rsp_count!=2)
            $fatal(1,"AXI fault failed precise retirement/older store");
        if(dut.u_soc.dmem_req_valid || dut.awvalid || dut.wvalid || dut.arvalid || retire_valid)
            $fatal(1,"AXI fault not sticky halt");
        rst_n=0;phase=1;repeat(3) @(negedge clk);
        if(dut.u_dmem.u_data_mem.mem[0]!==42) $fatal(1,"AXI reset erased RAM");
        dut.u_soc.u_imem.u_instr_mem.mem[3]=32'h0000a183; // lw x3,0(x1)
        rst_n=1;
        wait(retire_valid && wb_pc==16);#1;
        if(wb_data!==7 || fault || dut.u_soc.u_cpu.u_regfile.regs[3]!==42)
            $fatal(1,"AXI CPU reset recovery failed");
        $display("AXI fault case %0d PASS: DECERR, failed PC=12 suppressed, older write retained, shared reset recovery",BAD_STORE);
        done=1;
    end
endmodule
