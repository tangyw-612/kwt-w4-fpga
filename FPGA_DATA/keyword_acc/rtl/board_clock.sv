`default_nettype none
module board_clock #(
    parameter bit VENDOR_TIMING = 0
)(
    input  wire sys_clk_p, sys_clk_n,
    output wire clk, rst_n, lcd_dclk
);
    wire input_clock, feedback_clock, feedback_buffered, pixel_clock, locked;
    (* ASYNC_REG = "TRUE" *) reg [3:0] reset_pipe = 0;

    // 两个功能共用一个时钟域，差分输入取自板上的 200 MHz 晶振。
    IBUFDS u_input (.I(sys_clk_p), .IB(sys_clk_n), .O(input_clock));
    MMCME4_BASE #(
        .CLKIN1_PERIOD(5.0), .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(VENDOR_TIMING ? 6.250 : 5.0),
        .CLKOUT0_DIVIDE_F(VENDOR_TIMING ? 37.875 : 30.0)
    ) u_mmcm (
        .CLKIN1(input_clock), .CLKFBIN(feedback_buffered),
        .CLKFBOUT(feedback_clock), .CLKOUT0(pixel_clock),
        .LOCKED(locked), .RST(1'b0), .PWRDWN(1'b0)
    );
    BUFG u_feedback (.I(feedback_clock), .O(feedback_buffered));
    BUFG u_pixel (.I(pixel_clock), .O(clk));
    always @(posedge clk or negedge locked)
        if (!locked) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[2:0], 1'b1};
    assign rst_n = reset_pipe[3];

    // 显示数据在上升沿推出，屏幕在半拍后的时钟上升沿采样。
    ODDRE1 u_panel_clock (.C(clk), .D1(1'b0), .D2(1'b1), .SR(1'b0), .Q(lcd_dclk));
endmodule
`default_nettype wire
