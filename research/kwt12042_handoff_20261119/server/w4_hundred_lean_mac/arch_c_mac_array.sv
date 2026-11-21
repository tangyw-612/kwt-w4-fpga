// Architecture C exploration: L-lane shared MAC array + serial drain/rescale.
// Lane: signed 32 (broadcast A) x signed 17 (per-lane B; lo half zero-extended,
// hi half sign-extended) -> 49b product, optional <<16, 64b accumulate, shadow.
// Drain: shadow[idx] + bias(64b) -> round-half-away rescale by 2^shift -> sat32/sat16.
// Not a production module; area/timing anchor for the cycle/area model.
module arch_c_mac_array #(parameter int L = 32) (
  input  logic               clk, rst_n,
  // compute stream (one element of the reduction per cycle)
  input  logic               in_valid,
  input  logic               in_first,      // first term of this accumulation
  input  logic               in_last,       // last term: copy result into shadow
  input  logic               in_hi,         // B is the high half: product << 16
  input  logic signed [31:0] in_a,
  input  logic        [L*17-1:0] in_b,      // lane j: in_b[j*17 +: 17]
  input  logic               in_pair, in_qk_pair, in_pv_pair,
  input  logic signed [31:0] in_a_odd,
  input  logic        [L*17-1:0] in_b_odd,
  // drain (one output per cycle)
  input  logic               dr_valid,
  input  logic [$clog2(L)-1:0] dr_idx,
  input  logic signed [63:0] dr_bias,
  input  logic        [15:0] dr_scale,
  input  logic        [5:0]  dr_shift,
  input  logic               dr_sat16,
  output logic               out_valid,
  output logic signed [31:0] out_data
);
  // ---- stage 1: register operands
  logic s1_v, s1_first, s1_last, s1_hi;
  logic signed [31:0] s1_a;
  logic [L*17-1:0] s1_b;
  logic s1_pair, s2_pair, s1_qk_pair, s2_qk_pair, s1_pv_pair, s2_pv_pair;
  logic signed [31:0] s1_a_odd;
  logic [L*17-1:0] s1_b_odd;
  always_ff @(posedge clk) begin
    if (in_valid) begin s1_pair <= in_pair; s1_qk_pair <= in_qk_pair; s1_pv_pair <= in_pv_pair; end
    if (in_valid && in_pair) begin s1_a_odd <= in_a_odd; s1_b_odd <= in_b_odd; end
    if (s1_v) begin s2_pair <= s1_pair; s2_qk_pair <= s1_qk_pair; s2_pv_pair <= s1_pv_pair; end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin s1_v <= 1'b0; s1_first <= 1'b0; s1_last <= 1'b0; s1_hi <= 1'b0; end
    else begin s1_v <= in_valid; s1_first <= in_first; s1_last <= in_last; s1_hi <= in_hi; end
  always_ff @(posedge clk) if (in_valid) begin s1_a <= in_a; s1_b <= in_b; end

  // ---- stage 2: multiply
  logic s2_v, s2_first, s2_last, s2_hi;
  logic signed [48:0] s2_p [L];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin s2_v <= 1'b0; s2_first <= 1'b0; s2_last <= 1'b0; s2_hi <= 1'b0; end
    else begin s2_v <= s1_v; s2_first <= s1_first; s2_last <= s1_last; s2_hi <= s1_hi; end

  // ---- stage 3: accumulate; shadow capture on last
  // W4 点积至多 256 项，绝对值至多 2^42。
  // QK 的 64 项均为 16 位有符号数。P×V 的非负概率之和为 2^24，V 为 16 位。
  localparam int ACC_W = 44;
  logic signed [ACC_W-1:0] acc [L];
  logic signed [ACC_W-1:0] shadow [L];
  for (genvar j = 0; j < L; j++) begin : g_lane
    wire signed [16:0] bj = s1_b[j*17 +: 17];
    always_ff @(posedge clk) if (s1_v) s2_p[j] <= s1_a * bj;
    logic signed [33:0] odd_lo;
    logic signed [19:0] odd_hi;
    logic signed [26:0] pv_hi;
    wire signed [16:0] a_lo = $signed({s1_qk_pair && s1_a_odd[15], s1_a_odd[15:0]});
    wire signed [16:0] b_odd = s1_b_odd[j*17 +: 17];
    always_ff @(posedge clk) if (s1_v && s1_pair) begin
      odd_lo <= a_lo * b_odd;
      if (s1_pv_pair) pv_hi <= $signed({1'b0, s1_a_odd[24:16]}) * b_odd;
      else if (!s1_qk_pair) odd_hi <= $signed(s1_a_odd[31:16]) * $signed(b_odd[3:0]);
    end
    wire signed [41:0] high_term = s2_qk_pair ? 42'sd0 : (s2_pv_pair ? 42'(pv_hi) : 42'(odd_hi));
    wire signed [41:0] s2_odd = 42'(odd_lo) + (high_term <<< 16);
    wire signed [ACC_W-1:0] previous = s2_first ? '0 : acc[j];
    wire signed [ACC_W-1:0] even_term = ACC_W'(s2_p[j]);
    wire signed [ACC_W-1:0] odd_term = s2_pair ? ACC_W'(s2_odd) : '0;
    wire [ACC_W-1:0] sum_bits = previous ^ even_term ^ odd_term;
    wire [ACC_W-1:0] carry_bits = ((previous & even_term) | (previous & odd_term) | (even_term & odd_term)) << 1;
    wire signed [ACC_W-1:0] nxt = sum_bits + carry_bits;
`ifndef SYNTHESIS
    wire signed [65:0] check_sum = 66'(previous) + 66'(s2_p[j]) + (s2_pair ? 66'(s2_odd) : 66'sd0);
    always @(posedge clk) if (rst_n && s2_v && (s2_hi || check_sum !== 66'(nxt)))
      $fatal(1, "W4 dot accumulator bound exceeded in lane %0d", j);
`endif
    always_ff @(posedge clk) if (s2_v) begin
      acc[j] <= nxt;
      if (s2_last) shadow[j] <= nxt;
    end
  end

  // 选中累加值，再用两个较窄的有符号乘法恢复尺度。
  logic scale_valid, prod_valid, d1_v;
  logic scale_sat16, prod_sat16, d1_sat16;
  logic [5:0] scale_shift, prod_shift, d1_shift;
  logic signed [63:0] scale_acc, scale_bias, prod_acc, prod_bias, d1_val;
  logic signed [12:0] channel_scale;
  logic prod_bypass;
  logic signed [35:0] prod_lo;
  logic signed [34:0] prod_hi;
  wire signed [63:0] full_product = 64'(prod_lo) + (64'(prod_hi) <<< 22);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin scale_valid <= 0; prod_valid <= 0; d1_v <= 0; end
    else begin scale_valid <= dr_valid; prod_valid <= scale_valid; d1_v <= prod_valid; end
  end
  always_ff @(posedge clk) begin
    if (dr_valid) begin
      scale_acc <= 64'(shadow[dr_idx]);
      scale_bias <= dr_bias;
      channel_scale <= $signed({1'b0, dr_scale[11:0]});
      scale_shift <= dr_shift;
      scale_sat16 <= dr_sat16;
    end
    if (scale_valid) begin
      prod_bypass <= channel_scale == 13'sd1;
      prod_acc <= scale_acc;
      prod_bias <= scale_bias;
      prod_shift <= scale_shift;
      prod_sat16 <= scale_sat16;
      if (channel_scale != 13'sd1) begin
        prod_lo <= $signed({1'b0, scale_acc[21:0]}) * channel_scale;
        prod_hi <= $signed(scale_acc[43:22]) * channel_scale;
      end
    end
    if (prod_valid) begin
      d1_val <= (prod_bypass ? prod_acc : full_product) + prod_bias;
      d1_shift <= prod_shift;
      d1_sat16 <= prod_sat16;
    end
  end
  // ---- D2: magnitude + rounding shift
  logic d2_v, d2_neg, d2_sat16; logic [63:0] d2_q;
  wire [63:0] mag  = d1_val[63] ? (~d1_val + 64'd1) : d1_val;
  wire [63:0] half = (d1_shift == 6'd0) ? 64'd0 : (64'd1 << (d1_shift - 6'd1));
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) d2_v <= 1'b0; else d2_v <= d1_v;
  always_ff @(posedge clk) if (d1_v) begin
    d2_q <= (mag + half) >> d1_shift; d2_neg <= d1_val[63]; d2_sat16 <= d1_sat16;
  end
  // ---- D3: sign restore + saturate
  wire signed [64:0] sv = d2_neg ? -$signed({1'b0, d2_q}) : $signed({1'b0, d2_q});
  wire signed [64:0] hi_lim = d2_sat16 ? 65'sd32767  : 65'sd2147483647;
  wire signed [64:0] lo_lim = d2_sat16 ? -65'sd32768 : -65'sd2147483648;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) out_valid <= 1'b0; else out_valid <= d2_v;
  always_ff @(posedge clk) if (d2_v)
    out_data <= (sv > hi_lim) ? hi_lim[31:0] : (sv < lo_lim) ? lo_lim[31:0] : sv[31:0];
endmodule
