module gearbox #(
  parameter        INPUT_BYTES_PER_BEAT    = 4,
  parameter        OUTPUT_BYTES_PER_BEAT   = 5,

  localparam int   BITS_PER_BYTE           = 8,

  localparam       INPUT_DATA_WIDTH        = BITS_PER_BYTE * INPUT_BYTES_PER_BEAT,
  localparam       OUTPUT_DATA_WIDTH       = BITS_PER_BYTE * OUTPUT_BYTES_PER_BEAT,

  localparam int   MAX_TRANSFER_BYTES      = (INPUT_BYTES_PER_BEAT > OUTPUT_BYTES_PER_BEAT) ? INPUT_BYTES_PER_BEAT : OUTPUT_BYTES_PER_BEAT,
  localparam int   BUFFER_CAPACITY_BYTES   = 2 * MAX_TRANSFER_BYTES,
  localparam int   BUFFER_DATA_WIDTH       = BITS_PER_BYTE * BUFFER_CAPACITY_BYTES,

  localparam int   BUFFER_POINTER_WIDTH    = $clog2(BUFFER_CAPACITY_BYTES),
  localparam int   BUFFER_COUNT_WIDTH      = $clog2(BUFFER_CAPACITY_BYTES + 1),

  localparam logic [BUFFER_POINTER_WIDTH-1:0] INPUT_POINTER_STEP    = INPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_POINTER_WIDTH-1:0] OUTPUT_POINTER_STEP   = OUTPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_POINTER_WIDTH:0]   BUFFER_POINTER_LIMIT  = BUFFER_CAPACITY_BYTES,

  localparam logic [BUFFER_COUNT_WIDTH-1:0]   INPUT_BYTE_COUNT      = INPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0]   OUTPUT_BYTE_COUNT     = OUTPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0]   BUFFER_BYTE_COUNT     = BUFFER_CAPACITY_BYTES
)
(
  input input_stream_valid,
  input [INPUT_DATA_WIDTH-1:0] input_stream_data,
  output logic input_stream_ready,

  input output_stream_ready,
  output logic [OUTPUT_DATA_WIDTH-1:0] output_stream_data,
  output logic output_stream_valid,

  input clk,
  input rstn
);

  logic input_stream_transfer;
  logic output_stream_transfer;

  logic [BUFFER_COUNT_WIDTH-1:0] stored_byte_count_q;
  logic [BUFFER_COUNT_WIDTH-1:0] stored_byte_count_next;

  logic [BUFFER_COUNT_WIDTH-1:0] bytes_added;
  logic [BUFFER_COUNT_WIDTH-1:0] bytes_removed;

  logic [BUFFER_COUNT_WIDTH:0]   next_stored_byte_count;
  logic [BUFFER_COUNT_WIDTH:0]   free_byte_count_after_output;

  assign input_stream_transfer =
      input_stream_valid
    & input_stream_ready;

  assign output_stream_transfer =
      output_stream_valid
    & output_stream_ready;

  assign free_byte_count_after_output =
      {1'b0, BUFFER_BYTE_COUNT}
    - {1'b0, stored_byte_count_q}
    + {1'b0, bytes_removed};

  assign next_stored_byte_count =
      {1'b0, stored_byte_count_q}
    + {1'b0, bytes_added}
    - {1'b0, bytes_removed};

  assign stored_byte_count_next =
    next_stored_byte_count[BUFFER_COUNT_WIDTH-1:0];

  always_ff @(posedge clk or negedge rstn) begin
    if(~rstn)
      stored_byte_count_q <= '0;
    else
      stored_byte_count_q <= stored_byte_count_next;
  end

  if(INPUT_BYTES_PER_BEAT < OUTPUT_BYTES_PER_BEAT) begin : g_small_to_large

    logic staged_input_valid_q;
    logic staged_input_valid_next;

    logic pack_buffer_has_space;
    logic staged_input_transfer;

    logic [INPUT_DATA_WIDTH-1:0]     staged_input_data_q;

    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_data_q;
    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_data_next;
    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_write_data;
    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_write_mask;

    logic [BUFFER_POINTER_WIDTH-1:0] write_byte_pointer_q;
    logic [BUFFER_POINTER_WIDTH-1:0] write_byte_pointer_next;
    logic [BUFFER_POINTER_WIDTH:0]   write_byte_pointer_sum;
    logic [BUFFER_POINTER_WIDTH:0]   write_byte_pointer_wrap;

    logic output_lane_q;
    logic output_lane_next;

    assign output_stream_data =
        output_lane_q
      ? pack_buffer_data_q[2*OUTPUT_DATA_WIDTH-1:OUTPUT_DATA_WIDTH]
      : pack_buffer_data_q[OUTPUT_DATA_WIDTH-1:0];

    assign output_stream_valid =
        stored_byte_count_q >= OUTPUT_BYTE_COUNT;

    assign bytes_removed =
        output_stream_transfer
      ? OUTPUT_BYTE_COUNT
      : '0;

    assign pack_buffer_has_space =
      free_byte_count_after_output >= {1'b0, INPUT_BYTE_COUNT};

    assign input_stream_ready =
        ~staged_input_valid_q
      |  pack_buffer_has_space;

    assign staged_input_transfer =
        staged_input_valid_q
      & pack_buffer_has_space;

    assign staged_input_valid_next =
        input_stream_transfer
      | (  staged_input_valid_q
         & ~staged_input_transfer);

    assign bytes_added =
        staged_input_transfer
      ? INPUT_BYTE_COUNT
      : '0;

    assign write_byte_pointer_sum =
        {1'b0, write_byte_pointer_q}
      + {1'b0, INPUT_POINTER_STEP};

    assign write_byte_pointer_wrap =
        write_byte_pointer_sum
      - BUFFER_POINTER_LIMIT;

    assign write_byte_pointer_next =
        staged_input_transfer
      ? ((write_byte_pointer_sum >= BUFFER_POINTER_LIMIT)
        ? write_byte_pointer_wrap[BUFFER_POINTER_WIDTH-1:0]
        : write_byte_pointer_sum[BUFFER_POINTER_WIDTH-1:0])
      : write_byte_pointer_q;

    assign output_lane_next =
        output_lane_q
      ^ output_stream_transfer;

    for(genvar out_byte_i = 0; out_byte_i < BUFFER_CAPACITY_BYTES; out_byte_i = out_byte_i + 1) begin : g_pack_buffer_byte

      localparam logic [BUFFER_POINTER_WIDTH-1:0] OUTPUT_BUFFER_BYTE_INDEX = out_byte_i;

      logic [INPUT_BYTES_PER_BEAT-1:0] write_byte_select;
      logic [BITS_PER_BYTE-1:0] [INPUT_BYTES_PER_BEAT-1:0] write_bit_select;

      for(genvar in_byte_i = 0; in_byte_i < INPUT_BYTES_PER_BEAT; in_byte_i = in_byte_i + 1) begin : g_staged_input_byte

        localparam logic [BUFFER_POINTER_WIDTH:0] INPUT_BYTE_OFFSET = in_byte_i;

        logic [BUFFER_POINTER_WIDTH:0]   write_byte_sum;
        logic [BUFFER_POINTER_WIDTH:0]   write_byte_wrap;
        logic [BUFFER_POINTER_WIDTH-1:0] write_byte_pointer;

        assign write_byte_sum =
            {1'b0, write_byte_pointer_q}
          + INPUT_BYTE_OFFSET;

        assign write_byte_wrap =
            write_byte_sum
          - BUFFER_POINTER_LIMIT;

        assign write_byte_pointer =
            write_byte_sum >= BUFFER_POINTER_LIMIT
          ? write_byte_wrap[BUFFER_POINTER_WIDTH-1:0]
          : write_byte_sum[BUFFER_POINTER_WIDTH-1:0];

        assign write_byte_select[in_byte_i] =
          write_byte_pointer == OUTPUT_BUFFER_BYTE_INDEX;

        for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_staged_input_bit
          assign write_bit_select[bit_i][in_byte_i] =
              write_byte_select[in_byte_i]
            & staged_input_data_q[BITS_PER_BYTE*in_byte_i + bit_i];
        end

      end

      for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_pack_buffer_bit
        assign pack_buffer_write_data[BITS_PER_BYTE*out_byte_i + bit_i] =
                  |write_bit_select[bit_i];
      end

      assign pack_buffer_write_mask[BITS_PER_BYTE*out_byte_i +: BITS_PER_BYTE] =
          (|write_byte_select)
        ? {BITS_PER_BYTE{1'b1}}
        : {BITS_PER_BYTE{1'b0}};

    end

    assign pack_buffer_data_next =
        staged_input_transfer
      ? ((pack_buffer_data_q & ~pack_buffer_write_mask) | pack_buffer_write_data)
      : pack_buffer_data_q;

    always_ff @(posedge clk) begin
      if(input_stream_transfer)
        staged_input_data_q <= input_stream_data;
    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        staged_input_valid_q <= '0;
        pack_buffer_data_q   <= '0;
        write_byte_pointer_q <= '0;
        output_lane_q        <= '0;
      end
      else begin
        staged_input_valid_q <= staged_input_valid_next;
        pack_buffer_data_q   <= pack_buffer_data_next;
        write_byte_pointer_q <= write_byte_pointer_next;
        output_lane_q        <= output_lane_next;
      end
    end

  end
  else if(INPUT_BYTES_PER_BEAT > OUTPUT_BYTES_PER_BEAT) begin : g_large_to_small

    logic output_from_buffer_valid;
    logic output_from_buffer_transfer;

    logic output_stage_ready;
    logic output_stage_load;

    logic output_stage_valid_q;
    logic output_stage_valid_next;

    logic [OUTPUT_DATA_WIDTH-1:0] output_stage_data_q;
    logic [OUTPUT_DATA_WIDTH-1:0] output_stage_data_next;
    logic [OUTPUT_DATA_WIDTH-1:0] selected_output_data;

    logic [BUFFER_DATA_WIDTH-1:0] unpack_buffer_data_q;
    logic [BUFFER_DATA_WIDTH-1:0] unpack_buffer_data_next;

    logic input_lane_q;
    logic input_lane_next;

    logic [BUFFER_POINTER_WIDTH-1:0] read_byte_pointer_q;
    logic [BUFFER_POINTER_WIDTH-1:0] read_byte_pointer_next;
    logic [BUFFER_POINTER_WIDTH:0]   read_byte_pointer_sum;
    logic [BUFFER_POINTER_WIDTH:0]   read_byte_pointer_wrap;

    assign output_stream_valid =
       output_stage_valid_q;

    assign output_stream_data =
       output_stage_data_q;

    assign output_stage_ready =
        ~output_stage_valid_q
      | output_stream_ready;

    assign output_from_buffer_valid =
      stored_byte_count_q >= OUTPUT_BYTE_COUNT;

    assign output_from_buffer_transfer =
        output_from_buffer_valid
      & output_stage_ready;

    assign output_stage_load =
        output_from_buffer_transfer;

    assign output_stage_valid_next =
         output_stage_load
      | (  output_stage_valid_q
         & ~output_stream_ready);

    assign output_stage_data_next =
        output_stage_load
      ? selected_output_data
      : output_stage_data_q;

    assign bytes_removed =
        output_from_buffer_transfer
      ? OUTPUT_BYTE_COUNT
      : '0;

    assign input_stream_ready =
        free_byte_count_after_output >= {1'b0, INPUT_BYTE_COUNT};

    assign bytes_added =
        input_stream_transfer
      ? INPUT_BYTE_COUNT
      : '0;

    assign input_lane_next =
        input_lane_q
      ^ input_stream_transfer;

    assign unpack_buffer_data_next =
        input_stream_transfer
      ? (  input_lane_q
        ? {input_stream_data, unpack_buffer_data_q[INPUT_DATA_WIDTH-1:0]}
        : {unpack_buffer_data_q[2*INPUT_DATA_WIDTH-1:INPUT_DATA_WIDTH], input_stream_data})
      : unpack_buffer_data_q;

    assign read_byte_pointer_sum =
        {1'b0, read_byte_pointer_q}
      + {1'b0, OUTPUT_POINTER_STEP};

    assign read_byte_pointer_wrap =
        read_byte_pointer_sum
      - BUFFER_POINTER_LIMIT;

    assign read_byte_pointer_next =
        output_from_buffer_transfer
      ? ((read_byte_pointer_sum >= BUFFER_POINTER_LIMIT)
         ? read_byte_pointer_wrap[BUFFER_POINTER_WIDTH-1:0]
         : read_byte_pointer_sum[BUFFER_POINTER_WIDTH-1:0])
      : read_byte_pointer_q;

    for(genvar out_byte_i = 0; out_byte_i < OUTPUT_BYTES_PER_BEAT; out_byte_i = out_byte_i + 1) begin : g_output_byte_selector

      localparam logic [BUFFER_POINTER_WIDTH:0] OUTPUT_BYTE_OFFSET = out_byte_i;

      logic [BUFFER_POINTER_WIDTH:0]   read_byte_sum;
      logic [BUFFER_POINTER_WIDTH:0]   read_byte_wrap;
      logic [BUFFER_POINTER_WIDTH-1:0] read_byte_pointer;

      logic [BUFFER_CAPACITY_BYTES-1:0] buffer_byte_select;
      logic [BUFFER_CAPACITY_BYTES-1:0] buffer_bit_select [BITS_PER_BYTE-1:0];

      assign read_byte_sum =
          {1'b0, read_byte_pointer_q}
        + OUTPUT_BYTE_OFFSET;

      assign read_byte_wrap =
          read_byte_sum
        - BUFFER_POINTER_LIMIT;

      assign read_byte_pointer =
          (read_byte_sum >= BUFFER_POINTER_LIMIT)
        ? read_byte_wrap[BUFFER_POINTER_WIDTH-1:0]
        : read_byte_sum[BUFFER_POINTER_WIDTH-1:0];

      for(genvar buf_byte_i = 0; buf_byte_i < BUFFER_CAPACITY_BYTES; buf_byte_i = buf_byte_i + 1) begin : g_buffer_byte

        localparam logic [BUFFER_POINTER_WIDTH-1:0] BUFFER_BYTE_INDEX = buf_byte_i;

        assign buffer_byte_select[buf_byte_i] =
          read_byte_pointer == BUFFER_BYTE_INDEX;

        for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_buffer_bit
          assign buffer_bit_select[bit_i][buf_byte_i] =
              buffer_byte_select[buf_byte_i]
            & unpack_buffer_data_q[BITS_PER_BYTE*buf_byte_i + bit_i];
        end

      end

      for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_output_bit_selector
        assign selected_output_data[BITS_PER_BYTE*out_byte_i + bit_i] =
            |buffer_bit_select[bit_i];
      end

    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        unpack_buffer_data_q <= '0;
        input_lane_q         <= '0;
        read_byte_pointer_q  <= '0;
        output_stage_valid_q <= '0;
        output_stage_data_q  <= '0;
      end
      else begin
        unpack_buffer_data_q <= unpack_buffer_data_next;
        input_lane_q         <= input_lane_next;
        read_byte_pointer_q  <= read_byte_pointer_next;
        output_stage_valid_q <= output_stage_valid_next;
        output_stage_data_q  <= output_stage_data_next;
      end
    end

  end
  else begin : g_equal_width

    always_ff@(posedge clk or negedge rstn) begin
      if(~rstn)
         output_stream_valid <= 1'b0;
      else
         output_stream_valid <= input_stream_valid
                                  | (  output_stream_valid
                                     & ~output_stream_ready);
    end

    always_ff@(posedge clk) begin
      if(input_stream_transfer)
         output_stream_data <= input_stream_data;
    end

    assign input_stream_ready =
             output_stream_ready
          | ~output_stream_valid;

    assign bytes_added = '0;
    assign bytes_removed = '0;

  end

`ifndef SYNTHESIS
  assert_stored_byte_count_in_range:
    assert property (@(posedge clk) disable iff (~rstn)
      stored_byte_count_q <= BUFFER_BYTE_COUNT)
    else $error("gearbox stored byte count exceeded buffer capacity");

  assert_no_byte_count_underflow:
    assert property (@(posedge clk) disable iff (~rstn)
      {1'b0, bytes_removed} <= {1'b0, stored_byte_count_q})
    else $error("gearbox attempted to remove more bytes than stored");

  assert_next_byte_count_in_range:
    assert property (@(posedge clk) disable iff (~rstn)
      next_stored_byte_count <= {1'b0, BUFFER_BYTE_COUNT})
    else $error("gearbox next stored byte count exceeded buffer capacity");

  assert_output_stream_valid_known:
    assert property (@(posedge clk) disable iff (~rstn)
      !$isunknown(output_stream_valid))
    else $error("gearbox output_stream_valid is unknown");

  assert_output_stream_data_known_when_valid:
    assert property (@(posedge clk) disable iff (~rstn)
      output_stream_valid |-> !$isunknown(output_stream_data))
    else $error("gearbox output_stream_data is unknown while output_stream_valid is high");
`endif

endmodule