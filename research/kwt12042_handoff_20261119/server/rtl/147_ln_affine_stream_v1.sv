`default_nettype none
// Exact signed32 product, beta<<24, ties-away shift28, signed32 saturation.
// Ten stages; beta and opaque metadata travel with their own feature.
module ln_affine_stream_v1 #(parameter integer TAG_W=32)(
 input wire clk,rst_n,in_valid,output wire in_ready,
 input wire signed[31:0]normalized,gamma_data,beta_data,
 input wire[TAG_W-1:0]in_tag,output wire out_valid,input wire out_ready,
 output logic signed[31:0]result,output wire[TAG_W-1:0]out_tag);
 logic[9:0]valid_q;logic[TAG_W-1:0]tag_q[0:9];
 logic signed[31:0]xq,gq,beta_q[0:5];
 logic signed[17:0]pp[0:15];
 logic signed[63:0]pair_q[0:7],quad_q[0:3],oct_q[0:1],prod_q,affine_q;
 logic[16:0]round_lo;logic[20:0]round_hi;logic signed[36:0]rounded_q;
 wire advance=!valid_q[9]||out_ready;
 wire inc=affine_q[27]&&(!affine_q[63]||(|affine_q[26:0]));
 wire signed[31:0]sat=(rounded_q>37'sd2147483647)?32'sh7fffffff:
  (rounded_q< -37'sd2147483648)?32'sh80000000:rounded_q[31:0];
 assign in_ready=rst_n&&advance;assign out_valid=rst_n&&valid_q[9];assign out_tag=tag_q[9];
 function automatic[63:0]add64(input logic[63:0]a,b);
  logic[8:0]t;logic c;integer k;begin c=0;for(k=0;k<8;k=k+1)begin
   t={1'b0,a[k*8+:8]}+{1'b0,b[k*8+:8]};add64[k*8+:8]=t[7:0]+c;
   c=t[8]|((&(a[k*8+:8]^b[k*8+:8]))&c);end end
 endfunction
 for(genvar i=0;i<4;i++)begin:gx for(genvar j=0;j<4;j++)begin:gg
  wire signed[8:0]xx=i==3?$signed({xq[31],xq[8*i+:8]}):$signed({1'b0,xq[8*i+:8]});
  wire signed[8:0]g=j==3?$signed({gq[31],gq[8*j+:8]}):$signed({1'b0,gq[8*j+:8]});
  always_ff @(posedge clk)if(advance)pp[4*i+j]<=xx*g;
 end end
 for(genvar k=0;k<8;k++)begin:gp
  localparam integer I0=(2*k)/4,J0=(2*k)%4,I1=(2*k+1)/4,J1=(2*k+1)%4;
  always_ff @(posedge clk)if(advance)pair_q[k]<=($signed({{46{pp[2*k][17]}},pp[2*k]})<<<(8*(I0+J0)))+($signed({{46{pp[2*k+1][17]}},pp[2*k+1]})<<<(8*(I1+J1)));
 end
 for(genvar k=0;k<4;k++)begin:g_quad always_ff @(posedge clk)if(advance)quad_q[k]<=add64(pair_q[2*k],pair_q[2*k+1]);end
 for(genvar k=0;k<2;k++)begin:go always_ff @(posedge clk)if(advance)oct_q[k]<=add64(quad_q[2*k],quad_q[2*k+1]);end
 always_ff @(posedge clk)if(advance)begin
  prod_q<=add64(oct_q[0],oct_q[1]);
  affine_q<=add64(prod_q,($signed({{32{beta_q[5][31]}},beta_q[5]})<<<24));
  round_lo<={1'b0,affine_q[43:28]}+inc;round_hi<={affine_q[63],affine_q[63:44]};
  rounded_q<={round_hi+round_lo[16],round_lo[15:0]};result<=sat;
 end
 always_ff @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid_q<=0;xq<=0;gq<=0;for(integer i=0;i<10;i++)tag_q[i]<=0;for(integer i=0;i<6;i++)beta_q[i]<=0;end
  else if(advance)begin
   valid_q<={valid_q[8:0],in_valid};tag_q[0]<=in_tag;
   for(integer i=1;i<10;i++)tag_q[i]<=tag_q[i-1];
   beta_q[0]<=beta_data;for(integer i=1;i<6;i++)beta_q[i]<=beta_q[i-1];
   if(in_valid)begin xq<=normalized;gq<=gamma_data;end
  end
 end
endmodule
`default_nettype wire
