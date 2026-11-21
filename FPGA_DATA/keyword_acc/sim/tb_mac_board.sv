`timescale 1ns/1ps
module board_clock #(parameter bit VENDOR_TIMING = 0) (
    input wire sys_clk_p, sys_clk_n,
    output wire clk, rst_n, lcd_dclk
);
    reg [3:0] reset_pipe = 0;
    always @(posedge sys_clk_p) reset_pipe <= {reset_pipe[2:0], 1'b1};
    assign clk = sys_clk_p;
    assign rst_n = reset_pipe[3];
    assign lcd_dclk = ~sys_clk_p;
endmodule

module tb_mac_board;
    reg clk = 0;
    always #15 clk = ~clk;
    reg tx_valid = 0;
    reg [7:0] tx_data = 0;
    wire tx_ready, serial_to_board, serial_from_board, rx_valid, rx_error;
    wire [7:0] rx_data;
    wire led, lcd_clk, lcd_pwm, lcd_hs, lcd_vs, lcd_de;
    wire [23:0] rgb;
    reg [63:0] expected [0:3];
    initial $readmemh("mac_expected.mem", expected);

    uart_byte u_host_uart (
        .clk(clk), .rst_n(dut.rst_n), .rx_pin(serial_from_board), .rx_valid(rx_valid),
        .rx_error(rx_error), .rx_data(rx_data), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_ready(tx_ready), .tx_pin(serial_to_board)
    );
    keyword_acc_top dut (
        .sys_clk_p(clk), .sys_clk_n(!clk), .pl_key_n(1'b1), .uart_rx(serial_to_board), .uart_tx(serial_from_board),
        .pl_led(led), .lcd_dclk(lcd_clk), .lcd_pwm(lcd_pwm), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs),
        .lcd_de(lcd_de), .lcd_r(rgb[23:16]), .lcd_g(rgb[15:8]), .lcd_b(rgb[7:0])
    );

    task automatic command(input [7:0] serial, input integer index, col, row);
        wait (tx_ready);
        @(negedge clk);
        tx_data = serial;
        tx_valid = 1;
        @(negedge clk);
        tx_valid = 0;
        wait (rx_valid);
        @(negedge clk);
        if (rx_data !== "P" || !led) $fatal(1,"UART acknowledgement or LED failed");
        if ({dut.value1, dut.value0} !== expected[index] || dut.match_count !== 2)
            $fatal(1,"MAC pair mismatch command=%0d got=%h%h", index, dut.value1, dut.value0);
        if ({dut.car_col, dut.car_row} !== {3'(col), 3'(row)}) $fatal(1,"Rover movement failed");
        $display("MAC_LCD_COMMAND_PASS cmd=%c dot0=%0d dot1=%0d cycles=%0d", serial,
                 $signed(dut.value0), $signed(dut.value1), dut.cycles);
    endtask

    integer pixels, hs_pulses, vs_lines;
    initial begin
        wait (dut.rst_n);
        command("R", 0, 3, 3);
        command("U", 1, 3, 2);
        command("L", 2, 2, 2);
        command("S", 3, 2, 2);
        wait (dut.x == 0 && dut.y == 0);
        // 光栅输出比坐标晚一拍，在完整一帧上统计物理显示口。
        pixels = 0;
        hs_pulses = 0;
        vs_lines = 0;
        repeat (1056*505) begin
            @(negedge clk);
            if (lcd_de) pixels++;
            if (!lcd_hs) hs_pulses++;
            if (!lcd_vs) vs_lines++;
            if (dut.x == 175 && dut.y == 249 && rgb !== 24'h75f0c9)
                $fatal(1,"Rover body pixel not rendered: %h", rgb);
        end
        if (pixels != 800*480 || hs_pulses != 128*505 || vs_lines != 3*1056)
            $fatal(1,"LCD timing mismatch: %0d %0d %0d", pixels, hs_pulses, vs_lines);
        $display("MAC_AN970_RTL_PASS active_pixels=%0d", pixels);
        $finish;
    end
    initial begin #40000000; $fatal(1,"MAC and LCD integration test timed out"); end
endmodule
