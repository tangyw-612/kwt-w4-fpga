`default_nettype none
module keyword_acc_top #(
    parameter bit COLOR_BARS = 0,
    parameter bit FULL_ENCODER = 0,
    parameter bit JTAG_DIAGNOSTICS = 0,
    parameter bit STEADY_BACKLIGHT = 0,
    parameter bit FRAMED_MAC_UART = 0,
    parameter bit AN970_LINK_UI = 0,
    parameter bit LIVE_KEYWORDS = 0,
    parameter int SERIAL_BAUD = 921600,
    parameter bit AN970_ENABLE = 1
)(
    input wire sys_clk_p, sys_clk_n, pl_key_n, uart_rx,
    output wire uart_tx, pl_led,
    output wire lcd_dclk, lcd_pwm, lcd_hs, lcd_vs, lcd_de,
    output wire [7:0] lcd_r, lcd_g, lcd_b
);
    wire clk, rst_n, panel_clock;
    board_clock #(.VENDOR_TIMING(STEADY_BACKLIGHT)) u_clock (.sys_clk_p(sys_clk_p), .sys_clk_n(sys_clk_n), .clk(clk),
                         .rst_n(rst_n), .lcd_dclk(panel_clock));
    assign lcd_dclk = AN970_ENABLE && panel_clock;

    wire key_pressed, rx_valid, rx_error, tx_valid, tx_ready;
    wire [7:0] rx_data, tx_data;
    wire result_valid, running, check_pass, accepted;
    wire [1:0] direction, match_count;
    wire [31:0] value0, value1, cycles;
    wire [3:0] layers_completed;
    wire jtag_valid;
    wire [1:0] jtag_direction;
    wire mac_result_event, uart_rejected;
    wire [15:0] rejected_sample;
    wire [9:0] live_sample;
    wire [127:0] live_wave;
    wire [1:0] live_status;
    wire [3:0] live_class;
    wire [31:0] live_cycles;

    board_key u_key (.clk(clk), .rst_n(rst_n), .key_n(pl_key_n), .pressed(key_pressed));
    uart_byte #(.BAUD(SERIAL_BAUD)) u_uart (
        .clk(clk), .rst_n(rst_n), .rx_pin(uart_rx), .rx_valid(rx_valid), .rx_error(rx_error),
        .rx_data(rx_data), .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_pin(uart_tx)
    );

    if (COLOR_BARS) begin : g_bars
        assign {result_valid, running, check_pass, accepted, tx_valid} = 0;
        assign {direction, match_count, value0, value1, cycles, layers_completed, tx_data} = 0;
        assign {mac_result_event, uart_rejected, rejected_sample} = 0;
    end else if (FULL_ENCODER) begin : g_full
        wire engine_rx_valid, engine_rx_error, engine_tx_valid, engine_tx_ready;
        wire engine_idle, engine_done, engine_ok, engine_start;
        wire [7:0] engine_tx_data;
        wire [3:0] engine_class;
        wire [31:0] engine_wait;
        encoder_uart_demo #(.LIVE_CLASSIFIER(LIVE_KEYWORDS)) u_demo (
            .clk(clk), .rst_n(rst_n), .key_pressed(key_pressed), .rx_valid(engine_rx_valid),
            .rx_error(engine_rx_error), .rx_data(rx_data), .tx_valid(engine_tx_valid), .tx_data(engine_tx_data),
            .tx_ready(engine_tx_ready), .running(running), .accepted(accepted), .result_valid(result_valid),
            .check_pass(check_pass), .direction(direction), .cycles(cycles), .layers_completed(layers_completed),
            .live_start(engine_start), .engine_idle(engine_idle), .live_done(engine_done),
            .live_ok(engine_ok), .live_class(engine_class), .wait_cycles(engine_wait)
        );
        if (LIVE_KEYWORDS) begin : g_live_uart
            keyword_live_uart u_live (
                .clk(clk), .rst_n(rst_n), .rx_valid(rx_valid), .rx_error(rx_error), .rx_data(rx_data),
                .tx_ready(tx_ready), .tx_valid(tx_valid), .tx_data(tx_data), .core_rx_valid(engine_rx_valid),
                .core_rx_error(engine_rx_error), .core_tx_ready(engine_tx_ready), .core_tx_valid(engine_tx_valid),
                .core_idle(engine_idle), .core_done(engine_done), .core_ok(engine_ok), .core_tx_data(engine_tx_data),
                .core_class(engine_class), .core_layers(layers_completed), .core_cycles(cycles), .core_wait(engine_wait),
                .start(engine_start), .sample_id(live_sample), .wave(live_wave), .display_status(live_status),
                .display_class(live_class), .display_cycles(live_cycles)
            );
        end else begin : g_plain_uart
            assign {engine_rx_valid, engine_rx_error, engine_tx_ready} = {rx_valid, rx_error, tx_ready};
            assign {tx_valid, tx_data} = {engine_tx_valid, engine_tx_data};
            assign engine_start = 0;
        end
        assign {match_count, value0, value1} = 0;
        assign {mac_result_event, uart_rejected, rejected_sample} = 0;
    end else begin : g_mac
        wire mac_rx_valid, mac_tx_valid, mac_tx_ready;
        wire [7:0] mac_rx_data, mac_tx_data;
        if (FRAMED_MAC_UART) begin : g_frames
            // 本地按键继续走原 MAC 控制，只有上位机发起的任务产生串口结果帧。
            assign mac_tx_ready = 1'b1;
            mac_uart_frame u_frame (
                .clk(clk), .rst_n(rst_n), .rx_valid(rx_valid), .rx_error(rx_error), .rx_data(rx_data),
                .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
                .mac_start(mac_rx_valid), .mac_command(mac_rx_data), .mac_busy(running),
                .rejected(uart_rejected), .rejected_sample(rejected_sample),
                .mac_done(mac_tx_valid), .mac_pass(check_pass), .mac_matches(match_count),
                .mac_cycles(cycles), .dot0(value0), .dot1(value1)
            );
        end else begin : g_legacy_uart
            assign {mac_rx_valid, mac_rx_data} = {rx_valid, rx_data};
            assign {tx_valid, tx_data} = {mac_tx_valid, mac_tx_data};
            assign mac_tx_ready = tx_ready;
            assign {uart_rejected, rejected_sample} = 0;
        end
        mac_demo_control u_demo (
            .clk(clk), .rst_n(rst_n), .key_pressed(key_pressed), .jtag_valid(jtag_valid),
            .jtag_direction(jtag_direction), .rx_valid(mac_rx_valid),
            .rx_data(mac_rx_data), .tx_valid(mac_tx_valid), .tx_data(mac_tx_data), .tx_ready(mac_tx_ready),
            .running(running), .accepted(accepted), .result_valid(result_valid), .check_pass(check_pass),
            .direction(direction), .match_count(match_count), .value0(value0), .value1(value1), .cycles(cycles)
        );
        assign layers_completed = 0;
        assign mac_result_event = mac_tx_valid;
    end
    assign pl_led = COLOR_BARS ? rst_n : result_valid && check_pass;

    wire [2:0] car_col, car_row;
    wire [39:0] trail;
    wire [10:0] x;
    wire [9:0] y;
    wire [23:0] pixel;
    wire frame_start;
    if (JTAG_DIAGNOSTICS) begin : g_diag
        logic toggle_sample;
        logic [18:0] pixels_counted, pixels_completed;
        logic [7:0] frame_count;
        wire [2:0] jtag_command;
        wire [7:0] jtag_status = {direction, match_count, result_valid, check_pass, running, pl_led};
        wire [26:0] jtag_video = {frame_count, pixels_completed};
        wire [5:0] jtag_position = {car_col, car_row};

        // 实板依次检查点积、车位和一帧的真实有效像素数。
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                toggle_sample <= 0;
                pixels_counted <= 0;
                pixels_completed <= 0;
                frame_count <= 0;
            end else begin
                toggle_sample <= jtag_command[2];
                if (frame_start) begin
                    pixels_completed <= pixels_counted;
                    pixels_counted <= 0;
                    frame_count <= frame_count + 1'b1;
                end else if (lcd_de) pixels_counted <= pixels_counted + 1'b1;
            end
        end
        assign jtag_valid = jtag_command[2] != toggle_sample;
        assign jtag_direction = jtag_command[1:0];
        mac_board_vio u_vio (.clk(clk), .probe_in0(jtag_status), .probe_in1(value0),
            .probe_in2(value1), .probe_in3(cycles), .probe_in4(jtag_video),
            .probe_in5(jtag_position), .probe_out0(jtag_command));
    end else begin : g_no_diag
        assign jtag_valid = 0;
        assign jtag_direction = 0;
    end
    rover_motion u_motion (.clk(clk), .rst_n(rst_n), .accepted(accepted), .direction(direction),
                           .car_col(car_col), .car_row(car_row), .trail(trail));
    if (!AN970_ENABLE) begin : g_no_display
        assign pixel = 0;
    end else if (FULL_ENCODER && LIVE_KEYWORDS) begin : g_keyword_ui
        an970_keyword_scene u_scene (
            .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .x(x), .y(y),
            .sample_id(live_sample), .wave(live_wave), .status(live_status),
            .class_id(live_class), .layers(layers_completed), .cycles(live_cycles), .pixel(pixel)
        );
    end else if (AN970_LINK_UI) begin : g_link_ui
        an970_link_scene u_scene (
            .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .x(x), .y(y),
            .mac_done(mac_result_event), .mac_pass(check_pass), .unsupported(uart_rejected),
            .rejected_sample(rejected_sample), .direction(direction), .matched(match_count),
            .value0(value0), .value1(value1), .cycles(cycles[7:0]), .pixel(pixel)
        );
    end else begin : g_rover_ui
        rover_scene #(.FULL_ENCODER(FULL_ENCODER), .COLOR_BARS(COLOR_BARS)) u_scene (
            .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .x(x), .y(y), .car_col(car_col),
            .car_row(car_row), .trail(trail), .result_valid(result_valid), .running(running),
            .check_pass(check_pass), .direction(direction), .match_count(match_count), .value0(value0),
            .value1(value1), .cycles(cycles), .layers_completed(layers_completed), .pixel(pixel)
        );
    end
    wire pwm, hs, vs, de;
    wire [23:0] rgb;
    // 禁用显示时固定屏口电平，保留编码器与串口的时钟。
    assign lcd_pwm = AN970_ENABLE && (STEADY_BACKLIGHT ? rst_n : pwm);
    assign {lcd_r, lcd_g, lcd_b, lcd_hs, lcd_vs, lcd_de} = AN970_ENABLE ? {rgb, hs, vs, de} : 27'b0;
    an970_raster #(.PIXEL_PIPELINED(AN970_LINK_UI || LIVE_KEYWORDS)) u_lcd (
        .clk(clk), .rst_n(rst_n && AN970_ENABLE), .pixel(pixel), .x(x), .y(y), .frame_start(frame_start),
        .rgb(rgb), .hs(hs), .vs(vs), .de(de), .backlight(pwm));
endmodule
`default_nettype wire
