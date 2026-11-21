    // 注意力输入已经小于二十七位。投影输入的高六位只乘四位权重。
    wire narrow_activation = s1_qk_pair || s1_pv_pair;
    wire signed [26:0] even_a_low = narrow_activation
        ? $signed(s1_a[26:0]) : $signed({1'b0, s1_a[25:0]});
`ifdef W4_FIXED_MAC_DSP
    wire signed [43:0] even_low_product;
`ifdef W4_FORCE_PROJECTION_SIGN
    localparam int WEIGHT_SIGN_BIT = 15;
    localparam bit SELECT_W4_SIGN = 1;
    (* DONT_TOUCH = "yes" *)
`elsif W4_FORCE_B16_SIGN
    // W4 的权重、查询键和值始终适合有符号十六位，保护此模式下的原语连线。
    localparam int WEIGHT_SIGN_BIT = 15;
    localparam bit SELECT_W4_SIGN = 0;
    (* DONT_TOUCH = "yes" *)
`else
    localparam int WEIGHT_SIGN_BIT = 16;
    localparam bit SELECT_W4_SIGN = 0;
`endif
    w4_dsp_mul27x17 #(.B_SIGN_BIT(WEIGHT_SIGN_BIT), .SELECT_W4_SIGN(SELECT_W4_SIGN)) u_even_low(
      .clk, .enable(s1_v), .projection(!narrow_activation), .a(even_a_low), .b(bj), .product(even_low_product));
`else
    (* use_dsp = "yes" *) logic signed [43:0] even_low_product;
    always_ff @(posedge clk) if (s1_v) even_low_product <= even_a_low * bj;
`endif
    (* use_dsp = "no" *) logic signed [9:0] even_high_product;
    always_ff @(posedge clk) if (s1_v)
      even_high_product <= $signed(s1_a[31:26]) * $signed(bj[3:0]);
`ifdef W4_FIXED_MAC_DSP
    wire [48:0] even_low_extended = {{5{even_low_product[43]}}, even_low_product};
    wire [48:0] even_high_shifted = {{13{even_high_product[9]}}, even_high_product, 26'b0};
    assign s2_p[j] = even_low_extended + ((s2_qk_pair || s2_pv_pair) ? 49'd0 : even_high_shifted);
`else
    assign s2_p[j] = 49'(even_low_product) + ((s2_qk_pair || s2_pv_pair)
        ? 49'sd0 : (49'(even_high_product) <<< 26));
`endif
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && s1_v) begin
      if (narrow_activation && s1_a !== 32'($signed(s1_a[26:0])))
        $fatal(1, "注意力偶项激活超过二十七位");
      if (!narrow_activation && bj !== 17'($signed(bj[3:0])))
        $fatal(1, "投影偶项权重超过四位");
    end
`endif
