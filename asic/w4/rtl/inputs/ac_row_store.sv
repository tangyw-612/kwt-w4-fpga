`default_nettype none
// 行缓存使用赛题已有的单端口宏，读请求后一拍返回。
module ac_row_store #(parameter int WIDTH=32, DEPTH=128)(
  input wire clk, rst_n, wr, rd,
  input wire [7:0] addr,
  input wire [WIDTH-1:0] data,
  output wire [WIDTH-1:0] q
);
  localparam int BANKS=(DEPTH+127)/128;
  reg wr_q, rd_q, bank_q;
  reg [7:0] addr_q;
  reg [WIDTH-1:0] data_q;
  wire [WIDTH-1:0] bank_data [BANKS];
  always @(negedge clk or negedge rst_n)
    if(!rst_n) begin wr_q<=0; rd_q<=0; addr_q<=0; data_q<=0; end
    else begin wr_q<=wr; rd_q<=rd; addr_q<=addr; data_q<=data; end
  always @(posedge clk or negedge rst_n)
    if(!rst_n) bank_q<=0;
    else if(rd_q) bank_q<=addr_q[7];
  for(genvar b=0;b<BANKS;b++) begin : g_bank
    wire en=(wr_q||rd_q)&&(BANKS==1||addr_q[7]==1'(b));
    for(genvar h=0;h<WIDTH/16;h++) begin : g_half
      RAMSP128X16 u_ram(.Q(bank_data[b][h*16+:16]),.CLK(clk),.CEN(!en),
        .WEN(16'h0000),.A(addr_q[6:0]),.D(data_q[h*16+:16]),
        .EMA(3'b010),.EMAW(2'b01),.GWEN(!wr_q),.RET1N(1'b1));
    end
  end
  assign q=BANKS==1?bank_data[0]:bank_data[bank_q];
`ifndef SYNTHESIS
  always @(posedge clk) if(rst_n) begin
    if(wr&&rd) $fatal(1,"ROW_PORT_CONFLICT");
    if((wr||rd)&&int'(addr)>=DEPTH) $fatal(1,"ROW_ADDRESS_RANGE");
  end
`endif
endmodule
`default_nettype wire
