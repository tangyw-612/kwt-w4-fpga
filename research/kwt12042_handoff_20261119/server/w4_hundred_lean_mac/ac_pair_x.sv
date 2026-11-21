`default_nettype none
// 将 99×64 激活按行奇偶分到原有四个宏。成对读取共用列地址。
module ac_pair_x (
  input wire clk, rst_n, wr, rd, pair_rd, col_pair_rd,
  input wire [12:0] addr,
  input wire [31:0] wdata, wdata_other,
  input wire pair_wr,
  output wire [31:0] q, q_other, q_odd, q_other_odd
);
  logic wr_q, rd_q, row_pair_q, col_pair_q, pair_wr_q, row_q, col_q;
  logic rd_row, rd_col, rd_depth;
  logic [10:0] addr_q;
  logic [31:0] data_q, other_q;
  wire [31:0] data [2][2][2];
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin wr_q <= 0; rd_q <= 0; end
    else begin wr_q <= wr; rd_q <= rd; end
  end
  always_ff @(negedge clk) begin
    if (rd || wr) begin
      addr_q <= {addr[12:7], addr[5:1]};
      row_q <= addr[6];
      col_q <= addr[0];
      row_pair_q <= pair_rd;
      col_pair_q <= col_pair_rd;
      pair_wr_q <= pair_wr;
    end
    if (wr) data_q <= wdata;
    if (pair_wr) other_q <= wdata_other;
  end
  always_ff @(posedge clk) if (rd_q) begin
    rd_row <= row_q;
    rd_col <= col_q;
    rd_depth <= addr_q[10];
  end
  for (genvar r = 0; r < 2; r++) begin : g_row
    for (genvar c = 0; c < 2; c++) begin : g_column
      for (genvar bank = 0; bank < 2; bank++) begin : g_depth
        wire in_depth = addr_q[10] == 1'(bank);
        wire writing = wr_q && in_depth && (pair_wr_q || row_q == 1'(r)) && col_q == 1'(c);
        wire reading = rd_q && in_depth && (row_pair_q || row_q == 1'(r)) && (col_pair_q || col_q == 1'(c));
        wire [31:0] in_data = r == 1 && pair_wr_q ? other_q : data_q;
        for (genvar half = 0; half < 2; half++) begin : g_half
          RAMSP1024X16 m(.Q(data[r][c][bank][half*16 +: 16]), .CLK(clk), .CEN(!(reading || writing)),
            .WEN(16'b0), .A(addr_q[9:0]), .D(in_data[half*16 +: 16]),
            .EMA(3'b010), .EMAW(2'b01), .GWEN(!writing), .RET1N(1'b1));
        end
      end
    end
  end
  assign q = data[rd_row][rd_col][rd_depth];
  assign q_other = data[!rd_row][rd_col][rd_depth];
  assign q_odd = data[rd_row][!rd_col][rd_depth];
  assign q_other_odd = data[!rd_row][!rd_col][rd_depth];
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    if (rd && wr) $fatal(1, "PAIR_X_PORT_CONFLICT");
    if (pair_rd && (!rd || addr[6])) $fatal(1, "PAIR_X_INVALID_ROW_PAIR");
    if (col_pair_rd && (!rd || addr[0])) $fatal(1, "PAIR_X_INVALID_COLUMN_PAIR");
  end
`endif
endmodule
`default_nettype wire
