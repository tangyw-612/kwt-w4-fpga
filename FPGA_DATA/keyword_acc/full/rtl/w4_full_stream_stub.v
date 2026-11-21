// 用于板级套接已综合的编码核。端口与流接口保持一致。
(* black_box = "true" *)
module w4_full_stream (
    input clk, rst_n, start, in_valid,
    input [31:0] in_data,
    output in_ready, out_valid,
    output [31:0] out_data,
    input out_ready,
    output busy, done,
    output [3:0] layers_completed,
    output [31:0] cycles, wait_cycles
);
endmodule
