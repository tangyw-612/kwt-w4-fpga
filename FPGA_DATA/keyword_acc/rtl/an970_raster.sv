`default_nettype none
module an970_raster #(parameter bit PIXEL_PIPELINED = 0) (
    input  wire clk, rst_n,
    input  wire [23:0] pixel,
    output logic [10:0] x,
    output logic [9:0] y,
    output wire frame_start,
    output logic [23:0] rgb,
    output logic hs, vs, de, backlight
);
    // 对齐 ALINX 800×480 彩条例程的前肩、同步宽度和后肩。
    localparam int WIDTH = 800, HEIGHT = 480;
    localparam int H_TOTAL = 1056, V_TOTAL = 505;
    wire active = x < WIDTH && y < HEIGHT;
    wire hsync = !(x >= WIDTH + 40 && x < WIDTH + 40 + 128);
    wire vsync = !(y >= HEIGHT + 1 && y < HEIGHT + 1 + 3);
    logic active_q, hsync_q, vsync_q;
    wire output_active = PIXEL_PIPELINED ? active_q : active;
    assign frame_start = x == 0 && y == HEIGHT;
    logic [17:0] pwm_count;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            x <= 0;
            y <= 0;
            rgb <= 0;
            hs <= 1;
            vs <= 1;
            de <= 0;
            {active_q, hsync_q, vsync_q} <= 3'b011;
            pwm_count <= 0;
            backlight <= 0;
        end else begin
            if (x == H_TOTAL - 1) begin
                x <= 0;
                y <= y == V_TOTAL - 1 ? 0 : y + 1'b1;
            end else x <= x + 1'b1;

            // 标志和波形使用同步 ROM。新版界面的同步信号随像素增加一拍。
            {active_q, hsync_q, vsync_q} <= {active, hsync, vsync};
            rgb <= output_active ? pixel : 24'b0;
            hs <= PIXEL_PIPELINED ? hsync_q : hsync;
            vs <= PIXEL_PIPELINED ? vsync_q : vsync;
            de <= output_active;

            // 约 200 Hz、30% 占空比。
            pwm_count <= pwm_count == 18'd166666 ? 18'b0 : pwm_count + 1'b1;
            backlight <= pwm_count < 18'd50000;
        end
    end
endmodule
`default_nettype wire
