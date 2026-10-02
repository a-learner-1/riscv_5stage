`timescale 1ns/1ps
module axi_lite_ctrl_tb;
    wire main_done, boundary_done;
    reg test_pass=0;
    axi_ctrl_main_case main_case(main_done);
    axi_ctrl_one_cycle_case boundary_case(boundary_done);
    initial begin
        wait(main_done&&boundary_done);
        $display("PASS: AXI control demo register semantics, independent channels, job timing/snapshots, errors, backpressure and reset");
        test_pass=1;
        $stop;
    end
    initial begin
        #300000;
        $fatal(1,"AXI control timeout main=%b boundary=%b",main_done,boundary_done);
    end
endmodule

module axi_ctrl_main_case(output reg test_done=0);
    localparam [31:0] BASE=32'h30000000;
    localparam integer JOB_CYCLES=64;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [31:0] awaddr=0,wdata=0,araddr=0;
    reg [3:0] wstrb=0;
    reg awvalid=0,wvalid=0,arvalid=0,bready=0,rready=0;
    wire awready,wready,arready,bvalid,rvalid,busy,done;
    wire [31:0] rdata,result,start_count;
    wire [1:0] bresp,rresp;
    axi_lite_ctrl #(
        .BASE_ADDR(BASE),.JOB_CYCLES(JOB_CYCLES),
        .AW_WAIT_CYCLES(2),.W_WAIT_CYCLES(2),.AR_WAIT_CYCLES(2),
        .B_WAIT_CYCLES(2),.R_WAIT_CYCLES(2)
    ) dut (
        .clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awprot(3'b000),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arprot(3'b000),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .busy(busy),.done(done),.result(result),.start_count(start_count)
    );
    integer aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0;
    integer b_errors=0,r_errors=0,b_stalls=0,r_stalls=0;
    integer order_aw=0,order_w=0,order_same=0,write_cases=0,read_cases=0;
    integer job_starts=0,job_completions=0,job_cancels=0,reset_cases=0;
    integer clock_index=0,job_start_clock=0;
    time aw_time=0,w_time=0;
    reg held_b=0,held_r=0;
    reg [1:0] held_bresp=0;
    reg [33:0] held_rpayload=0;
    reg previous_busy=0;
    reg [31:0] previous_count=0,expected_job_result=0;

    always @(posedge clk) begin
        clock_index=clock_index+1;
        if (!rst_n) begin held_b=0;held_r=0;end
        else begin
            if (held_b&&(!bvalid||bresp!==held_bresp)) $fatal(1,"Control B response changed while held");
            if (held_r&&(!rvalid||{rdata,rresp}!==held_rpayload)) $fatal(1,"Control R snapshot changed while held");
            held_b=bvalid&&!bready;held_r=rvalid&&!rready;
            if (held_b) begin held_bresp=bresp;b_stalls=b_stalls+1;end
            if (held_r) begin held_rpayload={rdata,rresp};r_stalls=r_stalls+1;end
            if (awvalid&&awready) begin aw_count=aw_count+1;aw_time=$time;end
            if (wvalid&&wready) begin w_count=w_count+1;w_time=$time;end
            if (bvalid&&bready) begin b_count=b_count+1;if(bresp!=0)b_errors=b_errors+1;end
            if (arvalid&&arready) ar_count=ar_count+1;
            if (rvalid&&rready) begin r_count=r_count+1;if(rresp!=0)r_errors=r_errors+1;end
        end
        #1;
        if (!rst_n) begin
            if (previous_busy) job_cancels=job_cancels+1;
            previous_busy=0;previous_count=0;
        end else begin
            if (start_count!==previous_count) begin
                if (start_count!==previous_count+1 || !busy || done)
                    $fatal(1,"START did not increment once and begin one job");
                job_starts=job_starts+1;job_start_clock=clock_index;
            end
            if (previous_busy&&!busy) begin
                if (!done || result!==expected_job_result || clock_index-job_start_clock!=JOB_CYCLES)
                    $fatal(1,"Job completion timing/result got=%h expected=%h clocks=%0d",
                           result,expected_job_result,clock_index-job_start_clock);
                job_completions=job_completions+1;
            end
            previous_busy=busy;previous_count=start_count;
        end
    end

    task tick;
        begin @(posedge clk);#2;end
    endtask
    task reset_device;
        begin
            @(negedge clk);rst_n=0;
            awvalid=0;wvalid=0;arvalid=0;bready=0;rready=0;
            #1;
            if (awready||wready||arready||bvalid||rvalid||busy||done||result!==0||start_count!==0)
                $fatal(1,"Control reset failed to clear device/protocol state");
            repeat(3)@(negedge clk);
            rst_n=1;tick();
        end
    endtask
    task offer_aw;
        input [31:0] address;
        integer before_count;
        begin
            before_count=aw_count;
            @(negedge clk);awaddr=address;awvalid=1;
            while(aw_count==before_count)tick();
            @(negedge clk);awvalid=0;
            if(aw_count!=before_count+1)$fatal(1,"Duplicate AW acceptance");
        end
    endtask
    task offer_w;
        input [31:0] data;
        input [3:0] mask;
        integer before_count;
        begin
            before_count=w_count;
            @(negedge clk);wdata=data;wstrb=mask;wvalid=1;
            while(w_count==before_count)tick();
            @(negedge clk);wvalid=0;
            if(w_count!=before_count+1)$fatal(1,"Duplicate W acceptance");
        end
    endtask
    task begin_write;
        input [31:0] address,data;
        input [3:0] mask;
        input integer channel_order;
        integer before_aw,before_w;
        reg aw_finished,w_finished;
        begin
            before_aw=aw_count;before_w=w_count;
            if(channel_order==0)begin
                offer_aw(address);
                repeat(3)begin tick();if(bvalid)$fatal(1,"B emitted before W");end
                offer_w(data,mask);
                if(!(aw_time<w_time))$fatal(1,"AW-first order");
                order_aw=order_aw+1;
            end else if(channel_order==1)begin
                offer_w(data,mask);
                repeat(3)begin tick();if(bvalid)$fatal(1,"B emitted before AW");end
                offer_aw(address);
                if(!(w_time<aw_time))$fatal(1,"W-first order");
                order_w=order_w+1;
            end else begin
                @(negedge clk);awaddr=address;wdata=data;wstrb=mask;awvalid=1;wvalid=1;
                aw_finished=0;w_finished=0;
                while(!aw_finished||!w_finished)begin
                    tick();
                    if(aw_count!=before_aw)aw_finished=1;
                    if(w_count!=before_w)w_finished=1;
                    @(negedge clk);
                    if(aw_finished)awvalid=0;
                    if(w_finished)wvalid=0;
                end
                if(aw_time!=w_time)$fatal(1,"Simultaneous AW/W order");
                order_same=order_same+1;
            end
            if(aw_count!=before_aw+1||w_count!=before_w+1)$fatal(1,"Write accepted more than once");
        end
    endtask
    task finish_b;
        input [1:0] expected_response;
        input integer hold_clocks;
        integer before_count;
        begin
            before_count=b_count;
            while(!bvalid)tick();
            if(bresp!==expected_response)$fatal(1,"BRESP got=%b expected=%b",bresp,expected_response);
            repeat(hold_clocks)begin
                tick();
                if(!bvalid||bresp!==expected_response||awready||wready)
                    $fatal(1,"Held B lost response or accepted another write");
            end
            @(negedge clk);bready=1;
            while(b_count==before_count)tick();
            @(negedge clk);bready=0;
            tick();if(bvalid||b_count!=before_count+1)$fatal(1,"Duplicate B response");
        end
    endtask
    task write_reg;
        input [31:0] address,data;
        input [3:0] mask;
        input integer channel_order;
        input [1:0] expected_response;
        begin
            begin_write(address,data,mask,channel_order);
            finish_b(expected_response,1);
            write_cases=write_cases+1;
        end
    endtask
    task begin_read;
        input [31:0] address;
        integer before_count;
        begin
            before_count=ar_count;
            @(negedge clk);araddr=address;arvalid=1;
            while(ar_count==before_count)tick();
            @(negedge clk);arvalid=0;
            if(ar_count!=before_count+1)$fatal(1,"Duplicate AR acceptance");
        end
    endtask
    task finish_r;
        input [31:0] expected_data;
        input [1:0] expected_response;
        input integer hold_clocks;
        integer before_count;
        begin
            before_count=r_count;
            while(!rvalid)tick();
            if(rdata!==expected_data||rresp!==expected_response)
                $fatal(1,"R response got=%h/%b expected=%h/%b",rdata,rresp,expected_data,expected_response);
            repeat(hold_clocks)begin
                tick();
                if(!rvalid||rdata!==expected_data||rresp!==expected_response||arready)
                    $fatal(1,"Held R snapshot changed");
            end
            @(negedge clk);rready=1;
            while(r_count==before_count)tick();
            @(negedge clk);rready=0;
            tick();if(rvalid||r_count!=before_count+1)$fatal(1,"Duplicate R response");
        end
    endtask
    task read_reg;
        input [31:0] address,expected_data;
        input [1:0] expected_response;
        begin
            begin_read(address);finish_r(expected_data,expected_response,2);
            read_cases=read_cases+1;
        end
    endtask

    integer held_start_count;
    initial begin
        reset_device();
        read_reg(BASE,0,0);read_reg(BASE+4,0,0);read_reg(BASE+8,0,0);
        read_reg(BASE+12,0,0);read_reg(BASE+16,0,0);read_reg(BASE+20,0,0);
        write_reg(BASE+8,32'h11223344,15,0,0);
        write_reg(BASE+12,32'h01020304,15,1,0);
        write_reg(BASE+8,32'haabbccdd,5,2,0);
        write_reg(BASE+12,32'hfedcba98,10,2,0);
        write_reg(BASE+8,32'hdeadbeef,0,2,0);
        read_reg(BASE+8,32'h11bb33dd,0);read_reg(BASE+12,32'hfe02ba04,0);
        write_reg(BASE+8,40,15,2,0);write_reg(BASE+12,2,15,2,0);
        expected_job_result=42;
        write_reg(BASE,1,1,2,0);
        if(!busy||done||start_count!==1)$fatal(1,"First START state");
        write_reg(BASE,1,1,2,2);
        if(!busy||done||start_count!==1)$fatal(1,"Busy START restarted job");
        write_reg(BASE,3,8,2,0);
        if(!busy||done||start_count!==1)$fatal(1,"Disabled CTRL byte lane affected a busy job");
        write_reg(BASE+8,100,15,2,0);write_reg(BASE+12,200,15,2,0);
        if(!busy)$fatal(1,"Operand modifications were not made during a job");
        // AR captures busy=1. Leave RREADY low across job completion.
        begin_read(BASE+4);
        while(!rvalid)tick();
        if(rdata!==1||rresp!==0)$fatal(1,"STATUS busy snapshot");
        while(busy)tick();
        if(!done||result!==42||start_count!==1||rdata!==1)$fatal(1,"Job snapshot/held STATUS changed");
        finish_r(1,0,3);read_cases=read_cases+1;
        read_reg(BASE+4,2,0);read_reg(BASE+4,2,0);read_reg(BASE+16,42,0);read_reg(BASE+20,1,0);
        read_reg(BASE+8,100,0);read_reg(BASE+12,200,0);
        // CTRL only consumes lane zero; neither of these may START or CLEAR.
        write_reg(BASE,3,8,2,0);write_reg(BASE,3,0,2,0);
        if(busy||!done||start_count!==1)$fatal(1,"CTRL disabled byte lane had side effect");
        read_reg(BASE,0,0);
        write_reg(BASE+8,32'hffffffff,15,2,0);write_reg(BASE+12,2,15,2,0);
        expected_job_result=1;
        write_reg(BASE,3,1,2,0);
        if(!busy||done||start_count!==2)$fatal(1,"CLEAR+START ordering");
        write_reg(BASE,2,1,2,0);
        if(!busy||done||start_count!==2)$fatal(1,"CLEAR_DONE cancelled a running job");
        // The two request wait counters are 2: from offering both VALID
        // at cycle +60.5, acceptance is +63 and pairing is +64. This
        // deliberately places CLEAR_DONE on the new completion edge.
        while(clock_index<job_start_clock+JOB_CYCLES-4)tick();
        begin_write(BASE,2,1,2);
        finish_b(0,1);write_cases=write_cases+1;
        if(busy||!done||result!==1||start_count!==2)
            $fatal(1,"New completion did not win over same-edge CLEAR_DONE");
        while(busy)tick();
        read_reg(BASE+16,1,0);read_reg(BASE+4,2,0);read_reg(BASE+20,2,0);
        write_reg(BASE,2,1,2,0);
        read_reg(BASE+4,0,0);read_reg(BASE+16,1,0);
        write_reg(BASE+4,32'hffffffff,0,2,2);
        write_reg(BASE+16,99,15,2,2);write_reg(BASE+20,99,15,2,2);
        write_reg(BASE+24,99,15,2,2);write_reg(BASE+9,99,15,2,2);
        write_reg(BASE+32'h100,99,15,2,2);
        read_reg(BASE+24,0,2);read_reg(BASE+9,0,2);read_reg(BASE+32'h100,0,2);
        read_reg(BASE+8,32'hffffffff,0);read_reg(BASE+12,2,0);read_reg(BASE+16,1,0);read_reg(BASE+20,2,0);

        offer_aw(BASE+8);repeat(4)tick();
        if(bvalid||busy||start_count!==2)$fatal(1,"AW-only caused a side effect");
        reset_device();reset_cases=reset_cases+1;
        offer_w(1,1);repeat(4)tick();
        if(bvalid||busy||start_count!==0)$fatal(1,"W-only caused a side effect");
        reset_device();reset_cases=reset_cases+1;
        // Commit is observable before the B response is consumed.
        begin_write(BASE+8,35,15,2);
        while(!bvalid)tick();
        read_reg(BASE+8,35,0);
        if(!bvalid||bresp!==0)$fatal(1,"Write waited for BREADY to commit");
        reset_device();reset_cases=reset_cases+1;
        write_reg(BASE+8,7,15,2,0);
        begin_read(BASE+8);while(!rvalid)tick();
        write_reg(BASE+8,9,15,2,0);
        if(rdata!==7||rresp!==0||!rvalid)$fatal(1,"Read snapshot changed after a later operand write");
        reset_device();reset_cases=reset_cases+1;
        write_reg(BASE+8,12,15,2,0);write_reg(BASE+12,13,15,2,0);
        expected_job_result=25;
        write_reg(BASE,1,1,2,0);repeat(4)tick();
        if(!busy||done||start_count!==1)$fatal(1,"Busy-reset setup");
        reset_device();reset_cases=reset_cases+1;
        repeat(JOB_CYCLES+5)tick();
        if(busy||done||result!==0||start_count!==0)$fatal(1,"Cancelled job completed after reset");
        read_reg(BASE+8,0,0);read_reg(BASE+12,0,0);
        write_reg(BASE+8,32'hfffffffe,15,2,0);write_reg(BASE+12,3,15,2,0);
        expected_job_result=1;write_reg(BASE,1,1,2,0);
        while(busy)tick();
        read_reg(BASE+4,2,0);read_reg(BASE+16,1,0);read_reg(BASE+20,1,0);
        if(job_starts!=4||job_completions!=3||job_cancels!=1||reset_cases!=5||
            b_errors!=7||r_errors!=3||aw_count!=36||w_count!=36||b_count!=34||
            ar_count!=35||r_count!=34||write_cases!=34||read_cases!=34||
            order_aw!=1||order_w!=1||order_same!=33||b_stalls==0||r_stalls==0)
            $fatal(1,"Control coverage jobs=%0d/%0d cancelled=%0d reset=%0d errors=%0d/%0d",
                   job_starts,job_completions,job_cancels,reset_cases,b_errors,r_errors);
        $display("CTRL main PASS: jobs started=4 completed=3 reset-cancelled=1, five reset cases; write errors=7 read errors=3");
        $display("CTRL channels AW=%0d W=%0d B=%0d AR=%0d R=%0d; write/read cases=%0d/%0d; orders=%0d/%0d/%0d; B/R held cycles=%0d/%0d",
                 aw_count,w_count,b_count,ar_count,r_count,write_cases,read_cases,order_aw,order_w,order_same,b_stalls,r_stalls);
        test_done=1;
    end
endmodule

// Minimum legal JOB_CYCLES is independently checked without wait insertion.
module axi_ctrl_one_cycle_case(output reg test_done=0);
    localparam [31:0] BASE=32'h30000000;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [31:0] awaddr=0,wdata=0;
    reg awvalid=0,wvalid=0,bready=0;
    wire awready,wready,bvalid,busy,done;
    wire [1:0] bresp;
    wire [31:0] result,start_count;
    integer aw_count=0,w_count=0,b_count=0,cycle_index=0,start_cycle=0;
    reg saw_start=0,saw_completion=0;
    axi_lite_ctrl #(.BASE_ADDR(BASE),.JOB_CYCLES(1)) dut (
        .clk(clk),.rst_n(rst_n),.s_axi_awaddr(awaddr),.s_axi_awprot(3'd0),
        .s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(32'd0),.s_axi_arprot(3'd0),.s_axi_arvalid(1'b0),.s_axi_arready(),
        .s_axi_rdata(),.s_axi_rresp(),.s_axi_rvalid(),.s_axi_rready(1'b0),
        .busy(busy),.done(done),.result(result),.start_count(start_count)
    );
    always @(posedge clk)begin
        cycle_index=cycle_index+1;
        if(rst_n)begin
            if(awvalid&&awready)aw_count=aw_count+1;
            if(wvalid&&wready)w_count=w_count+1;
            if(bvalid&&bready)b_count=b_count+1;
        end
        #1;
        if(rst_n&&start_count==1&&!saw_start)begin
            if(!busy||done)$fatal(1,"JOB1 START must be visible before completion");
            saw_start=1;start_cycle=cycle_index;
        end else if(rst_n&&saw_start&&!saw_completion&&!busy)begin
            if(cycle_index-start_cycle!=1||!done||result!==15||start_count!==1)
                $fatal(1,"JOB1 did not finish exactly one clock after START");
            saw_completion=1;
        end
    end
    task write_reg;
        input [31:0] address,data;
        integer old_aw,old_w,old_b;
        begin
            old_aw=aw_count;old_w=w_count;old_b=b_count;
            @(negedge clk);awaddr=address;wdata=data;awvalid=1;wvalid=1;
            while(aw_count==old_aw||w_count==old_w)begin @(posedge clk);#2;end
            @(negedge clk);awvalid=0;wvalid=0;
            while(!bvalid)begin @(posedge clk);#2;end
            if(bresp!==0)$fatal(1,"JOB1 write error");
            repeat(3)begin @(posedge clk);#2;end
            @(negedge clk);bready=1;
            while(b_count==old_b)begin @(posedge clk);#2;end
            @(negedge clk);bready=0;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        write_reg(BASE+8,9);write_reg(BASE+12,6);write_reg(BASE,1);
        if(!saw_start||!saw_completion||!done||busy||result!==15||start_count!==1||
            aw_count!=3||w_count!=3||b_count!=3)$fatal(1,"JOB1 final state");
        $display("CTRL JOB_CYCLES=1 PASS: one START, one next-clock completion, result=15, three writes");
        test_done=1;
    end
endmodule
