`default_nettype none
module board_key #(
    parameter int STABLE_CYCLES = 500000
)(
    input  wire clk, rst_n, key_n,
    output logic pressed
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] key_sync;
    localparam int COUNT_BITS = $clog2(STABLE_CYCLES + 1);
    logic [COUNT_BITS-1:0] stable_count;
    logic stable_key;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            key_sync <= 2'b11;
            stable_count <= 0;
            stable_key <= 1;
            pressed <= 0;
        end else begin
            key_sync <= {key_sync[0], key_n};
            pressed <= 0;
            if (stable_key == key_sync[1]) stable_count <= 0;
            else if (stable_count == STABLE_CYCLES - 1) begin
                stable_count <= 0;
                stable_key <= key_sync[1];
                pressed <= !key_sync[1];
            end else stable_count <= stable_count + 1'b1;
        end
    end
endmodule
`default_nettype wire
