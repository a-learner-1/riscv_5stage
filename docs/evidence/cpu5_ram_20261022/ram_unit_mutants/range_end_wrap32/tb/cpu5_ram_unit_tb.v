`timescale 1ns/1ps
module cpu5_ram_unit_tb;
    reg [31:0] instr,rs1_value,rs2_value,response_word;
    wire [2:0] supported,is_load,is_store,uses_rs1,uses_rs2,writes_rd;
    wire [4:0] rs1[0:2],rs2[0:2],rd[0:2];
    wire [31:0] imm[0:2],addr[0:2],wdata[0:2],load_value[0:2],fault_cause[0:2];
    wire [1:0] size[0:2];wire [3:0] wstrb[0:2];
    wire [2:0] misaligned,out_of_range,fault;
    reg test_pass=0;
    integer checks=0,cases=0,known_checks=0,load_checks=0,store_checks=0,unsupported_checks=0;
    integer misalign_checks=0,range_checks=0,valid_checks=0,wrap_checks=0,x0_checks=0;
    integer i,j,k,f,kind,delta,dest,output_file;
    reg [31:0] state=32'hc505a301,a,b,r,word;
    genvar g;
    generate for(g=0;g<3;g=g+1)begin:configs
        localparam [31:0] BASE=g==0?32'h10000:g==1?32'hfffffff0:32'h10000;
        localparam integer WORDS=g==0?4096:g==1?4:3;
        cpu5_ram_unit #(.DMEM_BASE_ADDR(BASE),.DMEM_WORDS(WORDS)) dut(
            .instr(instr),.rs1_value(rs1_value),.rs2_value(rs2_value),.response_word(response_word),
            .supported(supported[g]),.is_load(is_load[g]),.is_store(is_store[g]),
            .uses_rs1(uses_rs1[g]),.uses_rs2(uses_rs2[g]),.writes_rd(writes_rd[g]),
            .rs1(rs1[g]),.rs2(rs2[g]),.rd(rd[g]),.imm(imm[g]),.addr(addr[g]),
            .wdata(wdata[g]),.load_value(load_value[g]),.size(size[g]),.wstrb(wstrb[g]),
            .misaligned(misaligned[g]),.out_of_range(out_of_range[g]),.fault(fault[g]),.fault_cause(fault_cause[g]));
    end endgenerate
    function [31:0] random_word;
        input [31:0] old;reg [31:0] x;
        begin x=old^(old<<13);x=x^(x>>17);random_word=x^(x<<5);end
    endfunction
    function [31:0] encode;
        input integer mem_kind,funct,offset,src1,src2,destination;
        reg [11:0] bits;
        begin
            bits=offset;
            if(mem_kind==1)encode=(bits<<20)|(src1<<15)|(funct<<12)|(destination<<7)|32'h03;
            else encode=(bits[11:5]<<25)|(src2<<20)|(src1<<15)|(funct<<12)|(bits[4:0]<<7)|32'h23;
        end
    endfunction
    function integer offset_corner;
        input integer index;
        begin case(index)
            0:offset_corner=-2048;1:offset_corner=-1025;2:offset_corner=-17;3:offset_corner=-1;
            4:offset_corner=0;5:offset_corner=1;6:offset_corner=2;7:offset_corner=3;
            8:offset_corner=4;default:offset_corner=2047;
        endcase end
    endfunction
    function [31:0] address_corner;
        input integer index;
        begin case(index)
            0:address_corner=0;1:address_corner=32'hffffffff;2:address_corner=32'hffff;
            3:address_corner=32'h10000;4:address_corner=32'h10001;5:address_corner=32'h10002;
            6:address_corner=32'h10003;7:address_corner=32'h10008;8:address_corner=32'h1000b;
            9:address_corner=32'h1000c;10:address_corner=32'h13ffc;11:address_corner=32'h13ffd;
            12:address_corner=32'h13ffe;13:address_corner=32'h13fff;14:address_corner=32'h14000;
            15:address_corner=32'hfffffff0;16:address_corner=32'hfffffffc;
            17:address_corner=32'hfffffffd;18:address_corner=32'hfffffffe;default:address_corner=32'hffffffef;
        endcase end
    endfunction
    task check;
        input [31:0] instruction,lhs,rhs,response;
        input integer mem_kind,funct,offset,src1,src2,destination;
        integer n,lane,bytes,sz,lsb,expected_rd,expected_rs2;
        reg legal,ld,st,mis,oor;
        reg [31:0] ea,iv,sv,lv,fc;
        reg [7:0] picked_byte;reg [15:0] picked_half;
        reg [3:0] strobes;
        reg [63:0] first,last,lo,hi;
        begin
            instr=instruction;rs1_value=lhs;rs2_value=rhs;response_word=response;
            legal=(mem_kind==1 && (funct==0||funct==1||funct==2||funct==4||funct==5)) ||
                (mem_kind==2 && (funct==0||funct==1||funct==2));
            ld=legal && mem_kind==1;st=legal && mem_kind==2;
            iv=legal?offset:0;ea=legal?(lhs+offset):0;
            sz=!legal?0:(funct==0||funct==4)?0:(funct==1||funct==5)?1:2;
            bytes=sz==0?1:sz==1?2:4;lsb=ea%4;
            // Byte selection and lane assembly deliberately avoid the RTL's
            // variable shift expressions, including at invalid alignments.
            case(lsb)
                0:begin picked_byte=response[7:0];picked_half=response[15:0];end
                1:begin picked_byte=response[15:8];picked_half=response[23:8];end
                2:begin picked_byte=response[23:16];picked_half=response[31:16];end
                3:begin picked_byte=response[31:24];picked_half={8'd0,response[31:24]};end
            endcase
            lv=0;
            if(ld)case(funct)
                0:lv=picked_byte[7]?32'hffffff00+picked_byte:picked_byte;
                1:lv=picked_half[15]?32'hffff0000+picked_half:picked_half;
                2:lv=response;4:lv=picked_byte;5:lv=picked_half;
            endcase
            sv=0;strobes=0;
            if(st)for(lane=0;lane<4;lane=lane+1)begin
                if(lane>=lsb)sv[lane*8+:8]=rhs[(lane-lsb)*8+:8];
                if(sz==2 || (lane>=lsb && lane<lsb+bytes))strobes[lane]=1;
            end
            expected_rd=st?0:destination;
            expected_rs2=mem_kind==1?(offset&31):src2;
            #1;
            for(n=0;n<3;n=n+1)begin
                lo=n==1?64'hfffffff0:64'h10000;
                hi=n==0?64'h14000:n==1?64'h100000000:64'h1000c;
                first={32'd0,ea};last=first+bytes-1;
                mis=legal && ((sz==1 && lsb%2!=0)||(sz==2 && lsb!=0));
                oor=legal && (first<lo || last>=hi);
                fc=!(mis||oor)?0:mis?(st?6:4):(st?7:5);
                checks=checks+1;
                if({supported[n],is_load[n],is_store[n],uses_rs1[n],uses_rs2[n],writes_rd[n]} !==
                   {legal,ld,st,legal,st,(ld && expected_rd!=0)})
                    $fatal(1,"RAM decode case=%0d config=%0d instr=%h",cases,n,instruction);
                if(rs1[n]!==src1 || rs2[n]!==expected_rs2 || rd[n]!==expected_rd)
                    $fatal(1,"RAM indices case=%0d config=%0d actual=%d/%d/%d expected=%d/%d/%d",cases,n,rs1[n],rs2[n],rd[n],src1,expected_rs2,expected_rd);
                if(imm[n]!==iv || addr[n]!==ea || size[n]!==sz || wdata[n]!==sv || wstrb[n]!==strobes || load_value[n]!==lv)
                    $fatal(1,"RAM format case=%0d config=%0d instr=%h imm=%h/%h addr=%h/%h size=%d/%d data=%h/%h strobe=%h/%h load=%h/%h",cases,n,instruction,imm[n],iv,addr[n],ea,size[n],sz,wdata[n],sv,wstrb[n],strobes,load_value[n],lv);
                if(misaligned[n]!==mis || out_of_range[n]!==oor || fault[n]!== (legal&&(mis||oor)) || fault_cause[n]!==fc)
                    $fatal(1,"RAM fault case=%0d config=%0d addr=%h first=%h last=%h actual=%b/%b/%b/%d expected=%b/%b/%b/%d",cases,n,ea,first,last,misaligned[n],out_of_range[n],fault[n],fault_cause[n],mis,oor,(legal&&(mis||oor)),fc);
                if(mis)misalign_checks=misalign_checks+1;
                if(oor)range_checks=range_checks+1;
                if(legal && !mis && !oor)valid_checks=valid_checks+1;
            end
            cases=cases+1;
            if(ld)load_checks=load_checks+1;
            if(st)store_checks=store_checks+1;
            if(!legal)unsupported_checks=unsupported_checks+1;
            if(ld && expected_rd==0)x0_checks=x0_checks+1;
            if(legal && offset>0 && ea<lhs)wrap_checks=wrap_checks+1;
        end
    endtask
    initial begin
        instr=0;rs1_value=0;rs2_value=0;response_word=0;
        // Fixed machine words are independent of encode(). The offset/raw
        // register arguments below are hand decoded, including S-immediate.
        check(32'hfff08283,32'h10004,0,32'h80ff7f01,1,0,-1,1,0,5);known_checks=known_checks+1;
        check(32'h00209283,32'h10000,0,32'h80ff7f01,1,1,2,1,0,5);known_checks=known_checks+1;
        check(32'h0000a283,32'hfffffffc,0,32'hfedcba98,1,2,0,1,0,5);known_checks=known_checks+1;
        check(32'h0030c003,32'h10000,0,32'h80ff7f01,1,4,3,1,0,0);known_checks=known_checks+1;
        check(32'h0020d283,32'h10000,0,32'h80ff7f01,1,5,2,1,0,5);known_checks=known_checks+1;
        check(32'hfe208fa3,32'h10004,32'h89abcdef,0,2,0,-1,1,2,31);known_checks=known_checks+1;
        check(32'h00209123,32'h10000,32'h89abcdef,0,2,1,2,1,2,2);known_checks=known_checks+1;
        check(32'h0020a023,32'h10000,32'h89abcdef,0,2,2,0,1,2,0);known_checks=known_checks+1;
        check(32'h8000a283,32'h10800,0,32'h76543210,1,2,-2048,1,0,5);known_checks=known_checks+1;
        check(32'h7ff0a283,32'hf801,0,32'h76543210,1,2,2047,1,0,5);known_checks=known_checks+1;
        check(32'hfff09283,32'h14000,0,32'h76543210,1,1,-1,1,0,5);known_checks=known_checks+1;
        check(32'h0010a283,32'hffffffff,0,32'h76543210,1,2,1,1,0,5);known_checks=known_checks+1;
        // Every f3, every width, all byte offsets, range ends, negative S/I
        // offsets and the full 32-bit endpoint boundary under three RAM maps.
        for(kind=1;kind<=2;kind=kind+1)for(f=0;f<8;f=f+1)
            for(i=0;i<10;i=i+1)for(j=0;j<20;j=j+1)begin
                delta=offset_corner(i);a=address_corner(j)-delta;
                dest=(i+j+f)%32;state=random_word(state);b=state;
                state=random_word(state);r=state;
                check(encode(kind,f,delta,(j+1)%32,(i+3)%32,dest),a,b,r,kind,f,delta,(j+1)%32,(i+3)%32,
                    kind==1?dest:(delta&31));
            end
        for(i=0;i<2048;i=i+1)begin
            state=random_word(state);delta=(state%4096)-2048;kind=1+(i%2);f=(i/2)%8;
            state=random_word(state);a=(i%3==0)?state:32'h10000+(state%16388)-2-delta;
            state=random_word(state);b=state;state=random_word(state);r=state;
            check(encode(kind,f,delta,i%32,(i/8)%32,(i/32)%32),a,b,r,kind,f,delta,i%32,(i/8)%32,
                kind==1?(i/32)%32:(delta&31));
        end
        // All other opcode encodings must remain non-memory, regardless of f3.
        for(k=0;k<128;k=k+1)if(k!=3 && k!=35)for(f=0;f<8;f=f+1)begin
            word=32'hfedcba80 | (f<<12) | k;
            // Replace, rather than OR, f3 so the independent raw arguments agree.
            word=(word & 32'hffff8fff) | (f<<12);
            check(word,32'h10000,32'h89abcdef,32'h80ff7f01,0,f,0,word[19:15],word[24:20],word[11:7]);
        end
        if(known_checks!=12 || load_checks==0 || store_checks==0 || unsupported_checks==0 ||
            misalign_checks==0 || range_checks==0 || valid_checks==0 || wrap_checks==0 || x0_checks==0)
            $fatal(1,"RAM unit coverage gate");
        output_file=$fopen("build/cpu5_s5_ram_unit/summary.json","w");
        $fdisplay(output_file,"{\"pass\":true,\"configurations\":3,\"cases\":%0d,\"checks\":%0d,\"known_machine_words\":%0d,\"loads\":%0d,\"stores\":%0d,\"unsupported\":%0d,\"misaligned_checks\":%0d,\"range_checks\":%0d,\"valid_checks\":%0d,\"wrapped_addresses\":%0d,\"load_x0\":%0d}",
            cases,checks,known_checks,load_checks,store_checks,unsupported_checks,misalign_checks,range_checks,valid_checks,wrap_checks,x0_checks);
        $fclose(output_file);
        $display("CPU5 RAM UNIT TEST PASS cases=%0d checks=%0d known=%0d",cases,checks,known_checks);
        test_pass=1;$stop;
    end
endmodule
