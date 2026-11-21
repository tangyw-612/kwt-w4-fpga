`default_nettype none
module attention_exp_interpolate (
    input logic [31:0] a,b,
    input logic [11:0] remainder_value,
    input logic outside,
    output logic [31:0] exponent,
    output logic error
);
    logic [43:0] weighted,rounded;
    assign weighted=44'(a)*(44'd4096-44'(remainder_value))+44'(b)*44'(remainder_value);
    assign rounded=(weighted+44'd2048)>>12;
    assign exponent=outside?32'd0:32'(rounded);
    assign error=!outside&&rounded>44'd1073741824;
endmodule
`default_nettype wire
