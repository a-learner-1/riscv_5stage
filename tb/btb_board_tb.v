`timescale 1ns/1ps
`include "programs/btb_board_symbols.vh"

// Future image-level acceptance. Uses physical UART timing and the shortened
// heartbeat DATA image; instruction bytes must match the hardware image.
module btb_board_tb;
    wire [1:0] done;
    reg test_pass = 0;
    btb_board_case normal_restart(done[0]);
    btb_board_case #(.FORCE_FAIL(1)) forced_failure(done[1]);
    initial begin
        wait (&done); test_pass = 1;
        $display("BTB BOARD TESTS PASS: exact UART counter/PASS/FAIL bytes, RAM diagnostics, heartbeat, KEY1 reset and restart");
        $stop;
    end
    initial begin
        #30000000;
        $fatal(1, "BTB board timeout done=%b", done);
    end
endmodule

module btb_board_uart_checker #(parameter integer FORCE_FAIL = 0)(
    input wire tx, rst_n, restart_allowed,
    output reg [31:0] boots = 0,
    output reg [31:0] counter0 = 0, counter1 = 0, counter2 = 0,
    output reg [31:0] counter3 = 0, counter4 = 0, counter5 = 0, counter6 = 0
);
    localparam integer BIT_NS = 434 * 20;
    localparam [12*8-1:0] COUNTER_PREFIX = "BTB COUNTERS";
    localparam [16*8-1:0] PASS_MESSAGE = "BTB BOARD PASS\015\012";
    localparam [34*8-1:0] FAIL_MESSAGE = "BTB BOARD FAIL 00000008 00000000\015\012";
    integer byte_index = 0, bit_index, column, counter_index, result_length;
    reg [7:0] value, expected;
    reg [3:0] digit;
    reg [31:0] values [0:6];
    initial begin
        for(counter_index=0;counter_index<7;counter_index=counter_index+1) values[counter_index] = 0;
        forever begin
            @(negedge tx);
            if (!rst_n || boots >= (FORCE_FAIL ? 1 : 2) || (boots == 1 && !restart_allowed))
                $fatal(1, "BTB board unexpected UART frame");
            #(BIT_NS/2);
            if (tx !== 0) $fatal(1, "BTB UART invalid start");
            for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
                #(BIT_NS); value[bit_index] = tx;
            end
            #(BIT_NS);
            if (tx !== 1 || ^value === 1'bx) $fatal(1, "BTB UART unknown data/stop");
            if (byte_index < 77) begin
                if (byte_index < 12) begin
                    expected = COUNTER_PREFIX[(11-byte_index)*8 +: 8];
                    if (value !== expected) $fatal(1, "BTB UART counter prefix byte=%0d",byte_index);
                end else if (byte_index < 75) begin
                    column = (byte_index-12) % 9;
                    counter_index = (byte_index-12) / 9;
                    if (column == 0) begin
                        if (value !== " ") $fatal(1,"BTB UART counter separator");
                        values[counter_index] = 0;
                    end else begin
                        if (value >= "0" && value <= "9") digit = value-"0";
                        else if (value >= "A" && value <= "F") digit = value-"A"+10;
                        else $fatal(1,"BTB UART invalid counter hex %h",value);
                        values[counter_index] = (values[counter_index] << 4) | digit;
                    end
                end else if (value !== (byte_index == 75 ? 8'h0d : 8'h0a))
                    $fatal(1,"BTB UART counter line termination");
            end else begin
                result_length = FORCE_FAIL ? 34 : 16;
                expected = FORCE_FAIL ? FAIL_MESSAGE[(33-(byte_index-77))*8 +: 8] :
                                        PASS_MESSAGE[(15-(byte_index-77))*8 +: 8];
                if (value !== expected) $fatal(1,"BTB UART result boot=%0d byte=%0d got=%h expected=%h",boots,byte_index-77,value,expected);
                if (byte_index == 77+result_length-1) begin
                    counter0 = values[0]; counter1 = values[1]; counter2 = values[2];
                    counter3 = values[3]; counter4 = values[4]; counter5 = values[5]; counter6 = values[6];
                    boots = boots + 1;
                    byte_index = -1;
                end
            end
            byte_index = byte_index + 1;
        end
    end
endmodule

module btb_board_case #(parameter integer FORCE_FAIL = 0)(output reg done = 0);
    reg clk = 0, key1_n = 1, restart_allowed = 0;
    always #10 clk = ~clk;
    wire tx;
    wire [7:0] led;
    wire [31:0] boots;
    wire [31:0] uart_counters [0:6];
    integer index, timeout_cycles;
    reg phase;
    btb_board_top #(.DATA_FILE("programs/btb_board_sim_data.hex"),
                    .RESET_HOLD_CYCLES(16)) dut (
        .clk_50m(clk), .key1_n(key1_n), .keys_n(7'h7f),
        .led(led), .uart_tx(tx), .uart_rx(1'b1)
    );
    btb_board_uart_checker #(.FORCE_FAIL(FORCE_FAIL)) serial (
        .tx(tx), .rst_n(dut.cpu_rst_n), .restart_allowed(restart_allowed), .boots(boots),
        .counter0(uart_counters[0]), .counter1(uart_counters[1]), .counter2(uart_counters[2]),
        .counter3(uart_counters[3]), .counter4(uart_counters[4]), .counter5(uart_counters[5]),
        .counter6(uart_counters[6])
    );
    always @(posedge clk) begin
        if (dut.cpu_rst_n && !done &&
            (dut.u_cpu.imem_fault || dut.u_cpu.dmem_fault || dut.u_cpu.trap_valid))
            $fatal(1,"BTB board unexpected fault/trap");
    end
    task check_completed;
        begin
            timeout_cycles = 0;
            while(dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_DONE-32'h10000)/4] !== 1) begin
                @(negedge clk); timeout_cycles = timeout_cycles + 1;
                if(timeout_cycles > 100000) $fatal(1,"BTB board done timeout");
            end
            if(dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_FAILED-32'h10000)/4] !== (FORCE_FAIL ? 8 : 0) ||
               dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_RESULT-32'h10000)/4] !== 0 ||
               dut.gpio_oe !== 7 || led[7:1] !== (FORCE_FAIL ? 7'b0000010 : 7'b0000001))
                $fatal(1,"BTB board result/LED mismatch");
            if(dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_BASELINE-32'h10000)/4] !== `BTB_BOARD_EXPECT_CONFIG ||
               dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_SNAPSHOT-32'h10000)/4] !== `BTB_BOARD_EXPECT_CONFIG)
                $fatal(1,"BTB hardware configuration mismatch");
            for(index=0;index<7;index=index+1) begin
                if(uart_counters[index] !==
                   (dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_SNAPSHOT-32'h10000)/4+index+1] -
                    dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_BASELINE-32'h10000)/4+index+1]))
                    $fatal(1,"BTB UART counter %0d disagrees with RAM diagnostic",index);
                if(index<5 && uart_counters[index] == 0)
                    $fatal(1,"BTB board did not exercise counter %0d",index);
            end
        end
    endtask
    initial begin
        if(FORCE_FAIL) begin
            #1;
            dut.u_cpu.u_data_mem.mem[(`BTB_BOARD_BLINK_CYCLES-32'h10000)/4] = 0;
        end
        wait(boots == 1); check_completed();
        if(FORCE_FAIL) begin
            repeat(1000) @(negedge clk);
            if(led !== 4) $fatal(1,"BTB FAIL LED did not remain steady");
            done = 1;
        end else begin
            phase = led[0];
            wait(led[0] !== phase);
            @(negedge clk); restart_allowed = 1; key1_n = 0;
            repeat(20) @(negedge clk);
            if(dut.cpu_rst_n || led !== 0 || dut.u_cpu.u_if_stage.bp_lookup_count ||
               dut.u_cpu.bp_resolved_count || dut.u_cpu.bp_mispredict_count)
                $fatal(1,"KEY1 failed to clear CPU/predictor counters and LEDs");
            key1_n = 1;
            wait(boots == 2); check_completed();
            phase = led[0]; wait(led[0] !== phase);
            done = 1;
        end
    end
endmodule
