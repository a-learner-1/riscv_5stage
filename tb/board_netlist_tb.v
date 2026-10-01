// Checks the actual hardware-image synthesis netlist; no accelerated RAM image.
// Functional simulation only (no routing SDF); hardware remains unverified.
`timescale 1ns/1ps
module board_netlist_tb;
reg clk_50m=0;
reg key1_n=1;
reg [6:0] keys_n=7'h7f;
wire [7:0] led;
wire uart_tx;
integer bytes=0;
integer boots=0;
integer i;
reg [7:0] value;
reg [7:0] expected [0:13];
board_top dut(.clk_50m(clk_50m),.key1_n(key1_n),.keys_n(keys_n),
              .led(led),.uart_tx(uart_tx));
always #10 clk_50m=~clk_50m;
initial begin
 expected[0]="H";expected[1]="e";expected[2]="l";expected[3]="l";
 expected[4]="o";expected[5]=" ";expected[6]="R";expected[7]="I";
 expected[8]="S";expected[9]="C";expected[10]="-";expected[11]="V";
 expected[12]=13;expected[13]=10;
 forever begin
  @(negedge uart_tx);
  #4340;
  if(uart_tx !== 0) $fatal(1,"Netlist UART start");
  for(i=0;i<8;i=i+1) begin #8680; value[i]=uart_tx; end
  #8680;
  if(uart_tx !== 1 || value !== expected[bytes])
    $fatal(1,"Netlist UART byte=%0d got=%h expected=%h",bytes,value,expected[bytes]);
  bytes=bytes+1;
  if(bytes==14) begin bytes=0;boots=boots+1;
    $display("NETLIST: hardware initialization UART boot=%0d verified",boots);
  end
 end
end
initial begin
 #100;
 if(led !== 0 || uart_tx !== 1) $fatal(1,"Netlist power-on defaults");
 wait(boots==1); #9000;
 if(led !== 1) $fatal(1,"Netlist firmware LED defaults");
 keys_n[0]=0; repeat(200) @(posedge clk_50m); #2;
 if(led !== 3) $fatal(1,"Netlist KEY2 press");
 keys_n[0]=1; repeat(200) @(posedge clk_50m); #2;
 if(led !== 1) $fatal(1,"Netlist KEY2 release");
 key1_n=0; #100;
 if(led !== 0 || uart_tx !== 1) $fatal(1,"Netlist KEY1 reset");
 #500; key1_n=1;
 wait(boots==2); #9000;
 if(led !== 1) $fatal(1,"Netlist firmware restart");
 $display("PASS: synthesized hardware ROM/RAM init, UART, KEY2 and KEY1 restart");
 $stop;
end
initial begin #6000000; $fatal(1,"Netlist timeout boots=%0d",boots); end
endmodule
