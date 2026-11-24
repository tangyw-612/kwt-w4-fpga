// Arch C M2a: 12-layer encoder, single 32-lane MAC array, serial schedule, ping-pong parameter banks.
// Next-layer parameters stream in through ld_* (with backpressure) while the current layer computes;
// a COMMIT word (region 10) marks them complete; the layer boundary swaps W_att half / W_ffn bank /
// bias half / shift config and copies LN gamma/beta from the bias staging area into the LN units.
// Numeric contract = I09C frozen integer model (bit-exact). Reuses I09C units:
// attention_softmax, attention_table_ihp, ffn_gelu_ihp, linear_requantize; LN = ac_ln_stream (dual-set copy of ln_top_stream).
//
// Phase order: KV (K,V for 99 keys) -> per query row i:
//   Q -> QK -> softmax -> PV -> O(+o_b) -> LN1(x+attn) -> FFN1(+b1,GELU) -> FFN2(+b2) -> LN2(n1+f2) -> X[i]
// Load port (idle only): ld_word = {region[63:60], addr[59:32], data[31:0]} (see m1/gen_vectors.py).
`default_nettype none
module ac_enc #(parameter int L = 32) (
  input  wire        clk, rst_n,
  input  wire        ld_valid,
  output logic       ld_ready,
  input  wire [63:0] ld_word,
  input  wire        start,
  output logic       busy, done,
  output logic [31:0] cycles, wait_cycles,
  output logic [3:0] cur_layer,
  output logic       next_free,
  input  wire        xr_valid,
  input  wire [12:0] xr_addr,
  output wire [31:0] xr_data,
  output logic       layer_done,
  // debug streams (stage taps): dbg0 = MAC drain / LN norm / softmax prob, dbg1 = GELU / LN residual
  output logic       dbg0_valid, dbg1_valid,
  output logic [3:0] dbg0_kind, dbg1_kind,
  output logic [6:0] dbg0_row, dbg1_row,
  output logic [7:0] dbg0_idx, dbg1_idx,
  output logic [31:0] dbg0_data, dbg1_data
);
  localparam int LW = $clog2(L);
  // destination / debug kinds
  localparam logic [3:0] D_K = 0, D_V = 1, D_Q = 2, D_S = 3, D_P = 4, D_C = 5, D_O = 6, D_R1 = 7,
                         D_N1 = 8, D_F1 = 9, D_G = 10, D_F2 = 11, D_R2 = 12, D_OUT = 13;
  localparam logic [2:0] A_X = 0, A_QC = 1, A_P = 2, A_F1 = 3, A_H = 4;
  localparam logic [1:0] B_WATT = 0, B_WFFN = 1, B_KV = 2;

  typedef struct packed {
    logic [2:0]  asrc;
    logic [1:0]  bsrc;
    logic        split;
    logic [8:0]  nterm;   // terms - 1
    logic [9:0]  bbase;
    logic [12:0] abase;
    logic [3:0]  dest;
    logic [6:0]  row;
    logic [2:0]  g;
    logic [5:0]  nout;    // valid lanes (1..32)
    logic [5:0]  shift;
    logic        sat16;
    logic        bias_en;
    logic [8:0]  bbias;
  } pass_t;

  // ---------------------------------------------------------------- load decode
  wire [3:0]  ld_reg  = ld_word[63:60];
  wire [27:0] ld_addr = ld_word[59:32];
  wire [31:0] ld_data = ld_word[31:0];
  wire ld = ld_valid && ld_ready;
  logic att_sel, ffn_sel, bias_sel, next_ready, swap;   // *_sel = bank used by the current layer
  logic [5:0] sh_q, sh_k, sh_v, sh_o, sh_f2, nx_q, nx_k, nx_v, nx_o, nx_f2;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin {sh_q, sh_k, sh_v, sh_o, sh_f2, nx_q, nx_k, nx_v, nx_o, nx_f2} <= '0; next_ready <= 0; end
    else begin
      if (ld && ld_reg == 4'd9)
        case (ld_addr[2:0])
          3'd0: nx_q <= ld_data[5:0]; 3'd1: nx_k <= ld_data[5:0]; 3'd2: nx_v <= ld_data[5:0];
          3'd3: nx_o <= ld_data[5:0]; default: nx_f2 <= ld_data[5:0];
        endcase
      if (ld && ld_reg == 4'd10) next_ready <= 1;
      if (swap) begin
        {sh_q, sh_k, sh_v, sh_o, sh_f2} <= {nx_q, nx_k, nx_v, nx_o, nx_f2};
        next_ready <= 0;
      end
    end
  assign next_free = !next_ready;
`ifndef SYNTHESIS
  // MODE B guard: a parameter load may only target the idle bank. Writes are refused while the idle bank
  // still holds committed, unconsumed parameters (next_ready), and the bank select must not swap mid-load.
  logic b_loading;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) b_loading <= 1'b0;
    else if (ld && ld_reg == 4'd10) b_loading <= 1'b0;
    else if (ld && (ld_reg == 4'd2 || ld_reg == 4'd3 || ld_reg == 4'd4 || ld_reg == 4'd5 || ld_reg == 4'd9)) b_loading <= 1'b1;
  always @(posedge clk) if (rst_n) begin
    if (ld && (ld_reg == 4'd2 || ld_reg == 4'd3 || ld_reg == 4'd4 || ld_reg == 4'd5 || ld_reg == 4'd9 || ld_reg == 4'd10) && next_ready)
      $fatal(1, "B_BANK_OVERWRITE: parameter write while the idle bank holds committed data");
    if (swap && b_loading) $fatal(1, "B_BANK_SWAP_DURING_LOAD");
  end
`endif

  // ---------------------------------------------------------------- row registers
  // 每路仅保留宏的读出线，数值格式和计算顺序保持一致。
  wire signed [31:0] qc_q[2], af_q[2], n1_q[2], score_q[2], prob_q[2];
  wire signed [15:0] hidden_q[2], n1_quantized[2];

  // ---------------------------------------------------------------- memories
  // X
  wire signed [31:0] ln_norm[2];
  logic x_wr, x_rd, x_pair_rd, x_pair_wr; logic [12:0] x_addr; logic [31:0] x_wdata; wire [31:0] x_q, x_q_other;
  wire x_col_pair_rd;
  wire [31:0] x_q_odd, x_q_other_odd;
  ac_pair_x u_x(.clk, .rst_n, .wr(x_wr), .rd(x_rd), .pair_rd(x_pair_rd),
    .addr(x_addr), .wdata(x_wdata), .pair_wr(x_pair_wr), .wdata_other(ln_norm[1]), .q(x_q), .q_other(x_q_other),
    .col_pair_rd(x_col_pair_rd), .q_odd(x_q_odd), .q_other_odd(x_q_other_odd));
  // per-lane weight / KV memories (shared address, per-lane write enable)
  logic [L-1:0] watt_we, wffn_we, kv_we;
  logic watt_rd, wffn_rd, kv_rd;
  logic [9:0] watt_addr, wffn_raddr, kv_addr;
  logic [15:0] kv_wd [L];
  wire [15:0] weight_q [L], kv_q [L], v_odd_q [L], k_odd_q [L];
  logic [L-1:0] v_odd_we, k_odd_we;
  logic k_odd_rd, s1_qk_pair;
  logic [6:0] k_odd_addr;
  logic [15:0] k_odd_wd [2];
  logic v_odd_rd, s1_v_odd, s1_pv_pair, s1_v_even;
  wire kv_write_v, kv_read_v;
  wire [31:0] prob_odd_q [2];
  logic [6:0] v_odd_addr;
  wire [15:0] v_odd_write_data;
  logic [1:0] s1_code_pos;
  logic s1_ffn_pair;
  wire signed [15:0] n1_odd_q [2], hidden_odd_q [2];
  logic signed [31:0] mac_in_a_odd [2];
  wire signed [31:0] qc_odd_q [2];
  logic [L*17-1:0] mac_in_b_odd;
  logic [15:0] dr_scale;
  wire save_packed;
  wire [9:0] active_weight_base = att_sel ? 10'd384 : 10'd0;
  wire [9:0] idle_weight_base = att_sel ? 10'd0 : 10'd384;
  wire [9:0] weight_raddr = active_weight_base +
      (wffn_rd ? 10'd128 + (wffn_raddr >> 2) : watt_addr >> 2);
  wire [9:0] weight_waddr = idle_weight_base +
      (ld_reg == 4'd3 ? 10'd128 + (ld_addr[9:0] >> 2) : 10'(ld_addr[8:2]));
  for (genvar l = 0; l < L; l++) begin : lane_mem
    wire [15:0] lwd = (l % 2) ? ld_data[31:16] : ld_data[15:0];
    wire [15:0] packed_q;
    logic [15:0] saved_word;
    wire wr = watt_we[l] || wffn_we[l];
    wire rd = watt_rd || wffn_rd;
    // 首个位置直接用宏输出，其余位置用寄存器。空出的读周期可预取下一层。
    ac_mem16 u_weight(.clk, .rst_n, .wr, .rd,
                      .addr(wr ? weight_waddr : weight_raddr), .wdata(lwd), .q(packed_q));
    always_ff @(posedge clk) if (save_packed) saved_word <= packed_q;
    assign weight_q[l] = s1_code_pos == 0 ? packed_q : saved_word;
    wire [15:0] k_even_q, v_even_q;
    wire write_k = kv_we[l] && !kv_write_v;
    wire write_v = kv_we[l] && kv_write_v;
    ac_row_store #(.WIDTH(16), .DEPTH(128)) u_k_even(.clk, .rst_n, .wr(write_k), .rd(kv_rd && !kv_read_v),
      .addr({1'b0, kv_addr[7:6], kv_addr[5:1]}), .data(kv_wd[l]), .q(k_even_q));
    ac_row_store #(.WIDTH(16), .DEPTH(128)) u_v_even(.clk, .rst_n, .wr(write_v), .rd(kv_rd && kv_read_v),
      .addr({1'b0, v_odd_addr}), .data(kv_wd[l]), .q(v_even_q));
    assign kv_q[l] = s1_v_even ? v_even_q : k_even_q;
    ac_row_store #(.WIDTH(16), .DEPTH(128)) u_k_odd(.clk, .rst_n, .wr(k_odd_we[l]), .rd(k_odd_rd),
      .addr({1'b0, k_odd_addr}), .data(k_odd_wd[l%2]), .q(k_odd_q[l]));
    ac_row_store #(.WIDTH(16), .DEPTH(128)) u_v_odd(.clk, .rst_n, .wr(v_odd_we[l]), .rd(v_odd_rd),
      .addr({1'b0, v_odd_addr}), .data(v_odd_write_data), .q(v_odd_q[l]));
  end
  // bias
  logic b_wr, b_rd; logic [1:0] b_wmask; logic [9:0] b_addr; logic [63:0] b_wdata; wire [63:0] b_q;
  ac_mem_bias u_bias(.clk, .rst_n, .wr(b_wr), .rd(b_rd), .wmask(b_wmask), .addr(b_addr), .wdata(b_wdata), .q(b_q));

  // ---------------------------------------------------------------- MAC array
  logic mac_in_valid, mac_in_first, mac_in_last, mac_in_hi;
  logic signed [31:0] mac_in_a [2]; logic [L*17-1:0] mac_in_b;
  logic dr_valid, dr_sat16; logic [LW-1:0] dr_idx; logic signed [63:0] dr_bias; logic [5:0] dr_shift;
  wire [1:0] mac_out_valid;
  wire signed [31:0] mac_out_data [2];
  logic v_valid, v_serial, v_second, v_pair;
  wire s1_pair;
  // 两路共享同一拍的权重和控制，每路单独保留部分和。
  for (genvar side = 0; side < 2; side++) begin : g_mac
    wire use_input = mac_in_valid && (side == 0 || s1_pair);
    wire use_drain = v_valid && (side == 0 ? !v_second : (v_pair && (!v_serial || v_second)));
    arch_c_mac_array #(.L(L)) u_mac(
      .clk, .rst_n, .in_valid(use_input), .in_first(mac_in_first), .in_last(mac_in_last),
      .in_hi(mac_in_hi), .in_a(mac_in_a[side]), .in_b(mac_in_b),
      .in_pair(s1_ffn_pair), .in_qk_pair(s1_qk_pair), .in_pv_pair(s1_pv_pair), .in_a_odd(mac_in_a_odd[side]), .in_b_odd(mac_in_b_odd),
      .dr_valid(use_drain), .dr_idx, .dr_bias, .dr_scale, .dr_shift, .dr_sat16,
      .out_valid(mac_out_valid[side]), .out_data(mac_out_data[side])
    );
  end

  // ---------------------------------------------------------------- issuer
  pass_t cur, launch_desc; logic launch; logic iss_busy; logic [8:0] t;
  logic s1_pair_q;
  assign s1_pair = s1_pair_q;
  logic s1_valid, s1_first, s1_last, s1_hi, s1_split; logic [2:0] s1_asrc; logic [1:0] s1_bsrc; logic [7:0] s1_aidx;
  assign save_packed = s1_valid && s1_bsrc != B_KV && s1_code_pos == 0;
  // drain descriptor queue (2 entries)
  pass_t dq [0:1]; logic dq_wp, dq_rp; logic [1:0] dq_count; logic [1:0] dq_ready;
  logic [3:0] last_dly;
  logic dr_active; logic [LW:0] dr_l; logic dr_second; pass_t dr_cur;
  wire dr_serial = 1'b0;
  wire dr_complete = (dr_l == 6'(dr_cur.nout) - 1) && (!dr_serial || dr_second);
  wire dr_last_pending = dr_active && dr_complete;
  wire drain_block = (dq_count >= 2) || (dq_count == 1 && !dr_last_pending);
  wire iss_ffn_pair = cur.bsrc == B_WFFN || cur.dest == D_O || cur.dest == D_S || cur.dest == D_C || cur.asrc == A_X;
  wire [8:0] iss_step = iss_ffn_pair ? 9'd2 : 9'd1;
  wire iss_last = iss_busy && (t == cur.nterm);
  wire x_write_busy, x_may_write;
  wire iss_go = iss_busy && !(iss_last && drain_block) && !(cur.asrc == A_X && x_write_busy);
  wire [7:0] iss_k = cur.split ? 8'(t >> 1) : 8'(t);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      iss_busy <= 0; t <= 0; s1_valid <= 0; s1_first <= 0; s1_last <= 0; s1_hi <= 0;
    end else begin
      s1_valid <= iss_go; s1_first <= iss_go && t == 0; s1_last <= iss_go && iss_last;
      s1_hi <= iss_go && cur.split && t[0];
      if (iss_go) begin s1_pair_q <= cur.row != 98; s1_code_pos <= t[1:0]; s1_v_odd <= v_odd_rd; s1_pv_pair <= cur.dest == D_C; s1_v_even <= kv_read_v; s1_qk_pair <= k_odd_rd; s1_ffn_pair <= iss_ffn_pair; s1_split <= cur.split; s1_asrc <= cur.asrc; s1_bsrc <= cur.bsrc; s1_aidx <= iss_k; end
      if (launch) begin cur <= launch_desc; iss_busy <= 1; t <= 0; end
      else if (iss_go) begin if (iss_last) iss_busy <= 0; else t <= t + iss_step; end
    end
  end

  // MAC input (stage S1: memory data has arrived)
  always_comb begin
    mac_in_valid = s1_valid; mac_in_first = s1_first; mac_in_last = s1_last; mac_in_hi = s1_hi;
    for (int side = 0; side < 2; side++) begin
      case (s1_asrc)
        A_X:  mac_in_a_odd[side] = side == 0 ? x_q_odd : x_q_other_odd;
        A_QC: mac_in_a_odd[side] = qc_odd_q[side];
        A_P:  mac_in_a_odd[side] = s1_v_odd ? prob_odd_q[side] : 32'd0;
        A_F1: mac_in_a_odd[side] = 32'(n1_odd_q[side]);
        default: mac_in_a_odd[side] = 32'(hidden_odd_q[side]);
      endcase
      case (s1_asrc)
        A_X:  mac_in_a[side] = side == 0 ? x_q : x_q_other;
        A_QC: mac_in_a[side] = qc_q[side];
        A_P:  mac_in_a[side] = prob_q[side];
        A_F1: mac_in_a[side] = 32'(n1_quantized[side]);
        default: mac_in_a[side] = 32'(hidden_q[side]);
      endcase
    end
    for (int l = 0; l < L; l++) begin
      logic [15:0] w;
      w = s1_bsrc == B_KV ? kv_q[l] : 16'($signed(weight_q[l][4*s1_code_pos +: 4]));
      mac_in_b_odd[l*17 +: 17] = s1_qk_pair ? 17'($signed(k_odd_q[l])) :
                                    s1_pv_pair ? (s1_v_odd ? 17'($signed(v_odd_q[l])) : 17'd0) :
                                    17'($signed(weight_q[l][4*s1_code_pos + 4 +: 4]));
      mac_in_b[l*17 +: 17] = (s1_split && !s1_hi) ? {1'b0, w} : {w[15], w};
    end
  end

  // ---------------------------------------------------------------- drainer
  // R stage: bias read; V stage: dr_valid into MAC drain; then 3-stage MAC drain pipe.
  logic [3:0] v_dest; logic [6:0] v_row; logic [7:0] v_col; logic v_bias;
  localparam int DRAIN_STAGES = 5;
  logic [DRAIN_STAGES-1:0] o_valid_sr; logic [3:0] o_dest [0:DRAIN_STAGES-1];
  logic [6:0] o_row [0:DRAIN_STAGES-1]; logic [7:0] o_col [0:DRAIN_STAGES-1];
  wire dr_fire = dr_active;
  wire [7:0] dr_colw = {dr_cur.g, 5'(dr_l)};
  logic [8:0] scale_pair_addr;
  logic scale_read, v_scaled;
  wire [15:0] scale_q [2][2];
  // 尺度顺序与参数打包一致，QK 和 P×V 继续使用原有 16 位数据。
  always_comb begin
    scale_read = dr_fire;
    case (dr_cur.dest)
      D_Q:  scale_pair_addr =         9'(dr_colw[7:1]);
      D_K:  scale_pair_addr =  9'd32 + 9'(dr_colw[7:1]);
      D_V:  scale_pair_addr =  9'd64 + 9'(dr_colw[7:1]);
      D_O:  scale_pair_addr =  9'd96 + 9'(dr_colw[7:1]);
      D_F1: scale_pair_addr = 9'd128 + 9'(dr_colw[7:1]);
      D_F2: scale_pair_addr = 9'd256 + 9'(dr_colw[7:1]);
      default: begin scale_pair_addr = 0; scale_read = 0; end
    endcase
  end
  for (genvar b = 0; b < 2; b++) begin : scale_bank
    for (genvar p = 0; p < 2; p++) begin : scale_parity
      wire wr = ld && ld_reg == 4'd11 && att_sel != 1'(b);
      wire rd = scale_read && att_sel == 1'(b);
      ac_mem16 u_scale(.clk, .rst_n, .wr, .rd,
                       .addr(wr ? ld_addr[9:0] : 10'(scale_pair_addr)),
                       .wdata(ld_data[p*16 +: 16]), .q(scale_q[b][p]));
    end
  end
  always_ff @(posedge clk) v_scaled <= scale_read;
  assign dr_scale = v_scaled ? scale_q[att_sel][v_col[0]] : 16'd1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dq_wp <= 0; dq_rp <= 0; dq_count <= 0; dq_ready <= 0; last_dly <= 0;
      dr_active <= 0; dr_l <= 0; dr_second <= 0; v_valid <= 0; o_valid_sr <= 0;
    end else begin
      // push descriptor when the issuer emits the last term
      last_dly <= {last_dly[2:0], iss_go && iss_last};
      if (iss_go && iss_last) begin dq[dq_wp] <= cur; dq_wp <= !dq_wp; end
      begin
        logic push, pop, rdy, take;
        push = iss_go && iss_last; rdy = last_dly[3];
        take = !dr_active && dq_ready != 0;
        pop = dr_fire && dr_complete;
        dq_count <= dq_count + 2'(push) - 2'(pop);
        dq_ready <= dq_ready + 2'(rdy) - 2'(take);
        if (take) begin dr_cur <= dq[dq_rp]; dq_rp <= !dq_rp; dr_active <= 1; dr_l <= 0; dr_second <= 0; end
        else if (dr_active) begin
          if (pop) dr_active <= 0;
          else if (dr_l == 6'(dr_cur.nout) - 1) begin
            dr_l <= 0;
            dr_second <= 1;
          end else dr_l <= dr_l + 1'b1;
        end
      end
      v_valid <= dr_fire;
      if (dr_fire) begin
        v_dest <= dr_cur.dest; v_row <= dr_cur.row; v_col <= dr_colw; v_bias <= dr_cur.bias_en;
        v_pair <= dr_cur.row != 98; v_serial <= dr_serial; v_second <= dr_second;
        dr_idx <= LW'(dr_l); dr_shift <= dr_cur.shift; dr_sat16 <= dr_cur.sat16;
      end
      o_valid_sr <= {o_valid_sr[DRAIN_STAGES-2:0], v_valid};
      o_dest[0] <= v_dest; o_row[0] <= v_row; o_col[0] <= v_col;
      for (int s = 1; s < DRAIN_STAGES; s++) begin o_dest[s] <= o_dest[s-1]; o_row[s] <= o_row[s-1]; o_col[s] <= o_col[s-1]; end
    end
  end
  assign dr_valid = v_valid;
  assign dr_bias  = v_bias ? $signed(b_q) : 64'sd0;
  wire        out_v    = |mac_out_valid;
  wire        out_side = !mac_out_valid[0] && mac_out_valid[1];
  wire signed [31:0] out_data = mac_out_data[out_side];
  wire [3:0]  out_dest = o_dest[DRAIN_STAGES-1];
  wire [6:0]  out_row  = o_row[DRAIN_STAGES-1];
  wire [7:0]  out_col  = o_col[DRAIN_STAGES-1];
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && (out_v !== o_valid_sr[DRAIN_STAGES-1])) $fatal(1, "drain tag pipe misaligned");
`endif

  // Q、K、V 在原 Q20 结果上再按独立的小数位数舍入饱和。
  wire signed [15:0] q16 [2], k16 [2], v16 [2];
  for (genvar side = 0; side < 2; side++) begin : g_qkv16
    linear_requantize #(.ACC_W(32), .OUT_W(16), .SHIFT(8)) u_q16(.value(mac_out_data[side]), .result(q16[side]));
    linear_requantize #(.ACC_W(32), .OUT_W(16), .SHIFT(10)) u_k16(.value(mac_out_data[side]), .result(k16[side]));
    linear_requantize #(.ACC_W(32), .OUT_W(16), .SHIFT(9)) u_v16(.value(mac_out_data[side]), .result(v16[side]));
  end
  assign v_odd_write_data = v16[1];
  wire [6:0] write_row = out_row + 7'(out_side);
  wire [9:0] k_word = {2'b0, out_row[6:5], out_col[5:0]};
  wire [9:0] v_word = 10'd256 + 10'(out_col[7:5]) * 10'd99 + 10'(write_row);

  // 每路按列序排空，严格大于时更新，以保留最早的最大值列。
  logic signed [31:0] score_max[2];
  logic [6:0] score_max_col[2];
  for(genvar side=0;side<2;side++) begin : g_score_max
    always_ff @(posedge clk) if(mac_out_valid[side]&&out_dest==D_S)
      if(out_col==0||$signed(mac_out_data[side])>score_max[side]) begin
        score_max[side]<=mac_out_data[side];score_max_col[side]<=out_col[6:0];
      end
  end

  // ---------------------------------------------------------------- softmax + exp table
  logic nonlin_side;
  logic [6:0] row_i;
  logic sm_start;
  wire [1:0] sm_done, sm_error, sm_score_read, sm_pw;
  logic [1:0] sm_seen;
  wire [6:0] sm_score_col[2], sm_pcol[2];
  wire [31:0] sm_pdata[2];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) sm_seen <= 0;
    else if (sm_start) sm_seen <= 0;
    else sm_seen <= sm_seen | sm_done;

  // 两路使用各自的指数表读口，装载仍广播同一份数据。
  for (genvar k=0;k<2;k++) begin:g_softmax_lane
    wire tbl_rd;
    wire [12:0] ta,tb;
    wire [31:0] tda,tdb;
    attention_softmax #(.TOKENS(99),.PRECOMPUTED_MAX(1)) u_sm(
      .clk,.rst_n,.start(sm_start && (k==0 || row_i!=98)),.done(sm_done[k]),.error(sm_error[k]),
      .score_read(sm_score_read[k]),.score_col(sm_score_col[k]),.score_data(score_q[k]),
      .precomputed_max(score_max[k]),.precomputed_col(score_max_col[k]),
      .table_read(tbl_rd),.table_a(ta),.table_b(tb),.table_data_a(tda),.table_data_b(tdb),
      .probability_write(sm_pw[k]),.probability_col(sm_pcol[k]),.probability_data(sm_pdata[k]));
    attention_table_ihp u_exp(.clk,.rst_n,.write_valid(ld && ld_reg==4'd7),
      .write_addr(ld_addr[12:0]),.write_data(ld_data),.read_valid(tbl_rd),
      .address_a(ta),.address_b(tb),.data_a(tda),.data_b(tdb));
  end

  // ---------------------------------------------------------------- GELU
  wire [1:0] g_in_valid, g_in_ready, g_out_valid;
  wire signed [15:0] g_out_data [2];
  wire [7:0] g_out_col [2];
  logic [1:0] g_write_valid;
  logic signed [15:0] g_write_data [2];
  logic [7:0] g_write_col [2];
  logic [3:0] g_outstanding [2];
  // 两路各自查表，使行对的 FFN1 排空仍只需要 32 拍。
  for (genvar side = 0; side < 2; side++) begin : g_pair_gelu
    assign g_in_valid[side] = mac_out_valid[side] && out_dest == D_F1;
    ffn_gelu_ihp #(.TAG_W(8)) u_gelu(.clk, .rst_n, .table_write(ld && ld_reg == 4'd8),
      .table_addr(ld_addr[12:0]), .table_data(ld_data), .in_valid(g_in_valid[side]),
      .in_ready(g_in_ready[side]), .in_data(mac_out_data[side][15:0]), .in_tag(out_col),
      .out_valid(g_out_valid[side]), .out_ready(1'b1), .out_data(g_out_data[side]), .out_tag(g_out_col[side]));
    always_ff @(posedge clk) begin
      if (!rst_n) begin g_outstanding[side] <= 0; g_write_valid[side] <= 0; end
      else begin
        g_outstanding[side] <= g_outstanding[side] + 4'(g_in_valid[side]) - 4'(g_write_valid[side]);
        g_write_valid[side] <= g_out_valid[side];
        if (g_out_valid[side]) begin
          g_write_data[side] <= g_out_data[side];
          g_write_col[side] <= g_out_col[side];
        end
      end
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && |(g_in_valid & ~g_in_ready)) $fatal(1, "GELU input blocked");
`endif

  // ---------------------------------------------------------------- LayerNorm x2 (ROWS=1 per start)
  // single LN unit, time-shared: ROWS=198 per layer, even rows = LN1, odd rows = LN2 (gamma/beta set = row parity)
  logic fd_sel;
  logic lc_valid, lc_n, lc_kind; logic [5:0] lc_col; logic signed [31:0] lc_data; logic [8:0] lc_i;
  logic ln_start;
  wire [1:0] ln_start_ready, ln_load_error, ln_in_ready, ln_out_valid;
  wire signed [31:0] ln_res[2];
  wire [5:0] ln_ocol[2];
  logic fd_active, fv_valid;
  logic [6:0] fd_cnt;
  wire ln_dual = row_i != 98;
  assign x_may_write = fd_sel && fd_active;
  wire fd_req = fd_active && fd_cnt < 64 && ln_in_ready[0] && (!ln_dual || ln_in_ready[1]);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin fv_valid <= 0; fd_cnt <= 0; end
    else begin
      fv_valid <= fd_req;
      if (fd_req) fd_cnt <= fd_cnt + 1'b1;
      if (!fd_active) fd_cnt <= 0;
    end

  for (genvar ln_lane=0;ln_lane<2;ln_lane++) begin:g_ln_pair
    ac_ln_stream #(.ROWS(ln_lane==0?100:98),.FEATURES(64)) u_ln(
      .kwt_ln_storage(),.clk,.rst_n,.start(ln_start),.layer_index(4'd0),.position(1'b0),
      .parameter_set(fd_sel),.start_ready(ln_start_ready[ln_lane]),.busy(),.done(),
      .load_valid(lc_valid),.load_kind(lc_kind),.load_addr({lc_n,lc_col}),.load_data(lc_data),
      .load_ready(),.load_error(ln_load_error[ln_lane]),
      .in_valid(fv_valid&&(ln_lane==0||ln_dual)),.in_ready(ln_in_ready[ln_lane]),
      .in_a(fd_sel?n1_q[ln_lane]:(ln_lane==0?x_q:x_q_other)),.in_b(af_q[ln_lane]),
      .out_valid(ln_out_valid[ln_lane]),.out_ready(1'b1),.out_residual(ln_res[ln_lane]),
      .out_normalized(ln_norm[ln_lane]),.out_row(),.out_col(ln_ocol[ln_lane]),
      .out_layer(),.out_position());
  end
  assign lc_data = lc_kind ? $signed(b_q[63:32]) : $signed(b_q[31:0]);
  assign xr_data = x_q;
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && ln_dual && (|ln_out_valid) &&
        (!(&ln_out_valid) || ln_ocol[0]!=ln_ocol[1])) $fatal(1,"LN_LANES_NOT_ALIGNED");
`endif

  // ---------------------------------------------------------------- sequencer
  typedef enum logic [4:0] {S_IDLE, S_WAITP, S_SWAP, S_LNC, S_KV, S_BAR, S_Q, S_QK, S_SM, S_SMW, S_PV, S_O, S_LN1, S_LN1W,
                            S_F1, S_F2, S_LN2, S_LN2W, S_DONE} st_t;
  st_t st, st_next_after_bar;
  logic [6:0] key_j; logic [3:0] sub; logic [6:0] ln_outs;
  wire early_q_ready, early_q, early_qk;
  wire [6:0] next_pair_row = row_i + 7'd2;
  wire [3:0] early_next = sub + 4'(early_q || early_qk);
  wire [1:0] early_qk_group = sub[1:0] - 2'd2;
  wire pipe_empty = !iss_busy && !s1_valid && dq_count == 0 && !v_valid && o_valid_sr == 0 &&
                    g_outstanding[0] == 0 && g_outstanding[1] == 0 && !launch;
  // 输入装载独立判定，避免权重读使能和装载反压之间形成组合环。
  assign x_write_busy = (ln_out_valid[0] && fd_sel) || (ld_valid && ld_reg == 4'd1 && (!busy || st == S_WAITP));
  assign early_q_ready = pipe_empty || (out_v && out_dest == D_Q && out_col == 8'd48);

  function automatic pass_t mk(input logic [2:0] asrc, input logic [1:0] bsrc, input logic split,
      input logic [8:0] nterm, input logic [9:0] bbase, input logic [12:0] abase, input logic [3:0] dest,
      input logic [6:0] row, input logic [2:0] g, input logic [5:0] nout, input logic [5:0] shift,
      input logic sat16, input logic bias_en, input logic [8:0] bbias);
    pass_t p;
    p.asrc = asrc; p.bsrc = bsrc; p.split = split; p.nterm = nterm; p.bbase = bbase; p.abase = abase;
    p.dest = dest; p.row = row; p.g = g; p.nout = nout; p.shift = shift; p.sat16 = sat16;
    p.bias_en = bias_en; p.bbias = bbias;
    return p;
  endfunction

  wire can_launch = !launch &&
      (!iss_busy || (iss_go && (iss_last || (!drain_block && t + iss_step == cur.nterm && (!x_may_write || cur.asrc != A_X)))));
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && launch && iss_busy && !(iss_go && iss_last))
    $fatal(1, "issuer replaced an incomplete reduction");
`endif
  assign early_q = st == S_LN2W && row_i != 98 && can_launch && sub < 2;
  assign early_qk = st == S_LN2W && row_i != 98 && can_launch && sub >= 2 && sub < 6 &&
                    (sub != 2 || early_q_ready);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; launch <= 0; done <= 0; busy <= 0; cycles <= 0; row_i <= 0; key_j <= 0; sub <= 0;
      layer_done <= 0; wait_cycles <= 0; cur_layer <= 0; att_sel <= 0; ffn_sel <= 0; bias_sel <= 0; swap <= 0; lc_valid <= 0; lc_i <= 0;
      nonlin_side <= 0; sm_start <= 0; ln_start <= 0; fd_active <= 0; fd_sel <= 0; ln_outs <= 0;
    end else begin
      launch <= 0; done <= 0; sm_start <= 0; ln_start <= 0; swap <= 0; lc_valid <= 0; layer_done <= 0;
      if (busy) cycles <= cycles + 1;
      if (fd_active && !fd_sel && ln_out_valid[0] && ln_ocol[0] == 6'd63) fd_active <= 0;
      case (st)
        S_IDLE: if (start) begin busy <= 1; cycles <= 0; wait_cycles <= 0; cur_layer <= 0; st <= S_WAITP; end
        S_WAITP: if (next_ready) st <= S_SWAP; else wait_cycles <= wait_cycles + 1;
        S_SWAP: begin
          swap <= 1; att_sel <= !att_sel; ffn_sel <= !ffn_sel; bias_sel <= !bias_sel; lc_i <= 0; st <= S_LNC;
        end
        // copy LN1/LN2 gamma/beta (bias entries 384..511 of the new current half) into the LN units
        S_LNC: begin
          if (lc_i < 256) begin
            lc_valid <= 1; lc_n <= lc_i[7]; lc_kind <= lc_i[6]; lc_col <= lc_i[5:0]; lc_i <= lc_i + 1'b1;
          end else begin key_j <= 0; sub <= 0; row_i <= 0; st <= S_KV; end
        end
        S_KV: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_X, B_WATT, 0, 9'd62, sub[1] ? 10'(256 + sub[0]*64) : 10'(128 + sub[0]*64),
                            13'(key_j * 64), sub[1] ? D_V : D_K, key_j, 3'(sub[0]), 6'd32,
                            sub[1] ? sh_v : sh_k, 0, 0, 0);
          if (sub == 3) begin
            sub <= 0;
            if (key_j == 98) begin st <= S_BAR; st_next_after_bar <= S_Q; end else key_j <= key_j + 7'd2;
          end else sub <= sub + 1'b1;
        end
        S_BAR: if (pipe_empty ||
            (st_next_after_bar == S_Q && !iss_busy && !launch) ||
            (out_v && out_col == 8'd32 &&
             ((st_next_after_bar == S_LN1 && out_dest == D_O) ||
              (st_next_after_bar == S_LN2 && out_dest == D_F2))) ||
            (st_next_after_bar == S_QK && out_v && out_dest == D_Q && out_col == 8'd48) ||
            (st_next_after_bar == S_O && out_v && out_dest == D_C && out_col == 8'd48) ||
            (st_next_after_bar == S_F2 && g_write_valid[0] && g_write_col[0] == 8'd224)) begin
          // 下一算子先读低段，高段的写入在消费到它之前结束。
          st <= st_next_after_bar; sub <= 0;
        end
        S_Q: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_X, B_WATT, 0, 9'd62, 10'(sub[0]*64), 13'(row_i * 64), D_Q, row_i, 3'(sub[0]),
                            6'd32, sh_q, 0, 0, 0);
          if (sub == 1) begin st <= S_BAR; st_next_after_bar <= S_QK; end else sub <= sub + 1'b1;
        end
        S_QK: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_QC, B_KV, 0, 9'd62, 10'(sub[1:0] * 64), 13'd0, D_S, row_i, 3'(sub[1:0]),
                            (sub == 3) ? 6'd3 : 6'd32, 6'd5, 0, 0, 0);
          if (sub == 3) begin st <= S_BAR; st_next_after_bar <= S_SM; end else sub <= sub + 1'b1;
        end
        S_SM: begin sm_start <= 1; st <= S_SMW; end
        S_SMW: if (!sm_start && (sm_seen[0] || sm_done[0]) &&
                       (row_i == 98 || sm_seen[1] || sm_done[1])) begin
          nonlin_side <= 0; st <= S_PV; sub <= 0;
        end
        S_PV: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_P, B_KV, 0, 9'd98, 10'(256 + sub[0] * 99), 13'd0, D_C, row_i, 3'(sub[0]),
                            6'd32, 6'd15, 0, 0, 0);
          if (sub == 1) begin st <= S_BAR; st_next_after_bar <= S_O; end else sub <= sub + 1'b1;
        end
        S_O: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_QC, B_WATT, 0, 9'd62, 10'(384 + sub[0] * 64), 13'd0, D_O, row_i, 3'(sub[0]),
                            6'd32, sh_o, 0, 1, 9'd0);
          if (sub == 1) begin st <= S_BAR; st_next_after_bar <= S_LN1; end else sub <= sub + 1'b1;
        end
        // LN units run ROWS=99 per layer: started once at row 0, then wait in INPUT_ROW for each row
        S_LN1: if (row_i != 0 || (&ln_start_ready)) begin
          ln_start <= row_i == 0; fd_active <= 1; fd_sel <= 0; ln_outs <= 0; st <= S_LN1W;
        end
        S_LN1W: begin
          // 发射第一个 FFN1 块时，写口已进入高段，读口从第零段开始。
          if (ln_out_valid[0] && ln_ocol[0] == 6'd40) begin st <= S_F1; sub <= 0; end
        end
        S_F1: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_F1, B_WFFN, 0, 9'd62, 10'(sub[2:0] * 64), 13'd0, D_F1, row_i, sub[2:0],
                            6'd32, 6'd11, 1, 1, 9'd64);
          if (sub == 7) begin st <= S_BAR; st_next_after_bar <= S_F2; end else sub <= sub + 1'b1;
        end
        S_F2: if (can_launch) begin
          launch <= 1;
          launch_desc <= mk(A_H, B_WFFN, 0, 9'd254, 10'(512 + sub[0] * 256), 13'd0, D_F2, row_i, 3'(sub[0]),
                            6'd32, sh_f2, 0, 1, 9'd320);
          if (sub == 1) begin st <= S_BAR; st_next_after_bar <= S_LN2; end else sub <= sub + 1'b1;
        end
        S_LN2: begin fd_active <= 1; fd_sel <= 1; ln_outs <= 0; st <= S_LN2W; end   // same LN unit, odd row
        S_LN2W: begin
          // 旧行对保留写回地址；新行对由发射描述符携带独立行号。
          if (early_q) begin
            launch <= 1;
            launch_desc <= mk(A_X, B_WATT, 0, 9'd62, 10'(sub[0]*64), 13'(next_pair_row * 64),
                              D_Q, next_pair_row, 3'(sub[0]), 6'd32, sh_q, 0, 0, 0);
          end else if (early_qk) begin
            launch <= 1;
            launch_desc <= mk(A_QC, B_KV, 0, 9'd62, 10'(early_qk_group * 64), 13'd0,
                              D_S, next_pair_row, 3'(early_qk_group),
                              early_qk_group == 3 ? 6'd3 : 6'd32, 6'd5, 0, 0, 0);
          end
          sub <= early_next;
          if (ln_out_valid[0]) ln_outs <= ln_outs + 1'b1;
          if (ln_outs == 64) begin
            fd_active <= 0;
            if (row_i == 98) begin
              layer_done <= 1;
              if (cur_layer == 11) st <= S_DONE; else begin cur_layer <= cur_layer + 1'b1; st <= S_WAITP; end
            end else begin
              row_i <= next_pair_row;
              if (early_next < 2) st <= S_Q;
              else if (early_next == 2 || early_next == 6) begin
                st <= S_BAR;
                st_next_after_bar <= early_next == 2 ? S_QK : S_SM;
              end else begin
                st <= S_QK;
                sub <= early_next - 4'd2;
              end
            end
          end
        end
        S_DONE: begin done <= 1; busy <= 0; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end

  assign x_col_pair_rd = iss_go && cur.asrc == A_X;

  assign kv_write_v = out_dest == D_V;
  assign kv_read_v = cur.dest == D_C;

  // ---------------------------------------------------------------- memory port muxes
  always_comb begin
    // X: load write / LN2 output write / issuer read / LN1 feeder read
    x_wr = 0; x_rd = 0; x_pair_rd = 0; x_pair_wr = 0; x_addr = '0; x_wdata = '0;
    if (ld && ld_reg == 4'd1) begin x_wr = 1; x_addr = ld_addr[12:0]; x_wdata = ld_data; end
    else if (ln_out_valid[0] && fd_sel) begin x_wr = 1; x_pair_wr = ln_out_valid[1]; x_addr = 13'(row_i * 64) + 13'(ln_ocol[0]); x_wdata = ln_norm[0]; end
    else if (iss_go && cur.asrc == A_X) begin x_rd = 1; x_pair_rd = cur.row != 98; x_addr = cur.abase + 13'(iss_k); end
    else if (fd_req && !fd_sel) begin x_rd = 1; x_pair_rd = ln_dual; x_addr = 13'(row_i * 64) + 13'(fd_cnt[5:0]); end
    else if (xr_valid) begin x_rd = 1; x_addr = xr_addr; end
    // weights: load write / issuer read
    watt_we = '0; wffn_we = '0; watt_rd = 0; wffn_rd = 0;
    watt_addr = {1'b0, 9'(cur.bbase + 10'(t))}; wffn_raddr = 10'(cur.bbase + 10'(t));
    if (ld && ld_reg == 4'd2) begin
      watt_we[{ld_addr[13:10], 1'b0}] = 1; watt_we[{ld_addr[13:10], 1'b1}] = 1;
    end
    if (iss_go && t[1:0] == 0 && cur.bsrc == B_WATT) watt_rd = 1;
    if (ld && ld_reg == 4'd3) begin wffn_we[{ld_addr[14:11], 1'b0}] = 1; wffn_we[{ld_addr[14:11], 1'b1}] = 1; end
    if (iss_go && t[1:0] == 0 && cur.bsrc == B_WFFN) wffn_rd = 1;
    // K 同列分宏写入，V 的奇偶行分拍写入。
    kv_we = '0; kv_rd = 0; kv_addr = 10'(cur.bbase + 10'(t));
    v_odd_we = '0; v_odd_rd = 0; v_odd_addr = '0;
    k_odd_we = '0; k_odd_rd = 0; k_odd_addr = '0;
    k_odd_wd[0] = k16[0]; k_odd_wd[1] = k16[1];
    for (int l = 0; l < L; l++) kv_wd[l] = v16[out_side];
    if (out_v && out_dest == D_K) begin
      if (out_col[0]) begin
        k_odd_we[out_row[4:0]] = mac_out_valid[0];
        k_odd_we[out_row[4:0] + 5'd1] = mac_out_valid[1];
        k_odd_addr = {out_row[6:5], out_col[5:1]};
      end else begin
        kv_we[out_row[4:0]] = mac_out_valid[0];
        kv_we[out_row[4:0] + 5'd1] = mac_out_valid[1];
        kv_addr = k_word;
        for (int l = 0; l < L; l++) kv_wd[l] = k16[l[0]];
      end
    end else if (out_v && out_dest == D_V) begin
      kv_we[out_col[4:0]] = mac_out_valid[0];
      kv_addr = v_word;
      v_odd_we[out_col[4:0]] = mac_out_valid[1];
      v_odd_addr = (out_col[5] ? 7'd50 : 7'd0) + 7'(out_row[6:1]);
    end else if (iss_go && cur.bsrc == B_KV) begin
      kv_rd = 1;
      v_odd_rd = cur.dest == D_C && t != 9'd98;
      v_odd_addr = (cur.bbase == 10'd256 ? 7'd0 : 7'd50) + 7'(t[6:1]);
      k_odd_rd = cur.dest == D_S;
      k_odd_addr = {cur.bbase[7:6], t[5:1]};
    end
    // bias: load / drainer read
    b_wr = 0; b_rd = 0; b_wmask = 2'b00; b_addr = {bias_sel, 9'(10'(dr_cur.bbias) + 10'(dr_colw))}; b_wdata = {2{ld_data}};
    if (st == S_LNC && lc_i < 256) begin
      b_rd = 1; b_addr = {bias_sel, 9'(9'd384 + {2'b0, lc_i[7], lc_i[5:0]})};
    end else if (ld && ld_reg == 4'd4) begin b_wr = 1; b_addr = {!bias_sel, ld_addr[9:1]}; b_wmask = ld_addr[0] ? 2'b10 : 2'b01; end
    else if (ld && ld_reg == 4'd5) begin b_wr = 1; b_addr = {!bias_sel, 9'(9'd384 + ld_addr[7:1])}; b_wmask = ld_addr[0] ? 2'b10 : 2'b01; end
    else if (dr_fire && dr_cur.bias_en) b_rd = 1;
    // load handshake: next-layer regions accept while not yet committed and the target port is free
    case (ld_reg)
      4'd1:             ld_ready = !busy || st == S_WAITP;
      4'd7, 4'd8:       ld_ready = !busy;
      4'd2, 4'd3:       ld_ready = !next_ready && !(watt_rd || wffn_rd);
      4'd9, 4'd11:       ld_ready = !next_ready;
      4'd4, 4'd5:       ld_ready = !next_ready && st != S_LNC && !(dr_fire && dr_cur.bias_en);
      4'd10:            ld_ready = !next_ready;
      default:          ld_ready = 1'b1;
    endcase
  end
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    if (iss_go && cur.asrc == A_X && ((ln_out_valid[0] && fd_sel) || (ld && ld_reg == 4'd1))) $fatal(1, "X port conflict");
    if (iss_go && cur.bsrc == B_KV && (out_v && (out_dest == D_K || out_dest == D_V))) $fatal(1, "KV port conflict");
    if (|sm_error) $fatal(1, "softmax error");
    if (xr_valid && !(st == S_WAITP || st == S_IDLE)) $fatal(1, "X read-back while computing");
    if (ln_load_error[0] || ln_load_error[1]) $fatal(1, "LN load error");
  end
`endif

  // 发射读请求与原流水线对齐，写入和读出分别占用不同计算阶段。
  for(genvar side=0;side<2;side++) begin : g_row_sram
    wire selected=side==0||ln_dual;
    wire active_row=side==0||cur.row!=98;
    wire q_wr=mac_out_valid[side]&&(out_dest==D_Q||out_dest==D_C);
    wire q_rd=iss_go&&cur.asrc==A_QC&&active_row;
    wire af_wr=mac_out_valid[side]&&(out_dest==D_O||out_dest==D_F2);
    wire af_rd=fd_req&&selected;
    wire n_wr=ln_out_valid[side]&&!fd_sel;
    wire n_mac=iss_go&&cur.asrc==A_F1&&active_row;
    wire n_rd=fd_req&&fd_sel&&selected;
    wire score_wr=mac_out_valid[side]&&out_dest==D_S;
    wire score_rd=sm_score_read[side];
    wire prob_wr=sm_pw[side];
    wire prob_rd=iss_go&&cur.asrc==A_P&&active_row;
    wire h_wr=g_write_valid[side];
    wire h_rd=iss_go&&cur.asrc==A_H&&active_row;
    wire [31:0] qc_half_q [2], qc_odd_half_q [2], af_half_q [2];
    logic qc_half, af_half;
    always_ff @(posedge clk) begin
      if (q_rd) qc_half <= iss_k[5];
      if (af_rd) af_half <= fd_cnt[5];
    end
    for (genvar h = 0; h < 2; h++) begin : g_tile_half
      wire qc_wr_here = q_wr && out_col[5] == 1'(h);
      wire af_wr_here = af_wr && out_col[5] == 1'(h);
      wire odd_wr_here = qc_wr_here && out_col[0];
      // P×V 的奇列独立缓存，投影时与偶列同拍读取。
      ac_row_store #(.DEPTH(16)) u_qc_odd(.clk, .rst_n, .wr(odd_wr_here),
        .rd(q_rd && iss_k[5] == 1'(h)),
        .addr(odd_wr_here ? {4'b0, out_col[4:1]} : {4'b0, iss_k[4:1]}),
        .data(out_dest == D_Q ? 32'(q16[side]) : mac_out_data[side]), .q(qc_odd_half_q[h]));
      ac_row_store #(.DEPTH(32)) u_qc(.clk, .rst_n, .wr(qc_wr_here), .rd(q_rd && iss_k[5] == 1'(h)),
        .addr(qc_wr_here ? {3'b0, out_col[4:0]} : {3'b0, iss_k[4:0]}),
        .data(out_dest == D_Q ? 32'(q16[side]) : mac_out_data[side]), .q(qc_half_q[h]));
      ac_row_store #(.DEPTH(32)) u_af(.clk, .rst_n, .wr(af_wr_here), .rd(af_rd && fd_cnt[5] == 1'(h)),
        .addr(af_wr_here ? {3'b0, out_col[4:0]} : {3'b0, fd_cnt[4:0]}),
        .data(mac_out_data[side]), .q(af_half_q[h]));
    end
    assign qc_q[side] = qc_half_q[qc_half];
    assign qc_odd_q[side] = qc_odd_half_q[qc_half];
    assign af_q[side] = af_half_q[af_half];
    ac_row_store #(.DEPTH(64)) u_n1(.clk,.rst_n,.wr(n_wr),.rd(n_rd),
      .addr(n_wr?{2'b0,ln_ocol[side]}:{2'b0,fd_cnt[5:0]}),
      .data(ln_norm[side]),.q(n1_q[side]));
    ac_row_store #(.DEPTH(99)) u_score(.clk,.rst_n,.wr(score_wr),.rd(score_rd),
      .addr(score_wr?out_col:{1'b0,sm_score_col[side]}),.data(mac_out_data[side]),.q(score_q[side]));
    wire [31:0] prob_data [2];
    for (genvar p = 0; p < 2; p++) begin : g_prob_parity
      wire prob_wr_here = prob_wr && sm_pcol[side][0] == 1'(p);
      // 99 项的末拍只有偶项，奇项由发射端清零。
      ac_row_store #(.DEPTH(50)) u_prob(.clk, .rst_n, .wr(prob_wr_here),
        .rd(prob_rd && (p == 0 || iss_k != 8'd98)),
        .addr(prob_wr_here ? {2'b0, sm_pcol[side][6:1]} : {2'b0, iss_k[6:1]}),
        .data(sm_pdata[side]), .q(prob_data[p]));
    end
    assign prob_q[side] = prob_data[0];
    assign prob_odd_q[side] = prob_data[1];
    wire signed [15:0] n1_compact;
    logic n1_write;
    logic [5:0] n1_write_col;
    logic signed [15:0] n1_write_value;
    logic [1:0] n1_read_tile;
    wire [15:0] n1_pair_q [2][3];
    wire [1:0] n1_read_segment = iss_k[5] ? (iss_k[4] ? 2'd2 : 2'd1) : 2'd0;
    wire [1:0] n1_write_segment = n1_write_col[5] ? (n1_write_col[4] ? 2'd2 : 2'd1) : 2'd0;
    linear_requantize #(.ACC_W(32), .OUT_W(16), .SHIFT(9)) u_n1_pair_rq(
      .value(ln_norm[side]), .result(n1_compact));
    always_ff @(posedge clk) begin
      n1_write <= rst_n && n_wr;
      if (n_wr) begin n1_write_col <= ln_ocol[side]; n1_write_value <= n1_compact; end
      if (n_mac) n1_read_tile <= n1_read_segment;
    end
    for (genvar p = 0; p < 2; p++) begin : g_n1_parity
      for (genvar s = 0; s < 3; s++) begin : g_n1_tile
        wire writing = n1_write && n1_write_col[0] == 1'(p) && n1_write_segment == 2'(s);
        wire reading = n_mac && n1_read_segment == 2'(s);
        ac_row_store #(.WIDTH(16), .DEPTH(32)) u_n1_tile(.clk, .rst_n, .wr(writing), .rd(reading),
          .addr(writing ? {3'b0, n1_write_col[5:1]} : {3'b0, iss_k[5:1]}),
          .data(n1_write_value), .q(n1_pair_q[p][s]));
      end
    end
    assign n1_quantized[side] = n1_pair_q[0][n1_read_tile];
    assign n1_odd_q[side] = n1_pair_q[1][n1_read_tile];
    wire [15:0] hidden_half_q [2][2];
    logic hidden_half;
    always_ff @(posedge clk) if (h_rd) hidden_half <= iss_k[7];
    for (genvar p = 0; p < 2; p++) begin : g_hidden_parity
      for (genvar h = 0; h < 2; h++) begin : g_hidden_half
        wire half_wr = h_wr && g_write_col[side][0] == 1'(p) && g_write_col[side][7] == 1'(h);
        ac_row_store #(.WIDTH(16), .DEPTH(64)) u_hidden(.clk, .rst_n, .wr(half_wr),
          .rd(h_rd && iss_k[7] == 1'(h)),
          .addr(half_wr ? {2'b0, g_write_col[side][6:1]} : {2'b0, iss_k[6:1]}),
          .data(g_write_data[side]), .q(hidden_half_q[p][h]));
      end
    end
    assign hidden_q[side] = hidden_half_q[0][hidden_half];
    assign hidden_odd_q[side] = hidden_half_q[1][hidden_half];
  end
  always_comb begin
    dbg0_valid = 0; dbg0_kind = 0; dbg0_row = row_i + 7'(nonlin_side); dbg0_idx = 0; dbg0_data = 0;
    dbg1_valid = 0; dbg1_kind = 0; dbg1_row = row_i + 7'(nonlin_side); dbg1_idx = 0; dbg1_data = 0;
    if (ln_out_valid[0] && fd_sel) begin
      dbg0_valid = 1; dbg0_kind = D_OUT; dbg0_idx = 8'(ln_ocol[0]); dbg0_data = ln_norm[0];
    end else if (out_v) begin
      dbg0_valid = 1; dbg0_kind = out_dest; dbg0_row = write_row; dbg0_idx = out_col; dbg0_data = out_data;
    end else if (g_write_valid[0]) begin
      dbg0_valid = 1; dbg0_kind = D_G; dbg0_idx = g_write_col[0]; dbg0_data = 32'(g_write_data[0]);
    end else if (sm_pw[0]) begin
      dbg0_valid = 1; dbg0_kind = D_P; dbg0_idx = 8'(sm_pcol[0]); dbg0_data = sm_pdata[0];
    end else if (ln_out_valid[0]) begin
      dbg0_valid = 1; dbg0_kind = fd_sel ? D_OUT : D_N1;
      dbg0_idx = 8'(ln_ocol[0]); dbg0_data = ln_norm[0];
    end
    if (sm_pw[1]) begin
      dbg1_valid = 1; dbg1_kind = D_P; dbg1_row = row_i + 1'b1;
      dbg1_idx = 8'(sm_pcol[1]); dbg1_data = sm_pdata[1];
    end else if (g_write_valid[1]) begin dbg1_valid = 1; dbg1_kind = D_G; dbg1_row = row_i + 7'd1; dbg1_idx = g_write_col[1]; dbg1_data = 32'(g_write_data[1]); end
    else if (ln_out_valid[1]) begin
      dbg1_valid = 1; dbg1_kind = fd_sel ? D_OUT : D_N1;
      dbg1_row = row_i + 1'b1; dbg1_idx = 8'(ln_ocol[1]); dbg1_data = ln_norm[1];
    end
  end

`ifdef KWT_CYCLE_PROFILE
  // 每个时钟只记入一个调度状态，MAC 发射和排空可与状态重叠。
  longint unsigned state_cycles[0:31], mac_slots, drains, blocked;
  always @(posedge clk) begin
    if (!rst_n) begin
      foreach (state_cycles[i]) state_cycles[i] <= 0;
      mac_slots <= 0;
      drains <= 0;
      blocked <= 0;
    end else if (busy) begin
      state_cycles[st] <= state_cycles[st] + 1;
      if (mac_in_valid) mac_slots <= mac_slots + (s1_pair ? 2 : 1);
      if (v_valid) drains <= drains + 1;
      if (iss_busy && !iss_go) blocked <= blocked + 1;
    end
  end
  final begin
    foreach (state_cycles[i]) $display("KWT_STATE %0d %0d", i, state_cycles[i]);
    $display("KWT_MAC_SLOTS %0d DRAINS %0d ISSUE_BLOCKED %0d", mac_slots, drains, blocked);
  end
`endif

endmodule
`default_nettype wire
