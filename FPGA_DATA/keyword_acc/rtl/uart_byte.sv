`default_nettype none
module uart_byte #(
    parameter int CLOCK_HZ = 33333333,
    parameter int BAUD = 921600
)(
    input  wire clk, rst_n, rx_pin,
    output logic rx_valid, rx_error,
    output logic [7:0] rx_data,
    input  wire tx_valid,
    input  wire [7:0] tx_data,
    output wire tx_ready,
    output wire tx_pin
);
    localparam int TICKS = (CLOCK_HZ + BAUD/2) / BAUD;
    localparam int COUNT_BITS = $clog2(TICKS);
    (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync;
    logic [COUNT_BITS-1:0] rx_tick, tx_tick;
    logic [3:0] rx_bit, tx_left;
    logic rx_active;
    logic [7:0] rx_shift;
    logic [9:0] tx_shift;

    assign tx_ready = tx_left == 0;
    assign tx_pin = tx_shift[0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_sync <= 2'b11;
            rx_active <= 0;
            rx_valid <= 0;
            rx_error <= 0;
            rx_data <= 0;
            rx_shift <= 0;
            rx_tick <= 0;
            rx_bit <= 0;
            tx_left <= 0;
            tx_tick <= 0;
            tx_shift <= '1;
        end else begin
            rx_sync <= {rx_sync[0], rx_pin};
            rx_valid <= 0;
            rx_error <= 0;
            if (!rx_active) begin
                if (!rx_sync[1]) begin
                    rx_active <= 1;
                    rx_tick <= COUNT_BITS'(TICKS/2 - 1);
                    rx_bit <= 0;
                end
            end else if (rx_tick != 0) rx_tick <= rx_tick - 1'b1;
            else begin
                rx_tick <= COUNT_BITS'(TICKS - 1);
                rx_bit <= rx_bit + 1'b1;
                if (rx_bit == 0) begin
                    if (rx_sync[1]) rx_active <= 0;
                end else if (rx_bit <= 8) rx_shift <= {rx_sync[1], rx_shift[7:1]};
                else begin
                    rx_active <= 0;
                    rx_valid <= rx_sync[1];
                    rx_error <= !rx_sync[1];
                    rx_data <= rx_shift;
                end
            end

            if (tx_ready) begin
                if (tx_valid) begin
                    tx_shift <= {1'b1, tx_data, 1'b0};
                    tx_left <= 10;
                    tx_tick <= COUNT_BITS'(TICKS - 1);
                end
            end else if (tx_tick != 0) tx_tick <= tx_tick - 1'b1;
            else begin
                tx_shift <= {1'b1, tx_shift[9:1]};
                tx_left <= tx_left - 1'b1;
                tx_tick <= COUNT_BITS'(TICKS - 1);
            end
        end
    end
endmodule
`default_nettype wire
