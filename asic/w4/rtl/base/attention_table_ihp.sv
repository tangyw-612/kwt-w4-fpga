`default_nettype none
module attention_table_ihp(input logic clk,rst_n,write_valid,input logic [12:0] write_addr,input logic [31:0] write_data,input logic read_valid,input logic [12:0] address_a,address_b,output logic [31:0] data_a,data_b);
logic select_q,last_sel_q;logic [31:0] last_value,last_q;wire [31:0] even_q,odd_q;
wire [11:0] even_index=address_a[0]?address_b[12:1]:address_a[12:1];wire [10:0] odd_index=address_a[0]?address_a[11:1]:address_b[11:1];
wire ew=rst_n&&write_valid&&!write_addr[0]&&!write_addr[12];wire ow=rst_n&&write_valid&&write_addr[0];wire lw=rst_n&&write_valid&&!write_addr[0]&&write_addr[12];
wire er=rst_n&&read_valid&&!even_index[11];wire lr=rst_n&&read_valid&&even_index[11];wire r=rst_n&&read_valid;
always_ff @(posedge clk)begin if(lw)last_value<=write_data;if(lr)last_q<=last_value;if(r)begin select_q<=address_a[0];last_sel_q<=even_index[11];end end
wire [31:0] even_value=last_sel_q?last_q:even_q;assign data_a=select_q?odd_q:even_value;assign data_b=select_q?even_value:odd_q;
official_2048x32_1p even_mem(.clk(clk),.rst_n(rst_n),.wr(ew),.rd(er),.addr(ew?write_addr[11:1]:even_index[10:0]),.data(write_data),.mask(32'hffffffff),.q(even_q));
official_2048x32_1p odd_mem(.clk(clk),.rst_n(rst_n),.wr(ow),.rd(r),.addr(ow?write_addr[11:1]:odd_index),.data(write_data),.mask(32'hffffffff),.q(odd_q));
`ifndef SYNTHESIS
always @(posedge clk)begin if((ew&&er)||(ow&&r)||(lw&&lr))$fatal(1,"table single-port conflict");if(r&&even_index>2048)$fatal(1,"invalid even table index");end
`endif
endmodule
`default_nettype wire
