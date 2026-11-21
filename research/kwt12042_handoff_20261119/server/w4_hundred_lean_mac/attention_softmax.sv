`default_nettype none
module attention_softmax #(parameter int TOKENS=99, parameter bit PRECOMPUTED_MAX=0) (
    input logic clk,rst_n,start,
    output logic done,error,
    output logic score_read,
    output logic [6:0] score_col,
    input logic signed [31:0] score_data,
    input logic signed [31:0] precomputed_max,
    input logic [6:0] precomputed_col,
    output logic table_read,
    output logic [12:0] table_a,table_b,
    input logic [31:0] table_data_a,table_data_b,
    output logic probability_write,
    output logic [6:0] probability_col,
    output logic [31:0] probability_data
);
    typedef enum logic[3:0]{IDLE,MAX_READ,MAX_USE,EXP_READ,EXP_CAPTURE,EXP_ADDRESS,EXP_USE,
        E_READ,DIV_START,DIV_WAIT,RAW_WRITE,CORRECT,CORRECT_WRITE,E_DRAIN,E_CAPTURE}state_t;
    state_t state_q;
    localparam int COL_W=(TOKENS<=1)?1:$clog2(TOKENS);
    logic [6:0] col_q,max_col_q;
    logic [6:0] max_issue_q, max_return_q;
    logic max_valid_q;
    logic [6:0] exp_issue_q, exp_tag0_q, exp_tag1_q, exp_tag2_q;
    logic exp_v0_q, exp_v1_q, exp_v2_q;
    logic signed [31:0] maximum_q;
    logic signed [32:0] distance,distance_q,correction,corrected;
    logic [23:0] safe_distance;
    logic [11:0] remainder_q;
    logic outside_q;
    logic [31:0] exponent,e_q,p_q,max_probability_q;
    logic e_write_q;logic[6:0]e_write_addr_q;logic[31:0]e_write_data_q,e_ram_data;
    logic stream_req_v,stream_e_v,stream_valid,stream_error; logic[6:0] request_col_q;
    official_e_row128x32 u_e_row(.clk,.rst_n,.wr(e_write_q),.rd(state_q==E_READ&&request_col_q<TOKENS),.addr(e_write_q?e_write_addr_q:request_col_q),.data(e_write_data_q),.q(e_ram_data));
    logic [36:0] denominator_q;
    logic [30:0] probability_sum_q;
    logic [54:0] numerator,quotient;
    logic divide_done,divide_error,unused_divide_ready,exponent_error;
    assign score_read=state_q==MAX_READ||state_q==EXP_READ;
    assign score_col=state_q==MAX_READ?max_issue_q:(state_q==EXP_READ?exp_issue_q:col_q);
    function automatic [32:0] score_difference(input logic signed[31:0] aa,bb);
        logic [4:0] sums[0:7];
        logic [7:0] g0,p0,g1,p1,g2,p2,g3,p3;
        logic [8:0] carries;
        logic [31:0] inv_b;
        begin
            inv_b=~bb;
            for(int k=0;k<8;k++)begin
                sums[k]={1'b0,aa[k*4+:4]}+{1'b0,inv_b[k*4+:4]};
                g0[k]=sums[k][4];p0[k]=&(aa[k*4+:4]^inv_b[k*4+:4]);
            end
            for(int k=0;k<8;k++)begin
                if(k>=1)begin g1[k]=g0[k]|(p0[k]&g0[k-1]);p1[k]=p0[k]&p0[k-1];end
                else begin g1[k]=g0[k];p1[k]=p0[k];end
            end
            for(int k=0;k<8;k++)begin
                if(k>=2)begin g2[k]=g1[k]|(p1[k]&g1[k-2]);p2[k]=p1[k]&p1[k-2];end
                else begin g2[k]=g1[k];p2[k]=p1[k];end
            end
            for(int k=0;k<8;k++)begin
                if(k>=4)begin g3[k]=g2[k]|(p2[k]&g2[k-4]);p3[k]=p2[k]&p2[k-4];end
                else begin g3[k]=g2[k];p3[k]=p2[k];end
            end
            carries[0]=1'b1;
            for(int k=0;k<8;k++)begin
                carries[k+1]=g3[k]|p3[k];
                score_difference[k*4+:4]=sums[k][3:0]+carries[k];
            end
            score_difference[32]=aa[31]^(~bb[31])^carries[8];
        end
    endfunction
    assign distance=score_difference(maximum_q,score_data);
    assign safe_distance=distance_q>=33'sd16777216 ? 24'hffffff:distance_q[23:0];
    assign table_read=exp_v1_q;
    assign table_a={1'b0,safe_distance[23:12]};
    assign table_b=table_a+1'b1;
    attention_exp_interpolate u_exponent(.a(table_data_a),.b(table_data_b),.remainder_value(remainder_q),.outside(outside_q),.exponent(exponent),.error(exponent_error));
    assign numerator=(55'(e_q)<<24)+55'(denominator_q>>1);
    attention_divider_stream55 u_divider(.clk(clk),.rst_n(rst_n&&state_q!=IDLE),.in_valid(stream_e_v&&state_q==E_READ),.numerator(numerator),.denominator(denominator_q),.in_ready(),.out_valid(stream_valid),.error(stream_error),.quotient(quotient));
    assign correction=33'sd16777216-$signed({2'b0,probability_sum_q});
    assign corrected=$signed({1'b0,max_probability_q})+correction;
    assign probability_write=(state_q==E_READ&&stream_valid&&!stream_error&&quotient<=55'd16777216)||state_q==CORRECT_WRITE;
    assign probability_col=state_q==CORRECT_WRITE?max_col_q:col_q;
    assign probability_data=state_q==CORRECT_WRITE?32'(corrected):32'(quotient);
    always_ff @(posedge clk)begin
        if(!rst_n)begin e_write_q<=0;e_write_addr_q<=0;e_write_data_q<=0;stream_req_v<=0;stream_e_v<=0;request_col_q<=0;end
        else begin
            e_write_q<=exp_v2_q&&!exponent_error;
            if(exp_v2_q&&!exponent_error)begin e_write_addr_q<=exp_tag2_q;e_write_data_q<=exponent;end
            stream_req_v<=state_q==E_READ&&request_col_q<TOKENS;stream_e_v<=stream_req_v;
            if(state_q==IDLE)request_col_q<=0;else if(state_q==E_READ&&request_col_q<TOKENS)request_col_q<=request_col_q+1'b1;
            if(stream_req_v)e_q<=e_ram_data;
        end
    end
    always_ff @(posedge clk)begin
        if(!rst_n)begin
            state_q<=IDLE;col_q<=0;max_col_q<=0;maximum_q<=32'sh80000000;max_issue_q<=0;max_return_q<=0;max_valid_q<=0;exp_issue_q<=0;exp_v0_q<=0;exp_v1_q<=0;exp_v2_q<=0;
            remainder_q<=0;outside_q<=0;distance_q<=0;denominator_q<=0;probability_sum_q<=0;p_q<=0;max_probability_q<=0;done<=0;error<=0;
        end else begin
            done<=0;error<=0;
            exp_v0_q<=state_q==EXP_READ;exp_v1_q<=exp_v0_q;exp_v2_q<=exp_v1_q;
            if(state_q==EXP_READ)exp_tag0_q<=exp_issue_q;
            if(exp_v0_q)begin distance_q<=distance;exp_tag1_q<=exp_tag0_q;end
            if(exp_v1_q)begin remainder_q<=safe_distance[11:0];outside_q<=distance_q>=33'sd16777216;exp_tag2_q<=exp_tag1_q;end
            case(state_q)
                IDLE:if(start)begin col_q<=0;max_col_q<=0;max_issue_q<=0;max_return_q<=0;max_valid_q<=0;maximum_q<=32'sh80000000;denominator_q<=0;probability_sum_q<=0;max_probability_q<=0;
                    // 最大值由分数产生端提供，省去独立扫描。
                    if(PRECOMPUTED_MAX) begin
                        maximum_q<=precomputed_max;max_col_q<=precomputed_col;
                        exp_issue_q<=0;state_q<=EXP_READ;
                    end else state_q<=MAX_READ;
                end
                MAX_READ:begin
                    if(max_valid_q && (max_return_q==0 || score_data>maximum_q))begin maximum_q<=score_data;max_col_q<=max_return_q;end
                    max_return_q<=max_issue_q;max_valid_q<=1;
                    if(int'(max_issue_q)==TOKENS-1)state_q<=MAX_USE;
                    else max_issue_q<=max_issue_q+1'b1;
                end
                MAX_USE:begin
                    if(max_valid_q && (max_return_q==0 || score_data>maximum_q))begin maximum_q<=score_data;max_col_q<=max_return_q;end
                    max_valid_q<=0;col_q<=0;exp_issue_q<=0;state_q<=EXP_READ;
                end
                EXP_READ:begin
                    if(int'(exp_issue_q)==TOKENS-1)state_q<=EXP_USE;
                    else exp_issue_q<=exp_issue_q+1'b1;
                    if(exp_v2_q)begin
                        if(exponent_error)begin error<=1;state_q<=IDLE;end
                        else denominator_q<=denominator_q+37'(exponent);
                    end
                end
                EXP_USE:if(exp_v2_q)begin
                    if(exponent_error)begin error<=1;state_q<=IDLE;end
                    else begin
                        denominator_q<=denominator_q+37'(exponent);
                        if(int'(exp_tag2_q)==TOKENS-1)begin
                            col_q<=0;
                            if(denominator_q+37'(exponent)==0)begin error<=1;state_q<=IDLE;end
                            else state_q<=E_DRAIN;
                        end
                    end
                end
                E_DRAIN:state_q<=E_READ;
                E_READ:if(stream_valid)begin
                    if(stream_error||quotient>55'd16777216)begin error<=1;state_q<=IDLE;end
                    else begin
                        probability_sum_q<=probability_sum_q+31'(quotient);
                        if(col_q==max_col_q)max_probability_q<=32'(quotient);
                        if(int'(col_q)==TOKENS-1)state_q<=CORRECT;
                        else col_q<=col_q+1'b1;
                    end
                end
                CORRECT:if(corrected<0||corrected>33'sd16777216)begin error<=1;state_q<=IDLE;end else state_q<=CORRECT_WRITE;
                CORRECT_WRITE:begin done<=1;state_q<=IDLE;end
                default:state_q<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire

`default_nettype none
module official_e_row128x32(input wire clk,rst_n,wr,rd,input wire[6:0]addr,input wire[31:0]data,output wire[31:0]q);
 reg wr_q,rd_q;reg[6:0]addr_q;reg[31:0]data_q;
 always @(negedge clk or negedge rst_n)begin
  if(!rst_n)begin wr_q<=0;rd_q<=0;addr_q<=0;data_q<=0;end
  else begin wr_q<=wr;rd_q<=rd;addr_q<=addr;data_q<=data;end
 end
 for(genvar k=0;k<2;k++)begin:slice
  RAMSP128X16 m(.Q(q[k*16+:16]),.CLK(clk),.CEN(!(wr_q||rd_q)),.WEN(16'b0),.A(addr_q),.D(data_q[k*16+:16]),.EMA(3'b010),.EMAW(2'b01),.GWEN(!wr_q),.RET1N(1'b1));
 end
