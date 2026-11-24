// Arch C NICE core. Drop-in replacement for the I09C encoder_nice_core (same module name and
// ports, so the frozen E203 SoC top, firmware protocol, host model and testbench are reused).
//
// One NICE instruction per layer (.insn r 0x7b, 7, 0x21, rd, rs1=descriptor, rs2=0), as in I09C:
//   read 16-word descriptor -> DMA layer input X from A (every layer) -> [layer 0: GELU, EXP tables, start ac_enc]
//   -> DMA this layer's parameters (25,281 words, layout in m2/pack_params.py) into the idle banks + COMMIT
//   -> wait for ac_enc to finish the layer -> write the 99x64 output back to the descriptor y address
//   -> respond. All memory traffic goes through nice_icb (E203 LSU), one word in flight.
`default_nettype none
// MODE B (copy arch_c_B_20261113): each call loads one layer's parameters and returns after COMMIT,
// so the next layer's host write + NICE load overlap the current layer's compute. Layer 0 also loads X and
// the tables and starts ac_enc; the layer-11 call additionally waits for all 12 layers and writes Y back.
// Firmware and the descriptor protocol are unchanged.
module encoder_nice_core #(parameter int TOKENS=99, parameter bit TABLE_CACHE_ENABLE=0, parameter bit MODE_B=1)(
    output wire [175:0] kwt_att_storage,
    output wire [31:0] kwt_ln_storage,
    output wire [55:0] kwt_ffn_storage,
    input logic nice_clk, nice_rst_n,
    output wire [11:0] kwt_observe_cache,
    output logic nice_active, nice_mem_holdup,
    input logic nice_req_valid,
    output logic nice_req_ready,
    input logic [31:0] nice_req_inst, nice_req_rs1, nice_req_rs2,
    output logic nice_rsp_valid,
    input logic nice_rsp_ready,
    output logic [31:0] nice_rsp_rdat,
    output logic nice_rsp_err, nice_icb_cmd_valid,
    input logic nice_icb_cmd_ready,
    output logic [31:0] nice_icb_cmd_addr,
    output logic nice_icb_cmd_read,
    output logic [31:0] nice_icb_cmd_wdata,
    output logic [1:0] nice_icb_cmd_size,
    input logic nice_icb_rsp_valid,
    output logic nice_icb_rsp_ready,
    input logic [31:0] nice_icb_rsp_rdata,
    input logic nice_icb_rsp_err,
    output logic monitor_layer_start, monitor_layer_success, monitor_last_write_ack,
    output logic [31:0] monitor_task, monitor_epoch,
    output logic [3:0] monitor_layer,
    output logic [13:0] obs_valid,
    output logic [6:0] obs_row [0:13],
    output logic [7:0] obs_col [0:13],
    output logic [31:0] obs_data [0:13]
);
  localparam int NX = 99 * 64, NTAB = 4097, NPAR = 7137;
  wire clk = nice_clk, rst_n = nice_rst_n;
  assign kwt_att_storage = '0; assign kwt_ln_storage = '0; assign kwt_ffn_storage = '0;
  assign obs_valid = '0;
  for (genvar i = 0; i < 14; i++) begin : g_obs
    assign obs_row[i] = '0; assign obs_col[i] = '0; assign obs_data[i] = '0;
  end

  // ------------------------------------------------------------- accelerator
  logic ac_ld_valid; wire ac_ld_ready; logic [63:0] ac_ld_word; logic ac_start;
  wire ac_busy, ac_done, ac_next_free, ac_layer_done; wire [31:0] ac_cycles, ac_wait; wire [3:0] ac_layer;
  logic xr_valid; logic [12:0] xr_addr; wire [31:0] xr_data;
  wire d0v, d1v; wire [3:0] d0k, d1k; wire [6:0] d0r, d1r; wire [7:0] d0i, d1i; wire [31:0] d0d, d1d;
  ac_enc #(.L(32)) u_ac(.clk, .rst_n, .ld_valid(ac_ld_valid), .ld_ready(ac_ld_ready), .ld_word(ac_ld_word),
    .start(ac_start), .busy(ac_busy), .done(ac_done), .cycles(ac_cycles), .wait_cycles(ac_wait), .cur_layer(ac_layer),
    .next_free(ac_next_free), .xr_valid(xr_valid), .xr_addr(xr_addr), .xr_data(xr_data), .layer_done(ac_layer_done),
    .dbg0_valid(d0v), .dbg1_valid(d1v), .dbg0_kind(d0k), .dbg1_kind(d1k), .dbg0_row(d0r), .dbg1_row(d1r),
    .dbg0_idx(d0i), .dbg1_idx(d1i), .dbg0_data(d0d), .dbg1_data(d1d));

  // ------------------------------------------------------------- instruction / descriptor
  typedef enum logic [3:0] {IDLE, DESC_CMD, DESC_RSP, CHECK, DMA_CMD, DMA_RSP, DMA_BEAT, START_AC,
                            WAIT_LAYER, WB_READ, WB_CMD, WB_RSP, SUCCESS, RESPONSE} st_t;
  st_t st;
  logic [31:0] fields [0:15];
  logic [31:0] desc_ptr; logic [3:0] desc_i;
  logic [31:0] status;
  // DMA job: 0 = X, 1 = GELU, 2 = EXP, 3 = parameters
  logic [1:0] job; logic [14:0] widx, wcount; logic [31:0] wbase; logic [31:0] wdata_q; logic [2:0] beat;
  logic [12:0] wb_i; logic [31:0] wb_data;
  logic layer_seen, enc_done_seen;
  wire wb_has_next = wb_i != 13'(NX - 1);
  wire wb_chain = st == WB_RSP && nice_icb_rsp_valid && !nice_icb_rsp_err && wb_has_next;
  wire [3:0] layer = fields[3][3:0];
  wire legal = nice_req_inst[6:0] == 7'h7b && nice_req_inst[14:12] == 3'd7 && nice_req_inst[31:25] == 7'h21 &&
               nice_req_rs2 == 0 && nice_req_rs1[1:0] == 0;
  wire fields_ok = fields[0] == 32'h454e4331 && fields[1] == 1 && fields[3] < 12 && fields[8] == 28548;

  assign nice_req_ready = rst_n && st == IDLE;
  assign nice_active = st != IDLE || nice_req_valid;
  assign nice_mem_holdup = st != IDLE && st != RESPONSE;
  assign nice_rsp_valid = st == RESPONSE;
  assign nice_rsp_rdat = status;
  assign nice_icb_cmd_size = 2'd2;
  assign monitor_task = fields[2]; assign monitor_epoch = fields[4]; assign monitor_layer = layer;

  // ------------------------------------------------------------- word -> load beats (see pack_params.py)
  function automatic logic [63:0] beat_word(input logic [1:0] jb, input logic [14:0] i, input logic [31:0] d,
                                            input logic [2:0] b, output logic last);
    logic [3:0] reg_; logic [27:0] a; logic [31:0] v; logic [12:0] j; logic [8:0] e;
    reg_ = 0; a = 0; v = d; last = 1;
    if (jb == 0)      begin reg_ = 4'd1; a = 28'(i); end
    else if (jb == 1) begin reg_ = 4'd8; a = 28'(i); end
    else if (jb == 2) begin reg_ = 4'd7; a = 28'(i); end
    else if (i < 8192) begin
      reg_ = 4'd2; a = 28'({i[9:6], 1'b0, i[12:11], i[10], i[5:0]});           // {lane, mat, g, k}
    end else if (i < 16384) begin
      j = 13'(i - 15'd8192);
      reg_ = 4'd3; a = 28'({j[9:6], 1'b0, 1'b0, j[12:10], j[5:0]});            // {lane, 0, g, k}
    end else if (i < 24576) begin
      j = 13'(i - 15'd16384);
      reg_ = 4'd3; a = 28'({j[11:8], 1'b0, 1'b1, j[12], j[7:0]});              // {lane, 1, g, k}
    end else if (i < 24704) begin
      reg_ = 4'd4; a = 28'(i - 15'd24576);
    end else if (i < 25024) begin
      e = (i < 24960) ? 9'(9'd64 + (i - 15'd24704)) : 9'(9'd320 + (i - 15'd24960));
      reg_ = 4'd4; a = 28'({e, b[0]}); v = b[0] ? {32{d[31]}} : d; last = b[0];
    end else if (i < 25280) begin
      reg_ = 4'd5; a = 28'(i - 15'd25024);
    end else begin
      if (b < 5) begin reg_ = 4'd9; a = 28'(b); v = 32'((d >> (6 * b)) & 32'h3f); last = 0; end
      else begin reg_ = 4'd10; a = 0; v = 0; last = 1; end
    end
    return {reg_, a, v};
  endfunction
  logic beat_last; logic [63:0] beat_w;
  localparam int SCALE_WORDS = 288, PACKED_END = 6432;
  logic [14:0] logical_index;
  logic [31:0] packed_lanes;
  always_comb begin
    logical_index = widx;
    packed_lanes = wdata_q;
    if (job == 2'd3 && widx >= SCALE_WORDS) begin
      if (widx < PACKED_END) begin
        logical_index = (widx - 15'd288) << 2;
        // 一个总线字覆盖相邻两列，每列连续四个归约位置。
        for (int k = 0; k < 4; k++) begin
          packed_lanes[4*k +: 4] = wdata_q[8*k +: 4];
          packed_lanes[16+4*k +: 4] = wdata_q[8*k+4 +: 4];
        end
      end else logical_index = widx - 15'd6432 + 15'd24576;
    end
    if (job == 2'd3 && widx < SCALE_WORDS) begin
      beat_w = {4'd11, 28'(widx), wdata_q};
      beat_last = 1'b1;
    end else beat_w = beat_word(job, logical_index, packed_lanes, beat, beat_last);
  end

  // ------------------------------------------------------------- icb master (one transaction in flight)
  always_comb begin
    nice_icb_cmd_valid = 0; nice_icb_cmd_addr = 0; nice_icb_cmd_read = 1; nice_icb_cmd_wdata = 0;
    nice_icb_rsp_ready = 0;
    case (st)
      DESC_CMD: begin nice_icb_cmd_valid = 1; nice_icb_cmd_addr = desc_ptr + {26'b0, desc_i, 2'b0}; end
      DMA_CMD:  begin nice_icb_cmd_valid = 1; nice_icb_cmd_addr = wbase + {15'b0, widx, 2'b0}; end
      DMA_BEAT: if (ac_ld_ready && beat_last && widx != wcount - 1) begin
        // 当前总线应答已经接收，下一读与片内写入可并行。
        nice_icb_cmd_valid = 1;
        nice_icb_cmd_addr = wbase + {15'b0, (widx + 15'd1), 2'b0};
      end
      WB_CMD:   begin nice_icb_cmd_valid = 1; nice_icb_cmd_addr = fields[6] + {17'b0, wb_i, 2'b0};
                      nice_icb_cmd_read = 0; nice_icb_cmd_wdata = wb_data; end
      WB_RSP: begin
        nice_icb_rsp_ready = 1;
        if (wb_chain) begin
          nice_icb_cmd_valid = 1;
          nice_icb_cmd_addr = fields[6] + {17'b0, (wb_i + 13'd1), 2'b0};
          nice_icb_cmd_read = 0;
          nice_icb_cmd_wdata = wb_data;
        end
      end
      DESC_RSP, DMA_RSP: nice_icb_rsp_ready = 1;
      default: ;
    endcase
  end
  assign ac_ld_valid = st == DMA_BEAT;
  assign ac_ld_word = beat_w;
  // 在当前字被接收后取下一字。当前字的总线数据在接收沿前不变。
  wire wb_prefetch = st == WB_CMD && nice_icb_cmd_ready && wb_has_next;
  wire wb_chain_prefetch = wb_chain && nice_icb_cmd_ready && wb_i != 13'(NX - 2);
  assign xr_valid = st == WB_READ || wb_prefetch || wb_chain_prefetch;
  assign xr_addr = wb_chain_prefetch ? wb_i + 13'd2 : wb_prefetch ? wb_i + 13'd1 : wb_i;
  assign monitor_last_write_ack = st == WB_RSP && nice_icb_rsp_valid && !nice_icb_rsp_err && wb_i == 13'(NX - 1);

  task automatic begin_job(input logic [1:0] jb);
    job <= jb; widx <= 0; beat <= 0;
    case (jb)
      2'd0: begin wbase <= fields[5]; wcount <= 15'(NX); end
      2'd1: begin wbase <= fields[9]; wcount <= 15'(NTAB); end
      2'd2: begin wbase <= fields[10]; wcount <= 15'(NTAB); end
      default: begin wbase <= fields[7]; wcount <= 15'(NPAR); end
    endcase
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE; status <= 0; nice_rsp_err <= 0; desc_ptr <= 0; desc_i <= 0; job <= 0; widx <= 0; wcount <= 0;
      wbase <= 0; wdata_q <= 0; beat <= 0; wb_i <= 0; ac_start <= 0; layer_seen <= 0; enc_done_seen <= 0;
      monitor_layer_start <= 0; monitor_layer_success <= 0;
      for (int i = 0; i < 16; i++) fields[i] <= 0;
    end else begin
      ac_start <= 0; monitor_layer_start <= 0; monitor_layer_success <= 0;
      if (ac_layer_done) layer_seen <= 1;
      if (ac_start) enc_done_seen <= 0; else if (ac_done) enc_done_seen <= 1;
      case (st)
        IDLE: if (nice_req_valid) begin
          status <= 0; nice_rsp_err <= 0;
          if (!legal) begin status <= 1; nice_rsp_err <= 1; st <= RESPONSE; end
          else begin desc_ptr <= nice_req_rs1; desc_i <= 0; st <= DESC_CMD; end
        end
        DESC_CMD: if (nice_icb_cmd_ready) st <= DESC_RSP;
        DESC_RSP: if (nice_icb_rsp_valid) begin
          if (nice_icb_rsp_err) begin status <= 4; st <= RESPONSE; end
          else begin
            fields[desc_i] <= nice_icb_rsp_rdata;
            if (desc_i == 15) st <= CHECK; else begin desc_i <= desc_i + 1'b1; st <= DESC_CMD; end
          end
        end
        CHECK: if (!fields_ok) begin status <= 3; st <= RESPONSE; end
               else begin begin_job((MODE_B && layer != 0) ? 2'd3 : 2'd0); monitor_layer_start <= 1; st <= DMA_CMD; end
        DMA_CMD: if (nice_icb_cmd_ready) st <= DMA_RSP;
        DMA_RSP: if (nice_icb_rsp_valid) begin
          if (nice_icb_rsp_err) begin status <= 4; st <= RESPONSE; end
          else begin wdata_q <= nice_icb_rsp_rdata; beat <= 0; st <= DMA_BEAT; end
        end
        DMA_BEAT: if (ac_ld_ready) begin
          if (!beat_last) beat <= beat + 1'b1;
          else if (widx != wcount - 1) begin widx <= widx + 1'b1; st <= nice_icb_cmd_ready ? DMA_RSP : DMA_CMD; end
          else if (job == 2'd0) begin begin_job(layer == 0 ? 2'd1 : 2'd3); st <= DMA_CMD; end
          else if (job == 2'd1) begin begin_job(2'd2); st <= DMA_CMD; end
          else if (job == 2'd2) st <= START_AC;
          else if (MODE_B && layer != 11) st <= SUCCESS;          // B: parameters committed, compute continues
          else begin layer_seen <= 0; st <= WAIT_LAYER; end   // COMMIT accepted
        end
        START_AC: begin ac_start <= 1; begin_job(2'd3); st <= DMA_CMD; end     // ac_enc waits for COMMIT
        WAIT_LAYER: if (MODE_B ? (enc_done_seen || ac_done) : (layer_seen || ac_layer_done)) begin wb_i <= 0; st <= WB_READ; end
        WB_READ: st <= WB_CMD;                                                // xr data valid next cycle
        WB_CMD: begin
          if (nice_icb_cmd_ready) st <= WB_RSP;
        end
        WB_RSP: if (nice_icb_rsp_valid) begin
          if (nice_icb_rsp_err) begin status <= 4; st <= RESPONSE; end
          else if (wb_i == 13'(NX - 1)) st <= SUCCESS;
          else begin wb_i <= wb_i + 1'b1; st <= nice_icb_cmd_ready ? WB_RSP : WB_CMD; end
        end
        SUCCESS: begin monitor_layer_success <= 1; st <= RESPONSE; end
        RESPONSE: if (nice_rsp_ready) st <= IDLE;
        default: st <= IDLE;
      endcase
    end
  end
  // read-back word: X macro output holds after the WB_READ access until the next X access
  assign wb_data = xr_data;

  assign kwt_observe_cache = {nice_rst_n, 11'b0};
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && st == DMA_BEAT && ac_ld_valid && ac_ld_word[63:60] == 4'd0) $fatal(1, "bad beat");
`endif
endmodule
`default_nettype wire
