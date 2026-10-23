`timescale 1ns/1ps
// Hand-derived control tests. The expected retirement stream is declared by
// each scenario, independently of ready/valid logic inside the implementation.
module cpu5_alu_control_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,in_valid=0,in_fetch_error=0;
    reg [31:0] in_pc=0,in_instr=0;
    reg [63:0] in_seq=0,flush_cut_seq=0;
    reg id_enable=1,ex_enable=1,mem_enable=1,wb_ready=1,flush_valid=0;
    wire in_ready,retire_valid,wb_we,retire_fire,wb_fire,id_raw_wait;
    wire [31:0] wb_pc,wb_data,retire_pc,retire_instr,retire_value,arch_next_pc;
    wire [4:0] wb_rd,retire_rd;
    wire retire_writes_rd;
    wire [63:0] retire_seq,cycle_count,instret_count;
    wire halted,halt_fetch_error;
    wire [31:0] halt_pc,halt_instr;
    wire [63:0] halt_seq;
    cpu5_alu_pipeline dut(.clk(clk),.rst_n(rst_n),
        .in_valid(in_valid),.in_ready(in_ready),.in_pc(in_pc),.in_instr(in_instr),
        .in_pred_next_pc(in_pc+32'd4),.in_pred_taken(1'b0),.in_pred_hit(1'b0),
        .in_fetch_error(in_fetch_error),.in_fetch_tval(in_pc),.in_seq(in_seq),.in_epoch(8'd0),
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
    integer expected_count=0,retired=0,physical_writes=0;
    integer wb_expect_index[0:127];
    integer wb_head=0,wb_tail=0,edge_number=0,case_number=0;
    integer total_retired=0,total_writes=0,total_accepts=0,total_turnovers=0;
    integer total_raw_waits=0,total_held_wb_edges=0,total_mem_hold_edges=0;
    integer cases_passed=0,trace_fd,post_index,write_index,timeout;
    integer reset_discarded_wb=0;
    reg test_pass=0;
    reg last_id_fire=0;
    reg [63:0] last_id_seq=0;
    reg pre_retire,pre_wb,pre_we,pre_accept,pre_raw;
    reg [31:0] pre_write_data,pre_rf1,pre_rf2;
    reg [4:0] pre_write_rd;
    reg [63:0] pre_input_seq,pre_mem_seq,pre_wb_seq;

    function [31:0] addi(input [4:0] rd,input [4:0] rs1,input [11:0] imm);
        begin addi={imm,rs1,3'b000,rd,7'b0010011};end
    endfunction
    function [31:0] add(input [4:0] rd,input [4:0] rs1,input [4:0] rs2);
        begin add={7'b0000000,rs2,rs1,3'b000,rd,7'b0110011};end
    endfunction
    task expect_instruction(input [63:0] seq,input [31:0] pc,input [31:0] ins,
                            input [4:0] rd,input [31:0] value);
        begin
            expected_seq[expected_count]=seq;expected_pc[expected_count]=pc;
            expected_instr[expected_count]=ins;expected_rd[expected_count]=rd;
            expected_value[expected_count]=value;expected_count=expected_count+1;
        end
    endtask
    task tick;begin @(posedge clk);#2;end endtask
    task reset_case(input integer number);
        begin
            @(negedge clk);reset_discarded_wb=reset_discarded_wb+(wb_tail-wb_head);
            rst_n=0;in_valid=0;in_fetch_error=0;
            id_enable=1;ex_enable=1;mem_enable=1;wb_ready=1;flush_valid=0;
            case_number=number;expected_count=0;
            tick;tick;
            @(negedge clk);rst_n=1;
        end
    endtask
    task send(input [63:0] seq,input [31:0] pc,input [31:0] ins,input error);
        begin
            @(negedge clk);in_seq=seq;in_pc=pc;in_instr=ins;
            in_fetch_error=error;in_valid=1;timeout=0;
            tick;
            while(!(last_id_fire&&last_id_seq==seq))begin
                timeout=timeout+1;if(timeout>60)$fatal(1,"ID timeout case=%0d seq=%h",case_number,seq);
                tick;
            end
            @(negedge clk);in_valid=0;in_fetch_error=0;
        end
    endtask
    task drain;
        begin
            timeout=0;
            while(retired!=expected_count || wb_head!=wb_tail ||
                  dut.idex_valid_q || dut.exmem_valid_q || dut.memwb_valid_q)begin
                tick;timeout=timeout+1;
                if(timeout>70)$fatal(1,"drain timeout case=%0d retired=%0d/%0d",case_number,retired,expected_count);
            end
            repeat(3)tick;
            if(physical_writes!=expected_count)$fatal(1,"physical-write total mismatch");
        end
    endtask
    task case_pass;
        begin cases_passed=cases_passed+1;
            $display("CPU5_CONTROL_CASE_PASS case=%0d retire=%0d writes=%0d",case_number,retired,physical_writes);
        end
    endtask

    // Pre-edge events and post-NBA registered retirement are checked separately.
    // WB's expected FIFO is populated only by a checked, hand-expected retire.
    always @(posedge clk)begin
        edge_number=edge_number+1;
        if(!rst_n)begin
            retired=0;physical_writes=0;wb_head=0;wb_tail=0;last_id_fire=0;
            if(wb_we!==0||retire_fire!==0)$fatal(1,"side effect during reset");
            #1;
            if(retire_valid!==0||instret_count!==0||cycle_count!==0)
                $fatal(1,"reset counter/retirement state");
        end else begin
            pre_retire=retire_fire;pre_wb=wb_fire;pre_we=wb_we;
            pre_accept=in_valid&&in_ready;pre_raw=id_raw_wait;
            pre_rf1=dut.rf1;pre_rf2=dut.rf2;
            pre_input_seq=in_seq;pre_mem_seq=dut.exmem_q.seq;pre_wb_seq=dut.memwb_q.seq;
            pre_write_data=wb_data;pre_write_rd=wb_rd;
            last_id_fire=pre_accept;last_id_seq=in_seq;
            if(pre_accept)total_accepts=total_accepts+1;
            if(pre_raw)total_raw_waits=total_raw_waits+1;
            if(dut.memwb_valid_q&&!wb_ready)total_held_wb_edges=total_held_wb_edges+1;
            if(dut.exmem_valid_q&&!mem_enable)total_mem_hold_edges=total_mem_hold_edges+1;
            // A same-edge write remains invisible to ID's pre-edge GPR read.
            if(case_number==1&&in_valid&&in_seq==2&&wb_we&&wb_rd==1&&in_ready)
                $fatal(1,"dependent ID accepted at producer WB write edge");
            if(pre_accept&&case_number==1&&in_seq==2&&(pre_rf1!==7||pre_rf2!==7))
                $fatal(1,"dependent ID did not read newly written GPR");
            if(pre_wb)begin
                if(wb_head>=wb_tail)$fatal(1,"WB fired without earlier retirement");
                write_index=wb_expect_index[wb_head];
                if(dut.memwb_q.seq!==expected_seq[write_index] || wb_pc!==expected_pc[write_index] ||
                   dut.memwb_q.instr!==expected_instr[write_index] || wb_rd!==expected_rd[write_index] ||
                   wb_data!==expected_value[write_index] || wb_we!==1)
                    $fatal(1,"physical WB owner/value mismatch case=%0d",case_number);
                wb_head=wb_head+1;physical_writes=physical_writes+1;total_writes=total_writes+1;
            end else if(wb_we!==0)$fatal(1,"write without WB consume");
            post_index=-1;
            if(pre_retire)begin
                if(retired>=expected_count)$fatal(1,"unexpected retirement case=%0d seq=%h",case_number,pre_mem_seq);
                post_index=retired;
                if(pre_mem_seq!==expected_seq[retired] || dut.exmem_q.pc!==expected_pc[retired] ||
                   dut.exmem_q.instr!==expected_instr[retired] || dut.exmem_q.rd!==expected_rd[retired] ||
                   dut.exmem_q.alu_result!==expected_value[retired])
                    $fatal(1,"MEM retirement identity/value mismatch case=%0d index=%0d",case_number,retired);
                wb_expect_index[wb_tail]=retired;wb_tail=wb_tail+1;
                retired=retired+1;total_retired=total_retired+1;
            end
            if(pre_wb&&pre_retire)begin
                if(pre_wb_seq==pre_mem_seq)$fatal(1,"turnover reused old owner");
                total_turnovers=total_turnovers+1;
            end
            #1;
            if(retire_valid!==pre_retire || instret_count!==retired)
                $fatal(1,"registered retire/counter edge mismatch case=%0d",case_number);
            if(post_index>=0&&(retire_seq!==expected_seq[post_index] ||
                retire_pc!==expected_pc[post_index] || retire_instr!==expected_instr[post_index] ||
                retire_rd!==expected_rd[post_index] || retire_value!==expected_value[post_index] ||
                retire_writes_rd!==1 || arch_next_pc!==(expected_pc[post_index]+32'd4)))
                $fatal(1,"registered retire bundle or arch_next_pc mismatch");
            if(pre_we&&dut.u_regfile.regs[pre_write_rd]!==pre_write_data)
                $fatal(1,"GPR physical write missing after NBA");
            if(pre_accept&&(dut.idex_q.seq!==pre_input_seq ||
                dut.idex_q.rs1_value!==pre_rf1 || dut.idex_q.rs2_value!==pre_rf2))
                $fatal(1,"accepted ID operand snapshot changed across edge");
            $fdisplay(trace_fd,"%0d,%0d,%0d,%h,%0d,%h,%h,%0d,%0d,%h,%0d,%h,%0d,%h,%0d,%h,%0d,%h,%0d",
                edge_number,case_number,pre_accept,pre_input_seq,pre_raw,pre_rf1,pre_rf2,
                pre_retire,pre_wb,pre_mem_seq,pre_we,pre_wb_seq,pre_write_rd,pre_write_data,retire_valid,
                retire_seq,instret_count,arch_next_pc,halted);
        end
    end

    initial begin
        trace_fd=$fopen("build/cpu5_s2_control/control_trace.csv","w");
        if(trace_fd==0)$fatal(1,"cannot create control trace");
        $fdisplay(trace_fd,"edge,case,id_accept,input_seq,id_raw_wait,id_rs1_value,id_rs2_value,pre_retire_fire,pre_wb_fire,pre_mem_seq,pre_wb_we,pre_wb_seq,pre_wb_rd,pre_wb_data,post_retire_valid,post_retire_seq,post_instret,post_arch_next_pc,post_halted");
        // 1: RAW includes the WB write edge, then reads the new GPR value.
        reset_case(1);
        expect_instruction(1,32'h100,addi(1,0,7),1,7);
        expect_instruction(2,32'h104,add(2,1,1),2,14);
        send(1,32'h100,addi(1,0,7),0);send(2,32'h104,add(2,1,1),0);
        drain;if(total_raw_waits<1)$fatal(1,"RAW scenario did not stall");case_pass;

        // 2: MEM disabled does not replay an older, already retired WB write.
        reset_case(2);
        expect_instruction(10,32'h200,addi(1,0,11),1,11);
        expect_instruction(11,32'h204,addi(2,0,22),2,22);
        send(10,32'h200,addi(1,0,11),0);send(11,32'h204,addi(2,0,22),0);
        mem_enable=0;repeat(5)tick;
        if(retired!=1||physical_writes!=1||!dut.exmem_valid_q||dut.memwb_valid_q)
            $fatal(1,"MEM hold failed to drain older WB exactly once");
        @(negedge clk);mem_enable=1;drain;case_pass;

        // 3: A fills WB, B waits at MEM, C at EX. Release permits A/B turnover.
        reset_case(3);wb_ready=0;
        expect_instruction(20,32'h300,addi(1,0,21),1,21);
        expect_instruction(21,32'h304,addi(2,0,22),2,22);
        expect_instruction(22,32'h308,addi(3,0,23),3,23);
        send(20,32'h300,addi(1,0,21),0);send(21,32'h304,addi(2,0,22),0);
        send(22,32'h308,addi(3,0,23),0);repeat(4)tick;
        if(retired!=1||physical_writes!=0)$fatal(1,"WB backpressure allowed extra retirement");
        @(negedge clk);wb_ready=1;drain;
        if(total_turnovers<1)$fatal(1,"missing same-edge WB/MEM turnover");case_pass;

        // 4: First-killed age spans bit 32. WB is already committed and survives.
        reset_case(4);wb_ready=0;
        expect_instruction(64'hfffffffe,32'h400,addi(1,0,31),1,31);
        send(64'hfffffffe,32'h400,addi(1,0,31),0);
        send(64'hffffffff,32'h404,addi(2,0,32),0);
        send(64'h100000000,32'h408,addi(3,0,33),0);
        @(negedge clk);in_valid=1;in_seq=64'h100000001;in_pc=32'h40c;in_instr=addi(4,0,34);
        flush_valid=1;flush_cut_seq=64'hffffffff;wb_ready=1;tick;
        if(retired!=1||physical_writes!=1||last_id_fire||dut.idex_valid_q||dut.exmem_valid_q)
            $fatal(1,"flush failed to kill MEM/EX/input while preserving old WB");
        @(negedge clk);in_valid=0;flush_valid=0;
        expect_instruction(64'h100000002,32'h410,addi(5,0,51),5,51);
        send(64'h100000002,32'h410,addi(5,0,51),0);drain;case_pass;

        // 5: With cut above bit 32, an older MEM on the low side must survive.
        reset_case(5);mem_enable=0;
        expect_instruction(64'hffffffff,32'h500,addi(1,0,41),1,41);
        send(64'hffffffff,32'h500,addi(1,0,41),0);
        send(64'h100000000,32'h504,addi(2,0,42),0);
        @(negedge clk);in_valid=1;in_seq=64'h100000001;in_pc=32'h508;in_instr=addi(3,0,43);
        flush_valid=1;flush_cut_seq=64'h100000000;mem_enable=1;tick;
        if(retired!=1||last_id_fire)$fatal(1,"64-bit flush killed older MEM or accepted younger input");
        @(negedge clk);in_valid=0;flush_valid=0;drain;case_pass;

        // 6/7: Unsupported MUL encoding and legal ADDI with IF fault both hold
        // at MEM, authorize no effects, and permit older WB to drain once.
        for(integer fault_kind=0;fault_kind<2;fault_kind=fault_kind+1)begin
            reset_case(6+fault_kind);
            expect_instruction(40,32'h600,addi(1,0,61),1,61);
            send(40,32'h600,addi(1,0,61),0);
            send(41,32'h604,fault_kind?addi(2,0,62):32'h02000133,fault_kind!=0);
            send(42,32'h608,addi(3,0,63),0);repeat(5)tick;
            if(!halted||halt_seq!==41||halt_pc!==32'h604||halt_fetch_error!==(fault_kind!=0)||
                retired!=1||physical_writes!=1)$fatal(1,"fault/unsupported hold or old WB drain mismatch");
            @(negedge clk);flush_valid=1;flush_cut_seq=41;tick;
            @(negedge clk);flush_valid=0;
            expect_instruction(43,32'h60c,addi(4,0,64),4,64);
            send(43,32'h60c,addi(4,0,64),0);drain;case_pass;
        end

        // 8: Reset with nonempty WB/MEM/EX suppresses residual writes. The
        // unchanged physical regfile is deliberately NOT assumed reset to 0.
        reset_case(8);
        expect_instruction(50,32'h700,addi(7,0,85),7,85);
        send(50,32'h700,addi(7,0,85),0);drain;
        wb_ready=0;
        expect_instruction(51,32'h704,addi(8,0,81),8,81);
        send(51,32'h704,addi(8,0,81),0);
        send(52,32'h708,addi(9,0,82),0);send(53,32'h70c,addi(10,0,83),0);
        if(!dut.memwb_valid_q||!dut.exmem_valid_q||!dut.idex_valid_q)
            $fatal(1,"reset test did not fill all execution slots");
        reset_case(8);
        if(dut.u_regfile.regs[7]!==85)$fatal(1,"unchanged regfile unexpectedly reset");
        expect_instruction(60,32'h720,addi(11,7,1),11,86);
        send(60,32'h720,addi(11,7,1),0);drain;case_pass;
        if(cases_passed!=8||total_mem_hold_edges<1||total_held_wb_edges<1)
            $fatal(1,"control scenario coverage incomplete");
        if(total_retired!=total_writes+reset_discarded_wb || reset_discarded_wb!=1)
            $fatal(1,"lifetime retirement/WB/reset-discard accounting mismatch");
        $display("CPU5_ALU_CONTROL_PASS cases=%0d retire=%0d physical_writes=%0d reset_discarded_wb=%0d id_accepts=%0d raw_wait_edges=%0d wb_mem_turnovers=%0d held_wb_edges=%0d mem_hold_edges=%0d",
            cases_passed,total_retired,total_writes,reset_discarded_wb,total_accepts,total_raw_waits,
            total_turnovers,total_held_wb_edges,total_mem_hold_edges);
        test_pass=1;$fclose(trace_fd);$finish;
    end
    initial begin #100000;$fatal(1,"control test timeout");end
endmodule
