`timescale 1ns/1ps
module uart_rx_cpu_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg rx = 1;
    wire uart_tx;
    wire [31:0] pc_x;

    localparam integer CLOCK_HZ = 100000000;
    localparam integer BAUD = 5000000;
    localparam integer CLOCKS_PER_BIT = (CLOCK_HZ + BAUD / 2) / BAUD;
    localparam integer BIT_NS = CLOCKS_PER_BIT * 10;
    localparam integer TEST_BYTES = 32;
    localparam integer TOHOST_WORD = 4095;
    localparam [31:0] RX_DATA_ADDR = 32'h20000018;
    localparam [31:0] RX_STATUS_ADDR = 32'h2000001c;

    integer sent = 0;
    integer echoed = 0;
    integer tx_accepted = 0;
    integer rx_data_reads = 0;
    integer rx_status_reads = 0;
    integer watchdog_cycles = 0;
    integer decode_bit;
    integer send_index;
    reg [7:0] decoded_byte;
    reg [31:0] last_rx_status = 0;
    reg test_started = 0;
    reg test_pass = 0;

    cpu_top #(
        .PROGRAM_FILE("programs/uart_rx_echo_test.hex"),
        .DATA_FILE("programs/uart_rx_echo_test_data.hex"),
        .IMEM_WORDS(8192), .DMEM_WORDS(4096),
        .DMEM_BASE_ADDR(32'h00010000),
        .UART_CLOCK_HZ(CLOCK_HZ), .UART_BAUD(BAUD),
        .UART_RX_FIFO_DEPTH(16), .SIM_CONSOLE_ECHO(0)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pc_x(pc_x), .instr_x(), .valid_x(),
        .wb_pc(), .wb_rd(), .wb_data(), .wb_we(), .retire_valid(),
        .cycle_count(), .instret_count(),
        .gpio_in(8'd0), .gpio_out(), .gpio_oe(),
        .uart_rx(rx), .uart_tx(uart_tx),
        .imem_req_valid(), .imem_req_ready(1'b0), .imem_req_addr(),
        .imem_rsp_valid(1'b0), .imem_rsp_ready(), .imem_rsp_rdata(32'd0),
        .imem_rsp_error(1'b0), .imem_fault(), .imem_fault_pc(),
        .dmem_req_valid(), .dmem_req_ready(1'b0), .dmem_req_write(),
        .dmem_req_addr(), .dmem_req_size(), .dmem_req_wdata(), .dmem_req_wstrb(),
        .dmem_rsp_valid(1'b0), .dmem_rsp_ready(), .dmem_rsp_rdata(32'd0),
        .dmem_rsp_error(1'b0), .dmem_fault()
    );
    always #5 clk = ~clk;

    function [7:0] expected_byte;
        input integer index;
        begin
            case (index)
                0: expected_byte = 8'h00;
                1: expected_byte = 8'hff;
                2: expected_byte = 8'h55;
                3: expected_byte = 8'haa;
                4: expected_byte = 8'h0d;
                5: expected_byte = 8'h0a;
                default: expected_byte = index - 6;
            endcase
        end
    endfunction

    // Offset transitions from clock edges to exercise the input synchronizer.
    task send_byte;
        input [7:0] value;
        integer bit_index;
        begin
            @(negedge clk);
            #3;
            rx = 0;
            #(BIT_NS);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rx = value[bit_index];
                #(BIT_NS);
            end
            rx = 1;
            #(BIT_NS);
        end
    endtask

    // RX MMIO must never touch RAM or pop twice while a synchronous load
    // remains in EX. This checks load_issue, rather than the held instruction.
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.load_pending && dut.u_uart_rx_mmio.read_enable)
                $fatal(1, "RX read repeated in load_pending at pc=%h", pc_x);

            if (dut.load_issue_x &&
                ((dut.mem_addr_x == RX_DATA_ADDR) ||
                 (dut.mem_addr_x == RX_STATUS_ADDR))) begin
                if (dut.mem_re_x || dut.mem_we_x)
                    $fatal(1, "RX MMIO incorrectly accessed data RAM");
                if (dut.mem_addr_x == RX_STATUS_ADDR) begin
                    rx_status_reads = rx_status_reads + 1;
                    last_rx_status = dut.mmio_read_data_x;
                    if (last_rx_status[3:2] !== 2'b00)
                        $fatal(1, "Unexpected RX errors status=%h", last_rx_status);
                end else begin
                    if (last_rx_status[0] !== 1'b1)
                        $fatal(1, "Software read RX DATA before nonempty status");
                    if (rx_data_reads >= TEST_BYTES ||
                        dut.mmio_read_data_x[7:0] !== expected_byte(rx_data_reads))
                        $fatal(1, "RX MMIO byte mismatch index=%0d got=%h",
                               rx_data_reads, dut.mmio_read_data_x[7:0]);
                    rx_data_reads = rx_data_reads + 1;
                end
            end
        end
        #1;
        if (rst_n && dut.mmio_putchar_valid) begin
            if (tx_accepted >= TEST_BYTES ||
                dut.mmio_putchar_data !== expected_byte(tx_accepted))
                $fatal(1, "TX MMIO byte mismatch index=%0d value=%h",
                       tx_accepted, dut.mmio_putchar_data);
            tx_accepted = tx_accepted + 1;
        end
    end

    // Independently decode the physical TX wire, including 00/FF and CR/LF.
    initial begin
        forever begin
            @(negedge uart_tx);
            if (!rst_n || !test_started)
                $fatal(1, "Unexpected UART echo while CPU is in reset");
            #(BIT_NS / 2);
            if (uart_tx !== 1'b0)
                $fatal(1, "Invalid echo start bit");
            for (decode_bit = 0; decode_bit < 8; decode_bit = decode_bit + 1) begin
                #(BIT_NS);
                decoded_byte[decode_bit] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1)
                $fatal(1, "Invalid echo stop bit");
            if (echoed >= TEST_BYTES ||
                decoded_byte !== expected_byte(echoed))
                $fatal(1, "Serial echo mismatch index=%0d got=%h expected=%h",
                       echoed, decoded_byte, expected_byte(echoed));
            echoed = echoed + 1;
        end
    end

    // Entire simulation is bounded, including reset/input preparation.
    initial begin
        #2000000;
        $fatal(1, "UART RX global timeout pc=%h sent=%0d echoed=%0d",
               pc_x, sent, echoed);
    end

    initial begin
        repeat (4) @(posedge clk);
        send_byte(8'h12);
        send_byte(8'h00);
        send_byte(8'hff);
        #(BIT_NS * 4);
        if (uart_tx !== 1'b1 || echoed != 0 || tx_accepted != 0)
            $fatal(1, "Reset-period RX frames produced an echo");
        @(negedge clk);
        test_started = 1;
        rst_n = 1;
        // CPU starts on an empty FIFO, and must poll instead of reading DATA.
        repeat (100) @(posedge clk);
        if (rx_data_reads != 0 || echoed != 0)
            $fatal(1, "CPU consumed reset-period bytes after reset release");
        for (send_index = 0; send_index < TEST_BYTES; send_index = send_index + 1) begin
            send_byte(expected_byte(send_index));
            sent = sent + 1;
        end

        while (dut.u_data_mem.mem[TOHOST_WORD] === 32'd0) begin
            @(posedge clk);
            #2;
            watchdog_cycles = watchdog_cycles + 1;
            if (watchdog_cycles > 150000)
                $fatal(1, "CPU RX echo timeout pc=%h reads=%0d echoed=%0d",
                       pc_x, rx_data_reads, echoed);
        end
        if (dut.u_data_mem.mem[TOHOST_WORD] !== 32'd1)
            $fatal(1, "Echo firmware failed tohost=%h",
                   dut.u_data_mem.mem[TOHOST_WORD]);
        repeat (3) @(posedge clk);
        #2;
        if (sent != TEST_BYTES || rx_data_reads != TEST_BYTES ||
            tx_accepted != TEST_BYTES || echoed != TEST_BYTES)
            $fatal(1, "UART RX count mismatch sent=%0d reads=%0d accepted=%0d echo=%0d",
                   sent, rx_data_reads, tx_accepted, echoed);
        if (rx_status_reads == 0 ||
            last_rx_status[15:8] !== 8'd0 ||
            last_rx_status[3:0] !== 4'b0000)
            $fatal(1, "RX FIFO/errors not clear at completion status=%h", last_rx_status);
        if (dut.uart_busy !== 1'b0 || uart_tx !== 1'b1)
            $fatal(1, "Echo firmware completed before TX drained");
        $display("UART RX: baud=%0d clocks_per_bit=%0d bytes=%0d RX_DATA reads=%0d",
                 BAUD, CLOCKS_PER_BIT, echoed, rx_data_reads);
        $display("PASS: CPU UART RX FIFO/MMIO and 32-byte physical serial echo; reset frames ignored");
        test_pass = 1;
        $stop;
    end
endmodule
