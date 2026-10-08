`timescale 1ns/1ps
// Real CPU: a late refill error must name the original LW, and a failed
// write-through hit must be discarded even if backing RAM already changed.
module dcache_fault_tb;
    wire [3:0] done;
    reg test_pass=0;
    dcache_fault_case load_fast(done[0]);
    dcache_fault_case #(.WAIT_CYCLES(3)) load_wait(done[1]);
    dcache_fault_case #(.STORE_FAULT(1)) store_fast(done[2]);
    dcache_fault_case #(.STORE_FAULT(1),.WAIT_CYCLES(3)) store_wait(done[3]);
    initial begin wait(&done);test_pass=1;$display("DCACHE CPU FAULT TESTS PASS: original PC/tval, no fault retirement, MRET recovery, invalidated partial write");$stop;end
    initial begin #200000;$fatal(1,"D-cache CPU fault timeout done=%h",done);end
endmodule
module dcache_fault_case #(parameter integer STORE_FAULT=0,WAIT_CYCLES=0)(output reg done=0);
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    wire iq_valid,iq_ready,is_ready,dq_valid,dq_ready,dq_write,ds_valid,ds_ready,ds_error;
    wire [31:0] iq_addr,dq_addr,dq_wdata,ds_data;
    wire [1:0] dq_size;
    wire [3:0] dq_strobe;
    reg is_valid=0,ipending=0;
    reg [31:0] is_data=0,ipaddr=0,rom[0:255];
    wire mv,mready,mwrite,mrsp_ready;
    wire [31:0] ma,mw;
    wire [1:0] ms;
    wire [3:0] mst;
    reg mrsp_valid=0,mrsp_error=0,mpending=0,mpwrite=0,fault_available=1;
    reg [31:0] mrsp_data=0,mpaddr=0,mpdata=0,ram[0:63];
    integer delay=0,cycle=0,traps=0,requests=0,responses=0,i;
    wire trap_valid,retire_valid,wb_we;
    wire [31:0] trap_pc,trap_cause,trap_tval,wb_pc,wb_data;
    wire [4:0] wb_rd;
    wire [31:0] errors,misses;
    assign iq_ready=rst_n&&!ipending&&!is_valid;
    assign mready=rst_n&&!mpending&&!mrsp_valid&&(WAIT_CYCLES==0||cycle%4==0);
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.DATA_FILE(""),
        .IMEM_WORDS(256),.DMEM_WORDS(64),.DMEM_BASE_ADDR(32'h10000),
        .EXTERNAL_IMEM(1),.EXTERNAL_DMEM(1),.ENABLE_TRAPS(1),.SIM_CONSOLE_ECHO(0)) cpu(
        .clk(clk),.rst_n(rst_n),.uart_rx(1'b1),.uart_tx(),.gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .pc_x(),.instr_x(),.valid_x(),.wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),.wb_we(wb_we),
        .retire_valid(retire_valid),.cycle_count(),.instret_count(),
        .imem_req_valid(iq_valid),.imem_req_ready(iq_ready),.imem_req_addr(iq_addr),
        .imem_rsp_valid(is_valid),.imem_rsp_ready(is_ready),.imem_rsp_rdata(is_data),.imem_rsp_error(1'b0),
        .imem_fault(),.imem_fault_pc(),
        .dmem_req_valid(dq_valid),.dmem_req_ready(dq_ready),.dmem_req_write(dq_write),
        .dmem_req_addr(dq_addr),.dmem_req_size(dq_size),.dmem_req_wdata(dq_wdata),.dmem_req_wstrb(dq_strobe),
        .dmem_rsp_valid(ds_valid),.dmem_rsp_ready(ds_ready),.dmem_rsp_rdata(ds_data),.dmem_rsp_error(ds_error),
        .dmem_fault(),.trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval));
    data_cache #(.SETS(4),.LINE_WORDS(4),.MEM_WORDS(64)) cache(
        .clk(clk),.rst_n(rst_n),.req_valid(dq_valid),.req_ready(dq_ready),.req_write(dq_write),
        .req_addr(dq_addr),.req_size(dq_size),.req_wdata(dq_wdata),.req_wstrb(dq_strobe),
        .rsp_valid(ds_valid),.rsp_ready(ds_ready),.rsp_rdata(ds_data),.rsp_error(ds_error),
        .mem_req_valid(mv),.mem_req_ready(mready),.mem_req_write(mwrite),.mem_req_addr(ma),
        .mem_req_size(ms),.mem_req_wdata(mw),.mem_req_wstrb(mst),
        .mem_rsp_valid(mrsp_valid),.mem_rsp_ready(mrsp_ready),.mem_rsp_rdata(mrsp_data),.mem_rsp_error(mrsp_error),
        .access_count(),.hit_count(),.miss_count(misses),.refill_word_count(),
        .error_count(errors),.write_count(),.bypass_count());
    always @(posedge clk) begin
        if(!rst_n) begin
            ipending<=0;is_valid<=0;mpending<=0;mrsp_valid<=0;cycle<=0;fault_available<=1;
        end else begin
            cycle<=cycle+1;
            if(is_valid&&is_ready) is_valid<=0;
            if(iq_valid&&iq_ready) begin ipending<=1;ipaddr<=iq_addr;end
            if(ipending) begin ipending<=0;is_valid<=1;is_data<=rom[ipaddr/4];end
            if(mrsp_valid&&mrsp_ready) mrsp_valid<=0;
            if(mv&&mready) begin
                mpending<=1;mpaddr<=ma;mpdata<=mw;mpwrite<=mwrite;delay<=WAIT_CYCLES;
                if(ms!==2||mwrite&&mst!==15) $fatal(1,"Unexpected CPU fault backend descriptor");
            end
            if(mpending) begin
                if(delay>0) delay<=delay-1;
                else begin
                    mpending<=0;mrsp_valid<=1;mrsp_error<=0;mrsp_data<=mpwrite?0:ram[(mpaddr-32'h10000)/4];
                    if(mpwrite) ram[(mpaddr-32'h10000)/4]<=mpdata;
                    if(fault_available&&((STORE_FAULT&&mpwrite)||(!STORE_FAULT&&mpaddr==32'h1000c))) begin
                        mrsp_error<=1;fault_available<=0;
                    end
                end
            end
        end
    end
    always @(posedge clk) if(rst_n&&!done) begin
        if(dq_valid&&dq_ready) requests=requests+1;
        if(ds_valid&&ds_ready) responses=responses+1;
        #1;
        if(trap_valid) begin
            if(traps!=0||trap_pc!==(STORE_FAULT?32'd24:32'd16)||
               trap_cause!==(STORE_FAULT?32'd7:32'd5)||trap_tval!==32'h10000||requests!=responses)
                $fatal(1,"Wrong cache CPU fault %m PC=%h cause=%h tval=%h",trap_pc,trap_cause,trap_tval);
            traps=traps+1;
        end
        if(retire_valid&&wb_pc==(STORE_FAULT?24:16)) $fatal(1,"Faulting data instruction retired");
    end
    initial begin
        for(i=0;i<256;i=i+1) rom[i]=32'h00000013;
        for(i=0;i<64;i=i+1) ram[i]=32'h11223344+i;
        rom[0]=32'h08000093;rom[1]=32'h30509073;rom[2]=32'h00010137;
        rom[3]=32'h06300193;rom[4]=32'h00012183;rom[5]=32'h00700213;
        rom[6]=32'h00412023;rom[7]=32'h00012303;rom[8]=32'h0000000f;
        rom[9]=32'h00100393;rom[10]=32'h0000006f;
        rom[32]=32'h341022f3;rom[33]=32'h00428293;rom[34]=32'h34129073;rom[35]=32'h30200073;
        repeat(4) @(negedge clk);rst_n=1;
        wait(wb_we&&wb_rd==7&&wb_data==1);repeat(3) @(negedge clk);
        if(traps!=1||requests!=3||responses!=3||errors!==1||misses!==2||
           cpu.u_regfile.regs[3]!==(STORE_FAULT?32'h11223344:32'd99)||
           cpu.u_regfile.regs[6]!==7||ram[0]!==7)
            $fatal(1,"Data cache exception recovery/data mismatch %m");
        $display("DCACHE CPU fault %m PASS: store_fault=%0d wait=%0d",STORE_FAULT,WAIT_CYCLES);
        done=1;
    end
endmodule
