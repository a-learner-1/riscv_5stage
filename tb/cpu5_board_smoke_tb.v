`timescale 1ns/1ps
`define BCPU dut.u_soc.u_core.u_cached.u_cpu
`define BPIPE dut.u_soc.u_core.u_cached.u_cpu.g_alu.u_pipeline
`define BEP dut.u_soc.u_core.u_cached.u_cpu.g_machine.u_router.u_normal.u_endpoint
`define BRAM dut.u_soc.u_core.u_backend.g_d0.u_ram.u_data_mem

module cpu5_board_smoke_tb #(parameter string BASE="firmware", RAW="raw");
    wire [1:0] done;
    reg test_pass=0;
    genvar n;
    generate for(n=0;n<2;n=n+1)begin:g_cases
        cpu5_board_smoke_case #(.CASE_ID(n),.BASE(BASE),.RAW(RAW)) u(done[n]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 BOARD SMOKE TWO SEEDS PASS");$stop;end
    initial begin #1200000000;$fatal(1,"CPU5 board smoke global timeout");end
endmodule

module cpu5_board_smoke_case #(parameter integer CASE_ID=0,parameter string BASE="firmware",RAW="raw")
    (output reg done=0);
    localparam integer BIT_CYCLES=434;
    localparam string PROFILE=CASE_ID==0?"smoke":"smoke-validation";
    reg clk=0,key1_n=0;
    always #10 clk=~clk;
    wire uart_tx;wire [7:0] led;
    cpu5_coremark_board_top #(.PROGRAM_FILE($sformatf("%s/%s/program.hex",BASE,PROFILE)),
        .DATA_FILE($sformatf("%s/%s/program_data.hex",BASE,PROFILE))) dut(
        .clk_50m(clk),.key1_n(key1_n),.keys_n(7'h7f),.led(led),.uart_tx(uart_tx),.uart_rx(1'b1));
    integer cycles=0,retired=0,wb=0,requests=0,responses=0,starts=0,stops=0;
    integer console_bytes=0,frames=0,fd,serial_fd,summary_fd,i,j,ones,idle_retire_count=0;
    reg pending=0,expected_wb_valid=0,host_seen=0,host_rsp=0,host_complete=0,host_retire=0,host_wb=0;
    reg [63:0] pending_seq,expected_seq,last_seq=0,host_seq;
    reg [31:0] pending_pc,expected_pc,expected_instr,expected_value;
    reg [4:0] expected_rd;reg expected_writes;
    reg seen_retire=0,rx_busy=0,restarted=0;
    reg [7:0] shift;
    string console="";
    reg [63:0] gold[0:9],start_gold[0:9],stop_gold[0:9];
    reg [63:0] start_cycle,stop_cycle,start_instret,stop_instret;
    reg [31:0] memory[0:4095];
    string directory;
    initial begin
        directory={RAW,"/",PROFILE};
        fd=$fopen({directory,"/console.txt"},"w");serial_fd=$fopen({directory,"/uart_serial.txt"},"w");
        if(!fd||!serial_fd)$fatal(1,"CPU5 board output directory missing");
        $readmemh({BASE,"/",PROFILE,"/program_data.hex"},memory);
        repeat(4)@(negedge clk);key1_n=1;
        @(negedge clk);key1_n=0;repeat(3)@(negedge clk);key1_n=1;
        // Reset after a real accepted BSS store, then let startup clear BSS again.
        do @(posedge clk);while(!dut.cpu_rst_n || !`BPIPE.ram_req_fire || !`BCPU.core_dreq_write);
        @(negedge clk);key1_n=0;repeat(3)@(negedge clk);key1_n=1;restarted=1;
    end
    always @(posedge clk)begin
        if(`BRAM.we)begin
            for(j=0;j<4;j=j+1)if(`BRAM.wstrb[j])
                memory[(`BRAM.addr-32'h10000)>>2][8*j+:8]=`BRAM.wdata[8*j+:8];
        end
    end
    always @(posedge clk or negedge dut.cpu_rst_n)begin
        if(!dut.cpu_rst_n)begin
            cycles=0;retired=0;wb=0;requests=0;responses=0;pending=0;expected_wb_valid=0;
            host_seen=0;host_rsp=0;host_complete=0;host_retire=0;host_wb=0;seen_retire=0;
            starts=0;stops=0;
            idle_retire_count=0;
            for(i=0;i<10;i=i+1)begin gold[i]=0;start_gold[i]=0;stop_gold[i]=0;end
        end else if(!done)begin
            cycles=cycles+1;
            if(cycles>50000000)$fatal(1,"CPU5 board watchdog");
            if(`BPIPE.cycle_count!==cycles-1 || `BPIPE.instret_count!==retired)
                $fatal(1,"CPU5 board cycle/retire independent count");
            if(`BPIPE.trap_valid || `BCPU.imem_fault || `BCPU.dmem_fault)
                $fatal(1,"CPU5 board unexpected trap/fault");
            ones=0;
            for(i=0;i<10;i=i+1)if(`BPIPE.perf_cycle_events[i])begin gold[i]=gold[i]+1;ones=ones+1;end
            if((cycles==1 && ones!=0)||(cycles>1 && ones!=1))$fatal(1,"CPU5 board one-hot profile");
            if(`BPIPE.ram_rsp_fire)begin
                if(!pending || `BPIPE.ram_rsp_seq!==pending_seq || `BPIPE.ram_rsp_pc!==pending_pc || `BCPU.core_drsp_error)
                    $fatal(1,"CPU5 board native response ownership");
                if(host_seen && pending_seq==host_seq)host_rsp=1;
                pending=0;responses=responses+1;
            end
            if(`BPIPE.ram_req_fire)begin
                if(pending)$fatal(1,"CPU5 board native overlap");
                pending=1;pending_seq=`BPIPE.ram_req_seq;pending_pc=`BPIPE.ram_req_pc;requests=requests+1;
                if(`BCPU.core_dreq_write && `BCPU.core_dreq_addr==32'h13ffc && `BCPU.core_dreq_wdata!=0)begin
                    if(host_seen || `BCPU.core_dreq_wdata!==1)$fatal(1,"CPU5 board CoreMark failed terminal result");
                    host_seen=1;host_seq=pending_seq;
                end
            end
            if(`BPIPE.ram_completion_valid && `BPIPE.ram_completion_ready && host_seen && `BPIPE.ram_completion_seq==host_seq)begin
                if(!host_rsp || `BPIPE.ram_completion_killed || `BPIPE.ram_completion_error || !`BPIPE.ram_completion_store)
                    $fatal(1,"CPU5 board terminal completion");
                host_complete=1;
            end
            if(`BPIPE.wb_fire)begin
                if(!expected_wb_valid || `BPIPE.memwb_q.seq!==expected_seq || `BPIPE.memwb_q.pc!==expected_pc ||
                    `BPIPE.memwb_q.instr!==expected_instr || `BPIPE.memwb_q.result!==expected_value ||
                    `BPIPE.memwb_q.rd!==expected_rd || `BPIPE.memwb_q.writes_rd!==expected_writes)
                    $fatal(1,"CPU5 board retired/WB packet mismatch");
                if(host_seen && expected_seq==host_seq)begin
                    if(!host_retire || `BPIPE.wb_we)$fatal(1,"CPU5 board terminal WB");host_wb=1;
                end
                expected_wb_valid=0;wb=wb+1;
            end
            if(`BPIPE.retire_fire)begin
                if(host_wb && `BPIPE.exmem_q.instr==32'h0000006f)
                    idle_retire_count=idle_retire_count+1;
                else idle_retire_count=0;
                if(expected_wb_valid || (seen_retire && `BPIPE.exmem_q.seq<=last_seq))$fatal(1,"CPU5 board retirement age");
                expected_wb_valid=1;expected_seq=`BPIPE.exmem_q.seq;expected_pc=`BPIPE.exmem_q.pc;
                expected_instr=`BPIPE.exmem_q.instr;expected_value=`BPIPE.mem_result_value;
                expected_rd=`BPIPE.exmem_q.rd;expected_writes=`BPIPE.exmem_q.writes_rd;
                if(host_seen && expected_seq==host_seq)begin
                    if(!host_complete || !`BPIPE.exmem_q.is_store || expected_writes)$fatal(1,"CPU5 board terminal retirement");
                    host_retire=1;
                end
                seen_retire=1;last_seq=expected_seq;retired=retired+1;
            end
            if(dut.u_soc.stats_arvalid && dut.u_soc.stats_arready)begin
                if(dut.u_soc.stats_araddr==32'h30000000)begin
                    starts=starts+1;start_cycle=`BPIPE.cycle_count;start_instret=`BPIPE.instret_count;
                    for(i=0;i<10;i=i+1)start_gold[i]=gold[i];
                end
                if(dut.u_soc.stats_araddr==32'h30000004)begin
                    stops=stops+1;stop_cycle=`BPIPE.cycle_count;stop_instret=`BPIPE.instret_count;
                    for(i=0;i<10;i=i+1)stop_gold[i]=gold[i];
                end
            end
            if(`BEP.tx_fire)begin
                console={console,$sformatf("%c",`BEP.wdata_q[7:0])};console_bytes=console_bytes+1;
                $fwrite(fd,"%c",`BEP.wdata_q[7:0]);
            end
            if(cycles%2000000==0)$display("CPU5 BOARD case%0d progress cycles=%0d retired=%0d UART=%0d",CASE_ID,cycles,retired,console_bytes);
        end
    end
    // Decode the real 115200-baud pad. The divider rounds 50MHz/115200 to 434.
    always @(negedge uart_tx)if(dut.cpu_rst_n && !rx_busy && !done)begin
        rx_busy=1;repeat(BIT_CYCLES/2)@(posedge clk);
        if(uart_tx!==0)$fatal(1,"CPU5 board UART start bit");
        for(integer b=0;b<8;b=b+1)begin repeat(BIT_CYCLES)@(posedge clk);shift[b]=uart_tx;end
        repeat(BIT_CYCLES)@(posedge clk);if(uart_tx!==1)$fatal(1,"CPU5 board UART stop bit");
        if(frames>=console_bytes || shift!==console.getc(frames))$fatal(1,"CPU5 board UART decoded byte mismatch");
        $fwrite(serial_fd,"%c",shift);frames=frames+1;rx_busy=0;
    end
    initial begin
        // portable_fini returns through stack loads after writing tohost.
        // Observe normal execution reach the startup self-loop before closing D.
        wait(host_wb && restarted && idle_retire_count>=3);@(negedge clk);
        if(!host_complete||!host_retire||!host_rsp||pending||requests!=responses||rx_busy||frames!=console_bytes||starts!=2||stops!=1)
            $fatal(1,"CPU5 board closure complete=%0d retire=%0d rsp=%0d pending=%0d req=%0d rspn=%0d rx_busy=%0d frames=%0d bytes=%0d starts=%0d stops=%0d",host_complete,host_retire,host_rsp,pending,requests,responses,rx_busy,frames,console_bytes,starts,stops);
        for(integer word=0;word<4096;word=word+1)
            if(memory[word]!==`BRAM.mem[word])$fatal(1,"CPU5 board RAM physical-write reconstruction");
        summary_fd=$fopen({directory,"/summary.json"},"w");
        $fwrite(summary_fd,"{\"pass\":true,\"case\":%0d,\"cycles\":%0d,\"retired\":%0d,\"writebacks\":%0d,\"requests\":%0d,\"responses\":%0d,\"console_bytes\":%0d,\"uart_frames\":%0d,",CASE_ID,cycles,retired,wb,requests,responses,console_bytes,frames);
        $fwrite(summary_fd,"\"window_cycles\":%0d,\"window_retired\":%0d,\"profile_delta\":[",stop_cycle-start_cycle,stop_instret-start_instret);
        for(integer k=0;k<10;k=k+1)$fwrite(summary_fd,"%0d%s",stop_gold[k]-start_gold[k],k==9?"":",");
        $fwrite(summary_fd,"],\"uart_bit_cycles\":434,\"reset_during_accepted_store\":true,\"terminal_seq\":\"%h\",\"ram_words_checked\":4096}\n",host_seq);
        $fclose(summary_fd);$fclose(fd);$fclose(serial_fd);done=1;
        $display("CPU5 BOARD CASE PASS case=%0d cycles=%0d retired=%0d UART=%0d",CASE_ID,cycles,retired,frames);
    end
endmodule
`undef BCPU
`undef BPIPE
`undef BEP
`undef BRAM
