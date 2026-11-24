`default_nettype none
// Four 1024x16 macros: address bit 10 selects a bank; two halfwords per bank.
// No read/write overlap; falling-edge request capture requires half-cycle STA.
module official_2048x32_1p(input wire clk,rst_n,wr,rd,input wire [10:0] addr,
 input wire [31:0] data,mask,output wire [31:0] q);
 reg wr_q,rd_q,sel_q;reg [10:0] addr_q;reg [31:0] data_q,mask_q;
 wire [31:0] bank_q[0:1];
 always @(negedge clk or negedge rst_n) begin
  if(!rst_n)begin wr_q<=0;rd_q<=0;addr_q<=0;data_q<=0;mask_q<=0;end
  else begin wr_q<=wr;rd_q<=rd;addr_q<=addr;data_q<=data;mask_q<=mask;end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)sel_q<=0;else if(rd_q)sel_q<=addr_q[10];
 end
 for(genvar b=0;b<2;b=b+1)begin: bank
  for(genvar j=0;j<2;j=j+1)begin: slice
   wire en=(wr_q||rd_q)&&(addr_q[10]==1'(b));
   RAMSP1024X16 m(.Q(bank_q[b][j*16+:16]),.CLK(clk),.CEN(!en),
    .WEN(~mask_q[j*16+:16]),.A(addr_q[9:0]),.D(data_q[j*16+:16]),
    .EMA(3'b010),.EMAW(2'b01),.GWEN(!wr_q),.RET1N(1'b1));
  end
 end
 assign q=bank_q[sel_q];
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n && wr && rd)$fatal(1,"official 1P conflict");
`endif
endmodule
`default_nettype wire
