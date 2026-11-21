// Arch C M1 memory wrappers. Same request convention as I09C official_* wrappers:
// request captured on the falling edge, macro accessed on the rising edge, so read
// data is valid in the cycle after the request (1-cycle latency). rd and wr exclusive.
`default_nettype none
module ac_mem16 (input wire clk, rst_n, wr, rd, input wire [9:0] addr,
                 input wire [15:0] wdata, output wire [15:0] q);
  reg wr_q, rd_q; reg [9:0] a_q; reg [15:0] d_q;
  always @(negedge clk or negedge rst_n)
    if (!rst_n) begin wr_q <= 0; rd_q <= 0; a_q <= 0; d_q <= 0; end
    else begin wr_q <= wr; rd_q <= rd; a_q <= addr; d_q <= wdata; end
  RAMSP1024X16 m(.Q(q), .CLK(clk), .CEN(!(wr_q || rd_q)), .WEN(16'h0000), .A(a_q), .D(d_q),
                 .EMA(3'b010), .EMAW(2'b01), .GWEN(!wr_q), .RET1N(1'b1));
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && wr && rd) $fatal(1, "ac_mem16 rd/wr conflict");
`endif
endmodule

// 99x64x32b activation store: 2 banks (addr[12]) x hi/lo halves of RAMSP4096X16.
module ac_mem_x (input wire clk, rst_n, wr, rd, input wire [12:0] addr,
                 input wire [31:0] wdata, output wire [31:0] q);
  reg wr_q, rd_q, sel_q; reg [12:0] a_q; reg [31:0] d_q;
  wire [31:0] bq [0:1];
  always @(negedge clk or negedge rst_n)
    if (!rst_n) begin wr_q <= 0; rd_q <= 0; a_q <= 0; d_q <= 0; end
    else begin wr_q <= wr; rd_q <= rd; a_q <= addr; d_q <= wdata; end
  always @(posedge clk or negedge rst_n) if (!rst_n) sel_q <= 0; else if (rd_q) sel_q <= a_q[12];
  for (genvar b = 0; b < 2; b++) begin : bank
    for (genvar j = 0; j < 2; j++) begin : half
      wire en = (wr_q || rd_q) && (a_q[12] == 1'(b));
      RAMSP4096X16 m(.Q(bq[b][j*16 +: 16]), .CLK(clk), .CEN(!en), .WEN(16'h0000), .A(a_q[11:0]),
                     .D(d_q[j*16 +: 16]), .EMA(3'b010), .EMAW(2'b01), .GWEN(!wr_q), .RET1N(1'b1));
    end
  end
  assign q = bq[sel_q];
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && wr && rd) $fatal(1, "ac_mem_x rd/wr conflict");
`endif
endmodule

// 64-bit bias store (384 entries used), 4 x RAMSP1024X16; write per 32-bit half.
module ac_mem_bias (input wire clk, rst_n, wr, rd, input wire [1:0] wmask, input wire [9:0] addr,
                    input wire [63:0] wdata, output wire [63:0] q);
  reg wr_q, rd_q; reg [1:0] m_q; reg [9:0] a_q; reg [63:0] d_q;
  always @(negedge clk or negedge rst_n)
    if (!rst_n) begin wr_q <= 0; rd_q <= 0; m_q <= 0; a_q <= 0; d_q <= 0; end
    else begin wr_q <= wr; rd_q <= rd; m_q <= wmask; a_q <= addr; d_q <= wdata; end
  for (genvar j = 0; j < 4; j++) begin : s
    wire en = rd_q || (wr_q && m_q[j/2]);
    RAMSP1024X16 m(.Q(q[j*16 +: 16]), .CLK(clk), .CEN(!en), .WEN(16'h0000), .A(a_q), .D(d_q[j*16 +: 16]),
                   .EMA(3'b010), .EMAW(2'b01), .GWEN(!wr_q), .RET1N(1'b1));
  end
endmodule
`default_nettype wire
