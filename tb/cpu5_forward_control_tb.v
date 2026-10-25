`timescale 1ns/1ps
// Hand-computed ALU streams exercise the pipeline's real forwarding paths.
// result_ready forcing below is an artificial unavailable ALU result: these
// tests do not claim that LOAD execution or a load-use interlock exists yet.
module cpu5_forward_control_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,in_fetch_error=0;
    reg [31:0] in_pc=0,in_instr=0;
    reg [63:0] in_seq=0,flush_cut_seq=0;
    reg [7:0] in_epoch=0;
    reg id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    wire in_ready,retire_valid,wb_we,retire_fire,wb_fire,id_raw_wait;
    wire [31:0] wb_pc,wb_data,retire_pc,retire_instr,retire_value,arch_next_pc;
    wire [4:0] wb_rd,retire_rd;
    wire retire_writes_rd,halted,halt_fetch_error;
    wire [63:0] retire_seq,cycle_count,instret_count,halt_seq;
    wire [31:0] halt_pc,halt_instr;
    cpu5_alu_pipeline #(.ENABLE_FORWARDING(1)) dut(.perf_cycle_events(),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),.clk(clk),.rst_n(rst_n),
        .in_valid(in_valid),.in_ready(in_ready),.in_pc(in_pc),.in_instr(in_instr),
        .in_pred_next_pc(in_pc+32'd4),.in_pred_taken(1'b0),.in_pred_hit(1'b0),
        .in_fetch_error(in_fetch_error),.in_fetch_tval(in_pc),.in_seq(in_seq),.in_epoch(in_epoch),
        .id_enable(id_enable),.ex_enable(ex_enable),.mem_enable(mem_enable),.wb_ready(wb_ready),
        .flush_valid(flush_valid),.flush_cut_seq(flush_cut_seq),
        .ex_valid(),.ex_pc(),.ex_instr(),.wb_pc(wb_pc),.wb_data(wb_data),.wb_rd(wb_rd),.wb_we(wb_we),
        .retire_valid(retire_valid),.retire_pc(retire_pc),.retire_instr(retire_instr),
        .retire_value(retire_value),.retire_rd(retire_rd),.retire_writes_rd(retire_writes_rd),
        .retire_seq(retire_seq),.cycle_count(cycle_count),.instret_count(instret_count),
        .arch_next_pc_q(arch_next_pc),.halted(halted),.halt_pc(halt_pc),.halt_instr(halt_instr),
        .halt_seq(halt_seq),.halt_fetch_error(halt_fetch_error),.id_raw_wait(id_raw_wait),
        .retire_fire(retire_fire),.wb_fire(wb_fire),
        .redirect_valid(),.redirect_kill_ifid(),.redirect_pc(),.redirect_seq(),
        .bp_commit_valid(),.bp_commit_seq(),.bp_commit_pc(),.bp_commit_target(),
        .bp_commit_taken(),.bp_commit_is_branch(),.bp_commit_is_jal(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),
        .bp_target_error_count(),.halt_cause(),.halt_tval(),
        .flush_ready(),.flush_fire(),.dmem_req_valid(),.dmem_req_ready(1'b0),
        .dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),.trap_fire(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),.trap_seq());

    reg [63:0] expected_seq[0:127];
    reg [31:0] expected_pc[0:127],expected_instr[0:127],expected_value[0:127];
    reg [4:0] expected_rd[0:127];
    integer expected_count=0,retired=0,physical_writes=0,wb_consumes=0;
    integer wb_expect_index[0:127],wb_head=0,wb_tail=0;
    integer edge_number=0,case_number=0,cases_passed=0,trace_fd,coverage_fd;
    integer total_retired=0,total_wb=0,total_writes=0,total_accepts=0;
    integer total_mem_sources=0,total_wb_sources=0,total_zero_sources=0;
    integer total_blocked_edges=0,total_held_ex_edges=0,total_held_mem_edges=0,total_held_wb_edges=0;
    integer total_wb_id_sources=0,total_cross_epoch_mem_sources=0,total_turnovers=0;
    integer no_bubble_accepts=0,previous_case1_edge=-1,post_index,write_index,timeout;
    integer recovered_unready_cases=0,retired_before_hold,accepted_before_hold;
    reg test_pass=0,last_id_fire=0;
    reg [63:0] last_id_seq=0;
    reg pre_retire,pre_wb,pre_we,pre_accept,pre_source_stall,pre_stall1,pre_stall2;
    reg [31:0] pre_write_data,pre_ex_value1,pre_ex_value2;
    reg [4:0] pre_write_rd;
    reg [2:0] pre_fwd1,pre_fwd2;
    reg [63:0] pre_input_seq,pre_mem_seq,pre_wb_seq,pre_ex_seq;

    function [31:0] addi(input [4:0] rd,input [4:0] rs1,input [11:0] imm);
        begin addi={imm,rs1,3'b000,rd,7'b0010011};end
    endfunction
    function [31:0] add(input [4:0] rd,input [4:0] rs1,input [4:0] rs2);
        begin add={7'b0000000,rs2,rs1,3'b000,rd,7'b0110011};end
    endfunction
    function [31:0] slli(input [4:0] rd,input [4:0] rs1,input [4:0] shamt);
        begin slli={7'b0000000,shamt,rs1,3'b001,rd,7'b0010011};end
    endfunction
    function [31:0] lui(input [4:0] rd,input [19:0] imm);
        begin lui={imm,rd,7'b0110111};end
    endfunction
    function [31:0] auipc(input [4:0] rd,input [19:0] imm);
        begin auipc={imm,rd,7'b0010111};end
    endfunction
    task tick;begin @(posedge clk);#2;end endtask
    task reset_case(input integer number);
        begin
            @(negedge clk);rst_n=0;in_valid=0;in_fetch_error=0;
            id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            case_number=number;expected_count=0;tick;tick;
            @(negedge clk);rst_n=1;
        end
    endtask
    task expect_instruction(input [63:0] seq,input [31:0] pc,input [31:0] ins,
                            input [4:0] rd,input [31:0] value);
        begin
            expected_seq[expected_count]=seq;expected_pc[expected_count]=pc;
            expected_instr[expected_count]=ins;expected_rd[expected_count]=rd;
            expected_value[expected_count]=value;expected_count=expected_count+1;
        end
    endtask
    // Consecutive calls replace the accepted input on the very next negative
    // edge. There is no deliberately inserted bubble between instructions.
    task send(input [63:0] seq,input [31:0] pc,input [31:0] ins,input [7:0] epoch);
        begin
            @(negedge clk);in_seq=seq;in_pc=pc;in_instr=ins;in_epoch=epoch;
            in_fetch_error=0;in_valid=1;timeout=0;tick;
            while(!(last_id_fire&&last_id_seq==seq))begin
                timeout=timeout+1;if(timeout>80)$fatal(1,"ID timeout case=%0d seq=%h",case_number,seq);
                tick;
            end
        end
    endtask
    task issue(input [63:0] seq,input [31:0] pc,input [31:0] ins,
               input [4:0] rd,input [31:0] value,input [7:0] epoch);
        begin expect_instruction(seq,pc,ins,rd,value);send(seq,pc,ins,epoch);end
    endtask
    task stop_input;begin @(negedge clk);in_valid=0;end endtask
    task drain;
        begin
            timeout=0;
            while(retired!=expected_count||wb_head!=wb_tail||
                  dut.idex_valid_q||dut.exmem_valid_q||dut.memwb_valid_q)begin
                tick;timeout=timeout+1;
                if(timeout>80)$fatal(1,"drain timeout case=%0d retired=%0d/%0d",case_number,retired,expected_count);
            end
            repeat(2)tick;
            if(wb_consumes!=expected_count)$fatal(1,"retirement/WB FIFO did not close");
        end
    endtask
    task case_pass;
        begin cases_passed=cases_passed+1;
            $display("CPU5_FORWARD_CONTROL_CASE_PASS case=%0d retire=%0d wb=%0d writes=%0d",case_number,retired,wb_consumes,physical_writes);
        end
    endtask
    task check_blocked_latest;
        begin
            #1;
            if(dut.ex_source_stall!==1||dut.ex_stall1!==1||dut.ex_fwd1!==4||
               dut.ex_rs1_value!==0||dut.ex_move!==0||retire_fire!==0)
                $fatal(1,"unready latest MEM was bypassed or retired case=%0d",case_number);
        end
    endtask

    // The scoreboard's expected stream and values are hand supplied above.
    // It checks physical WB before allowing the current MEM retirement to
    // append to the WB FIFO, then checks the registered retire after NBA.
    always @(posedge clk)begin
        edge_number=edge_number+1;
        if(!rst_n)begin
            retired=0;physical_writes=0;wb_consumes=0;wb_head=0;wb_tail=0;last_id_fire=0;
            if(wb_we!==0||retire_fire!==0)$fatal(1,"side effect during reset");
            #1;if(retire_valid!==0||instret_count!==0||cycle_count!==0)$fatal(1,"reset state");
        end else begin
            pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;pre_accept=in_valid&&in_ready;
            pre_input_seq=in_seq;pre_mem_seq=dut.exmem_q.seq;pre_wb_seq=dut.memwb_q.seq;
            pre_ex_seq=dut.idex_q.seq;pre_write_data=wb_data;pre_write_rd=wb_rd;
            pre_fwd1=dut.ex_fwd1;pre_fwd2=dut.ex_fwd2;
            pre_ex_value1=dut.ex_rs1_value;pre_ex_value2=dut.ex_rs2_value;
            pre_source_stall=dut.ex_source_stall;pre_stall1=dut.ex_stall1;pre_stall2=dut.ex_stall2;
            last_id_fire=pre_accept;last_id_seq=in_seq;
            if(id_raw_wait!==0)$fatal(1,"forward mode inserted a conservative ID RAW wait");
            if(halted)$fatal(1,"ALU-only stream unexpectedly halted");
            if(pre_accept)begin
                total_accepts=total_accepts+1;
                if(case_number==1)begin
                    if(previous_case1_edge>=0&&edge_number!=previous_case1_edge+1)
                        $fatal(1,"continuous ALU dependency stream developed a bubble");
                    previous_case1_edge=edge_number;no_bubble_accepts=no_bubble_accepts+1;
                end
                if(dut.uses_rs1&&dut.rs1!=0&&dut.wb_writer&&dut.memwb_q.rd==dut.rs1)
                    total_wb_id_sources=total_wb_id_sources+1;
                if(dut.uses_rs2&&dut.rs2!=0&&dut.wb_writer&&dut.memwb_q.rd==dut.rs2)
                    total_wb_id_sources=total_wb_id_sources+1;
            end
            if(dut.idex_valid_q&&!dut.ex_move)total_held_ex_edges=total_held_ex_edges+1;
            if(dut.exmem_valid_q&&!mem_enable)total_held_mem_edges=total_held_mem_edges+1;
            if(dut.memwb_valid_q&&!wb_ready)total_held_wb_edges=total_held_wb_edges+1;
            if(pre_source_stall)total_blocked_edges=total_blocked_edges+1;
            if(dut.idex_valid_q&&!dut.kill_ex)begin
                if(pre_fwd1==2)total_mem_sources=total_mem_sources+1;
                if(pre_fwd2==2)total_mem_sources=total_mem_sources+1;
                if(pre_fwd1==3)total_wb_sources=total_wb_sources+1;
                if(pre_fwd2==3)total_wb_sources=total_wb_sources+1;
                if(pre_fwd1==1)total_zero_sources=total_zero_sources+1;
                if(pre_fwd2==1)total_zero_sources=total_zero_sources+1;
                if((pre_fwd1==2||pre_fwd2==2)&&dut.idex_q.epoch!=dut.exmem_q.epoch)
                    total_cross_epoch_mem_sources=total_cross_epoch_mem_sources+1;
            end
            if(pre_wb)begin
                if(wb_head>=wb_tail)$fatal(1,"WB without an earlier checked retirement");
                write_index=wb_expect_index[wb_head];
                if(pre_wb_seq!==expected_seq[write_index]||wb_pc!==expected_pc[write_index]||
                   dut.memwb_q.instr!==expected_instr[write_index]||wb_rd!==expected_rd[write_index]||
                   wb_data!==expected_value[write_index]||wb_we!==(expected_rd[write_index]!=0))
                    $fatal(1,"physical WB owner/value mismatch case=%0d index=%0d",case_number,write_index);
                wb_head=wb_head+1;wb_consumes=wb_consumes+1;total_wb=total_wb+1;
                if(pre_we)begin physical_writes=physical_writes+1;total_writes=total_writes+1;end
            end else if(wb_we!==0)$fatal(1,"write without WB consume");
            post_index=-1;
            if(pre_retire)begin
                if(retired>=expected_count)$fatal(1,"unexpected retirement case=%0d seq=%h",case_number,pre_mem_seq);
                post_index=retired;
                if(pre_mem_seq!==expected_seq[retired]||dut.exmem_q.pc!==expected_pc[retired]||
                   dut.exmem_q.instr!==expected_instr[retired]||dut.exmem_q.rd!==expected_rd[retired]||
                   dut.exmem_q.alu_result!==expected_value[retired])
                    $fatal(1,"MEM identity/value mismatch case=%0d index=%0d got=%h expected=%h",case_number,retired,dut.exmem_q.alu_result,expected_value[retired]);
                wb_expect_index[wb_tail]=retired;wb_tail=wb_tail+1;
                retired=retired+1;total_retired=total_retired+1;
            end
            if(pre_wb&&pre_retire)begin
                if(pre_wb_seq==pre_mem_seq)$fatal(1,"MEM/WB turnover reused an owner");
                total_turnovers=total_turnovers+1;
            end
            #1;
            if(retire_valid!==pre_retire||instret_count!==retired)$fatal(1,"registered retire/counter mismatch case=%0d",case_number);
            if(post_index>=0&&(retire_seq!==expected_seq[post_index]||retire_pc!==expected_pc[post_index]||
                retire_instr!==expected_instr[post_index]||retire_rd!==expected_rd[post_index]||
                retire_value!==expected_value[post_index]||retire_writes_rd!==(expected_rd[post_index]!=0)||
                arch_next_pc!==(expected_pc[post_index]+32'd4)))$fatal(1,"registered retirement bundle mismatch");
            if(pre_we&&dut.u_regfile.regs[pre_write_rd]!==pre_write_data)$fatal(1,"GPR WB missing after NBA");
            $fdisplay(trace_fd,"%0d,%0d,%0d,%h,%h,%0d,%0d,%h,%h,%0d,%0d,%0d,%0d,%h,%0d,%h,%0d,%0d,%h,%h,%0d,%h,%h,%h,%0d,%0d",
                edge_number,case_number,pre_accept,pre_input_seq,pre_ex_seq,pre_fwd1,pre_fwd2,pre_ex_value1,pre_ex_value2,
                pre_stall1,pre_stall2,pre_source_stall,pre_retire,pre_mem_seq,pre_wb,pre_wb_seq,pre_we,pre_write_rd,
                pre_write_data,retire_seq,retire_valid,retire_pc,retire_instr,retire_value,retired,instret_count);
        end
    end

    initial begin
        trace_fd=$fopen("build/cpu5_s3_control/control_trace.csv","w");
        if(trace_fd==0)$fatal(1,"cannot create control trace");
        $fdisplay(trace_fd,"edge,case,id_accept,input_seq,ex_seq,fwd1,fwd2,ex_rs1_value,ex_rs2_value,stall1,stall2,source_stall,pre_retire_fire,pre_mem_seq,pre_wb_fire,pre_wb_seq,pre_wb_we,pre_wb_rd,pre_wb_data,post_retire_seq,post_retire_valid,post_retire_pc,post_retire_instr,post_retire_value,retired,post_instret");

        // 1: Immediate consumers, double-source RAW, x0 destination/read and
        // operand selectors all accept on consecutive clocks.
        reset_case(1);
        issue(1,'h100,addi(1,0,7),1,7,0);
        issue(2,'h104,addi(2,1,5),2,12,0);
        issue(3,'h108,add(3,2,1),3,19,0);
        issue(4,'h10c,add(0,3,1),0,26,0);
        issue(5,'h110,add(4,0,3),4,19,0);
        issue(6,'h114,slli(5,4,1),5,38,0);
        issue(7,'h118,lui(6,'h12345),6,'h12345000,0);
        issue(8,'h11c,auipc(7,1),7,'h111c,0);
        issue(9,'h120,addi(8,5,'hffd),8,35,0);
        stop_input;drain;if(no_bubble_accepts!=9)$fatal(1,"continuous stream was not observed");case_pass;

        // 2: New MEM wins over an older WB that writes the same destination.
        reset_case(2);
        issue(10,'h200,addi(1,0,10),1,10,0);
        issue(11,'h204,addi(1,0,20),1,20,0);
        issue(12,'h208,add(2,1,1),2,40,0);
        stop_input;
        if(dut.ex_fwd1!==2||dut.ex_fwd2!==2||dut.ex_rs1_value!==20||dut.ex_rs2_value!==20)
            $fatal(1,"newest MEM did not beat matching old WB");
        drain;case_pass;

        // 3: A single consumer simultaneously takes source 1 from WB and 2
        // from MEM, including data from a different IF fetch epoch.
        reset_case(3);
        issue(20,'h300,addi(1,0,13),1,13,254);
        issue(21,'h304,addi(2,0,17),2,17,255);
        issue(22,'h308,add(3,1,2),3,30,0);
        stop_input;
        if(dut.ex_fwd1!==3||dut.ex_fwd2!==2||dut.ex_rs1_value!==13||dut.ex_rs2_value!==17)
            $fatal(1,"dual-source WB/MEM or cross-epoch forwarding missing");
        drain;case_pass;

        // 4: Producer writes exactly when consumer is admitted to ID. EX is
        // then held long enough for every live producer to disappear.
        reset_case(4);
        issue(30,'h400,addi(1,0,37),1,37,0);
        issue(31,'h404,addi(2,0,1),2,1,0);
        issue(32,'h408,addi(3,0,2),3,2,0);
        issue(33,'h40c,addi(4,1,3),4,40,0);
        stop_input;ex_enable=0;repeat(5)tick;
        if(dut.idex_q.rs1_value!==37||dut.ex_rs1_value!==37||dut.memwb_valid_q)
            $fatal(1,"WB-to-ID value was lost after the producer drained");
        @(negedge clk);ex_enable=1;drain;case_pass;

        // 5: EX disable spans the producer's MEM, WB and vanished states.
        reset_case(5);
        issue(40,'h500,addi(1,0,19),1,19,0);
        issue(41,'h504,addi(2,1,1),2,20,0);
        stop_input;ex_enable=0;repeat(5)tick;
        if(dut.idex_q.rs1_value!==19||dut.ex_rs1_value!==19||dut.memwb_valid_q)
            $fatal(1,"EX held operand was not retained across producer drain");
        @(negedge clk);ex_enable=1;drain;case_pass;

        // 6: MEM stage enable controls movement, not the validity of the ALU
        // result used by the consumer held in EX.
        reset_case(6);mem_enable=0;
        issue(50,'h600,addi(1,0,23),1,23,0);
        issue(51,'h604,addi(2,1,2),2,25,0);stop_input;
        repeat(4)begin
            if(dut.ex_source_stall!==0||dut.ex_rs1_value!==23||dut.ex_fwd1!==2)
                $fatal(1,"MEM enable incorrectly blocked available forwarding data");
            tick;
        end
        if(retired!=0)$fatal(1,"MEM hold retired early");
        @(negedge clk);mem_enable=1;drain;case_pass;

        // 7: A held, retired WB packet still forwards while wb_ready is low.
        reset_case(7);wb_ready=0;
        issue(60,'h700,addi(1,0,5),1,5,0);
        issue(61,'h704,addi(2,0,11),2,11,0);
        issue(62,'h708,add(3,1,2),3,16,0);stop_input;
        repeat(4)begin
            if(dut.ex_source_stall!==0||dut.ex_rs1_value!==5||dut.ex_rs2_value!==11||
               dut.ex_fwd1!==3||dut.ex_fwd2!==2)$fatal(1,"WB backpressure hid valid producer data");
            tick;
        end
        if(retired!=1||wb_consumes!=0)$fatal(1,"WB pressure did not hold younger MEM");
        @(negedge clk);wb_ready=1;drain;case_pass;

        // 8: Artificially unavailable newest MEM cannot fall back to an old
        // same-rd WB value, and cannot retire merely because WB can drain.
        reset_case(8);wb_ready=0;
        issue(70,'h800,addi(1,0,10),1,10,0);
        issue(71,'h804,addi(1,0,20),1,20,0);
        issue(72,'h808,addi(2,1,1),2,21,0);stop_input;
        force dut.exmem_q.result_ready=1'b0;wb_ready=1;
        repeat(4)begin check_blocked_latest;tick;end
        if(retired!=1||wb_consumes!=1)$fatal(1,"unready result retired or older WB replayed");
        @(negedge clk);force dut.exmem_q.result_ready=1'b1;tick;
        @(negedge clk);release dut.exmem_q.result_ready;drain;
        recovered_unready_cases=recovered_unready_cases+1;case_pass;

        // 9: Flush spans the 32-bit age boundary. Already retired WB survives
        // while unretired MEM/EX/input at or beyond the cut are canceled.
        reset_case(9);wb_ready=0;
        expect_instruction(64'hfffffffe,'h900,addi(1,0,13),1,13);
        send(64'hfffffffe,'h900,addi(1,0,13),3);
        send(64'hffffffff,'h904,addi(1,0,99),4);
        send(64'h100000000,'h908,addi(2,1,1),4);
        @(negedge clk);in_valid=1;in_seq=64'h100000001;in_pc='h90c;in_instr=addi(3,0,77);
        flush_valid=1;flush_cut_seq=64'hffffffff;wb_ready=1;tick;
        if(retired!=1||wb_consumes!=1||last_id_fire||dut.idex_valid_q||dut.exmem_valid_q)
            $fatal(1,"flush boundary or already-retired WB ownership failed");
        @(negedge clk);in_valid=0;flush_valid=0;
        issue(64'h100000002,'h910,addi(2,1,1),2,14,7);stop_input;drain;case_pass;

        // 10: Age and fetch epoch serve different purposes. A live old
        // producer remains usable across both the age bit-32 and epoch wraps.
        reset_case(10);
        issue(64'hffffffff,'ha00,addi(1,0,43),1,43,255);
        issue(64'h100000000,'ha04,addi(2,1,1),2,44,0);stop_input;
        if(dut.ex_fwd1!==2||dut.ex_rs1_value!==43)$fatal(1,"live old epoch producer disappeared");
        drain;case_pass;

        // 11: Selector bits must survive an arbitrary EX hold too. In
        // particular LUI/AUIPC do not consume the instruction's rs bit fields.
        reset_case(11);
        issue(90,'hb00,addi(1,0,31),1,31,0);stop_input;drain;
        ex_enable=0;issue(91,'hb04,lui(5,'habcde),5,'habcde000,0);stop_input;
        repeat(3)tick;@(negedge clk);ex_enable=1;drain;
        ex_enable=0;issue(92,'hb08,auipc(6,1),6,'h1b08,0);stop_input;
        repeat(3)tick;@(negedge clk);ex_enable=1;drain;
        ex_enable=0;issue(93,'hb0c,addi(7,1,7),7,38,0);stop_input;
        repeat(3)tick;@(negedge clk);ex_enable=1;drain;
        ex_enable=0;issue(94,'hb10,slli(8,1,31),8,'h80000000,0);stop_input;
        repeat(3)tick;@(negedge clk);ex_enable=1;drain;case_pass;

        // 12: One source is blocked by unavailable MEM while the other comes
        // from a WB packet that drains now. Retain the available source even
        // while the consumer's overall source_stall remains asserted.
        reset_case(12);wb_ready=0;
        issue(100,'hc00,addi(1,0,17),1,17,0);
        issue(101,'hc04,addi(2,0,29),2,29,0);
        issue(102,'hc08,add(3,2,1),3,46,0);stop_input;
        force dut.exmem_q.result_ready=1'b0;wb_ready=1;check_blocked_latest;
        if(dut.ex_stall2!==0||dut.ex_fwd2!==3||dut.ex_rs2_value!==17)
            $fatal(1,"unblocked second source missing during first-source stall");
        tick;repeat(3)begin check_blocked_latest;tick;end
        if(dut.idex_q.rs2_value!==17||dut.ex_rs2_value!==17)
            $fatal(1,"resolved second source vanished during a different source's stall");
        @(negedge clk);force dut.exmem_q.result_ready=1'b1;tick;
        @(negedge clk);release dut.exmem_q.result_ready;drain;
        recovered_unready_cases=recovered_unready_cases+1;case_pass;

        // 13: Mirror case 12 so that preserving only the second source cannot
        // hide a first-source hold bug. WB supplies rs1 while MEM blocks rs2.
        reset_case(13);wb_ready=0;
        issue(110,'hd00,addi(1,0,31),1,31,0);
        issue(111,'hd04,addi(2,0,37),2,37,0);
        issue(112,'hd08,add(3,1,2),3,68,0);stop_input;
        force dut.exmem_q.result_ready=1'b0;wb_ready=1;#1;
        if(dut.ex_stall1!==0||dut.ex_fwd1!==3||dut.ex_rs1_value!==31)
            $fatal(1,"unblocked first source missing during second-source stall");
        repeat(4)begin
            if(dut.ex_source_stall!==1||dut.ex_stall2!==1||dut.ex_fwd2!==4||
               dut.ex_rs2_value!==0||dut.ex_move!==0||retire_fire!==0)
                $fatal(1,"unready second-source MEM was bypassed or retired");
            tick;
        end
        if(dut.idex_q.rs1_value!==31||dut.ex_rs1_value!==31)
            $fatal(1,"resolved first source vanished during a different source's stall");
        @(negedge clk);force dut.exmem_q.result_ready=1'b1;tick;
        @(negedge clk);release dut.exmem_q.result_ready;drain;
        recovered_unready_cases=recovered_unready_cases+1;case_pass;

        if(cases_passed!=13||no_bubble_accepts!=9||total_retired!=total_wb||
           total_mem_sources<1||total_wb_sources<1||total_zero_sources<1||
           total_blocked_edges<1||total_held_ex_edges<1||total_held_mem_edges<1||total_held_wb_edges<1||
           total_wb_id_sources<1||total_cross_epoch_mem_sources<1||total_turnovers<1||recovered_unready_cases!=3)
            $fatal(1,"forwarding control coverage or lifetime ownership ledger incomplete");
        coverage_fd=$fopen("build/cpu5_s3_control/coverage.csv","w");
        $fdisplay(coverage_fd,"cases,retire,wb_consume,physical_writes,id_accept,no_bubble_accept,mem_sources,wb_sources,zero_sources,blocked_edges,held_ex_edges,held_mem_edges,held_wb_edges,wb_id_sources,cross_epoch_mem_sources,turnovers,recovered_unready_cases");
        $fdisplay(coverage_fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
            cases_passed,total_retired,total_wb,total_writes,total_accepts,no_bubble_accepts,total_mem_sources,total_wb_sources,
            total_zero_sources,total_blocked_edges,total_held_ex_edges,total_held_mem_edges,total_held_wb_edges,
            total_wb_id_sources,total_cross_epoch_mem_sources,total_turnovers,recovered_unready_cases);
        $fclose(coverage_fd);$fclose(trace_fd);
        $display("CPU5_FORWARD_CONTROL_PASS cases=%0d retire=%0d wb=%0d writes=%0d accepted=%0d blocked_edges=%0d held_ex_edges=%0d",cases_passed,total_retired,total_wb,total_writes,total_accepts,total_blocked_edges,total_held_ex_edges);
        test_pass=1;$finish;
    end
    initial begin #200000;$fatal(1,"forwarding control timeout");end
endmodule
