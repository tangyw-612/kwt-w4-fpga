`default_nettype none
// Streaming exact square: one magnitude per clock, fixed seven-stage latency.
module ln_square_stream(input logic clk,rst_n,start,input logic [32:0] magnitude,
 output logic out_valid,output logic [65:0] result);
logic [6:0] token;logic [32:0] mq;wire [39:0] padded={7'b0,mq};logic [15:0] pp[0:24];logic [71:0] l1[0:12],l2[0:6],l3[0:3],l4[0:1],l5;
function automatic [71:0] fastadd(input logic [71:0] a,b);
 logic [8:0] t;logic c;integer k;begin c=0;for(k=0;k<9;k=k+1)begin t={1'b0,a[k*8+:8]}+{1'b0,b[k*8+:8]};fastadd[k*8+:8]=t[7:0]+c;c=t[8]|((&(a[k*8+:8]^b[k*8+:8]))&c);end end
endfunction
logic out_valid_q;assign out_valid=out_valid_q;
for(genvar i=0;i<5;i++)begin:gi for(genvar j=0;j<5;j++)begin:gj
 always_ff @(posedge clk)pp[i*5+j]<=padded[i*8+:8]*padded[j*8+:8];
end end
for(genvar k=0;k<13;k++)begin:g1
 localparam int a=2*k,b=2*k+1;
 wire [71:0] va=({56'b0,pp[a]}<<(8*((a/5)+(a%5))));
 if(b<25)begin wire [71:0] vb=({56'b0,pp[b]}<<(8*((b/5)+(b%5))));always_ff @(posedge clk)l1[k]<=fastadd(va,vb);end
 else always_ff @(posedge clk)l1[k]<=va;
end
for(genvar k=0;k<7;k++)begin:g2 if(2*k+1<13)always_ff @(posedge clk)l2[k]<=fastadd(l1[2*k],l1[2*k+1]);else always_ff @(posedge clk)l2[k]<=l1[2*k];end
for(genvar k=0;k<4;k++)begin:g3 if(2*k+1<7)always_ff @(posedge clk)l3[k]<=fastadd(l2[2*k],l2[2*k+1]);else always_ff @(posedge clk)l3[k]<=l2[2*k];end
for(genvar k=0;k<2;k++)begin:g4 always_ff @(posedge clk)l4[k]<=fastadd(l3[2*k],l3[2*k+1]);end
always_ff @(posedge clk)l5<=fastadd(l4[0],l4[1]);
always_ff @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin token<=0;mq<=0;result<=0;out_valid_q<=0;end
 else begin token<={token[5:0],start};out_valid_q<=token[6];if(start)mq<=magnitude;if(token[6])result<=l5[65:0];end
end
endmodule
`default_nettype wire
