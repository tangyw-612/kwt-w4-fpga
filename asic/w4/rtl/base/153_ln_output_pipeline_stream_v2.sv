`default_nettype none
// Area-reduced LN divide/affine tail. The row denominator is supplied once
// through row_start; the reciprocal is shared by every feature of the row so
// the divider carries only a 7-stage metadata pipe, not the v24 89-stage one.
module ln_output_pipeline_stream_v2 #(parameter integer TAG_W=32)(
 input wire clk,rst_n,row_start,in_valid,output wire in_ready,
 input wire signed[56:0]numerator,input wire[31:0]denominator,
 input wire signed[31:0]gamma_data,beta_data,residual,input wire[TAG_W-1:0]in_tag,
 output wire out_valid,input wire out_ready,output wire signed[31:0]result,out_residual,
 output wire signed[63:0]out_quotient,output wire out_error,output wire[TAG_W-1:0]out_tag);
 localparam integer MW=TAG_W+96;
 wire dv,dr,de; wire signed[63:0]dq;wire[MW-1:0]dm;
 wire[TAG_W+96:0]am;
 ln_round_divider_stream #(.TAG_W(MW)) divpipe(.clk(clk),.rst_n(rst_n),.row_start(row_start),
 .denominator(denominator),.row_ready(),.row_error(),
 .in_valid(in_valid),.in_ready(in_ready),.numerator(numerator),
 .in_tag({gamma_data,beta_data,residual,in_tag}),
 .out_valid(dv),.out_ready(dr),.quotient(dq),.out_tag(dm),.out_error(de));
 ln_affine_stream_v1 #(.TAG_W(TAG_W+97)) affine(.clk(clk),.rst_n(rst_n),
 .in_valid(dv),.in_ready(dr),.normalized(dq[31:0]),.gamma_data(dm[MW-1-:32]),
 .beta_data(dm[MW-33-:32]),.in_tag({dq,de,dm[TAG_W-1:0],dm[TAG_W+:32]}),
 .out_valid(out_valid),.out_ready(out_ready),.result(result),.out_tag(am));
 assign {out_quotient,out_error,out_tag,out_residual}=am;
endmodule
`default_nettype wire