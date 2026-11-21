    // 概率最大为二的二十四次方，奇项概率与十七位值可在单个乘法器内相乘。
    // 查询键保留低十六位符号，投影保留原高低字拆分。
    wire signed [25:0] odd_a = s1_pv_pair
        ? {1'b0, s1_a_odd[24:0]}
        : s1_qk_pair ? {{10{s1_a_odd[15]}}, s1_a_odd[15:0]}
                     : {10'b0, s1_a_odd[15:0]};
    wire signed [16:0] b_odd = s1_b_odd[j*17 +: 17];
`ifdef W4_FIXED_MAC_DSP
    wire signed [43:0] odd_product_full;
    wire signed [42:0] odd_product = odd_product_full[42:0];
`ifdef W4_FORCE_PROJECTION_SIGN
    (* DONT_TOUCH = "yes" *)
`elsif W4_FORCE_B16_SIGN
    (* DONT_TOUCH = "yes" *)
`endif
    w4_dsp_mul27x17 #(.B_SIGN_BIT(WEIGHT_SIGN_BIT), .SELECT_W4_SIGN(SELECT_W4_SIGN)) u_odd_low(
      .clk, .enable(s1_v && s1_pair), .projection(!narrow_activation), .a({odd_a[25], odd_a}),
      .b(b_odd), .product(odd_product_full));
`else
    (* keep = "true", use_dsp = "yes" *) logic signed [42:0] odd_product;
    always_ff @(posedge clk) if (s1_v && s1_pair) odd_product <= odd_a * b_odd;
`endif
    (* use_dsp = "no" *) logic signed [19:0] odd_hi;
    always_ff @(posedge clk) if (s1_v && s1_pair && !s1_pv_pair && !s1_qk_pair)
      odd_hi <= $signed(s1_a_odd[31:16]) * $signed(b_odd[3:0]);
`ifdef W4_FIXED_MAC_DSP
    wire [43:0] odd_low_extended = {odd_product[42], odd_product};
    wire [43:0] odd_high_shifted = {{8{odd_hi[19]}}, odd_hi, 16'b0};
    wire signed [ACC_W-1:0] odd_full = odd_low_extended +
      ((s2_qk_pair || s2_pv_pair) ? 44'd0 : odd_high_shifted);
    wire signed [41:0] s2_odd = odd_full[41:0];
`else
    wire signed [41:0] s2_odd = 42'(odd_product) + ((s2_qk_pair || s2_pv_pair)
        ? 42'sd0 : (42'(odd_hi) <<< 16));
`endif
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && s1_v && s1_pair && s1_pv_pair &&
        s1_a_odd[31:25] !== 7'd0)
      $fatal(1, "值乘法的奇项概率超过表示范围");
`endif
