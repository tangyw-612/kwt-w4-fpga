`timescale 1ns/1ps
module tb_mac_edges;
    logic clk=0,rst_n=0,in_valid=0,in_first=0,in_last=0,in_hi=0;
    logic in_pair=1,in_qk_pair=0,in_pv_pair=0,dr_valid=0,dr_sat16;
    logic signed [31:0] in_a,in_a_odd;
    logic [543:0] in_b,in_b_odd;
    logic [4:0] dr_idx;
    logic signed [63:0] dr_bias;
    logic [15:0] dr_scale;
    logic [5:0] dr_shift;
    wire out_valid;
    wire signed [31:0] out_data;
    arch_c_mac_array #(.L(32)) dut(.*);
    always #5 clk=~clk;
    longint signed sums[32];
    int checks=0;
    int case_index=0;
    task automatic exercise(input string label_name,input int a,b,c,d,
            input int terms,scale,shift,input longint signed bias,input bit narrow);
        longint signed value, expected, lo, hi;
        int even_w,odd_w;
        case_index++;
        foreach(sums[j]) sums[j]=0;
        for(int t=0;t<terms;t++) begin
            @(negedge clk); in_valid=1; in_first=(t==0); in_last=(t==terms-1);
            in_a=a; in_a_odd=c;
            for(int j=0;j<32;j++) begin
                even_w=j%2 ? d:b; odd_w=j%2 ? b:d;
                in_b[17*j+:17]=even_w; in_b_odd[17*j+:17]=odd_w;
                sums[j]+=longint'(a)*even_w;
                if(in_pair) sums[j]+=longint'(c)*odd_w;
            end
            if(t%3==1) begin @(negedge clk); in_valid=0; end
        end
        @(negedge clk); in_valid=0;
        repeat(4) @(negedge clk);
        for(int j=0;j<32;j++) begin
            dr_valid=1; dr_idx=j; dr_bias=bias; dr_scale=scale; dr_shift=shift; dr_sat16=narrow;
            @(negedge clk); dr_valid=0;
            wait(out_valid===1); @(negedge clk);
            // 用六十四位整数直接求和与取整，独立于硬件的分段乘法。
            value=sums[j]*scale+bias;
            expected=value>=0 ? value:-value;
            if(shift>0) expected=(expected+(64'sd1<<(shift-1)))>>shift;
            if(value<0) expected=-expected;
            hi=narrow ? 32767 : 64'sd2147483647;
            lo=narrow ? -32768 : -64'sd2147483648;
            if(expected>hi) expected=hi;
            if(expected<lo) expected=lo;
            if(out_data!==expected[31:0]) $fatal(1,"乘加输出不符 %s %0d %0d %0d",label_name,j,out_data,expected);
            checks++;
            @(negedge clk);
        end
        $display("MAC_CASE_PASS %s lanes=32",label_name);
    endtask
    initial begin
        $dumpfile("mac_edges.vcd");
        $dumpvars(1,tb_mac_edges);
        repeat(3) @(negedge clk); rst_n=1;
        exercise("weight_extremes",123456,-8,-654321,7,4,3,4,11,0);
        exercise("cancellation",13579,-7,13579,7,128,1,0,0,0);
        exercise("round_positive_half",1,1,0,1,1,1,1,0,0);
        exercise("round_negative_half",-1,1,0,1,1,1,1,0,0);
        exercise("round_below_half",1,1,0,1,1,1,2,0,0);
        exercise("round_above_half",3,1,0,1,1,1,2,0,0);
        exercise("sat16_high",32768,1,0,1,1,1,0,0,1);
        exercise("sat16_low",-32769,1,0,1,1,1,0,0,1);
        exercise("sat32_high",32'sh80000000,-8,32'sh80000000,-8,128,1,0,0,0);
        exercise("sat32_low",32'sh80000000,7,32'sh80000000,7,128,1,0,0,0);
        exercise("scale4095",-999999,-8,998877,7,2,4095,16,-321,0);
        in_qk_pair=1;
        exercise("qk_i16_signed",32767,-32768,-32768,32767,32,1,6,0,0);
        in_qk_pair=0; in_pv_pair=1;
        exercise("pv_u25_signed",8388607,-32768,8388609,32767,1,1,12,0,0);
        in_pv_pair=0; in_pair=0;
        exercise("single_term_without_odd",-6350,-8,8191,7,5,3,3,-12,0);
        $display("MAC_EDGES_PASS checks=%0d",checks); $finish;
    end
    initial begin #1000000; $fatal(1,"乘加用例超时"); end
endmodule