`ifndef SYNTHESIS
 always @(posedge clk)if(rst_n&&wr_q&&rd_q)$fatal(1,"E_ROW_SINGLE_PORT_COLLISION");
`endif
endmodule
`default_nettype wire

`default_nettype none
module attention_divider_stream55(input wire clk,rst_n,in_valid,input wire [54:0] numerator,input wire [36:0] denominator,output wire in_ready,out_valid,error,output wire[54:0]quotient);
  function automatic [39:0] sub40(input logic [39:0] a,b);logic [5:0] t;logic c;integer k;begin c=1;for(k=0;k<8;k=k+1)begin t={1'b0,a[k*5+:5]}+{1'b0,b[k*5+:5]};sub40[k*5+:5]=t[4:0]+c;c=t[5]|((&(a[k*5+:5]^b[k*5+:5]))&c);end end endfunction

  // 最多 25 个有效商位。补一位前导零，按十三组二进制位计算。
  localparam int STEPS = 13;
  reg [STEPS:0] v, z;
  reg [25:0] n [0:STEPS], q [0:STEPS];
  reg [36:0] rem [0:STEPS];
  reg [38:0] den1 [0:STEPS], den2 [0:STEPS], den3 [0:STEPS];
  assign in_ready = rst_n;
  assign out_valid = v[STEPS];
  assign error = z[STEPS];
  assign quotient = error ? 55'b0 : 55'(q[STEPS]);
  always @(posedge clk) begin
    if (!rst_n) v[0] <= 0;
    else begin
      v[0] <= in_valid;
      if (in_valid) begin
        z[0] <= denominator == 0;
        n[0] <= numerator[25:0];
        q[0] <= 0;
        rem[0] <= 37'(numerator[54:26]);
        den1[0] <= 39'(denominator);
        den2[0] <= 39'(denominator) << 1;
        den3[0] <= 39'(denominator) + (39'(denominator) << 1);
      end
    end
  end
  for (genvar k = 0; k < STEPS; k++) begin : step
    wire [38:0] trial = {rem[k], n[k][25:24]};
    wire [39:0] d1 = sub40({1'b0, trial}, ~{1'b0, den1[k]});
    wire [39:0] d2 = sub40({1'b0, trial}, ~{1'b0, den2[k]});
    wire [39:0] d3 = sub40({1'b0, trial}, ~{1'b0, den3[k]});
    wire [1:0] digit = !d3[39] ? 2'd3 : !d2[39] ? 2'd2 : !d1[39] ? 2'd1 : 2'd0;
    wire [36:0] reduced = !d3[39] ? d3[36:0] : !d2[39] ? d2[36:0] : !d1[39] ? d1[36:0] : trial[36:0];
    always @(posedge clk) begin
      if (!rst_n) v[k+1] <= 0;
      else begin
        v[k+1] <= v[k];
        if (v[k]) begin
          z[k+1] <= z[k];
          n[k+1] <= {n[k][23:0], 2'b0};
          q[k+1] <= {q[k][23:0], digit};
          rem[k+1] <= reduced;
          den1[k+1] <= den1[k];
          den2[k+1] <= den2[k];
          den3[k+1] <= den3[k];
        end
      end
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n && in_valid && denominator != 0 &&
      37'(numerator[54:26]) >= denominator) $fatal(1, "softmax radix-4 quotient bound exceeded");
`endif
endmodule
`default_nettype wire
