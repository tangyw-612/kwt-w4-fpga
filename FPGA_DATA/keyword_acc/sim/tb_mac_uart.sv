`timescale 1ns/1ps
module tb_mac_uart #(parameter bit CAPTURE_AN970 = 0);
    reg clk = 0;
    always #15 clk = ~clk;
    reg tx_valid = 0;
    reg [7:0] tx_data = 0;
    wire tx_ready, host_tx, board_tx, rx_valid, rx_error;
    wire [7:0] rx_data;
    wire lcd_de;
    wire [23:0] lcd_rgb;
    reg [63:0] expected [0:3];
    reg [7:0] reply [0:20];
    reg reject_reply = 0;

    initial $readmemh("mac_expected.mem", expected);
    uart_byte u_host_uart (
        .clk(clk), .rst_n(dut.rst_n), .rx_pin(board_tx), .rx_valid(rx_valid),
        .rx_error(rx_error), .rx_data(rx_data), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_ready(tx_ready), .tx_pin(host_tx)
    );
    keyword_acc_top #(.FRAMED_MAC_UART(1), .AN970_LINK_UI(CAPTURE_AN970)) dut (
        .sys_clk_p(clk), .sys_clk_n(!clk), .pl_key_n(1'b1), .uart_rx(host_tx), .uart_tx(board_tx),
        .lcd_de(lcd_de), .lcd_r(lcd_rgb[23:16]), .lcd_g(lcd_rgb[15:8]), .lcd_b(lcd_rgb[7:0])
    );

    task automatic send_byte(input [7:0] value);
        wait (tx_ready);
        @(negedge clk);
        tx_data = value;
        tx_valid = 1;
        @(negedge clk);
        tx_valid = 0;
    endtask

    task automatic capture_frame(input string filename, input bit expect_wave);
        integer file_id, pixels, wave_pixels;
        wait (dut.frame_start);
        wait (dut.x == 0 && dut.y == 0);
        file_id = $fopen(filename, "wb");
        if (file_id == 0) $fatal(1, "无法写出 AN970 预览帧");
        $fwrite(file_id, "P6\n800 480\n255\n");
        pixels = 0;
        wave_pixels = 0;
        repeat (1056 * 505) begin
            @(negedge clk);
            if (lcd_de) begin
                if (^lcd_rgb === 1'bx) $fatal(1, "AN970 像素出现未知态");
                $fwrite(file_id, "%c%c%c", lcd_rgb[23:16], lcd_rgb[15:8], lcd_rgb[7:0]);
                pixels++;
                if (lcd_rgb == 24'h1885a7) wave_pixels++;
            end
        end
        $fclose(file_id);
        if (pixels != 800*480 || (wave_pixels > 0) !== expect_wave)
            $fatal(1, "AN970 像素或波形偏差 pixels=%0d wave=%0d", pixels, wave_pixels);
        $display("AN970_FRAME_PASS name=%s pixels=%0d wave=%0d", filename, pixels, wave_pixels);
    endtask

    task automatic send_packet(input [15:0] sample, token, input [7:0] checksum_corruption);
        send_byte(8'hA5);
        send_byte(token[7:0]);
        send_byte(token[15:8]);
        send_byte(sample[7:0]);
        send_byte(sample[15:8]);
        send_byte(8'hA5 ^ token[7:0] ^ token[15:8] ^ sample[7:0] ^ sample[15:8] ^ checksum_corruption);
    endtask

    task automatic exercise(input [15:0] sample, token, input [7:0] status, input integer expected_index);
        reg [7:0] check;
        reg [159:0] payload;
        fork
            send_packet(sample, token, 0);
            begin
                for (integer index = 0; index < 21; index++) begin
                    @(posedge rx_valid);
                    @(negedge clk);
                    reply[index] = rx_data;
                end
            end
        join

        check = reply[20];
        for (integer index = 0; index < 20; index++) begin
            check ^= reply[index];
            payload[8*index +: 8] = reply[index];
        end
        if (check !== 0 || payload[55:0] !== {status, sample, token, 8'h01, 8'h5A})
            $fatal(1, "UART 回执帧格式错误 sample=%0d", sample);
        if (status == 0) begin
            if (payload[159:96] !== expected[expected_index] || payload[95:64] !== 32'd41
                    || payload[63:56] !== 8'd2)
                $fatal(1, "UART 回传的点积或周期不符 sample=%0d", sample);
        end else if (payload[159:56] !== 0)
            $fatal(1, "非计算回执的点积字段非零 sample=%0d", sample);
        $display("J8_RTL_RESULT sample=%0d status=%0d matches=%0d cycles=%0d", sample, status,
                 payload[63:56], payload[95:64]);
    endtask

    always @(posedge clk) begin
        if (rx_error) $fatal(1, "模拟串口帧错误");
        if (reject_reply && rx_valid) $fatal(1, "损坏的请求不应有回执");
    end

    initial begin
        wait (dut.rst_n);
        exercise(16'hFFFF, 16'hD7C3, 8'h10, 0);
        exercise(100, 16'h1A25, 0, 1);
        if (CAPTURE_AN970) capture_frame("an970_sample_100.ppm", 1);
        exercise(200, 16'h5AA5, 0, 2);
        exercise(250, 16'h0089, 0, 0);
        exercise(400, 16'h5321, 0, 3);
        exercise(599, 16'hFFFF, 2, 0);
        if (CAPTURE_AN970) capture_frame("an970_sample_599.ppm", 0);
        if (CAPTURE_AN970) begin
            exercise(138, 16'h529B, 2, 0);
            capture_frame("an970_sample_138.ppm", 1);
        end
        // 等待最后一个正常回执的有效脉冲撤销，再监视坏帧。
        if (rx_valid) @(negedge rx_valid);
        reject_reply = 1;
        send_packet(100, 16'h1111, 8'h01);
        repeat (9000) @(posedge clk);
        send_byte(8'hA5);
        repeat (67000) @(posedge clk);
        reject_reply = 0;
        exercise(100, 16'hBACA, 0, 1);
        send_byte("U");
        @(posedge rx_valid);
        if (rx_data !== "P") $fatal(1, "原单字节命令不兼容");
        $display("J8_RTL_PASS");
        $finish;
    end

    initial begin #(CAPTURE_AN970 ? 140000000 : 12000000); $fatal(1, "J8 RTL 验收超时"); end
endmodule

module tb_an970_link;
    tb_mac_uart #(.CAPTURE_AN970(1)) u_test ();
endmodule
