  // 通道重定标乘积单独进 DSP，保留累加值低字的无符号扩展和高字符号。
  wire [43:0] scaled_low_full, scaled_high_full;
  wire signed [35:0] prod_lo = scaled_low_full[35:0];
  wire signed [34:0] prod_hi = scaled_high_full[34:0];
  wire multiply_scale = scale_valid && channel_scale != 13'sd1;
  w4_dsp_mul27x17 u_scale_low(.clk, .enable(multiply_scale), .projection(1'b0),
    .a({5'b0, scale_acc[21:0]}), .b({{4{channel_scale[12]}}, channel_scale}), .product(scaled_low_full));
  w4_dsp_mul27x17 u_scale_high(.clk, .enable(multiply_scale), .projection(1'b0),
    .a({{5{scale_acc[43]}}, scale_acc[43:22]}),
    .b({{4{channel_scale[12]}}, channel_scale}), .product(scaled_high_full));
  wire signed [63:0] full_product = {{28{prod_lo[35]}}, prod_lo} +
    {{7{prod_hi[34]}}, prod_hi, 22'b0};
