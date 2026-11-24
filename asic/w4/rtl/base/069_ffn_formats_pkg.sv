`default_nettype none
// 从冻结的软件配置生成，各层只选择五位或六位舍入。
package ffn_formats_pkg;
    function automatic logic shift_five(input logic [3:0] layer);
        case (layer)
            4'd0: shift_five = 1'b0;
            4'd1: shift_five = 1'b0;
            4'd2: shift_five = 1'b0;
            4'd3: shift_five = 1'b0;
            4'd4: shift_five = 1'b0;
            4'd5: shift_five = 1'b0;
            4'd6: shift_five = 1'b0;
            4'd7: shift_five = 1'b0;
            4'd8: shift_five = 1'b0;
            4'd9: shift_five = 1'b0;
            4'd10: shift_five = 1'b0;
            4'd11: shift_five = 1'b1;
            default: shift_five = 1'b0;
        endcase
    endfunction
endpackage
`default_nettype wire
