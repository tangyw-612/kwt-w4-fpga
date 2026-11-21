`timescale 1ns/1ps

module tb_kwt_power #(parameter bit AN970_ENABLE = 1)(output wire capture);
    localparam int PAYLOAD_BYTES = 400696;
    localparam int BLOCK_BYTES = 1024;
    logic sys_clk_p = 0;
    always #2.5 sys_clk_p = ~sys_clk_p;
    keyword_acc_top #(.FULL_ENCODER(1), .LIVE_KEYWORDS(1), .AN970_ENABLE(AN970_ENABLE)) dut (
        .sys_clk_p, .sys_clk_n(~sys_clk_p), .pl_key_n(1'b1), .uart_rx(1'b1)
    );
    wire sample_frame_start;
    if (AN970_ENABLE) begin : g_display_timing
        assign sample_frame_start = dut.frame_start;
    end else begin : g_reference_timing
        // 关闭显示时只在测试平台生成帧边界，保证两版的同一采样时序。
        an970_raster u_timing (.clk(dut.clk), .rst_n(dut.rst_n), .pixel(24'b0), .frame_start(sample_frame_start));
    end

    logic rx_valid = 0;
    logic [7:0] rx_data = 0;
    logic [7:0] payload [0:PAYLOAD_BYTES-1];
    logic [7:0] header [0:21];
    logic [7:0] reply [0:15];
    logic [7:0] expected [0:25343];
    int credits = 0, reply_bytes = 0, words = 0;
    int captured_encoder_cycles = 0, captured_head_cycles = 0, captured_idle_cycles = 0;
    bit idle_mode, idle_window = 0;
    string inputs;

    // 与编码器有效周期的口径一致，排除实际等待参数的 S_WAITP。
    wire encoder_window = dut.g_full.u_demo.u_encoder.u_core.busy &&
        (dut.g_full.u_demo.u_encoder.u_core.st != 5'd1 ||
         dut.g_full.u_demo.u_encoder.u_core.next_ready);
    wire classifier_window = dut.g_full.u_demo.state == 4'd14 &&
        !dut.g_full.u_demo.head_valid;
    always @(negedge dut.clk) begin
        capture_cycle <= idle_mode ? idle_window : encoder_window || classifier_window;
    end
    logic capture_cycle = 0;
    assign capture = capture_cycle;

    always @(posedge dut.clk) begin
        if (!AN970_ENABLE && {dut.lcd_dclk, dut.lcd_pwm, dut.lcd_hs, dut.lcd_vs, dut.lcd_de,
                              dut.lcd_r, dut.lcd_g, dut.lcd_b} !== 29'b0)
            $fatal(1, "关闭显示时屏口必须保持低电平");
        if (capture_cycle) begin
            if (idle_mode) captured_idle_cycles++;
            else if (encoder_window) captured_encoder_cycles++;
            else if (classifier_window) captured_head_cycles++;
        end
        if (dut.tx_valid && dut.tx_ready) begin
            if (credits < (PAYLOAD_BYTES + BLOCK_BYTES - 1) / BLOCK_BYTES) begin
                if (dut.tx_data != "G") $fatal(1, "载荷许可异常");
                credits++;
            end else if (reply_bytes < 16) begin
                reply[reply_bytes] = dut.tx_data;
                reply_bytes++;
            end
        end
        if (dut.g_full.u_demo.state == 4'd14 && dut.g_full.u_demo.core_out_valid) begin
            if (words >= 6336 || dut.g_full.u_demo.core_out_data !==
                {expected[4*words+3], expected[4*words+2], expected[4*words+1], expected[4*words]})
                $fatal(1, "末层回读与参考不同，字号 %d", words);
            words++;
        end
    end

    task automatic send_byte(input logic [7:0] data, input bit pause_for_encoding);
        @(negedge dut.clk);
        rx_valid = 0;
        while (pause_for_encoding && encoder_window) @(negedge dut.clk);
        rx_data = data;
        rx_valid = 1;
    endtask

    initial begin
        int fd;
        logic [31:0] reported, waiting;
        idle_mode = $test$plusargs("idle");
        if (!$value$plusargs("inputs=%s", inputs)) $fatal(1, "缺少仿真输入目录");
        fd = $fopen({inputs,"/payload.bin"}, "rb");
        if (!fd || $fread(payload, fd) != PAYLOAD_BYTES) $fatal(1, "载荷长度异常");
        $fclose(fd);
        fd = $fopen({inputs,"/header.bin"}, "rb");
        if (!fd || $fread(header, fd) != 22) $fatal(1, "请求字头长度异常");
        $fclose(fd);
        fd = $fopen({inputs,"/golden.bin"}, "rb");
        if (!fd || $fread(expected, fd) != 25344) $fatal(1, "末层参考长度异常");
        $fclose(fd);

        // 跳过串口逐位传输，保留原有块许可、收包、数值计算和屏幕状态机。
        force dut.rx_valid = rx_valid;
        force dut.rx_data = rx_data;
        force dut.tx_ready = 1'b1;
        wait (dut.rst_n);
        for (int i = 0; i < 22; i++) send_byte(header[i], 0);
        @(negedge dut.clk);
        rx_valid = 0;
        @(posedge sample_frame_start);
        for (int i = 0; i < PAYLOAD_BYTES; i++) begin
            if ((i % BLOCK_BYTES) == 0) wait (credits > i / BLOCK_BYTES);
            send_byte(payload[i], 1);
            if ((i % BLOCK_BYTES) == BLOCK_BYTES-1 || i == PAYLOAD_BYTES-1) begin
                @(negedge dut.clk);
                rx_valid = 0;
            end
        end
        wait (reply_bytes == 16);
        @(negedge dut.clk);
        reported = {reply[10], reply[9], reply[8], reply[7]};
        waiting = {reply[14], reply[13], reply[12], reply[11]};
        if (reply[0] != "R" || {reply[4],reply[3]} != 250 || reply[5] != 7 || reply[6] != 12 ||
            words != 6336 || reported - waiting != 965557)
            $fatal(1, "W4 推理回执不匹配，层数=%d 分类=%d 活跃=%d 输出=%d",
                   reply[6], reply[5], reported - waiting, words);
        if (idle_mode) begin
            // 等结果锁存到显示帧后，记录两个完整帧的稳定待机活动。
            @(posedge sample_frame_start);
            @(negedge dut.clk);
            idle_window = 1;
            repeat (1066560) @(negedge dut.clk);
            idle_window = 0;
            repeat (2) @(negedge dut.clk);
            if (captured_idle_cycles != 1066560) $fatal(1, "待机窗口计数异常 %d", captured_idle_cycles);
        end else if (captured_encoder_cycles != 965557 || captured_head_cycles <= 0)
            $fatal(1, "活跃窗口计数异常 %d / %d", captured_encoder_cycles, captured_head_cycles);
        $display("POWER_TRACE_PASS sample=250 words=%0d layers=%0d class=%0d encoder=%0d classifier=%0d idle=%0d",
                 words, reply[6], reply[5], captured_encoder_cycles, captured_head_cycles, captured_idle_cycles);
        $finish;
    end

    initial begin
        #160000000;
        $fatal(1, "功耗仿真超时，已收许可 %d，回执 %d 字节",credits,reply_bytes);
    end
endmodule
