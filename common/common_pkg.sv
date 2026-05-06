package common_pkg;

  function automatic int unsigned greatest_common_divisor(
    input int unsigned lhs,
    input int unsigned rhs
  );
    int unsigned remainder;
    begin
      while(rhs != 0) begin
        remainder = rhs;
        rhs = lhs % rhs;
        lhs = remainder;
      end
      greatest_common_divisor = lhs;
    end
  endfunction

endpackage

module common_chunk_mux #(
  parameter int unsigned CHUNK_WIDTH = 1,
  parameter int unsigned CHUNK_COUNT = 1,
  parameter bit          ONEHOT_SELECT = 1'b0,

  localparam int unsigned CHUNK_INDEX_WIDTH  = (CHUNK_COUNT > 1) ? $clog2(CHUNK_COUNT) : 1,
  localparam int unsigned CHUNK_SELECT_WIDTH = ONEHOT_SELECT ? CHUNK_COUNT : CHUNK_INDEX_WIDTH
)
(
  input logic [CHUNK_SELECT_WIDTH-1:0] in_chunk_select,
  input logic [CHUNK_WIDTH*CHUNK_COUNT-1:0] in_chunk_data,
  output logic [CHUNK_WIDTH-1:0] out_chunk_data
);

  if(CHUNK_COUNT == 1) begin : g_leaf

    if(ONEHOT_SELECT) begin : g_onehot_leaf
      assign out_chunk_data =
          in_chunk_select[0]
        ? in_chunk_data
        : '0;
    end
    else begin : g_indexed_leaf
      assign out_chunk_data =
          in_chunk_data;
    end

  end
  else begin : g_tree

    localparam int unsigned LEFT_CHUNK_COUNT     = 1 << ($clog2(CHUNK_COUNT) - 1);
    localparam int unsigned RIGHT_CHUNK_COUNT    = CHUNK_COUNT - LEFT_CHUNK_COUNT;
    localparam int unsigned LEFT_INDEX_WIDTH     = (LEFT_CHUNK_COUNT > 1) ? $clog2(LEFT_CHUNK_COUNT) : 1;
    localparam int unsigned RIGHT_INDEX_WIDTH    = (RIGHT_CHUNK_COUNT > 1) ? $clog2(RIGHT_CHUNK_COUNT) : 1;

    logic select_right_tree;
    logic [CHUNK_WIDTH-1:0] left_chunk_data;
    logic [CHUNK_WIDTH-1:0] right_chunk_data;

    if(ONEHOT_SELECT) begin : g_onehot_tree

      common_chunk_mux #(
        .CHUNK_WIDTH(CHUNK_WIDTH),
        .CHUNK_COUNT(LEFT_CHUNK_COUNT),
        .ONEHOT_SELECT(ONEHOT_SELECT)
      ) u_left_mux (
        .in_chunk_select(in_chunk_select[LEFT_CHUNK_COUNT-1:0]),
        .in_chunk_data(in_chunk_data[0 +: CHUNK_WIDTH*LEFT_CHUNK_COUNT]),
        .out_chunk_data(left_chunk_data)
      );

      common_chunk_mux #(
        .CHUNK_WIDTH(CHUNK_WIDTH),
        .CHUNK_COUNT(RIGHT_CHUNK_COUNT),
        .ONEHOT_SELECT(ONEHOT_SELECT)
      ) u_right_mux (
        .in_chunk_select(in_chunk_select[CHUNK_COUNT-1:LEFT_CHUNK_COUNT]),
        .in_chunk_data(in_chunk_data[CHUNK_WIDTH*LEFT_CHUNK_COUNT +: CHUNK_WIDTH*RIGHT_CHUNK_COUNT]),
        .out_chunk_data(right_chunk_data)
      );

      assign out_chunk_data =
          left_chunk_data
        | right_chunk_data;

    end
    else begin : g_indexed_tree

      assign select_right_tree =
          in_chunk_select[CHUNK_INDEX_WIDTH-1];

      common_chunk_mux #(
        .CHUNK_WIDTH(CHUNK_WIDTH),
        .CHUNK_COUNT(LEFT_CHUNK_COUNT),
        .ONEHOT_SELECT(ONEHOT_SELECT)
      ) u_left_mux (
        .in_chunk_select(in_chunk_select[LEFT_INDEX_WIDTH-1:0]),
        .in_chunk_data(in_chunk_data[0 +: CHUNK_WIDTH*LEFT_CHUNK_COUNT]),
        .out_chunk_data(left_chunk_data)
      );

      common_chunk_mux #(
        .CHUNK_WIDTH(CHUNK_WIDTH),
        .CHUNK_COUNT(RIGHT_CHUNK_COUNT),
        .ONEHOT_SELECT(ONEHOT_SELECT)
      ) u_right_mux (
        .in_chunk_select(in_chunk_select[RIGHT_INDEX_WIDTH-1:0]),
        .in_chunk_data(in_chunk_data[CHUNK_WIDTH*LEFT_CHUNK_COUNT +: CHUNK_WIDTH*RIGHT_CHUNK_COUNT]),
        .out_chunk_data(right_chunk_data)
      );

      assign out_chunk_data =
          select_right_tree
        ? right_chunk_data
        : left_chunk_data;

    end

  end

endmodule
