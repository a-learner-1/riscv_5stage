`timescale 1ns/1ps
// Eight independently modeled source configurations. The oracle maintains its
// own two-flop raw history and arm state, never reading controller internals.
module cpu5_irq_ctrl_case #(parameter integer MASK=7)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,irq_external=0,irq_software=0,irq_timer=0;
    reg global_enable=0;reg [31:0] mie_value=0;
    reg normal_candidate=0,post_commit_global_enable=0;reg [31:0] post_commit_mie=0;
    reg safe_boundary=1,mem_enable=1,flush_active=0,sync_fault=0,force_trap=0;
    wire [31:0] pending_sync,irq_cause;wire irq_arm_q,irq_eligible_now,irq_take;
    wire retire_fire=normal_candidate&&mem_enable&&!flush_active&&!sync_fault&&!irq_take;
    wire trap_enter_fire=force_trap||irq_take;
    localparam [31:0] SOURCE_MASK=((MASK&4)?32'h800:0)|((MASK&2)?32'h8:0)|((MASK&1)?32'h80:0);
    cpu5_irq_ctrl #(.ENABLE_EXTERNAL_IRQ((MASK&4)!=0),.ENABLE_SOFTWARE_IRQ((MASK&2)!=0),
        .ENABLE_TIMER_IRQ((MASK&1)!=0)) dut(.*);
    reg [2:0] ref_meta=0,ref_sync=0;reg ref_arm=0;
    reg [31:0] expected_pending,enabled_pending,expected_cause,next_enables;
    reg expected_eligible,expected_take,expected_retire,next_arm;reg [2:0] next_meta;
    reg [31:0] rng=32'h2a19c703;
    integer checks=0,takes=0,retired=0,safe_blocked=0,mem_blocked=0,flush_blocked=0,fault_blocked=0;
    integer post_open=0,post_mie_open=0,priority_checks=0,withdrawn=0,reset_checks=0,cycles=0,i,j,fd;
    function [31:0] mask_word(input [2:0] bits_in);
        begin mask_word=(bits_in[2]?32'h800:0)|(bits_in[1]?32'h8:0)|(bits_in[0]?32'h80:0);end
    endfunction
    function [31:0] random_next(input [31:0] value);
        reg [31:0] x;begin x=value^(value<<13);x=x^(x>>17);random_next=x^(x<<5);end
    endfunction
    task tick;begin @(posedge clk);#2;end endtask
    task reset_case;
        begin @(negedge clk);rst_n=0;irq_external=0;irq_software=0;irq_timer=0;
            global_enable=0;mie_value=0;normal_candidate=0;post_commit_global_enable=0;post_commit_mie=0;
            safe_boundary=1;mem_enable=1;flush_active=0;sync_fault=0;force_trap=0;
            repeat(2)tick;@(negedge clk);rst_n=1;tick;
        end
    endtask
    task raw(input [2:0] levels);
        begin @(negedge clk);irq_external=levels[2];irq_software=levels[1];irq_timer=levels[0];end
    endtask
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!rst_n)begin
            ref_meta=0;ref_sync=0;ref_arm=0;#1;reset_checks=reset_checks+1;
            if(pending_sync!==0||irq_arm_q!==0||irq_take!==0)$fatal(1,"IRQ CTRL reset state");
        end else begin
            expected_pending=mask_word(ref_sync)&SOURCE_MASK;
            enabled_pending=expected_pending&mie_value&SOURCE_MASK;
            expected_eligible=global_enable&&|enabled_pending;
            expected_take=ref_arm&&expected_eligible&&safe_boundary&&mem_enable&&!flush_active&&!sync_fault;
            expected_cause=enabled_pending[11]?32'h8000000b:enabled_pending[3]?32'h80000003:
                enabled_pending[7]?32'h80000007:0;
            expected_retire=normal_candidate&&mem_enable&&!flush_active&&!sync_fault&&!expected_take;
            if(pending_sync!==expected_pending)$fatal(1,"IRQ CTRL two-flop pending mask=%0d got=%h want=%h",MASK,pending_sync,expected_pending);
            if(irq_arm_q!==ref_arm)$fatal(1,"IRQ CTRL pre-edge arm");
            if(irq_eligible_now!==expected_eligible)$fatal(1,"IRQ CTRL current CSR eligibility");
            if(irq_take!==expected_take)$fatal(1,"IRQ CTRL arbitration priority mask=%0d cycle=%0d got=%b want=%b",MASK,cycles,irq_take,expected_take);
            if(irq_cause!==expected_cause)$fatal(1,"IRQ CTRL source priority mask=%0d got=%h want=%h",MASK,irq_cause,expected_cause);
            if(retire_fire!==expected_retire||irq_take&&retire_fire)$fatal(1,"IRQ CTRL retirement exclusivity");
            if(irq_take)takes=takes+1;if(retire_fire)retired=retired+1;
            if(ref_arm&&expected_eligible)begin
                if(!safe_boundary)safe_blocked=safe_blocked+1;
                if(!mem_enable)mem_blocked=mem_blocked+1;
                if(flush_active)flush_blocked=flush_blocked+1;
                if(sync_fault)fault_blocked=fault_blocked+1;
            end
            if(retire_fire&&!global_enable&&post_commit_global_enable&&|(expected_pending&post_commit_mie&SOURCE_MASK))post_open=post_open+1;
            if(retire_fire&&global_enable&&!(|(expected_pending&mie_value&SOURCE_MASK))&&
                post_commit_global_enable&&|(expected_pending&post_commit_mie&SOURCE_MASK))post_mie_open=post_mie_open+1;
            if(|enabled_pending)priority_checks=priority_checks+1;
            if(ref_arm&&!expected_eligible)withdrawn=withdrawn+1;
            next_enables=expected_retire?post_commit_mie:mie_value;
            next_arm=(expected_retire?post_commit_global_enable:global_enable)&&|(expected_pending&next_enables&SOURCE_MASK);
            if(force_trap||expected_take)next_arm=0;
            next_meta={((MASK&4)!=0)?irq_external:1'b0,((MASK&2)!=0)?irq_software:1'b0,((MASK&1)!=0)?irq_timer:1'b0};
            ref_sync=ref_meta;ref_meta=next_meta;ref_arm=next_arm;
            #1;
            if(pending_sync!==(mask_word(ref_sync)&SOURCE_MASK))$fatal(1,"IRQ CTRL post-edge synchronizer");
            if(irq_arm_q!==ref_arm)$fatal(1,"IRQ CTRL post-commit arm timing mask=%0d got=%b want=%b",MASK,irq_arm_q,ref_arm);
            checks=checks+1;
        end
    end
    initial begin
        reset_case;raw(7);@(negedge clk);mie_value=32'hffffffff;post_commit_mie=32'hffffffff;
        post_commit_global_enable=1;repeat(5)tick;
        // Future enabling state has no effect until an actual retirement.
        if(irq_arm_q||irq_take)$fatal(1,"IRQ CTRL speculative post-state affected current IRQ");
        @(negedge clk);normal_candidate=1;tick;
        @(negedge clk);normal_candidate=0;global_enable=1;#1;
        if(MASK&&!irq_take)$fatal(1,"IRQ CTRL CSR enable missed next edge");
        tick;
        // A mie write independently opens eligibility at the next edge.
        reset_case;raw(7);@(negedge clk);global_enable=1;mie_value=0;
        post_commit_global_enable=1;post_commit_mie=32'hffffffff;repeat(5)tick;
        @(negedge clk);normal_candidate=1;tick;
        @(negedge clk);normal_candidate=0;mie_value=32'hffffffff;#1;
        if(MASK&&!irq_take)$fatal(1,"IRQ CTRL mie enable missed next edge");tick;
        // An armed IRQ wins over a would-be CSR disable, using old state.
        reset_case;raw(7);@(negedge clk);global_enable=1;mie_value=32'hffffffff;
        safe_boundary=0;repeat(5)tick;
        @(negedge clk);safe_boundary=1;normal_candidate=1;post_commit_global_enable=0;post_commit_mie=0;tick;
        // When unsafe, a disable may retire and must cancel the next arm.
        reset_case;raw(7);@(negedge clk);global_enable=1;mie_value=32'hffffffff;
        safe_boundary=0;repeat(5)tick;@(negedge clk);normal_candidate=1;
        post_commit_global_enable=0;post_commit_mie=0;tick;
        @(negedge clk);global_enable=0;mie_value=0;normal_candidate=0;safe_boundary=1;repeat(3)tick;
        // Every safety gate independently blocks an already armed candidate.
        reset_case;raw(7);@(negedge clk);global_enable=1;mie_value=32'hffffffff;
        safe_boundary=0;repeat(5)tick;
        @(negedge clk);safe_boundary=1;mem_enable=0;repeat(3)tick;
        @(negedge clk);mem_enable=1;flush_active=1;repeat(3)tick;
        @(negedge clk);flush_active=0;sync_fault=1;repeat(3)tick;
        @(negedge clk);force_trap=1;tick;
        @(negedge clk);force_trap=0;sync_fault=0;repeat(4)tick;
        // Source priority uses currently enabled sources, not a saved cause.
        @(negedge clk);safe_boundary=0;
        for(i=0;i<8;i=i+1)begin raw(i[2:0]);repeat(3)tick;
            for(j=0;j<8;j=j+1)begin @(negedge clk);mie_value=mask_word(j[2:0]);repeat(2)tick;end
        end
        // Deassertion after arm, before a safe edge, cancels the candidate.
        raw(7);@(negedge clk);mie_value=32'hffffffff;repeat(4)tick;
        raw(0);repeat(4)tick;@(negedge clk);safe_boundary=1;repeat(3)tick;
        // Disabled raw inputs may be unconnected Z without polluting pending.
        @(negedge clk);irq_external=(MASK&4)?1'b0:1'bz;
        irq_software=(MASK&2)?1'b0:1'bz;irq_timer=(MASK&1)?1'b0:1'bz;repeat(4)tick;
        for(i=0;i<384;i=i+1)begin
            @(negedge clk);rng=random_next(rng);irq_external=rng[0];irq_software=rng[1];irq_timer=rng[2];
            global_enable=rng[3];mie_value=mask_word(rng[6:4])|32'hfffff777;
            normal_candidate=rng[7];post_commit_global_enable=rng[8];post_commit_mie=mask_word(rng[11:9]);
            safe_boundary=rng[12];mem_enable=rng[13];flush_active=rng[14];sync_fault=rng[15];force_trap=rng[16]&rng[17];tick;
        end
        if(checks<580||reset_checks<8||(MASK&&(takes<3||post_open==0||post_mie_open==0||safe_blocked==0||
            mem_blocked==0||flush_blocked==0||fault_blocked==0||withdrawn==0||priority_checks<30)))
            $fatal(1,"IRQ CTRL coverage mask=%0d checks=%0d takes=%0d post=%0d",MASK,checks,takes,post_open);
        fd=$fopen($sformatf("build/cpu5_s9_irq_ctrl/ctrl_mask%0d.json",MASK),"w");
        $fdisplay(fd,"{\"pass\":true,\"mask\":%0d,\"checks\":%0d,\"takes\":%0d,\"retired\":%0d,\"post_commit_open\":%0d,\"post_commit_mie_open\":%0d,\"unsafe_blocked\":%0d,\"mem_blocked\":%0d,\"flush_blocked\":%0d,\"fault_blocked\":%0d,\"withdrawn\":%0d,\"priority_checks\":%0d}",MASK,checks,takes,retired,post_open,post_mie_open,safe_blocked,mem_blocked,flush_blocked,fault_blocked,withdrawn,priority_checks);
        $fclose(fd);done=1;
    end
endmodule

// Independent bank oracle for all IRQ source subsets, including no sources.
module cpu5_irq_bank_case #(parameter integer MASK=7)(output reg done=0);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,access_write_intent=0,commit_fire=0,mret_fire=0,trap_fire=0;
    reg [11:0] access_addr='h300;reg [2:0] access_funct3=1;
    reg [31:0] access_operand=0,irq_pending=0,fault_pc=0,fault_cause=0,fault_tval=0;
    wire [31:0] read_value,mtvec_value,mepc_value,mstatus_value,mie_value,post_commit_mie;
    wire access_illegal,post_commit_global_enable;
    localparam [31:0] SOURCE_MASK=((MASK&4)?32'h800:0)|((MASK&2)?32'h8:0)|((MASK&1)?32'h80:0);
    cpu5_csr_unit #(.ENABLE_EXTERNAL_IRQ((MASK&4)!=0),.ENABLE_SOFTWARE_IRQ((MASK&2)!=0),
        .ENABLE_TIMER_IRQ((MASK&1)!=0)) dut(.*);
    reg [31:0] ref_status='h1800,ref_mie=0,ref_epc=0,ref_cause=0,ref_tval=0;
    reg [31:0] expected_read,new_value,next_status,next_mie;reg expected_illegal,expected_post_global;
    integer checks=0,writes=0,mip_writes=0,trap_checks=0,mret_checks=0,i,j,fd;
    task tick;begin @(posedge clk);#2;end endtask
    task csr_access(input [11:0] addr,input [2:0] funct,input intent,input [31:0] value,input do_commit);
        begin @(negedge clk);access_addr=addr;access_funct3=funct;access_write_intent=intent;
            access_operand=value;commit_fire=do_commit;tick;
            @(negedge clk);commit_fire=0;access_write_intent=0;end
    endtask
    always @(posedge clk)begin
        if(!rst_n)begin
            ref_status='h1800;ref_mie=0;ref_epc=0;ref_cause=0;ref_tval=0;
            #1;if(mstatus_value!==ref_status||mie_value!==0)$fatal(1,"IRQ BANK reset");
        end else begin
            expected_illegal=0;
            case(access_addr)
                'h300:expected_read=ref_status;
                'h304:begin expected_read=ref_mie;expected_illegal=MASK==0;end
                'h344:begin expected_read=irq_pending&SOURCE_MASK;expected_illegal=MASK==0;end
                'h341:expected_read=ref_epc;'h342:expected_read=ref_cause;'h343:expected_read=ref_tval;
                default:begin expected_read=0;expected_illegal=1;end
            endcase
            if(read_value!==expected_read||access_illegal!==expected_illegal)
                $fatal(1,"IRQ BANK CSR decode/read mask=%0d addr=%h value=%h/%h illegal=%b/%b",MASK,access_addr,read_value,expected_read,access_illegal,expected_illegal);
            case(access_funct3[1:0])1:new_value=access_operand;2:new_value=expected_read|access_operand;
                3:new_value=expected_read&~access_operand;default:new_value=0;endcase
            next_status=ref_status;next_mie=ref_mie;
            if(mret_fire)next_status='h1880|(ref_status[7]?'h8:0);
            else if(commit_fire&&access_write_intent&&!expected_illegal)begin
                if(access_addr=='h300)next_status='h1800|(new_value&'h88);
                if(access_addr=='h304)next_mie=new_value&SOURCE_MASK;
            end
            expected_post_global=next_status[3];
            if(post_commit_global_enable!==expected_post_global||post_commit_mie!==next_mie)
                $fatal(1,"IRQ BANK post-commit preview mask=%0d global=%b/%b mie=%h/%h",MASK,post_commit_global_enable,expected_post_global,post_commit_mie,next_mie);
            if(commit_fire)begin writes=writes+1;if(access_addr=='h344)mip_writes=mip_writes+1;end
            if(trap_fire)begin
                next_status='h1800|(ref_status[3]?'h80:0);
                ref_epc=fault_pc&32'hfffffffc;ref_cause=fault_cause;ref_tval=fault_tval;trap_checks=trap_checks+1;
            end
            if(mret_fire)mret_checks=mret_checks+1;
            ref_status=next_status;ref_mie=next_mie;
            #1;
            if(mstatus_value!==ref_status||mie_value!==ref_mie||mepc_value!==ref_epc||
                dut.csr_mcause!==ref_cause||dut.csr_mtval!==ref_tval)
                $fatal(1,"IRQ BANK committed state mask=%0d status=%h/%h mie=%h/%h",MASK,mstatus_value,ref_status,mie_value,ref_mie);
            checks=checks+1;
        end
    end
    initial begin
        repeat(2)tick;@(negedge clk);rst_n=1;tick;
        // Read legality is conditional on actual implemented source presence.
        csr_access('h304,2,0,0,0);csr_access('h344,2,0,0,0);
        for(i=1;i<8;i=i+1)begin
            if(i==4)begin end else begin
                csr_access('h304,i[2:0],1,32'hffffffff,MASK!=0);
                csr_access('h304,2,0,0,0);
                csr_access('h304,i[2:0],1,32'hfffff777,MASK!=0);
                csr_access('h304,2,0,0,0);
            end
        end
        for(j=0;j<8;j=j+1)begin
            @(negedge clk);irq_pending=((j&4)?'h800:0)|((j&2)?'h8:0)|((j&1)?'h80:0)|32'hfffff777;
            csr_access('h344,1,1,0,MASK!=0);csr_access('h344,2,1,32'hffffffff,MASK!=0);
            csr_access('h344,3,1,32'hffffffff,MASK!=0);csr_access('h344,2,0,0,0);
        end
        csr_access('h304,1,1,32'hffffffff,MASK!=0);
        csr_access('h300,1,1,'h1888,1);
        // Saving an IRQ changes global status/exception state, not source MIE.
        @(negedge clk);trap_fire=1;fault_pc='h123;fault_cause=32'h8000000b;fault_tval=0;tick;
        @(negedge clk);trap_fire=0;access_addr='h341;tick;
        @(negedge clk);mret_fire=1;tick;
        @(negedge clk);mret_fire=0;tick;
        csr_access('h300,1,1,'h1800,1);
        @(negedge clk);mret_fire=1;tick;
        @(negedge clk);mret_fire=0;repeat(3)tick;
        if(checks<60||trap_checks!=1||mret_checks!=2||(MASK&&mip_writes!=24))
            $fatal(1,"IRQ BANK coverage mask=%0d checks=%0d mipwrites=%0d",MASK,checks,mip_writes);
        fd=$fopen($sformatf("build/cpu5_s9_irq_ctrl/bank_mask%0d.json",MASK),"w");
        $fdisplay(fd,"{\"pass\":true,\"mask\":%0d,\"checks\":%0d,\"writes\":%0d,\"mip_writes\":%0d,\"trap_checks\":%0d,\"mret_checks\":%0d}",MASK,checks,writes,mip_writes,trap_checks,mret_checks);
        $fclose(fd);done=1;
    end
endmodule

module cpu5_irq_ctrl_tb;
    wire [7:0] ctrl_done,bank_done;reg test_pass=0;
    genvar m;generate for(m=0;m<8;m=m+1)begin:g_masks
        cpu5_irq_ctrl_case #(.MASK(m)) ctrl(ctrl_done[m]);
        cpu5_irq_bank_case #(.MASK(m)) bank(bank_done[m]);
    end endgenerate
    initial begin wait((&ctrl_done)&&(&bank_done));test_pass=1;$display("CPU5 IRQ CTRL/BANK TEST PASS");$stop;end
    initial begin #200000;$fatal(1,"IRQ CTRL unit timeout");end
endmodule

module cpu5_irq_ctrl_guard_tb #(parameter integer BAD=2);
    cpu5_irq_ctrl #(.ENABLE_EXTERNAL_IRQ(BAD)) dut(
        .clk(1'b0),.rst_n(1'b0),.irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),
        .global_enable(1'b0),.mie_value(32'd0),.retire_fire(1'b0),.post_commit_global_enable(1'b0),
        .post_commit_mie(32'd0),.trap_enter_fire(1'b0),.safe_boundary(1'b1),.mem_enable(1'b1),
        .flush_active(1'b0),.sync_fault(1'b0),.pending_sync(),.irq_arm_q(),.irq_eligible_now(),.irq_take(),.irq_cause());
    initial begin #20;$fatal(1,"IRQ CTRL invalid parameter was accepted");end
endmodule
module cpu5_irq_bank_guard_tb #(parameter integer BAD=2);
    cpu5_csr_unit #(.ENABLE_TIMER_IRQ(BAD)) dut(
        .clk(1'b0),.rst_n(1'b0),.access_addr(12'h300),.access_funct3(3'd2),.access_write_intent(1'b0),
        .access_operand(32'd0),.read_value(),.access_illegal(),.commit_fire(1'b0),.mret_fire(1'b0),.trap_fire(1'b0),
        .fault_pc(32'd0),.fault_cause(32'd0),.fault_tval(32'd0),.mtvec_value(),.mepc_value(),
        .irq_pending(32'd0),.mstatus_value(),.mie_value(),.post_commit_global_enable(),.post_commit_mie());
    initial begin #20;$fatal(1,"IRQ BANK invalid parameter was accepted");end
endmodule
