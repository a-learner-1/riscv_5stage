`timescale 1ns/1ps
module cpu5_ram_unit_tb;
reg test_pass=0;
cpu5_ram_unit #(.DMEM_BASE_ADDR(32'hfffffff0),.DMEM_WORDS(5)) dut(
.instr(32'd0),.rs1_value(32'd0),.rs2_value(32'd0),.response_word(32'd0));
initial begin #1;test_pass=1;$stop;end
endmodule
