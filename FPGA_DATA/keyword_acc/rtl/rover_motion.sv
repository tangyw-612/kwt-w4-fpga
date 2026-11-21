`default_nettype none
module rover_motion (
    input  wire clk, rst_n, accepted,
    input  wire [1:0] direction,
    output logic [2:0] car_col, car_row,
    output logic [39:0] trail
);
    logic [2:0] next_col, next_row;
    always_comb begin
        next_col = car_col;
        next_row = car_row;
        case (direction)
            0: if (car_col < 6) next_col = car_col + 1'b1;
            1: if (car_row > 0) next_row = car_row - 1'b1;
            2: if (car_col > 0) next_col = car_col - 1'b1;
            default: begin end
        endcase
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            car_col <= 2;
            car_row <= 3;
            trail <= 40'b1 << 26;
        end else if (accepted) begin
            car_col <= next_col;
            car_row <= next_row;
            trail[{next_row, next_col}] <= 1;
        end
    end
endmodule
`default_nettype wire
