`timescale 1ns/1ps
module cpu5_machine_control_tb;
    wire [17:0] done;reg test_pass=0;genvar c;
    generate for(c=0;c<18;c=c+1)begin:g_cases
        cpu5_machine_control_case #(.SCENARIO(c/2),.ID_MODE(c%2),.CASE_ID(c)) u(done[c]);
    end endgenerate
    initial begin wait(&done);test_pass=1;$display("CPU5 MACHINE CONTROL TEST PASS");$stop;end
    initial begin #200000;$fatal(1,"MACHINE control timeout done=%h",done);end
endmodule

`define C dut.g_alu.u_pipeline
module cpu5_machine_control_case #(parameter integer SCENARIO=0,ID_MODE=0,CASE_ID=0)(output reg done=0);
    localparam integer DEVICE_MASK=SCENARIO<4?SCENARIO:3;
    localparam integer TIMER_DEVICE=DEVICE_MASK&1,SOFTWARE_DEVICE=(DEVICE_MASK>>1)&1;
    localparam integer IRQ_FLAGS=SCENARIO>=4;
    localparam integer SW_CASE=(SCENARIO==4 || SCENARIO==6);
    reg clk=0,rst_n=0,raw_sw=0,raw_timer=0;always #5 clk=~clk;
    wire iqv,iqr,irv,irr;wire [31:0] iqa;
    reg ipending=0,quiesce=0;reg [31:0] iaddr=0;
    reg [31:0] rom[0:255];integer cursor=0,terminal_pc=0,expected_return=0;
    integer cycles=0,retired=0,wb=0,traps=0,irqs=0,requests=0,responses=0,executions=0,software_writes=0,timer_writes=0;
    integer checks=0,terminal_wb=0,natural_wait_edges=0,natural_irq_time=0,fd,i,j;
    wire [31:0] wpc,wdata,tpc,tc,tv;wire [4:0] wrd;wire we,tvalid;
    wire dqv,dqw,dsr;wire [31:0] dqa,dqd;wire [1:0] dz;wire [3:0] dst;
    wire [63:0] cycle_count,instret_count;
    assign iqr=rst_n && !quiesce && (!ipending || (irv&&irr));assign irv=ipending;
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(64),
        .SKELETON_ONLY(0),.ENABLE_FORWARDING(1),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),.ENABLE_MMIO(1),
        .ENABLE_SYNC_TRAPS(1),.ENABLE_CSR(1),.ENABLE_BRANCH_PRED(1),.BRANCH_RESOLVE_IN_ID(ID_MODE),
        .ENABLE_EXTERNAL_IRQ(IRQ_FLAGS),.ENABLE_SOFTWARE_IRQ(IRQ_FLAGS),.ENABLE_TIMER_IRQ(IRQ_FLAGS),
        .ENABLE_TIMER_DEVICE(TIMER_DEVICE),.ENABLE_SOFTWARE_DEVICE(SOFTWARE_DEVICE)) dut(
        .clk(clk),.rst_n(rst_n),.pc_x(),.instr_x(),.valid_x(),.wb_pc(wpc),.wb_rd(wrd),.wb_data(wdata),.wb_we(we),
        .retire_valid(),.cycle_count(cycle_count),.instret_count(instret_count),.uart_tx(),.uart_rx(1'b1),.gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .dmem_req_valid(dqv),.dmem_req_ready(1'b1),.dmem_req_write(dqw),.dmem_req_addr(dqa),.dmem_req_size(dz),.dmem_req_wdata(dqd),.dmem_req_wstrb(dst),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(dsr),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),
        .imem_req_valid(iqv),.imem_req_ready(iqr),.imem_req_addr(iqa),.imem_rsp_valid(irv),.imem_rsp_ready(irr),
        .imem_rsp_rdata(rom[iaddr>>2]),.imem_rsp_error(1'b0),.imem_fault(),.imem_fault_pc(),
        .trap_valid(tvalid),.trap_pc(tpc),.trap_cause(tc),.trap_tval(tv),.bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),
        .bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(1'b0),.irq_software(raw_sw),.irq_timer(raw_timer),.perf_cycle_events());
    wire ep_fire,ep_write,ep_legal,ep_sw_fire,ep_timer_fire;
    wire [31:0] ep_addr,ep_wdata;wire [1:0] ep_size;wire [3:0] ep_strobe;
    wire [63:0] actual_time,actual_cmp;wire actual_msip;
    generate if(DEVICE_MASK!=0)begin:g_observe
        assign ep_fire=dut.g_machine.u_router.u_machine_endpoint.endpoint_fire;
        assign ep_write=dut.g_machine.u_router.u_machine_endpoint.write_q;
        assign ep_legal=dut.g_machine.u_router.u_machine_endpoint.access_legal;
        assign ep_sw_fire=dut.g_machine.u_router.u_machine_endpoint.software_write_fire;
        assign ep_timer_fire=dut.g_machine.u_router.u_machine_endpoint.timer_write_fire;
        assign ep_addr=dut.g_machine.u_router.u_machine_endpoint.addr_q;
        assign ep_wdata=dut.g_machine.u_router.u_machine_endpoint.wdata_q;
        assign ep_size=dut.g_machine.u_router.u_machine_endpoint.size_q;
        assign ep_strobe=dut.g_machine.u_router.u_machine_endpoint.wstrb_q;
        assign actual_time=dut.g_machine.u_router.u_machine_endpoint.mtime_value;
        assign actual_cmp=dut.g_machine.u_router.u_machine_endpoint.mtimecmp_value;
        assign actual_msip=dut.g_machine.u_router.u_machine_endpoint.software_msip;
    end else begin:g_no_observe
        assign {ep_fire,ep_write,ep_legal,ep_sw_fire,ep_timer_fire,ep_addr,ep_wdata,ep_size,ep_strobe,actual_time,actual_msip}=0;
        assign actual_cmp=64'hffffffffffffffff;
    end endgenerate
    function [31:0] addi(input integer d,a,v);addi={v[11:0],a[4:0],3'b000,d[4:0],7'h13};endfunction
    function [31:0] csr(input integer d,a,f,s);csr={a[11:0],s[4:0],f[2:0],d[4:0],7'h73};endfunction
    function [31:0] load(input integer d,a,off);load={off[11:0],a[4:0],3'b010,d[4:0],7'h03};endfunction
    function [31:0] store(input integer s,a,off);store={off[11:5],s[4:0],a[4:0],3'b010,off[4:0],7'h23};endfunction
    task put(input [31:0] word);begin rom[cursor]=word;cursor=cursor+1;end endtask
    task check(input condition,input [639:0] reason);
        begin checks=checks+1;if(condition!==1'b1)$fatal(1,"MACHINE control oracle %0s case=%0d cycle=%0d",reason,CASE_ID,cycles);end
    endtask
    reg [31:0] gpr[0:31];reg [31:0] known=1;
    reg [31:0] pc=0,status='h1800,vector='h100,scratch=0,mepc=0,mcause=0,mtval=0,mie=0;
    reg [63:0] model_time=0,model_cmp=64'hffffffffffffffff;
    reg model_msip=0,arm=0;reg [31:0] meta=0,pending=0;
    reg active=0,txn_write=0,txn_machine=0,txn_error=0;
    reg [63:0] txn_seq=0;reg [31:0] txn_pc=0,txn_addr=0,txn_data=0,txn_read=0;
    integer execute_at=0;reg txn_executed=0;
    reg [31:0] qpc[0:1023],qins[0:1023],qdata[0:1023];reg [4:0] qrd[0:1023];reg [63:0] qseq[0:1023];
    reg [31:0] raw_levels,expected_pending,word,av,bv,imm,value,nextpc,oldcsr,operand,newcsr;
    reg [31:0] pre_pc,pre_cause;integer op,funct,rd,rs1,rs2,address;
    reg expected_irq,eligible,pre_irq,pre_trap,pre_retire,write_intent;
    reg [63:0] next_time;
    initial begin
        for(i=0;i<256;i=i+1)rom[i]=32'h0000006f;
        put(32'h200000b7);put(addi(2,0,'h55));put(addi(5,0,0));put(addi(3,0,'h200));put(csr(0,'h305,1,3));
        if(SCENARIO<4)begin
            put(store(2,1,'h50));put(load(5,1,'h50));put(store(0,1,'h48));put(store(0,1,'h4c));put(load(6,1,'h48));put(load(7,1,'h4c));
        end else if(SW_CASE)begin
            put(store(2,1,'h50));if(SCENARIO==4)put(store(0,1,'h50));
            put(addi(4,0,8));put(csr(0,'h304,1,4));put(csr(8,'h344,2,0));put(csr(0,'h300,5,8));expected_return=cursor*4;
        end else begin
            if(SCENARIO==8)begin put(addi(4,0,250));put(store(4,1,'h48));end
            else put(store(0,1,'h48));
            put(store(0,1,'h4c));
            if(SCENARIO==5)begin put(addi(4,0,-1));put(store(4,1,'h4c));put(store(4,1,'h48));end
            put(addi(4,0,128));put(csr(0,'h304,1,4));put(csr(8,'h344,2,0));put(csr(0,'h300,5,8));expected_return=cursor*4;
        end
        put(addi(10,0,1));terminal_pc=cursor*4;if(SCENARIO==8)expected_return=terminal_pc;put(32'h0000006f);
        cursor=128;put(csr(20,'h342,2,0));put(csr(21,'h341,2,0));
        if(SCENARIO<4)begin put(addi(21,21,4));put(csr(0,'h341,1,21));end
        else begin
            if(SW_CASE)put(store(0,1,'h50));
            else begin put(addi(24,0,-1));put(store(24,1,'h4c));put(store(24,1,'h48));end
            put(addi(11,0,1));put(addi(12,0,2));put(csr(23,'h344,2,0));
        end
        put(32'h30200073);
        fd=$fopen($sformatf("build/cpu5_s11_machine_control/case%0d.csv",CASE_ID),"w");
        $fwrite(fd,"cycle,pc,event,seq,value,pending,mtime,mtimecmp,msip\n");
        repeat(4)@(negedge clk);raw_sw=(SCENARIO==4);raw_timer=(SCENARIO==5);rst_n=1;
    end
    always @(negedge clk)if(rst_n&&irqs)begin raw_sw=0;raw_timer=0;end
    always @(posedge clk)begin
        if(!rst_n)begin ipending<=0;iaddr<=0;end
        else if(!done)begin
            if(irv&&irr)ipending<=0;
            if(iqv&&iqr)begin check(iqa<1024&&iqa[1:0]==0,"IF address");iaddr<=iqa;ipending<=1;end
        end
    end
    always @(posedge clk)if(rst_n&&!done)begin
        cycles=cycles+1;gpr[0]=0;
        check(actual_time===model_time&&actual_cmp===model_cmp&&actual_msip===model_msip,"pre-edge machine device model");
        check(dut.machine_timer_irq===(TIMER_DEVICE&&(model_time>=model_cmp))&&dut.machine_software_irq===(SOFTWARE_DEVICE&&model_msip),"device IRQ level independent of CPU source flags");
        raw_levels=(raw_sw||(SOFTWARE_DEVICE&&model_msip)?32'h8:0)|(raw_timer||(TIMER_DEVICE&&model_time>=model_cmp)?32'h80:0);
        expected_pending=IRQ_FLAGS?pending:0;eligible=status[3]&&|(expected_pending&mie);expected_irq=arm&&eligible;
        check(`C.irq_pending_sync===expected_pending&&`C.irq_arm_q===arm&&`C.irq_eligible_now===eligible&&`C.irq_take===expected_irq,"two-flop old-arm arbitration");
        check(`C.g_csr.u_csr.csr_mstatus===status&&`C.g_csr.u_csr.csr_mie===mie&&`C.arch_next_pc_q===pc,"committed CSR and architectural PC");
        if(SCENARIO==8&&status[3]&&model_time<250)natural_wait_edges=natural_wait_edges+1;
        pre_irq=`C.irq_take;pre_trap=`C.trap_fire;pre_retire=`C.retire_fire;pre_pc=pc;
        pre_cause=(expected_pending&mie&32'h800)?'h8000000b:(expected_pending&mie&8)?'h80000003:'h80000007;
        next_time=TIMER_DEVICE?model_time+1:0;
        if(dqv)check(0,"local device escaped external route");
        if(`C.wb_fire)begin
            check(wb<retired&&wpc===qpc[wb]&&wrd===qrd[wb]&&wdata===qdata[wb]&&`C.memwb_q.seq===qseq[wb]&&we===(qrd[wb]!=0),"retired WB stream");
            if(wpc==terminal_pc)terminal_wb=terminal_wb+1;wb=wb+1;
        end
        if(dut.core_dreq_valid)begin
            check(`C.exmem_valid_q&&`C.exmem_q.seq===`C.ram_req_seq&&`C.ram_req_pc===pc,"first presentation oldest MEM");
        end
        if(dut.core_dreq_valid&&dut.core_dreq_ready)begin
            check(!active,"request owner overwrite");word=rom[pc>>2];op=word&127;rs1=(word>>15)&31;rs2=(word>>20)&31;
            check((op==3||op=='h23)&&known[rs1],"machine request word/operand");
            imm=op==3?{{20{word[31]}},word[31:20]}:{{20{word[31]}},word[31:25],word[11:7]};
            txn_addr=gpr[rs1]+imm;txn_write=op=='h23;txn_data=txn_write?gpr[rs2]:0;txn_pc=pc;txn_seq=`C.ram_req_seq;
            check(dut.core_dreq_addr===txn_addr&&dut.core_dreq_write===txn_write&&dut.core_dreq_wdata===txn_data&&dut.core_dreq_size===2&&dut.core_dreq_wstrb===(txn_write?4'hf:4'h0),"captured machine request descriptor");
            txn_machine=(TIMER_DEVICE&&txn_addr>='h20000040&&txn_addr<'h20000050)||(SOFTWARE_DEVICE&&txn_addr=='h20000050);
            txn_error=!txn_machine;txn_read=0;active=1;txn_executed=0;execute_at=cycles+1;requests=requests+1;
            $fwrite(fd,"%0d,%08h,request,%016h,%08h,%08h,%016h,%016h,%0d\n",cycles,pc,txn_seq,txn_data,expected_pending,model_time,model_cmp,model_msip);
        end
        check(ep_fire===(active&&txn_machine&&!txn_executed&&cycles==execute_at),"unique delayed machine endpoint execution");
        if(active&&txn_machine&&!txn_executed&&cycles==execute_at)begin
            check(ep_addr===txn_addr&&ep_write===txn_write&&ep_wdata===txn_data&&ep_size===2&&ep_strobe===(txn_write?15:0)&&ep_legal,"staged machine descriptor");
            txn_executed=1;executions=executions+1;
            if(txn_write)begin
                if(txn_addr=='h20000050)begin model_msip=txn_data[0];software_writes=software_writes+1;end
                else begin
                    timer_writes=timer_writes+1;
                    case(txn_addr)
                        'h20000040:next_time={model_time[63:32],txn_data};'h20000044:next_time={txn_data,model_time[31:0]};
                        'h20000048:model_cmp={model_cmp[63:32],txn_data};'h2000004c:model_cmp={txn_data,model_cmp[31:0]};
                    endcase
                end
            end else case(txn_addr)
                'h20000040:txn_read=model_time[31:0];'h20000044:txn_read=model_time[63:32];
                'h20000048:txn_read=model_cmp[31:0];'h2000004c:txn_read=model_cmp[63:32];'h20000050:txn_read={31'd0,model_msip};
            endcase
        end
        check(ep_sw_fire===(ep_fire&&txn_write&&txn_addr=='h20000050)&&ep_timer_fire===(ep_fire&&txn_write&&txn_addr!='h20000050),"unique source-specific machine writes");
        if(dut.core_drsp_valid&&dut.core_drsp_ready)begin
            check(active&&dut.core_drsp_error===txn_error&&dut.core_drsp_rdata===txn_read,"machine response route and frozen value");
            active=0;responses=responses+1;
        end
        if(pre_irq)begin
            check(!pre_retire&&!pre_trap&&irqs==0&&SCENARIO>=4&&pc==expected_return,"IRQ precise return PC and mutual exclusion");
            if(SCENARIO==8)begin check(model_time>=250&&natural_wait_edges>100,"natural timer reached programmed deadline");natural_irq_time=model_time;end
            status='h1800|(status[3]?'h80:0);mepc=pc;mcause=pre_cause;mtval=0;pc=vector;irqs=irqs+1;
            $fwrite(fd,"%0d,%08h,irq,%016h,%08h,%08h,%016h,%016h,%0d\n",cycles,pre_pc,`C.irq_seq,mcause,expected_pending,model_time,model_cmp,model_msip);
        end else if(pre_trap)begin
            check(SCENARIO<4&&txn_error&&`C.halt_pc===pc&&`C.halt_tval===txn_addr,"disabled device precise trap");
            word=rom[pc>>2];check(`C.halt_cause===(word[6:0]=='h23 ? 7 : 5),"disabled device access cause");
            mepc=pc;mcause=word[6:0]=='h23 ? 7 : 5;mtval=txn_addr;status='h1800|(status[3]?'h80:0);pc=vector;traps=traps+1;
        end else if(pre_retire)begin
            word=rom[pc>>2];op=word&127;funct=(word>>12)&7;rd=(word>>7)&31;rs1=(word>>15)&31;rs2=(word>>20)&31;value=0;nextpc=pc+4;
            check(`C.exmem_q.pc===pc&&`C.exmem_q.instr===word,"retirement follows independent machine word PC");
            if(pc==terminal_pc&&(SCENARIO!=8||irqs!=0))quiesce<=1;
            if(op=='h37)value=word&32'hfffff000;
            else if(op=='h13)begin check(known[rs1],"ADDI initialized operand");value=gpr[rs1]+{{20{word[31]}},word[31:20]};end
            else if(op==3)begin check(txn_pc==pc&&!txn_error,"LOAD successful device owner");value=txn_read;end
            else if(op=='h23)begin rd=0;check(txn_pc==pc&&!txn_error,"STORE successful device owner");end
            else if(op=='h6f)begin check(word==32'h0000006f,"terminal JAL encoding");rd=0;value=pc+4;nextpc=pc;end
            else if(word==32'h30200073)begin rd=0;nextpc=mepc;status='h1880|(status[7]?8:0);end
            else if(op=='h73)begin
                address=word>>20;case(address)
                    'h300:oldcsr=status;'h304:oldcsr=mie;'h305:oldcsr=vector;'h340:oldcsr=scratch;
                    'h341:oldcsr=mepc;'h342:oldcsr=mcause;'h343:oldcsr=mtval;'h344:oldcsr=expected_pending;
                    default:begin oldcsr=0;check(0,"CSR decoder subset");end
                endcase
                value=oldcsr;operand=funct[2]?rs1:gpr[rs1];write_intent=(funct==1||funct==5||rs1!=0);
                newcsr=(funct&3)==1?operand:(funct&3)==2?oldcsr|operand:oldcsr&~operand;
                if(write_intent)case(address)
                    'h300:status='h1800|(newcsr&'h88);'h304:mie=newcsr&'h888;'h305:vector=newcsr&'hfffffffc;
                    'h340:scratch=newcsr;'h341:mepc=newcsr&'hfffffffc;'h342:mcause=newcsr;'h343:mtval=newcsr;
                    default:begin end
                endcase
            end else check(0,"instruction decoder subset");
            if(`C.mem_result_value!==value||`C.exmem_q.rd!==rd[4:0])$display("VALUEDEBUG case=%0d cycle=%0d pc=%h word=%h result=%h/%h rd=%d/%d txn_pc=%h read=%h",CASE_ID,cycles,pc,word,`C.mem_result_value,value,`C.exmem_q.rd,rd,txn_pc,txn_read);
            check(`C.mem_result_value===value&&`C.exmem_q.rd===rd[4:0],"retirement independent value");
            qpc[retired]=pc;qins[retired]=word;qdata[retired]=value;qrd[retired]=rd;qseq[retired]=`C.exmem_q.seq;
            if(retired)check(qseq[retired]>qseq[retired-1],"strict retired owner age");retired=retired+1;
            if(rd)begin gpr[rd]=value;known[rd]=1;end
            $fwrite(fd,"%0d,%08h,retire,%016h,%08h,%08h,%016h,%016h,%0d\n",cycles,pc,`C.exmem_q.seq,value,expected_pending,model_time,model_cmp,model_msip);pc=nextpc;
        end
        arm=(pre_irq||pre_trap)?0:(status[3]&&|(expected_pending&mie));
        pending=IRQ_FLAGS?meta:0;meta=IRQ_FLAGS?raw_levels:0;model_time=next_time;
        #1;
        check(actual_time===model_time&&actual_cmp===model_cmp&&actual_msip===model_msip,"post-edge machine state and write timing");
        if(pre_irq)check(tvalid&&tpc===pre_pc&&tc===pre_cause&&tv===0,"registered IRQ descriptor");
        if(quiesce&&terminal_wb&&retired==wb&&!`C.idex_valid_q&&!`C.exmem_valid_q&&!`C.memwb_valid_q)begin
            check(!active&&requests==responses,"device transaction ledger closure");
            check(irqs===(SCENARIO>=4?1:0),"IRQ coverage");
            check(traps===(SCENARIO<4?((SOFTWARE_DEVICE?0:2)+(TIMER_DEVICE?0:4)):0),"disabled device trap coverage");
            if(SCENARIO<4)check(gpr[5]===(SOFTWARE_DEVICE?1:0),"polled MSIP and disabled source behavior");
            else begin check(gpr[8]===(SCENARIO==8?0:SW_CASE?8:'h80),"pending includes raw OR bank source");check(gpr[23]===0,"source cleared before MRET");end
            for(j=1;j<32;j=j+1)if(known[j])check(`C.u_regfile.regs[j]===gpr[j],"final physical GPR");
            $fclose(fd);fd=$fopen($sformatf("build/cpu5_s11_machine_control/case%0d_summary.json",CASE_ID),"w");
            $fdisplay(fd,"{\"pass\":true,\"case\":%0d,\"scenario\":%0d,\"id_mode\":%0d,\"checks\":%0d,\"retired\":%0d,\"wb\":%0d,\"irqs\":%0d,\"traps\":%0d,\"requests\":%0d,\"responses\":%0d,\"executions\":%0d,\"software_writes\":%0d,\"timer_writes\":%0d,\"natural_wait_edges\":%0d,\"natural_irq_time\":%0d}",CASE_ID,SCENARIO,ID_MODE,checks,retired,wb,irqs,traps,requests,responses,executions,software_writes,timer_writes,natural_wait_edges,natural_irq_time);$fclose(fd);done=1;
            $display("CPU5_MACHINE_CONTROL_CASE_PASS case=%0d scenario=%0d checks=%0d",CASE_ID,SCENARIO,checks);
        end
    end
endmodule
`undef C

module cpu5_machine_control_guard_tb #(parameter integer KIND=0);
    cpu5_top #(.PROGRAM_FILE("programs/data_handshake_blank.hex"),.IMEM_WORDS(256),.DMEM_WORDS(8),
        .SKELETON_ONLY(0),.ENABLE_CONTROL_FLOW(1),.ENABLE_RAM(1),.ENABLE_MMIO(KIND==2?0:1),
        .ENABLE_TIMER_DEVICE(KIND==0?2:KIND==2?1:0),.ENABLE_SOFTWARE_DEVICE(KIND==1?2:0)) dut(
        .clk(1'b0),.rst_n(1'b0),.pc_x(),.instr_x(),.valid_x(),.wb_pc(),.wb_rd(),.wb_data(),.wb_we(),.retire_valid(),.cycle_count(),.instret_count(),
        .uart_tx(),.uart_rx(1'b1),.gpio_in(8'd0),.gpio_out(),.gpio_oe(),
        .dmem_req_valid(),.dmem_req_ready(1'b0),.dmem_req_write(),.dmem_req_addr(),.dmem_req_size(),.dmem_req_wdata(),.dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0),.dmem_rsp_ready(),.dmem_rsp_rdata(32'd0),.dmem_rsp_error(1'b0),.dmem_fault(),
        .imem_req_valid(),.imem_req_ready(1'b0),.imem_req_addr(),.imem_rsp_valid(1'b0),.imem_rsp_ready(),.imem_rsp_rdata(32'd0),.imem_rsp_error(1'b0),
        .imem_fault(),.imem_fault_pc(),.trap_valid(),.trap_pc(),.trap_cause(),.trap_tval(),
        .bp_lookup_count(),.bp_hit_count(),.bp_taken_count(),.bp_resolved_count(),.bp_mispredict_count(),.bp_direction_error_count(),.bp_target_error_count(),
        .irq_external(1'b0),.irq_software(1'b0),.irq_timer(1'b0),.perf_cycle_events());
    initial begin #20;$fatal(1,"MACHINE invalid device configuration was accepted");end
endmodule
