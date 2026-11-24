package attention_formats_pkg;
    function automatic logic [5:0] matrix_shift(input logic[3:0] layer,input logic[2:0] stage);
        case(stage)
            1,5:matrix_shift=layer==5?6'd15:6'd16;
            2:matrix_shift=(layer==1||layer==3)?6'd15:6'd16;
            3:matrix_shift=23;
            4:matrix_shift=24;
            default:matrix_shift=16;
        endcase
    endfunction
endpackage
