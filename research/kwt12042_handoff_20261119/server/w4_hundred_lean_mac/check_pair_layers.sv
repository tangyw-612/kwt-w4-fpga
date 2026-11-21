`timescale 1ns/1fs

// 逐层核对 LN2 写回，便于在完整冷任务结束前定位首个差异。
module check_pair_layers (
  input logic clk, rst_n, valid, valid_other,
  input logic [3:0] layer,
  input logic [6:0] row,
  input logic [5:0] col,
  input logic [31:0] data, data_other,
  input logic [5:0] col_other
);
  localparam int ROW_WORDS = 64;
  localparam int LAYER_WORDS = 99 * ROW_WORDS;
  logic [31:0] expected [12 * LAYER_WORDS];
  string vectors, sample, path;
  int file_id, loaded, index, compared;
  logic [31:0] actual_bytes;
  bit seen[12*LAYER_WORDS];

  initial begin
    if (!$value$plusargs("vectors=%s", vectors) ||
        !$value$plusargs("sample=%s", sample))
      $fatal(1, "PAIR_CHECK_ARGUMENTS");
    for (int l = 0; l < 12; l++) begin
      path = $sformatf("%s/golden/%s/layer_%02d.bin", vectors, sample, l);
      file_id = $fopen(path, "rb");
      if (!file_id) $fatal(1, "PAIR_GOLDEN_OPEN %s", path);
      loaded = $fread(expected, file_id, l * LAYER_WORDS, LAYER_WORDS);
      if (loaded != LAYER_WORDS * 4) $fatal(1, "PAIR_GOLDEN_SIZE %s %0d", path, loaded);
      $fclose(file_id);
    end
    compared = 0;
  end

  task automatic check_word(input int row_value, col_value, input logic [31:0] word);
    index = int'(layer) * LAYER_WORDS + row_value * ROW_WORDS + col_value;
    actual_bytes = {word[7:0], word[15:8], word[23:16], word[31:24]};
    if (row_value < 0 || row_value >= 99 || col_value < 0 || col_value >= 64 ||
        layer >= 12 || seen[index] || actual_bytes !== expected[index])
      $fatal(1,"PAR_LN_COMPARE layer=%0d row=%0d col=%0d got=%h want=%h",
             layer,row_value,col_value,actual_bytes,expected[index]);
    seen[index] = 1;
    compared++;
    if (compared % LAYER_WORDS == 0)
      $display("PAIR_LAYER_PASS layer=%0d total_words=%0d",layer,compared);
  endtask
  always @(posedge clk) if (rst_n) begin
    if (valid) check_word(int'(row),int'(col),data);
    if (valid_other) check_word(int'(row)+1,int'(col_other),data_other);
  end
endmodule

bind ac_enc check_pair_layers u_pair_check(
  .clk(clk), .rst_n(rst_n), .valid(fd_sel&&ln_out_valid[0]),
  .valid_other(fd_sel&&ln_out_valid[1]), .layer(cur_layer),
  .row(row_i), .col(ln_ocol[0]), .data(ln_norm[0]),
  .col_other(ln_ocol[1]), .data_other(ln_norm[1])
);
