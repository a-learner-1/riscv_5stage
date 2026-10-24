`timescale 1ns/1ps
module cpu5_mmio_endpoint_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, req_valid=0, req_write=0, rsp_ready=0;
    reg [31:0] req_addr=0, req_wdata=0;
    reg [1:0] req_size=0;
    reg [3:0] req_wstrb=0;
    wire req_ready,rsp_valid,rsp_error,uart_tx;
    wire [31:0] rsp_rdata;
    reg [63:0] cycle_count=64'h12345678ffffffe0;
    reg [63:0] instret_count=64'h22334455fffffff0;
    reg uart_rx=1;
    reg [7:0] gpio_in=0;
    wire [7:0] gpio_out,gpio_oe;
    integer test_pass=0;
    cpu5_mmio_endpoint #(.UART_CLOCK_HZ(800),.UART_BAUD(100),
        .UART_RX_FIFO_DEPTH(2),.SIM_CONSOLE_ECHO(0)) dut(.*);
    integer checks=0, accepted=0, fires=0, responses=0, legal_ops=0, errors=0;
    integer rx_pops=0, tx_sends=0, physical_tx=0, gpio_writes=0;
    integer canceled=0, held_cycles=0, reset_count=0;
    integer fd, i,j,k,n;
    reg [31:0] addresses[0:15];
    integer ref_state=0, tx_remaining=0;
    reg ref_write=0;
    reg [31:0] ref_addr=0,ref_data=0;
    reg [1:0] ref_size=0;
    reg [3:0] ref_strb=0;
    reg [31:0] expected_data=0;
    reg expected_error=0;
    reg legal,word_shape,tx_shape;
    reg [7:0] out_ref=0,oe_ref=0,in_meta_ref=0,in_sync_ref=0;
    reg [7:0] rx_queue[0:7];
    integer rx_count=0;
    reg overflow_ref=0,frame_ref=0;
    reg [7:0] expected_tx[0:63];
    integer physical_index=0;
    reg [7:0] physical_byte;

    task check;
        input condition; input [1023:0] message;
        begin
            checks=checks+1;
            if (condition!==1'b1) $fatal(1,"MMIO endpoint oracle %0s at check=%0d accepted=%0d fire=%0d addr=%h",message,checks,accepted,fires,ref_addr);
        end
    endtask

    // The oracle owns its descriptor, protocol state, counters and device model.
    // It samples public request pins only on handshake and uses no DUT data to
    // derive any expected address, legality, response or destructive-read value.
    always @(posedge clk) begin
        if (!rst_n) begin
            ref_state=0; out_ref=0; oe_ref=0; in_meta_ref=0; in_sync_ref=0;
            rx_count=0; overflow_ref=0; frame_ref=0; tx_remaining=0;
            expected_data=0; expected_error=0;
            #1;
            check(!rsp_valid && !req_ready && gpio_out==0 && gpio_oe==0,"reset cancels response and effects");
        end else begin
            check(req_ready===(ref_state==0),"ready has no response bypass");
            check(rsp_valid===(ref_state==2),"response phase");
            check(dut.endpoint_fire===(ref_state==1),"unique delayed endpoint fire");
            check(gpio_out===out_ref && gpio_oe===oe_ref,"GPIO only changes on execution edge");
            if (ref_state==2) begin
                check(rsp_rdata===expected_data && rsp_error===expected_error,"frozen response payload");
                if (!rsp_ready) held_cycles=held_cycles+1;
            end
            case (ref_state)
                0: if (req_valid && req_ready) begin
                    ref_write=req_write; ref_addr=req_addr; ref_size=req_size;
                    ref_data=req_wdata; ref_strb=req_wstrb;
                    accepted=accepted+1; ref_state=1;
                end
                1: begin
                    fires=fires+1;
                    legal=0; expected_data=0;
                    word_shape=(ref_size==2 && ref_addr[1:0]==0);
                    tx_shape=ref_write && ref_addr==32'h20000010 &&
                        ((ref_size==0 && ref_strb==1) || (ref_size==1 && ref_strb==3) || (ref_size==2 && ref_strb==15));
                    if (!ref_write && word_shape && ref_strb==0) begin
                        case (ref_addr)
                            32'h20000000: begin legal=1; expected_data=cycle_count[31:0]; end
                            32'h20000004: begin legal=1; expected_data=instret_count[31:0]; end
                            32'h20000014: begin legal=1; expected_data=(tx_remaining!=0); end
                            32'h20000018: begin
                                legal=1; expected_data=(rx_count==0)?0:{24'd0,rx_queue[0]};
                                if (rx_count>0) begin rx_queue[0]=rx_queue[1]; rx_count=rx_count-1; rx_pops=rx_pops+1; end
                            end
                            32'h2000001c: begin legal=1; expected_data=(rx_count<<8)|(frame_ref<<3)|(overflow_ref<<2)|((rx_count==2)<<1)|(rx_count!=0); end
                            32'h20000020: begin legal=1; expected_data={24'd0,out_ref}; end
                            32'h20000024: begin legal=1; expected_data={24'd0,in_sync_ref}; end
                            32'h20000028: begin legal=1; expected_data={24'd0,oe_ref}; end
                            default: ;
                        endcase
                    end else if (tx_shape) begin
                        legal=(tx_remaining==0);
                        if (legal) begin
                            expected_tx[tx_sends]=ref_data[7:0];
                            tx_sends=tx_sends+1; tx_remaining=81;
                        end
                    end else if (ref_write && word_shape && ref_strb==15) begin
                        case (ref_addr)
                            32'h2000001c: begin legal=1; overflow_ref=overflow_ref & !ref_data[2]; frame_ref=frame_ref & !ref_data[3]; end
                            32'h20000020: begin legal=1; out_ref=ref_data[7:0]; gpio_writes=gpio_writes+1; end
                            32'h20000028: begin legal=1; oe_ref=ref_data[7:0]; gpio_writes=gpio_writes+1; end
                            32'h2000002c: begin legal=1; out_ref=out_ref|ref_data[7:0]; gpio_writes=gpio_writes+1; end
                            32'h20000030: begin legal=1; out_ref=out_ref&~ref_data[7:0]; gpio_writes=gpio_writes+1; end
                            32'h20000034: begin legal=1; out_ref=out_ref^ref_data[7:0]; gpio_writes=gpio_writes+1; end
                            default: ;
                        endcase
                    end
                    expected_error=!legal;
                    if (legal) legal_ops=legal_ops+1; else errors=errors+1;
                    check(dut.tx_fire===(legal && tx_shape),"TX side effect qualification");
                    check(dut.rx_read_fire===(legal && !ref_write && (ref_addr==32'h20000018 || ref_addr==32'h2000001c)),"RX side effect qualification");
                    check(dut.gpio_write_fire===(legal && ref_write && ref_addr>=32'h20000020 && ref_addr<=32'h20000034 && ref_addr!=32'h20000024),"GPIO side effect qualification");
                    ref_state=2;
                end
                2: if (rsp_ready) begin responses=responses+1; ref_state=0; end
            endcase
            if (tx_remaining>0) tx_remaining=tx_remaining-1;
            in_sync_ref=in_meta_ref; in_meta_ref=gpio_in;
            #1;
            check(gpio_out===out_ref && gpio_oe===oe_ref,"GPIO post-execution model");
            check(rsp_valid===(ref_state==2),"registered response timing");
            if (ref_state==2) check(rsp_rdata===expected_data && rsp_error===expected_error,"pre-effect read snapshot and errors");
        end
    end

    always @(negedge clk) begin
        cycle_count=cycle_count+64'h100000003;
        instret_count=instret_count+64'h200000007;
    end
    // Decode actual UART TX pin at bit centers, without reading the TX unit.
    initial forever begin
        @(negedge uart_tx);
        if (rst_n) begin
            repeat(4) @(negedge clk);
            check(uart_tx===0,"TX physical start bit");
            physical_byte=0;
            for (integer bitn=0;bitn<8;bitn=bitn+1) begin
                repeat(8) @(negedge clk);
                physical_byte[bitn]=uart_tx;
            end
            repeat(8) @(negedge clk);
            check(uart_tx===1,"TX physical stop bit");
            check(physical_index<tx_sends && physical_byte===expected_tx[physical_index],"TX physical captured byte");
            physical_index=physical_index+1; physical_tx=physical_tx+1;
        end
    end

    task access;
        input wr; input [31:0] addr; input [1:0] sz;
        input [31:0] data; input [3:0] strobe; input integer hold;
        begin
            @(negedge clk); req_valid=1; req_write=wr; req_addr=addr;
            req_size=sz; req_wdata=data; req_wstrb=strobe; rsp_ready=0;
            @(posedge clk); #2;
            check(!req_ready && !rsp_valid,"request capture has no immediate response");
            @(negedge clk);
            // Hostile live pins prove complete descriptor capture and no bypass.
            req_valid=1; req_write=!wr; req_addr=32'h20000034;
            req_size=0; req_wdata=32'hdeadbeef; req_wstrb=1;
            @(posedge clk); #2; check(rsp_valid,"captured request executes next edge");
            repeat(hold) begin
                @(negedge clk); req_wdata=req_wdata+1; req_addr=req_addr^32'h10;
            end
            @(negedge clk); req_valid=0; rsp_ready=1;
            @(posedge clk); #2; check(req_ready && !rsp_valid,"response consumes before next acceptance");
            @(negedge clk); rsp_ready=0;
        end
    endtask

    task send_rx;
        input [7:0] data; input bad_stop;
        begin
            @(negedge clk); uart_rx=0; repeat(8) @(negedge clk);
            for(integer bitn=0;bitn<8;bitn=bitn+1) begin
                uart_rx=data[bitn]; repeat(8) @(negedge clk);
            end
            uart_rx=!bad_stop; repeat(8) @(negedge clk);
            uart_rx=1; repeat(12) @(negedge clk);
            if (bad_stop) frame_ref=1;
            else if (rx_count==2) overflow_ref=1;
            else begin rx_queue[rx_count]=data; rx_count=rx_count+1; end
        end
    endtask

    task reset_device;
        begin
            @(negedge clk); rst_n=0; req_valid=0; rsp_ready=0;
            reset_count=reset_count+1;
            repeat(3) @(negedge clk);
            rst_n=1; repeat(3) @(negedge clk);
        end
    endtask

    initial begin
        addresses[0]=32'h20000000; addresses[1]=32'h20000004;
        addresses[2]=32'h20000010; addresses[3]=32'h20000014;
        addresses[4]=32'h20000018; addresses[5]=32'h2000001c;
        addresses[6]=32'h20000020; addresses[7]=32'h20000024;
        addresses[8]=32'h20000028; addresses[9]=32'h2000002c;
        addresses[10]=32'h20000030; addresses[11]=32'h20000034;
        addresses[12]=32'h20000008; addresses[13]=32'h20000038;
        addresses[14]=32'h10000020; addresses[15]=32'h20000120;
        reset_device();
        gpio_in=8'h96; repeat(4) @(negedge clk);
        access(0,32'h20000000,2,0,0,17);
        access(0,32'h20000004,2,0,0,13);
        access(1,32'h20000020,2,32'h123456a5,15,12);
        access(0,32'h20000020,2,0,0,5);
        access(1,32'h20000028,2,32'hfedcba39,15,5);
        access(0,32'h20000024,2,0,0,4);
        access(0,32'h20000028,2,0,0,4);
        access(1,32'h2000002c,2,32'h12,15,4);
        access(1,32'h20000030,2,32'h81,15,4);
        access(1,32'h20000034,2,32'h55,15,15);
        access(0,32'h20000020,2,0,0,3);
        // Each TX width is accepted once, with a busy rejection between sends.
        for(i=0;i<3;i=i+1) begin
            access(1,32'h20000010,i,32'h123400a3+i,(i==0)?1:((i==1)?3:15),4);
            access(0,32'h20000014,2,0,0,3);
            access(1,32'h20000010,2,32'h55,15,3);
            repeat(85) @(negedge clk);
            access(0,32'h20000014,2,0,0,3);
        end
        // Real serial frames fill the depth-two queue; a third sets overflow.
        send_rx(8'h5a,0); send_rx(8'hc3,0); send_rx(8'h77,0); send_rx(8'hb6,1);
        access(0,32'h2000001c,2,0,0,7);
        // Illegal destructive-register accesses while nonempty must leave both
        // bytes and sticky flags intact for the subsequent valid read/W1C.
        access(0,32'h20000018,0,0,0,5);
        access(0,32'h20000018,1,0,0,5);
        access(0,32'h20000019,2,0,0,5);
        access(0,32'h20000018,2,0,15,5);
        access(1,32'h20000018,2,32'hcc,15,5);
        access(1,32'h2000001c,0,12,1,5);
        access(1,32'h2000001c,2,12,3,5);
        access(0,32'h2000001c,2,0,0,5);
        access(0,32'h20000018,2,0,0,19);
        access(0,32'h2000001c,2,0,0,5);
        access(1,32'h2000001c,2,4,15,9);
        access(0,32'h2000001c,2,0,0,3);
        access(1,32'h2000001c,2,8,15,6);
        access(0,32'h20000018,2,0,0,17);
        access(0,32'h20000018,2,0,0,3);
        access(0,32'h2000001c,2,0,0,3);
        // Full address/direction/width/strobe cross product, plus each misaligned
        // offset. Busy TX outcomes are modeled from prior accepted TX time.
        for(i=0;i<16;i=i+1) for(j=0;j<2;j=j+1) for(k=0;k<4;k=k+1)
            access(j,addresses[i],k,32'h6da5c3f0,j?15:0,1);
        for(i=0;i<12;i=i+1) for(j=1;j<4;j=j+1) begin
            access(0,addresses[i]+j,2,0,0,1);
            access(1,addresses[i]+j,2,32'hfe,15,1);
        end
        for(i=0;i<12;i=i+1) for(j=0;j<16;j=j+1) begin
            if(j!=15) access(1,addresses[i],2,32'had,j,1);
            if(j!=0) access(0,addresses[i],2,0,j,1);
        end
        // TX has its own lane contract: all strobes at every width, and all
        // widths/strobes at each byte offset around the sole legal base.
        for(i=0;i<4;i=i+1) for(j=0;j<16;j=j+1)
            access(1,32'h20000010,i,32'h51a4c38e,j,1);
        for(i=1;i<4;i=i+1) for(j=0;j<4;j=j+1) for(k=0;k<16;k=k+1)
            access(1,32'h20000010+i,j,32'hffffddbb,k,1);
        // Reset in the captured-but-unexecuted interval must cancel the write.
        @(negedge clk); req_valid=1; req_write=1; req_addr=32'h20000020;
        req_size=2; req_wdata=32'hff; req_wstrb=15;
        @(posedge clk); #2; check(ref_state==1,"reset gap reached");
        canceled=canceled+1; reset_device();
        access(0,32'h20000020,2,0,0,4);
        // Reset also cancels a held response; it cannot execute the descriptor again.
        @(negedge clk); req_valid=1; req_write=0; req_addr=32'h20000000;
        req_size=2; req_wstrb=0; req_wdata=0;
        @(posedge clk); @(negedge clk); req_valid=0;
        @(posedge clk); #2; check(rsp_valid,"reset held response reached");
        reset_device();
        access(0,32'h20000020,2,0,0,4);
        repeat(100) @(negedge clk);
        check(accepted==fires+canceled,"accepted execution conservation");
        check(fires==responses+1,"one reset-canceled held response");
        check(tx_sends==physical_tx && physical_tx>=3,"physical UART conservation");
        check(rx_pops==2 && gpio_writes>=5 && errors>800 && accepted==860,"scenario coverage");
        fd=$fopen("build/cpu5_s10_mmio_endpoint/summary.json","w");
        $fdisplay(fd,"{\"pass\":true,\"checks\":%0d,\"accepted\":%0d,\"fires\":%0d,\"responses\":%0d,\"errors\":%0d,\"legal_ops\":%0d,\"rx_pops\":%0d,\"tx_sends\":%0d,\"physical_tx\":%0d,\"gpio_writes\":%0d,\"held_cycles\":%0d,\"canceled_before_fire\":%0d,\"resets\":%0d}",checks,accepted,fires,responses,errors,legal_ops,rx_pops,tx_sends,physical_tx,gpio_writes,held_cycles,canceled,reset_count);
        $fclose(fd); test_pass=1;
        $display("CPU5 MMIO ENDPOINT ORACLE PASS checks=%0d accepted=%0d fire=%0d errors=%0d",checks,accepted,fires,errors);
        $finish;
    end
    initial begin #3000000; $fatal(1,"MMIO endpoint watchdog"); end
endmodule

module cpu5_mmio_endpoint_echo_guard_tb;
    wire ready,valid,error,tx; wire [31:0] data; wire [7:0] gout,goe;
    cpu5_mmio_endpoint #(.UART_CLOCK_HZ(800),.UART_BAUD(100),.SIM_CONSOLE_ECHO(2)) dut(
        .clk(1'b0),.rst_n(1'b0),.req_valid(1'b0),.req_ready(ready),.req_write(1'b0),
        .req_addr(32'd0),.req_size(2'd0),.req_wdata(32'd0),.req_wstrb(4'd0),
        .rsp_valid(valid),.rsp_ready(1'b0),.rsp_rdata(data),.rsp_error(error),
        .cycle_count(64'd0),.instret_count(64'd0),.uart_rx(1'b1),.uart_tx(tx),
        .gpio_in(8'd0),.gpio_out(gout),.gpio_oe(goe));
    initial #10 $finish;
endmodule

module cpu5_mmio_endpoint_clock_guard_tb;
    wire ready,valid,error,tx; wire [31:0] data; wire [7:0] gout,goe;
    cpu5_mmio_endpoint #(.UART_CLOCK_HZ(300),.UART_BAUD(100)) dut(
        .clk(1'b0),.rst_n(1'b0),.req_valid(1'b0),.req_ready(ready),.req_write(1'b0),
        .req_addr(32'd0),.req_size(2'd0),.req_wdata(32'd0),.req_wstrb(4'd0),
        .rsp_valid(valid),.rsp_ready(1'b0),.rsp_rdata(data),.rsp_error(error),
        .cycle_count(64'd0),.instret_count(64'd0),.uart_rx(1'b1),.uart_tx(tx),
        .gpio_in(8'd0),.gpio_out(gout),.gpio_oe(goe));
    initial #10 $finish;
endmodule

module cpu5_mmio_endpoint_fifo_guard_tb;
    wire ready,valid,error,tx; wire [31:0] data; wire [7:0] gout,goe;
    cpu5_mmio_endpoint #(.UART_CLOCK_HZ(800),.UART_BAUD(100),.UART_RX_FIFO_DEPTH(256)) dut(
        .clk(1'b0),.rst_n(1'b0),.req_valid(1'b0),.req_ready(ready),.req_write(1'b0),
        .req_addr(32'd0),.req_size(2'd0),.req_wdata(32'd0),.req_wstrb(4'd0),
        .rsp_valid(valid),.rsp_ready(1'b0),.rsp_rdata(data),.rsp_error(error),
        .cycle_count(64'd0),.instret_count(64'd0),.uart_rx(1'b1),.uart_tx(tx),
        .gpio_in(8'd0),.gpio_out(gout),.gpio_oe(goe));
    initial #10 $finish;
endmodule
