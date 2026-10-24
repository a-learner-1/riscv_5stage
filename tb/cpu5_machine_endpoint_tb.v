`timescale 1ns/1ps
// Independent descriptor/protocol and unsigned 64-bit device model.
module cpu5_machine_endpoint_case #(parameter integer MASK=0)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
    reg [31:0] req_addr=0,req_wdata=0;reg [1:0] req_size=0;reg [3:0] req_wstrb=0;
    wire req_ready,rsp_valid,rsp_error,irq_timer,irq_software;
    wire [31:0] rsp_rdata;wire [63:0] mtime_value,mtimecmp_value;
    cpu5_machine_endpoint #(.ENABLE_TIMER_DEVICE(MASK&1),.ENABLE_SOFTWARE_DEVICE((MASK>>1)&1)) dut(.*);
    integer checks=0,accepted=0,fires=0,responses=0,errors=0,legal_ops=0;
    integer timer_writes=0,software_writes=0,held_cycles=0,canceled_before_fire=0,canceled_after_fire=0,resets=0;
    integer carries=0,wraps=0,mtip_high=0,msip_high=0;
    integer ref_state=0,fd,i,j,k,n;
    reg [31:0] addresses[0:6];
    reg ref_write=0;reg [31:0] ref_addr=0,ref_data=0;reg [1:0] ref_size=0;reg [3:0] ref_strb=0;
    reg [63:0] time_model=0,compare_model=64'hffffffffffffffff,next_time;
    reg software_model=0,legal=0,timer_hit=0,software_hit=0;
    reg [31:0] expected_data=0;reg expected_error=0;
    task check(input condition,input [1023:0] description);
        begin checks=checks+1;if(condition!==1'b1)$fatal(1,"MACHINE endpoint oracle %0s mask=%0d check=%0d addr=%h",description,MASK,checks,ref_addr);end
    endtask
    task check_devices;
        begin
            check(mtime_value===(MASK&1?time_model:64'd0),"mtime mathematical state");
            check(mtimecmp_value===(MASK&1?compare_model:64'hffffffffffffffff),"mtimecmp mathematical state");
            check(irq_timer===((MASK&1)!=0 && time_model>=compare_model),"MTIP unsigned level");
            check(irq_software===((MASK&2)!=0 && software_model),"MSIP retained level");
        end
    endtask
    always @(posedge clk)begin
        if(!rst_n)begin
            ref_state=0;time_model=0;compare_model=64'hffffffffffffffff;software_model=0;
            expected_data=0;expected_error=0;
            #1;check(!req_ready&&!rsp_valid&&!irq_timer&&!irq_software,"reset cancels response and source");check_devices;
        end else begin
            check(req_ready===(ref_state==0),"ready has no response bypass");
            check(rsp_valid===(ref_state==2),"response phase");
            check(dut.endpoint_fire===(ref_state==1),"unique delayed endpoint fire");
            check_devices;
            if(irq_timer)mtip_high=mtip_high+1;if(irq_software)msip_high=msip_high+1;
            next_time=time_model+64'd1;
            if(ref_state==2)begin
                check(rsp_rdata===expected_data&&rsp_error===expected_error,"frozen response payload");
                if(!rsp_ready)held_cycles=held_cycles+1;
            end
            case(ref_state)
                0:if(req_valid&&req_ready)begin
                    ref_write=req_write;ref_addr=req_addr;ref_size=req_size;ref_data=req_wdata;ref_strb=req_wstrb;
                    accepted=accepted+1;ref_state=1;
                end
                1:begin
                    fires=fires+1;expected_data=0;
                    timer_hit=(MASK&1)!=0 && (ref_addr==32'h20000040||ref_addr==32'h20000044||ref_addr==32'h20000048||ref_addr==32'h2000004c);
                    software_hit=(MASK&2)!=0 && ref_addr==32'h20000050;
                    legal=ref_size==2 && ref_addr[1:0]==0 && (timer_hit||software_hit) && (ref_write?ref_strb==15:ref_strb==0);
                    if(legal)begin
                        legal_ops=legal_ops+1;
                        if(ref_write)begin
                            if(timer_hit)begin
                                timer_writes=timer_writes+1;
                                case(ref_addr)
                                    32'h20000040:next_time={time_model[63:32],ref_data};
                                    32'h20000044:next_time={ref_data,time_model[31:0]};
                                    32'h20000048:compare_model={compare_model[63:32],ref_data};
                                    32'h2000004c:compare_model={ref_data,compare_model[31:0]};
                                endcase
                            end else begin software_model=ref_data[0];software_writes=software_writes+1;end
                        end else begin
                            case(ref_addr)
                                32'h20000040:expected_data=time_model[31:0];
                                32'h20000044:expected_data=time_model[63:32];
                                32'h20000048:expected_data=compare_model[31:0];
                                32'h2000004c:expected_data=compare_model[63:32];
                                32'h20000050:expected_data=software_model;
                            endcase
                        end
                    end else errors=errors+1;
                    check(dut.timer_write_fire===(legal&&ref_write&&timer_hit),"timer write qualification");
                    check(dut.software_write_fire===(legal&&ref_write&&software_hit),"software write qualification");
                    expected_error=!legal;ref_state=2;
                end
                2:if(rsp_ready)begin responses=responses+1;ref_state=0;end
            endcase
            if((MASK&1)!=0)begin
                if(time_model[31:0]==32'hffffffff && next_time==time_model+64'd1)carries=carries+1;
                if(time_model==64'hffffffffffffffff && next_time==0)wraps=wraps+1;
                time_model=next_time;
            end
            #1;check_devices;
            check(rsp_valid===(ref_state==2),"registered response timing");
            if(ref_state==2)check(rsp_rdata===expected_data&&rsp_error===expected_error,"pre-edge read snapshot and errors");
        end
    end
    task access(input write_op,input [31:0] address,input [1:0] size,input [31:0] data,input [3:0] strb,input integer hold_cycles);
        begin
            @(negedge clk);req_valid=1;req_write=write_op;req_addr=address;req_size=size;req_wdata=data;req_wstrb=strb;rsp_ready=0;
            @(posedge clk);#2;check(!req_ready&&!rsp_valid,"request capture has no response");
            @(negedge clk);req_valid=1;req_write=!write_op;req_addr=32'h20000050;req_size=0;req_wdata=~data;req_wstrb=3;
            @(posedge clk);#2;check(rsp_valid,"captured request executes next edge");
            repeat(hold_cycles)begin @(negedge clk);req_addr=req_addr^4;req_wdata=req_wdata+13;end
            @(negedge clk);req_valid=0;rsp_ready=1;
            @(posedge clk);#2;check(req_ready&&!rsp_valid,"response drains before next acceptance");
            @(negedge clk);rsp_ready=0;
        end
    endtask
    task read_word(input [31:0] address);begin access(0,address,2,0,0,5);end endtask
    task write_word(input [31:0] address,input [31:0] data);begin access(1,address,2,data,15,1);end endtask
    task reset_device;
        begin
            @(negedge clk);if(ref_state==1)canceled_before_fire=canceled_before_fire+1;
            if(ref_state==2)canceled_after_fire=canceled_after_fire+1;
            rst_n=0;req_valid=0;rsp_ready=0;resets=resets+1;
            repeat(3)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
        end
    endtask
    initial begin
        addresses[0]='h20000040;addresses[1]='h20000044;addresses[2]='h20000048;addresses[3]='h2000004c;
        addresses[4]='h20000050;addresses[5]='h20000054;addresses[6]='h30000040;
        reset_device;
        for(i=0;i<5;i=i+1)read_word(addresses[i]);
        write_word('h20000050,1);read_word('h20000050);
        write_word('h20000050,'hfffffffe);read_word('h20000050);
        write_word('h20000050,'hffffffff);repeat(12)@(negedge clk);read_word('h20000050);write_word('h20000050,0);
        // MTIP is level owned by the comparator; acknowledgements do not clear.
        write_word('h20000048,0);write_word('h2000004c,0);repeat(12)@(negedge clk);
        read_word('h20000048);read_word('h2000004c);
        // Safe RV32 compare update and both high halves read back independently.
        write_word('h2000004c,'hffffffff);write_word('h20000048,'h12345678);write_word('h2000004c,'h80000000);
        read_word('h20000048);read_word('h2000004c);
        // Distinguish unsigned comparison from signed time, then restore quiet.
        write_word('h20000044,'h90000000);write_word('h20000040,'h12340000);repeat(7)@(negedge clk);
        write_word('h2000004c,'hffffffff);write_word('h20000048,'hffffffff);
        // Crossing low carry and the full 64-bit wrap uses real MMIO writes.
        write_word('h20000044,'hffffffff);write_word('h20000040,'hfffffffa);repeat(20)@(negedge clk);
        read_word('h20000040);read_word('h20000044);
        write_word('h20000044,'h12345678);write_word('h20000040,'hfffffffa);repeat(20)@(negedge clk);
        read_word('h20000040);read_word('h20000044);
        // Full direction/size/strobe/offset matrix, including unmapped and
        // disabled words. Model time keeps running through every response hold.
        for(i=0;i<7;i=i+1)for(j=0;j<4;j=j+1)for(k=0;k<4;k=k+1)for(n=0;n<16;n=n+1)begin
            access(0,addresses[i]+k,j,0,n,1+n%2);
            access(1,addresses[i]+k,j,32'h89abcdef^i^k,n,1+n%3);
        end
        // Reset after capture, before execution: no register write may occur.
        @(negedge clk);req_valid=1;req_write=1;req_addr='h20000050;req_size=2;req_wdata=1;req_wstrb=15;
        @(posedge clk);#2;check(ref_state==1,"reset captured request fixture");reset_device;
        // Reset after execution while response is held; source and response clear.
        @(negedge clk);req_valid=1;req_write=1;req_addr='h20000050;req_size=2;req_wdata=1;req_wstrb=15;
        @(posedge clk);#2;@(negedge clk);req_valid=0;@(posedge clk);#2;
        check(ref_state==2,"reset held response fixture");reset_device;
        read_word('h20000040);read_word('h20000044);read_word('h20000048);read_word('h2000004c);read_word('h20000050);
        check(accepted==fires+canceled_before_fire,"accepted execution conservation");
        check(fires==responses+canceled_after_fire,"executed response conservation");
        check(canceled_before_fire==1&&canceled_after_fire==1&&resets==3,"reset coverage");
        if(MASK&1)check(carries>=2&&wraps>=1&&mtip_high>10&&timer_writes>10,"timer carry wrap and IRQ coverage");
        if(MASK&2)check(software_writes>=6&&msip_high>10,"software level coverage");
        $display("MACHINE_COUNTS mask=%0d accepted=%0d fires=%0d responses=%0d errors=%0d held=%0d carries=%0d wraps=%0d",MASK,accepted,fires,responses,errors,held_cycles,carries,wraps);
        check(errors>3500&&accepted>3600&&held_cycles>3000,"illegal and hold coverage");
        fd=$fopen($sformatf("build/cpu5_s11_machine_endpoint/mask%0d_summary.json",MASK),"w");
        $fdisplay(fd,"{\"pass\":true,\"mask\":%0d,\"checks\":%0d,\"accepted\":%0d,\"fires\":%0d,\"responses\":%0d,\"errors\":%0d,\"legal_ops\":%0d,\"timer_writes\":%0d,\"software_writes\":%0d,\"held_cycles\":%0d,\"canceled_before_fire\":%0d,\"canceled_after_fire\":%0d,\"resets\":%0d,\"carries\":%0d,\"wraps\":%0d,\"mtip_high\":%0d,\"msip_high\":%0d}",MASK,checks,accepted,fires,responses,errors,legal_ops,timer_writes,software_writes,held_cycles,canceled_before_fire,canceled_after_fire,resets,carries,wraps,mtip_high,msip_high);
        $fclose(fd);done=1;
    end
endmodule
module cpu5_machine_endpoint_tb;
    wire [3:0] done;reg test_pass=0;
    genvar m;generate for(m=0;m<4;m=m+1)begin:g_masks
        cpu5_machine_endpoint_case #(.MASK(m)) test(done[m]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 MACHINE ENDPOINT TEST PASS");$stop;end
    initial begin #1000000;$fatal(1,"MACHINE endpoint timeout");end
endmodule
module cpu5_machine_endpoint_timer_guard_tb;
    cpu5_machine_endpoint #(.ENABLE_TIMER_DEVICE(2)) dut(
        .clk(1'b0),.rst_n(1'b0),.req_valid(1'b0),.req_ready(),.req_write(1'b0),.req_addr(32'd0),
        .req_size(2'd2),.req_wdata(32'd0),.req_wstrb(4'd0),.rsp_valid(),.rsp_ready(1'b0),
        .rsp_rdata(),.rsp_error(),.irq_timer(),.irq_software(),.mtime_value(),.mtimecmp_value());
    initial begin #20;$fatal(1,"MACHINE invalid timer enable accepted");end
endmodule
module cpu5_machine_endpoint_software_guard_tb;
    cpu5_machine_endpoint #(.ENABLE_SOFTWARE_DEVICE(2)) dut(
        .clk(1'b0),.rst_n(1'b0),.req_valid(1'b0),.req_ready(),.req_write(1'b0),.req_addr(32'd0),
        .req_size(2'd2),.req_wdata(32'd0),.req_wstrb(4'd0),.rsp_valid(),.rsp_ready(1'b0),
        .rsp_rdata(),.rsp_error(),.irq_timer(),.irq_software(),.mtime_value(),.mtimecmp_value());
    initial begin #20;$fatal(1,"MACHINE invalid software enable accepted");end
endmodule
