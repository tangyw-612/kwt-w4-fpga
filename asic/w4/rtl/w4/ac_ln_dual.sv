// Derived from I09C 150_ln_top_stream.sv / 108_ln_parameters_ihp.sv (frozen originals untouched).
`default_nettype none
// Streaming PostNorm LayerNorm top. The mean, square sum, radicand and isqrt
// expressions are copied unchanged from the 6.2 fullpipe datapath. The exact
// divide/affine tail uses the frozen v24 streaming modules.
// Arch C copy: one unit serves LN1 (even rows) and LN2 (odd rows); the gamma/beta set is row parity.
// Arithmetic is unchanged from I09C ln_top_stream.
module ac_ln_stream #(parameter int ROWS = 198, FEATURES = 64,
    parameter int ROW_W = (ROWS <= 1) ? 1 : $clog2(ROWS),
    parameter int COL_W = (FEATURES <= 1) ? 1 : $clog2(FEATURES)) (
    output wire [31:0] kwt_ln_storage,
    input logic clk, rst_n, start,
    input logic [3:0] layer_index,
    input logic position, parameter_set,
    output logic start_ready, busy, done,
    input logic load_valid, load_kind,
    input logic [6:0] load_addr,
    input logic signed [31:0] load_data,
    output logic load_ready, load_error,
    input logic in_valid,
    output logic in_ready,
    input logic signed [31:0] in_a, in_b,
    output logic out_valid,
    input logic out_ready,
    output logic signed [31:0] out_residual, out_normalized,
    output logic [ROW_W-1:0] out_row,
    output logic [COL_W-1:0] out_col,
    output logic [3:0] out_layer,
    output logic out_position
);
    typedef enum logic[3:0] {IDLE,INPUT_ROW,MEAN,MOM_PRODUCTS,SQ_WAIT,ROOT_START,ROOT_WAIT,OUT_PREP,OUT_PRIME,OUT_FEED,OUT_WAIT,MOM_COMBINE} state_t;
    state_t state_q;
    logic parameters_complete;
    logic signed [31:0] gamma_data,beta_data;
    logic read_parameters;logic [COL_W-1:0] read_col;
    logic signed [37:0] sum_q;
    logic signed [31:0] mean_q;
    logic [31:0] root_q,sqrt_result;
    logic [69:0] squares_q;
    logic signed [69:0] mean_sum_q;
    logic signed [63:0] mean_squared_q;
    logic [6:0] in_col,sq_col,feed_col;
    logic [6:0] sq_done_count,out_count;
    logic [3:0] active_layer_q;
    logic active_position_q;
    logic [ROW_W-1:0] row_q;
    logic signed [32:0] residual_sum;
    logic signed [31:0] residual_sat;
    wire signed[32:0] square_center=33'(residual_sat);
    wire [32:0] square_mag=square_center[32]?$unsigned(-square_center):$unsigned(square_center);
    wire sq_start=state_q==INPUT_ROW&&in_valid&&in_ready;
    wire sqrt_start=state_q==ROOT_START;
    logic sqrt_done;
    logic [65:0] square_result;
    logic sq_out_valid;
    logic pipe_in_ready,pipe_out_valid;
    logic feed_valid;
    wire feed_ready = !feed_valid || pipe_in_ready;
    logic signed [32:0] feed_center;
    logic signed [31:0] feed_gamma, feed_beta, feed_residual;
    logic [31:0] feed_tag;
    logic signed[31:0] pipe_normalized,pipe_residual;
    logic [31:0] pipe_tag;
    logic signed[63:0] pipe_quotient;
    logic pipe_error;
    logic [63:0] radicand64;
    logic [71:0] radicand72;
    logic [70:0] variance_unused;
    logic signed [31:0] row_value;
    wire signed [32:0] output_center = 33'(row_value) - 33'(mean_q);
    wire row_write = state_q == INPUT_ROW && in_valid && in_ready;
    logic [16:0] mean_lo;logic [15:0] mean_hi;
    logic signed [31:0] mean_calc;
    function automatic [71:0] fastadd72(input logic [71:0] a,b);
      logic [8:0] t;logic c;integer k;begin c=0;for(k=0;k<9;k=k+1)begin t={1'b0,a[k*8+:8]}+{1'b0,b[k*8+:8]};fastadd72[k*8+:8]=t[7:0]+c;c=t[8]|((&(a[k*8+:8]^b[k*8+:8]))&c);end end
    endfunction
    wire [70:0] variance=(squares_q+70'(FEATURES/2))/70'(FEATURES);
    assign variance_unused=variance;
    // The radicand expression is the exact 6.2 formula, including the low-bit
    // rounding term. The unused high variance bits remain zero as in 6.2.
    assign radicand72=fastadd72({8'b0,squares_q[69:6]},{8'b0,(64'd1099512|{63'b0,squares_q[5]})});
    assign radicand64=radicand72[63:0];
    assign residual_sum=33'(in_a)+33'(in_b);
    wire signed[31:0] sat_max=32'sd2147483647;
    wire signed[31:0] sat_min=$signed(32'h80000000);
    assign residual_sat=(residual_sum>33'sd2147483647)?sat_max:
                        ((residual_sum< -33'sd2147483648)?sat_min:32'(residual_sum));
    assign mean_lo={1'b0,sum_q[21:6]}+(sum_q[5]&&(!sum_q[37]||(|sum_q[4:0])));
    assign mean_hi=sum_q[37:22];
    assign mean_calc={mean_hi+mean_lo[16],mean_lo[15:0]};
    always_comb begin
      read_parameters=1'b0;read_col='0;
      if(state_q==OUT_PREP)begin read_parameters=1'b1;read_col='0;end
      else if(state_q==OUT_FEED&&feed_ready)begin read_parameters=feed_col!=7'(FEATURES-1);read_col=read_parameters?COL_W'(feed_col+1'b1):'0;end
    end
    ac_ln_params2 #(.FEATURES(FEATURES),.COL_W(COL_W)) u_parameters(.clk(clk),.rst_n(rst_n),.idle(state_q==IDLE),
      .load_valid(load_valid),.load_kind(load_kind),.load_addr(load_addr),.load_data(load_data),
      .load_ready(load_ready),.load_error(load_error),.complete(parameters_complete),
      .read_valid(read_parameters),.read_set(parameter_set),.read_col(read_col),.gamma_data(gamma_data),.beta_data(beta_data));
    // 与 gamma、beta 同拍预读，停顿时三个读口同时保持输出。
    ac_row_store #(.DEPTH(FEATURES)) u_row(
      .clk, .rst_n, .wr(row_write), .rd(read_parameters),
      .addr(row_write ? 8'(in_col) : 8'(read_col)), .data(residual_sat), .q(row_value));
    ln_square_stream u_square(.clk(clk),.rst_n(rst_n),.start(sq_start),.magnitude(square_mag),
      .out_valid(sq_out_valid),.result(square_result));
    ln_isqrt_free u_sqrt(.clk(clk),.rst_n(rst_n),.start(sqrt_start),.radicand(radicand64),
      .start_ready(),.done(sqrt_done),.result(sqrt_result));
    wire ln_row_start=(state_q==OUT_PRIME);
    // 在倒数准备期间可先缓存第一列，随后每拍都可接收一列。
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) feed_valid <= 0;
      else if (feed_ready) feed_valid <= state_q == OUT_FEED;
    end
    always_ff @(posedge clk) if (feed_ready && state_q == OUT_FEED) begin
      feed_center <= output_center;
      feed_gamma <= gamma_data;
      feed_beta <= beta_data;
      feed_residual <= row_value;
      feed_tag <= {(32-5-ROW_W-COL_W)'(0),active_position_q,active_layer_q,row_q,feed_col[COL_W-1:0]};
    end
    ln_output_pipeline_stream_v2 #(.TAG_W(32)) u_output(.clk(clk),.rst_n(rst_n),.row_start(ln_row_start),.in_valid(feed_valid),
      .in_ready(pipe_in_ready),.numerator({feed_center,24'b0}),.denominator(root_q),.gamma_data(feed_gamma),.beta_data(feed_beta),
      .residual(feed_residual),.in_tag(feed_tag),
      .out_valid(pipe_out_valid),.out_ready(out_ready),.result(pipe_normalized),.out_residual(pipe_residual),
      .out_quotient(pipe_quotient),.out_error(pipe_error),.out_tag(pipe_tag));
    assign out_valid=pipe_out_valid;
    assign out_normalized=pipe_normalized;
    assign out_residual=pipe_residual;
    assign out_col=pipe_tag[COL_W-1:0];
    assign out_row=ROW_W'(pipe_tag[COL_W+ROW_W-1:COL_W]);
    assign out_layer=pipe_tag[COL_W+ROW_W+3:COL_W+ROW_W];
    assign out_position=pipe_tag[COL_W+ROW_W+4];
    assign in_ready=rst_n&&state_q==INPUT_ROW;
    assign start_ready=rst_n&&state_q==IDLE&&parameters_complete&&layer_index<12&&!load_valid;
    assign busy=state_q!=IDLE;
    always_ff @(posedge clk or negedge rst_n)begin
      if(!rst_n)begin
        state_q<=IDLE;sum_q<=0;mean_q<=0;root_q<=0;squares_q<=0;
        in_col<=0;sq_col<=0;feed_col<=0;sq_done_count<=0;out_count<=0;
        row_q<=0;active_layer_q<=0;active_position_q<=0;done<=0;
      end else begin
        done<=0;
        if(sq_out_valid&&(state_q==INPUT_ROW||state_q==MEAN||state_q==SQ_WAIT))begin
          squares_q<=fastadd72({2'b0,squares_q},{6'b0,square_result});
          sq_done_count<=sq_done_count+1'b1;
          if(sq_done_count==7'(FEATURES-1)&&state_q==SQ_WAIT)state_q<=MOM_PRODUCTS;
        end
        // The stream tail has a short latency, so results may arrive while the
        // row is still being fed. Count them across OUT_FEED and OUT_WAIT.
        if((state_q==OUT_FEED||state_q==OUT_WAIT)&&pipe_out_valid&&out_ready)begin
          out_count<=out_count+1'b1;
          if(out_count==7'(FEATURES-1))begin
            out_count<=0;
            if(row_q==ROW_W'(ROWS-1))begin done<=1;state_q<=IDLE;end
            else begin row_q<=row_q+1'b1;in_col<=0;sum_q<=0;squares_q<=0;sq_done_count<=0;state_q<=INPUT_ROW;end
          end
        end
        case(state_q)
          IDLE:if(start&&start_ready)begin
            state_q<=INPUT_ROW;row_q<=0;in_col<=0;sum_q<=0;squares_q<=0;sq_done_count<=0;out_count<=0;
            active_layer_q<=layer_index;active_position_q<=position;
          end
          INPUT_ROW:if(in_valid&&in_ready)begin
            sum_q<=sum_q+38'(residual_sat);
            if(in_col==7'(FEATURES-1))begin in_col<=0;state_q<=MEAN;end else in_col<=in_col+1'b1;
          end
          MEAN:begin mean_q<=mean_calc;state_q<=SQ_WAIT;end
          SQ_WAIT:if(sq_done_count==7'(FEATURES)) state_q<=MOM_PRODUCTS;
          MOM_PRODUCTS:begin
            mean_sum_q<=mean_q*sum_q;
            mean_squared_q<=mean_q*mean_q;
            state_q<=MOM_COMBINE;
          end
          MOM_COMBINE:begin
            // 取整数均值后仍满足恒等式：Σ(x−μ)^2 = Σx²−2μΣx+64μ²。
            squares_q<=squares_q-($unsigned(mean_sum_q)<<1)+(70'(mean_squared_q)<<6);
            state_q<=ROOT_START;
          end
          ROOT_START:state_q<=ROOT_WAIT;
          ROOT_WAIT:if(sqrt_done)begin root_q<=sqrt_result;state_q<=OUT_PREP;feed_col<=0;out_count<=0;end
          OUT_PREP:state_q<=OUT_PRIME;
          OUT_PRIME:state_q<=OUT_FEED;
          OUT_FEED:if(feed_ready)begin
            if(feed_col==7'(FEATURES-1))begin feed_col<=0;state_q<=OUT_WAIT;end else feed_col<=feed_col+1'b1;
          end
          OUT_WAIT:;
          default:state_q<=IDLE;
        endcase
      end
    end
        assign kwt_ln_storage[0+:8]=8'(state_q==INPUT_ROW);
    assign kwt_ln_storage[8+:8]=8'(sq_start);
    assign kwt_ln_storage[16+:8]=8'(read_parameters);
    assign kwt_ln_storage[24+:8]=8'(pipe_in_ready);
endmodule
`default_nettype wire
`default_nettype none
module ac_ln_params2 #(parameter int FEATURES = 64, parameter int COL_W = (FEATURES <= 1) ? 1 : $clog2(FEATURES)) (
    input logic clk, rst_n, idle,
    input logic load_valid, load_kind,
    input logic [6:0] load_addr,
    input logic signed [31:0] load_data,
    output logic load_ready, load_error, complete,
    input logic read_valid, read_set,
    input logic [COL_W-1:0] read_col,
    output logic signed [31:0] gamma_data, beta_data
);
    wire [63:0] macro_q;
    assign gamma_data = macro_q[31:0];
    assign beta_data = macro_q[63:32];
    // two parameter sets (load_addr[6] = set): per (set, kind) sequential load, like the original
    logic [6:0] next_q [0:3];
    logic [3:0] valid_q;
    logic legal;
    wire [1:0] sk = {load_addr[6], load_kind};
    wire [5:0] lcol = load_addr[5:0];
    assign load_ready = idle && rst_n;
    assign legal = int'(lcol) < FEATURES &&
                   (lcol == 0 || (!valid_q[sk] && 7'(lcol) == next_q[sk]));
    assign load_error = load_valid && load_ready && !legal;
    assign complete = &valid_q;
    wire wr = load_valid && load_ready && legal;
    ac_mem64x128 mem(.clk(clk),.rst_n(rst_n),.wr(wr),.rd(read_valid),
        .addr(wr?{load_addr[6],lcol}:{read_set,read_col}),.data({2{load_data}}),
        .mask(load_kind?64'hffffffff00000000:64'h00000000ffffffff),.q(macro_q));
`ifndef SYNTHESIS
    always @(posedge clk) if (wr && read_valid) $fatal(1,"LN parameter memory conflict");
