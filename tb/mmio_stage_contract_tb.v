`timescale 1ns/1ps
// Real CPU instructions, physical UART input, exact peripheral event ledgers.
// EXPECT_MMIO_STAGE=0 permits the same functional checks on the frozen parent;
// =1 additionally checks the new capture clock and its reset cancellation gap.
module mmio_stage_contract_tb #(parameter integer EXPECT_MMIO_STAGE=1);
    reg clk=0,rst_n=0,rx=1,fetch_enable=0,test_pass=0;
    always #5 clk=~clk;
    localparam integer BIT_NS=100;
    wire [31:0] pc,wb_pc,wb_data,trap_pc,trap_cause,trap_tval;
    wire [4:0] wb_rd;
    wire wb_we,retire,trap_valid,ifault,dfault,iqv,iqr,ipr;
    wire [31:0] iqa;
    wire [7:0] gpio_out,gpio_oe;
    reg ipv=0;reg [31:0] ipd=0;
    reg [31:0] rom[0:255],fixed_value[0:255];
    reg fixed_check[0:255];
    integer cursor=0,terminal_pc=0,i,phase=0,cycle=0,checks=0;
    cpu_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),
        .DMEM_WORDS(64),.DMEM_BASE_ADDR(32'h10000),.EXTERNAL_IMEM(1),
        .DMEM_REQ_WAIT_CYCLES(2),.DMEM_RSP_WAIT_CYCLES(3),
        .UART_CLOCK_HZ(100000000),.UART_BAUD(10000000),.UART_RX_FIFO_DEPTH(16),
        .ENABLE_TRAPS(1),.ENABLE_TIMER_IRQ(1),.ENABLE_SOFTWARE_IRQ(1),.ENABLE_BRANCH_PRED(1),
        .SIM_CONSOLE_ECHO(0)) cpu(
        .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(),.gpio_in(8'h3c),.gpio_out(gpio_out),.gpio_oe(gpio_oe),
        .pc_x(pc),.instr_x(),.valid_x(),.wb_pc(wb_pc),.wb_rd(wb_rd),.wb_data(wb_data),
        .wb_we(wb_we),.retire_valid(retire),.cycle_count(),.instret_count(),
        .imem_req_valid(iqv),.imem_req_ready(iqr),.imem_req_addr(iqa),
        .imem_rsp_valid(ipv),.imem_rsp_ready(ipr),.imem_rsp_rdata(ipd),.imem_rsp_error(1'b0),
        .imem_fault(ifault),.imem_fault_pc(),.dmem_req_valid(),.dmem_req_ready(1'b0),
        .dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(dfault),
        .trap_valid(trap_valid),.trap_pc(trap_pc),.trap_cause(trap_cause),.trap_tval(trap_tval),.irq_external(1'b0),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),
        .bp_direction_error_count(),.bp_target_error_count(),.perf_cycle_events());
    assign iqr=rst_n&&fetch_enable&&(!ipv||ipr);
    always @(posedge clk) begin
        if(!rst_n) begin ipv<=0;ipd<=0;end
        else begin
            if(ipv&&ipr) ipv<=0;
            if(iqv&&iqr) begin
                if(iqa[1:0]||iqa>=1024) $fatal(1,"Contract bad instruction address");
                ipv<=1;ipd<=rom[iqa>>2];
            end
        end
    end
    wire stage_pending,stage_fire;
    wire [71:0] stage_descriptor;
    generate if(EXPECT_MMIO_STAGE) begin: stage_observer
        assign stage_pending=cpu.mmio_endpoint_pending;
        assign stage_fire=cpu.mmio_endpoint_fire;
        assign stage_descriptor={cpu.mmio_endpoint_addr_q,cpu.mmio_endpoint_wdata_q,
            cpu.mmio_endpoint_wstrb_q,cpu.mmio_endpoint_size_q,cpu.mmio_endpoint_write_q,cpu.mmio_endpoint_is_mmio_q};
    end else begin: parent_observer
        assign stage_pending=1'b0,stage_fire=1'b0,stage_descriptor=72'd0;
    end endgenerate
    integer gpio_events=0,timer_events=0,msip_events=0,rx_writes=0,pop_events=0,tx_events=0;
    integer requests=0,responses=0,traps=0,started=0,launch_cycle=0,accepted_cycle=0,fd,ram_events=0;
    reg active=0,accepted=0,response_seen=0,response_error=0,response_write=0;
    reg [31:0] txn_pc=0,txn_addr=0,read_snapshot=0,response_snapshot=0;
    reg [71:0] captured=0;
    always @(posedge clk) begin
        cycle=cycle+1;response_seen=0;
        if(!rst_n) begin
            gpio_events=0;timer_events=0;msip_events=0;rx_writes=0;pop_events=0;tx_events=0;
            requests=0;responses=0;traps=0;started=0;active=0;accepted=0;ram_events=0;
        end else begin
            if(ifault||dfault||cpu.mem_we_x)
                $fatal(1,"MMIO contract faulted fetch or wrote internal RAM");
            if(cpu.mem_re_x) begin
                if(phase!=1||cpu.mem_req_mmio) $fatal(1,"MMIO transaction leaked to internal RAM");
                ram_events=ram_events+1;
            end
            if(EXPECT_MMIO_STAGE&&stage_fire!==(cpu.mem_req_fire&&cpu.mem_req_mmio))
                $fatal(1,"Endpoint execution and CPU acceptance differ");
            if(cpu.mem_start_x) begin
                if(active) $fatal(1,"MMIO contract unexpected transaction overlap");
                active=1;accepted=0;started=started+1;launch_cycle=cycle;txn_pc=pc;txn_addr=cpu.mem_addr_x;
                captured={cpu.mem_addr_x,cpu.mem_wdata_x,cpu.mem_wstrb_x,cpu.mem_size_x,cpu.mem_req_write,cpu.mem_req_mmio};
            end
            if(cpu.mem_req_fire) begin
                if(!active||accepted||{cpu.mem_addr_x,cpu.mem_wdata_x,cpu.mem_wstrb_x,cpu.mem_size_x,cpu.mem_req_write,cpu.mem_req_mmio}!==captured)
                    $fatal(1,"MMIO complete descriptor changed before endpoint acceptance");
                if(EXPECT_MMIO_STAGE&&captured[0]&&(!stage_pending||stage_descriptor!==captured))
                    $fatal(1,"MMIO endpoint did not use its complete captured descriptor");
                accepted=1;accepted_cycle=cycle;requests=requests+1;
                read_snapshot=cpu.mmio_read_data_x;
            end
            if(cpu.mmio_gpio_write_x) gpio_events=gpio_events+1;
            if(cpu.mmio_timer_write_x) timer_events=timer_events+1;
            if(cpu.mmio_msip_write_x) msip_events=msip_events+1;
            if(cpu.mmio_uart_rx_write_x) rx_writes=rx_writes+1;
            if(cpu.u_uart_rx_mmio.fifo_pop) pop_events=pop_events+1;
            if(cpu.mmio_putchar_write_x) tx_events=tx_events+1;
            if((cpu.mmio_gpio_write_x||cpu.mmio_timer_write_x||cpu.mmio_msip_write_x||cpu.mmio_uart_rx_write_x||cpu.mmio_putchar_write_x||cpu.u_uart_rx_mmio.fifo_pop)&&
                !(cpu.mem_req_fire&&cpu.mem_req_mmio&&cpu.mem_req_access_ok))
                $fatal(1,"MMIO side effect escaped legal single acceptance edge");
            if(cpu.mem_rsp_fire) begin
                if(!active||!accepted) $fatal(1,"MMIO response has no accepted owner");
                responses=responses+1;response_seen=1;response_error=cpu.mem_rsp_error;
                response_write=cpu.mem_write_q;response_snapshot=cpu.mem_rsp_rdata;
                $fwrite(fd,"%0d,%08h,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%08h,%0d\n",
                    phase,txn_pc,txn_addr,captured[1],launch_cycle,accepted_cycle,cycle,
                    accepted_cycle-launch_cycle,cycle-accepted_cycle,response_snapshot,response_error);
                active=0;accepted=0;
            end
        end
        #1;
        if(rst_n) begin
            if(EXPECT_MMIO_STAGE&&captured[0]&&active&&!accepted&&cycle==launch_cycle&&(!stage_pending||stage_descriptor!==captured))
                $fatal(1,"First MMIO edge did not capture all metadata");
            if(accepted&&cycle==accepted_cycle&&captured[0]&&!captured[1]&&cpu.load_mmio_data_q!==read_snapshot)
                $fatal(1,"load_mmio_data_q did not capture the pre-side-effect read value");
            if(accepted&&cycle==accepted_cycle&&captured[0]&&!captured[1]&&cpu.u_data_bus_adapter.mmio_rdata_q!==read_snapshot)
                $fatal(1,"Local endpoint read capture differs from pre-pop value");
            if(response_seen&&!response_error) begin
                if(!retire||wb_pc!==txn_pc||wb_we===response_write)
                    $fatal(1,"MMIO completion did not retire its exact instruction");
                if(!response_write&&(wb_data!==read_snapshot||response_snapshot!==read_snapshot))
                    $fatal(1,"MMIO read return differs from its endpoint snapshot");
            end
            if(response_seen&&response_error&&retire&&wb_pc==txn_pc)
                $fatal(1,"Faulting MMIO response retired its instruction");
            if(retire&&wb_we&&fixed_check[wb_pc>>2]&&wb_data!==fixed_value[wb_pc>>2])
                $fatal(1,"Contract readback pc=%h got=%h expected=%h",wb_pc,wb_data,fixed_value[wb_pc>>2]);
            if(trap_valid) begin traps=traps+1;
                if(phase==1) $fatal(1,"Legal MMIO program unexpectedly trapped pc=%h cause=%h",trap_pc,trap_cause);
                if(retire&&wb_pc==trap_pc) $fatal(1,"Faulting MMIO instruction retired at trap entry");
            end
            if(EXPECT_MMIO_STAGE&&!stage_pending&&
                (cpu.mmio_cycle_addr_x||cpu.mmio_instret_addr_x||cpu.mmio_uart_status_addr_x||
                 cpu.uart_rx_read_hit_x||cpu.uart_rx_write_hit_x||cpu.gpio_read_hit_x||cpu.gpio_write_hit_x||
                 cpu.timer_read_hit_x||cpu.timer_write_hit_x||cpu.mmio_msip_read_hit_x||cpu.bp_mmio_read_hit_x))
                $fatal(1,"Stale MMIO decode survived an invalid endpoint stage");
            if(cpu.mmio_putchar_valid&&phase==1) begin
                case(tx_events)
                    1:if(cpu.mmio_putchar_data!==8'h41) $fatal(1,"SB UART payload");
                    2:if(cpu.mmio_putchar_data!==8'h42) $fatal(1,"SH UART payload");
                    3:if(cpu.mmio_putchar_data!==8'h43) $fatal(1,"SW UART payload");
                    default:$fatal(1,"UART side effect duplicated");
                endcase
            end
        end
    end
    function [31:0] it(input integer imm,input [4:0] rs1,input [2:0] f3,input [4:0] rd,input [6:0] op);
        it={imm[11:0],rs1,f3,rd,op};
    endfunction
    function [31:0] st(input integer imm,input [4:0] rs2,input [4:0] rs1,input [2:0] f3);
        st={imm[11:5],rs2,rs1,f3,imm[4:0],7'h23};
    endfunction
    function [31:0] branch(input integer imm,input [4:0] rs2,input [4:0] rs1,input [2:0] f3);
        branch={imm[12],imm[10:5],rs2,rs1,f3,imm[4:1],imm[11],7'h63};
    endfunction
    task emit(input [31:0] instruction);begin rom[cursor]=instruction;cursor=cursor+1;end endtask
    task value(input integer v);begin emit(it(v,0,0,2,'h13));end endtask
    task store_word(input integer offset);begin emit(st(offset,2,1,2));end endtask
    task load_word(input integer offset,input [4:0] rd,input bit fixed,input [31:0] expected);
        begin fixed_check[cursor]=fixed;fixed_value[cursor]=expected;emit(it(offset,1,2,rd,3));end
    endtask
    task reset_program;
        begin
            @(negedge clk);rst_n=0;fetch_enable=0;rx=1;
            repeat(3) @(negedge clk);
            if(stage_pending||cpu.local_rsp_valid||cpu.u_uart_rx_mmio.fifo_pop||gpio_out||gpio_oe)
                $fatal(1,"MMIO reset did not cancel endpoint/response/side effects");
            for(i=0;i<256;i=i+1) begin rom[i]=32'h00000013;fixed_check[i]=0;fixed_value[i]=0;end
            cursor=0;emit({20'h20000,5'd1,7'h37});
        end
    endtask
    task start_program;
        begin repeat(2) @(negedge clk);rst_n=1;fetch_enable=1;end
    endtask
    task finish_program;
        begin terminal_pc=cursor*4;emit(it(1,0,0,31,'h13));emit(32'h0000006f);end
    endtask
    task wait_terminal;
        begin wait(retire&&wb_pc==terminal_pc);@(negedge clk);
            if(active||requests!=responses||traps) $fatal(1,"MMIO terminal transaction ledger mismatch");
        end
    endtask
    task send_byte(input [7:0] b);
        integer bit_index;
        begin @(negedge clk);#3;rx=0;#(BIT_NS);
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin rx=b[bit_index];#(BIT_NS);end
            rx=1;#(BIT_NS);
        end
    endtask
    task preload_uart;
        begin @(negedge clk);rst_n=1;fetch_enable=0;
            send_byte(8'h11);send_byte(8'h22);send_byte(8'h33);repeat(20) @(negedge clk);
            if(cpu.u_uart_rx_mmio.fifo_count!==3) $fatal(1,"Physical UART prefill failed");
            fetch_enable=1;
        end
    endtask
    task uart_put(input integer byte_value,input [2:0] f3);
        integer poll;
        begin value(byte_value);emit(st('h10,2,1,f3));poll=cursor*4;
            emit(it('h14,1,2,15,3));emit(branch(poll-cursor*4,0,15,1));
        end
    endtask
    task cancellation(input integer offset,input bit is_write);
        begin
            reset_program;phase=3;value('h55);
            emit(is_write?st(offset,2,1,2):it(offset,1,2,13,3));finish_program;
            if(is_write) start_program;else preload_uart;
            wait(cpu.mem_start_x&&cpu.mem_req_mmio);@(posedge clk);#1;
            if(!stage_pending||requests||responses||gpio_events||timer_events||msip_events||pop_events)
                $fatal(1,"MMIO capture edge executed an early side effect");
            reset_program;
            repeat(2) @(negedge clk);rst_n=1;fetch_enable=0;repeat(6) @(negedge clk);
            if(stage_pending||cpu.local_rsp_valid||requests||responses||gpio_events||timer_events||msip_events||pop_events)
                $fatal(1,"Canceled MMIO appeared after reset release");
            checks=checks+1;$display("MMIO STAGE RESET CANCEL PASS offset=%h write=%b",offset,is_write);
        end
    endtask
    task illegal_access(input [31:0] instruction,input [31:0] expected_cause,input [31:0] expected_tval);
        begin reset_program;phase=2;value('h77);emit(instruction);finish_program;start_program;
            wait(trap_valid);@(negedge clk);
            if(trap_pc!==8||trap_cause!==expected_cause||trap_tval!==expected_tval||traps!=1||
                gpio_events||timer_events||msip_events||rx_writes||tx_events||pop_events)
                $fatal(1,"Illegal MMIO exception or side-effect contract pc=%h cause=%h tval=%h",trap_pc,trap_cause,trap_tval);
            checks=checks+1;$display("MMIO STAGE ILLEGAL ACCESS PASS cause=%0d tval=%h",expected_cause,expected_tval);
        end
    endtask
    initial begin
        fd=$fopen("build/verification/mmio_stage_contract.csv","w");
        if(!fd) $fatal(1,"Create build/verification before contract simulation");
        $fwrite(fd,"phase,pc,addr,is_write,launch,accept,response,launch_to_accept,accept_to_response,rdata,error\n");
        reset_program;phase=1;
        value('h12);store_word('h20);value(3);store_word('h2c);value(1);store_word('h30);
        value(5);store_word('h34);value('ha5);store_word('h28);
        load_word('h20,3,1,'h17);load_word('h28,4,1,'ha5);load_word('h24,5,1,'h3c);
        emit({20'h00010,5'd22,7'h37});fixed_check[cursor]=1;fixed_value[cursor]=0;emit(it(0,22,2,23,3));
        value(1);store_word('h50);load_word('h50,6,1,1);value(0);store_word('h50);load_word('h50,7,1,0);
        value('h123);store_word('h48);value(0);store_word('h4c);
        load_word('h48,8,1,'h123);load_word('h4c,9,1,0);
        value(2);store_word('h44);value('h234);store_word('h40);load_word('h40,16,0,0);load_word('h44,17,1,2);
        fixed_check[cursor]=1;fixed_value[cursor]=0;emit(it(4,22,2,23,3));
        load_word(0,10,0,0);load_word(4,11,0,0);load_word('h70,12,1,32'h00400001);
        load_word('h1c,18,1,32'h301);
        load_word('h18,13,1,'h11);load_word('h18,14,1,'h22);load_word('h18,19,1,'h33);
        load_word('h1c,20,1,0);load_word('h18,21,1,0);value(12);store_word('h1c);
        uart_put('h41,0);uart_put('h42,1);uart_put('h43,2);finish_program;preload_uart;wait_terminal;
        if(gpio_events!=5||timer_events!=4||msip_events!=2||rx_writes!=1||pop_events!=4||tx_events!=3||
            gpio_out!==8'h17||gpio_oe!==8'ha5||cpu.software_msip!==0||cpu.u_uart_rx_mmio.fifo_count!==0||ram_events!=2)
            $fatal(1,"Legal MMIO exactly-once ledger failed gpio/timer/msip/rx/pop/tx=%0d/%0d/%0d/%0d/%0d/%0d",
                gpio_events,timer_events,msip_events,rx_writes,pop_events,tx_events);
        checks=checks+1;$display("MMIO STAGE LEGAL CONTRACT PASS: GPIO/counters/timer/MSIP/BP/UART pre-pop and SB/SH/SW exactly once");
        illegal_access(st(0,2,1,2),7,32'h20000000);
        illegal_access(it('h20,1,1,3,3),5,32'h20000020);
        illegal_access(it('h60,1,2,3,3),5,32'h20000060);
        illegal_access(st('h1c,2,1,1),7,32'h2000001c);
        illegal_access(it('h41,1,2,3,3),4,32'h20000041);
        if(EXPECT_MMIO_STAGE) begin
            cancellation('h20,1);cancellation('h40,1);cancellation('h50,1);cancellation('h18,0);
        end
        reset_program;$fclose(fd);test_pass=1;
        $display("MMIO STAGE CONTRACT TESTS PASS expected_stage=%0d checks=%0d",EXPECT_MMIO_STAGE,checks);$stop;
    end
    initial begin #500000;$fatal(1,"MMIO contract timeout phase=%0d pc=%h",phase,pc);end
endmodule
