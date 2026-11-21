`default_nettype none
// Exact signed rounded divider. Reciprocal is computed once per row; after
// row_ready, one numerator may be accepted per clock. The qhat correction
// stream preserves the original qhat+correction algorithm and every bit.
module ln_round_divider_stream #(parameter integer TAG_W=32)(
 input logic clk,rst_n,
 input logic row_start,
 input logic [31:0] denominator,
 output logic row_ready,row_error,
 input logic in_valid,
 output logic in_ready,
 input logic signed [56:0] numerator,
 input logic [TAG_W-1:0] in_tag,
 output logic out_valid,
 input logic out_ready,
 output logic signed [63:0] quotient,
 output logic [TAG_W-1:0] out_tag,
 output logic out_error
);
 localparam int CLAT=3;
 localparam int IDX=2;
 logic vcorr_q;
 logic recip_busy,recip_err,cache_valid_q;
 logic [31:0] den_q,cache_den_q;
 logic [56:0] recip_q,cache_recip_q;
 logic recip_ready_q;
 wire recip_start_ready,recip_done,recip_error;
 wire [56:0] recip_result;
 wire recip_hit_on_start=1'b0; // 双路共享行读写地址，倒数运算必须等长。
 wire advance=out_ready||!vcorr_q;
 assign row_ready=rst_n&&recip_ready_q&&!recip_busy;
 assign row_error=recip_err;
 assign in_ready=rst_n&&row_ready&&advance;
 // 根至少为 floor(sqrt(1099512)) = 1048，因此初始十个商位恒为零。
 ln_recip_radix4 u_recip(.clk(clk),.rst_n(rst_n),.start(row_start&&!recip_hit_on_start),
  .numerator({57{1'b1}}),.denominator(denominator),.start_ready(recip_start_ready),
  .done(recip_done),.error(recip_error),.quotient(recip_result));
 wire signed [56:0] absolute=numerator[56]?$unsigned(-numerator):$unsigned(numerator);
 wire [56:0] rounded=absolute+57'(den_q>>1);
 wire fire=rst_n&&in_valid&&in_ready;
 logic [56:0] n_q,recip_d;
 logic sign_q;
 logic [56:0] n_delay[0:7];
 logic sign_delay[0:7];
 logic [7:0] vprod;
 // qhat product pipeline, in-order; carry chains are combinational.
 logic [56:0] np_q[0:2][0:2];
 logic [39:0] nd_q[0:4];
 wire [39:0] ncar1=nd_q[1]+(nd_q[0]>>19);
 wire [39:0] ncar2=nd_q[2]+(ncar1>>19);
 wire [39:0] ncar3=nd_q[3]+(ncar2>>19);
 wire [39:0] ncar4=nd_q[4]+(ncar3>>19);
 wire [56:0] qhat_value={ncar4[37:0],ncar3[18:0]};
 wire [18:0] den_high={6'b0,den_q[31:19]};
 logic [56:0] trial_q;
 // correction product pipeline
 logic [37:0] cp_q[0:2][0:1];
 logic [39:0] cd_q[0:3];
 wire [39:0] ccar1=cd_q[1]+(cd_q[0]>>19);
 wire [39:0] ccar2=cd_q[2]+(ccar1>>19);
 wire [39:0] ccar3=cd_q[3]+(ccar2>>19);
 wire [96:0] correction_value={ccar3,ccar2[18:0],ccar1[18:0],cd_q[0][18:0]};
 logic vcorr[0:CLAT-1];
 logic [56:0] qhat_corr[0:CLAT-1],n_corr[0:CLAT-1];
 logic sign_corr[0:CLAT-1];
 logic [TAG_W-1:0] tag_delay[0:6];
 logic err_delay[0:6];
 logic signed [63:0] quotient_q;
 assign out_valid=vcorr_q;
 assign quotient=quotient_q;
 assign out_tag=tag_delay[6];
 assign out_error=err_delay[6];
 wire corr_now=vcorr[IDX];
 wire correction=correction_value<={40'b0,n_corr[IDX]};
 wire [56:0] exact_quotient=qhat_corr[IDX]+57'(correction);
 integer ip,ish;
 always_ff @(posedge clk)begin
  if(!rst_n)begin
   for(ip=0;ip<3;ip++)begin for(int j=0;j<3;j++)np_q[ip][j]<=0; for(int j=0;j<2;j++)cp_q[ip][j]<=0; end
   for(ip=0;ip<5;ip++)nd_q[ip]<=0; for(ip=0;ip<4;ip++)cd_q[ip]<=0;
  end else if(advance)begin
   for(ip=0;ip<3;ip++)begin
    for(int j=0;j<3;j++)np_q[ip][j]<=n_q[ip*19+:19]*recip_d[j*19+:19];
    cp_q[ip][0]<=trial_q[ip*19+:19]*den_q[18:0];
    cp_q[ip][1]<=trial_q[ip*19+:19]*den_high;
   end
   nd_q[0]<={2'b0,np_q[0][0]};
   nd_q[1]<={2'b0,np_q[0][1]}+{2'b0,np_q[1][0]};
   nd_q[2]<={2'b0,np_q[0][2]}+{2'b0,np_q[1][1]}+{2'b0,np_q[2][0]};
   nd_q[3]<={2'b0,np_q[1][2]}+{2'b0,np_q[2][1]};
   nd_q[4]<={2'b0,np_q[2][2]};
   cd_q[0]<={2'b0,cp_q[0][0]};
   cd_q[1]<={2'b0,cp_q[0][1]}+{2'b0,cp_q[1][0]};
   cd_q[2]<={2'b0,cp_q[1][1]}+{2'b0,cp_q[2][0]};
   cd_q[3]<={2'b0,cp_q[2][1]};
  end
 end
 always_ff @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   recip_busy<=0;recip_err<=0;cache_valid_q<=0;den_q<=0;cache_den_q<=0;
   recip_q<=0;cache_recip_q<=0;recip_ready_q<=0;sign_q<=0;n_q<=0;recip_d<=0;vprod<=0;
   trial_q<=0;quotient_q<=0;vcorr_q<=0;
   for(ish=0;ish<8;ish++)begin n_delay[ish]<=0;sign_delay[ish]<=0;end
   for(ish=0;ish<CLAT;ish++)begin vcorr[ish]<=0;qhat_corr[ish]<=0;n_corr[ish]<=0;sign_corr[ish]<=0;end
   for(ish=0;ish<7;ish++)begin tag_delay[ish]<=0;err_delay[ish]<=0;end
  end else begin
   if(row_start)begin
    den_q<=denominator;recip_ready_q<=0;recip_err<=0;
    if(recip_hit_on_start)begin recip_q<=cache_recip_q;recip_d<=cache_recip_q;recip_ready_q<=1;recip_busy<=0;end
    else recip_busy<=1;
   end
   if(recip_done)begin
    recip_q<=recip_result;recip_d<=recip_result;cache_recip_q<=recip_result;cache_den_q<=den_q;cache_valid_q<=!recip_error;
    recip_busy<=0;recip_err<=recip_error;recip_ready_q<=!recip_error;
   end
   if(advance)begin
    vprod<={vprod[6:0],fire};
    if(fire)begin n_q<=rounded;sign_q<=numerator[56];n_delay[0]<=rounded;sign_delay[0]<=numerator[56];
      tag_delay[0]<=in_tag;err_delay[0]<=den_q==0;end
    for(ish=7;ish>0;ish=ish-1)begin n_delay[ish]<=n_delay[ish-1];sign_delay[ish]<=sign_delay[ish-1];end
    for(ish=6;ish>0;ish=ish-1)begin tag_delay[ish]<=tag_delay[ish-1];err_delay[ish]<=err_delay[ish-1];end
    if(vprod[2])begin
     trial_q<=qhat_value+57'd1;
     qhat_corr[0]<=qhat_value;n_corr[0]<=n_delay[2];sign_corr[0]<=sign_delay[2];vcorr[0]<=1;
    end else vcorr[0]<=0;
    for(ish=CLAT-1;ish>0;ish=ish-1)begin
     vcorr[ish]<=vcorr[ish-1];qhat_corr[ish]<=qhat_corr[ish-1];n_corr[ish]<=n_corr[ish-1];sign_corr[ish]<=sign_corr[ish-1];
    end
    vcorr_q<=vcorr[IDX];
    if(corr_now)begin
     quotient_q<=sign_corr[IDX]?-$signed({7'b0,exact_quotient}):$signed({7'b0,exact_quotient});
    end
   end
  end
 end
endmodule
`default_nettype wire