`endif
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin for (int i = 0; i < 4; i++) next_q[i] <= 0; valid_q <= 0; end
        else if (load_valid && load_ready && legal) begin
            next_q[sk] <= 7'(lcol) + 1'b1;
            valid_q[sk] <= int'(lcol) == FEATURES-1;
        end
    end
endmodule
`default_nettype wire

`default_nettype none
// official_64x64_1p with the 7th address bit used (the RAMSP128X16 macros are 128 deep).
module ac_mem64x128(input wire clk,rst_n,wr,rd,input wire [6:0] addr,
 input wire [63:0] data,mask,output wire [63:0] q);
 reg wr_q,rd_q; reg [6:0] addr_q;reg [63:0] data_q,mask_q;
 always @(negedge clk or negedge rst_n) begin
  if(!rst_n)begin wr_q<=0;rd_q<=0;addr_q<=0;data_q<=0;mask_q<=0;end
  else begin wr_q<=wr;rd_q<=rd;addr_q<=addr;data_q<=data;mask_q<=mask;end
 end
 for(genvar j=0;j<4;j=j+1)begin: slice
  RAMSP128X16 m(.Q(q[j*16+:16]),.CLK(clk),.CEN(!(wr_q||rd_q)),
   .WEN(~mask_q[j*16+:16]),.A(addr_q),.D(data_q[j*16+:16]),
   .EMA(3'b010),.EMAW(2'b01),.GWEN(!wr_q),.RET1N(1'b1));
 end
`ifndef SYNTHESIS
 always @(posedge clk) if(rst_n && wr && rd) $fatal(1,"ac_mem64x128 conflict");
`endif
endmodule
`default_nettype wire
