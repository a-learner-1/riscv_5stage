`timescale 1ns/1ps
module uart_cpu_tb;
    reg clk = 0;
    reg rst_n = 0;
    wire [31:0] pc_x, instr_x, wb_pc, wb_data;
    wire [4:0] wb_rd;
    wire valid_x, wb_we, retire_valid, uart_tx;
    wire [63:0] cycle_count, instret_count;
    integer received = 0;
    integer accepted = 0;
    integer busy_reads = 0;
    integer idle_reads = 0;
    integer watchdog_cycles = 0;
    integer bit_number;
    reg [7:0] byte_value;

    localparam integer CLOCK_HZ = 100000000;
    localparam integer BAUD = 115200;
    localparam integer CLOCKS_PER_BIT = (CLOCK_HZ + BAUD / 2) / BAUD;
    localparam integer BIT_NS = CLOCKS_PER_BIT * 10;
    localparam integer MESSAGE_LENGTH = 13;
    localparam integer TOHOST_WORD = 4095;

    cpu_top #(
        .PROGRAM_FILE("programs/uart_demo.hex"),
        .DATA_FILE("programs/uart_demo_data.hex"),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000),
        .UART_CLOCK_HZ(CLOCK_HZ), .UART_BAUD(BAUD),
        .SIM_CONSOLE_ECHO(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1),
        .pc_x(pc_x), .instr_x(instr_x), .valid_x(valid_x),
        .wb_pc(wb_pc), .wb_rd(wb_rd), .wb_data(wb_data), .wb_we(wb_we),
        .retire_valid(retire_valid), .cycle_count(cycle_count),
        .instret_count(instret_count), .gpio_in(8'd0), .gpio_out(), .gpio_oe(), .uart_tx(uart_tx),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault(),
        .trap_valid(), .trap_pc(), .trap_cause(), .trap_tval()
    );
    always #5 clk = ~clk;

    function [7:0] expected_byte;
        input integer index;
        case (index)
            0: expected_byte = "H";
            1: expected_byte = "e";
            2: expected_byte = "l";
            3: expected_byte = "l";
            4: expected_byte = "o";
            5: expected_byte = " ";
            6: expected_byte = "R";
            7: expected_byte = "I";
            8: expected_byte = "S";
            9: expected_byte = "C";
            10: expected_byte = "-";
            11: expected_byte = "V";
            12: expected_byte = 8'h0a;
            default: expected_byte = 8'hxx;
        endcase
    endfunction

    // Observe both busy and idle status reads and check RAM isolation.
    always @(posedge clk) begin
        if (rst_n && dut.load_issue_x && dut.mmio_uart_status_addr_x) begin
            if (dut.mmio_read_data_x[0] === 1'b1)
                busy_reads = busy_reads + 1;
            else if (dut.mmio_read_data_x[0] === 1'b0)
                idle_reads = idle_reads + 1;
            else
                $fatal(1, "Unknown UART status");
            if (dut.mem_re_x || dut.mem_we_x)
                $fatal(1, "UART status incorrectly accessed ordinary RAM");
        end
        #1;
        if (rst_n && dut.mmio_putchar_valid) begin
            if (accepted >= MESSAGE_LENGTH ||
                dut.mmio_putchar_data !== expected_byte(accepted))
                $fatal(1, "Unexpected UART MMIO byte index=%0d value=%h",
                       accepted, dut.mmio_putchar_data);
            accepted = accepted + 1;
        end
    end

    // This receiver checks the physical serial wire, not the $write echo.
    initial begin
        wait (rst_n);
        $write("UART received: ");
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2);
            if (uart_tx !== 1'b0)
                $fatal(1, "Invalid UART start bit");
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                #(BIT_NS);
                byte_value[bit_number] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1)
                $fatal(1, "Invalid UART stop bit");
            if (received >= MESSAGE_LENGTH ||
                byte_value !== expected_byte(received))
                $fatal(1, "UART RX mismatch index=%0d got=%h expected=%h",
                       received, byte_value, expected_byte(received));
            $write("%c", byte_value);
            #(BIT_NS / 2);
            #1;
            received = received + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        while (dut.u_data_mem.mem[TOHOST_WORD] === 32'd0) begin
            @(posedge clk);
            #2;
            watchdog_cycles = watchdog_cycles + 1;
            if (watchdog_cycles > 500000)
                $fatal(1, "CPU UART test timeout pc=%h", pc_x);
        end
        if (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1)
            $fatal(1, "UART demo failed tohost=%h",
                   dut.u_data_mem.mem[TOHOST_WORD]);
        @(posedge clk);
        #2;
        if (received != MESSAGE_LENGTH || accepted != MESSAGE_LENGTH)
            $fatal(1, "Lost UART bytes accepted=%0d received=%0d",
                   accepted, received);
        if (dut.uart_busy !== 0 || uart_tx !== 1)
            $fatal(1, "UART demo ended before transmission drained");
        if (busy_reads == 0 || idle_reads == 0)
            $fatal(1, "Software did not poll both busy and idle states");
        $display("UART: baud=115200 clocks_per_bit=%0d bytes=%0d",
                 CLOCKS_PER_BIT, received);
        $display("PASS: CPU UART transmit test");
        $stop;
    end
endmodule
