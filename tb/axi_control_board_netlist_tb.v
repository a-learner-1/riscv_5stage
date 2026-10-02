// Functional check of the new synthesized hardware image; no SDF, no download.
// Uses the physical 0.5-second heartbeat data and 1ms reset hold without
// modifying netlist memories. Full-period heartbeat is checked by the RTL TB.
`timescale 1ns/1ps
module axi_control_board_netlist_tb;
    reg clk_50m=0,key1_n=1;
    wire [7:0] led;
    wire uart_tx;
    reg test_pass=0,restart_requested=0;
    integer bytes=0,boots=0,bit_index;
    reg [7:0] value;
    localparam integer BIT_NS=434*20;
    localparam integer MESSAGE_BYTES=55;
    localparam [MESSAGE_BYTES*8-1:0] MESSAGE=
        "AXI RESULTS 0000002A 00000001 80000000\015\012AXI CTRL PASS\015\012";
    board_top dut(.clk_50m(clk_50m),.key1_n(key1_n),.keys_n(7'h7f),
                  .led(led),.uart_tx(uart_tx),.uart_rx(1'b1));
    always #10 clk_50m=~clk_50m;
    initial begin
        forever begin
            @(negedge uart_tx);
            if(boots>=2||(boots==1&&!restart_requested))
                $fatal(1,"AXI netlist duplicated a boot message");
            #(BIT_NS/2);
            if(uart_tx!==0) $fatal(1,"AXI netlist UART start");
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                #(BIT_NS);
                if(uart_tx!==0&&uart_tx!==1) $fatal(1,"AXI netlist unknown UART data");
                value[bit_index]=uart_tx;
            end
            #(BIT_NS);
            if(uart_tx!==1||value!==MESSAGE[(MESSAGE_BYTES-1-bytes)*8+:8])
                $fatal(1,"AXI netlist UART byte=%0d got=%h expected=%h",bytes,value,
                       MESSAGE[(MESSAGE_BYTES-1-bytes)*8+:8]);
            bytes=bytes+1;
            if(bytes==MESSAGE_BYTES) begin
                bytes=0;boots=boots+1;
                $display("AXI BOARD NETLIST: boot=%0d physical-rate 55-byte results/PASS verified",boots);
            end
        end
    end
    task check_pass_led;
        begin
            if(led[7:1]!==7'b0000001||(led[0]!==0&&led[0]!==1))
                $fatal(1,"AXI netlist expected PASS LED2 and no fault LED, got=%h",led);
        end
    endtask
    initial begin
        #100;
        if(led!==0||uart_tx!==1) $fatal(1,"AXI netlist power-on defaults");
        wait(boots==1);#100000;
        check_pass_led;
        restart_requested=1;@(negedge clk_50m);key1_n=0;#100;
        if(led!==0||uart_tx!==1) $fatal(1,"AXI netlist KEY1 assertion");
        repeat(5) @(negedge clk_50m);key1_n=1;
        #900000;
        if(led!==0||uart_tx!==1||boots!=1) $fatal(1,"AXI netlist KEY1 release hold");
        wait(boots==2);#100000;
        check_pass_led;
        test_pass=1;
        $display("PASS: AXI control board synthesized hardware ROM/RAM initialization, three results, 50MHz UART, PASS LED and KEY1 restart");
        $stop;
    end
    initial begin #20000000;$fatal(1,"AXI netlist timeout boots=%0d",boots);end
endmodule
