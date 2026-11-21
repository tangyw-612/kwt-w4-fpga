    // 用显式符号位计算八倍插值，避免负表值被当作无符号数。
    wire signed [32:0] interp_delta = {b[31], b} - {a[31], a};
    wire signed [3:0] interp_fraction = {1'b0, remainder_q};
    wire signed [36:0] interp_product = interp_delta * interp_fraction;
    assign interpolation = {{5{a[31]}}, a, 3'b0} + {{3{interp_product[36]}}, interp_product};
