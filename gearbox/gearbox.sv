module gearbox #(
  parameter        INPUT_CHUNKS_PER_BEAT    = 4,
  parameter        OUTPUT_CHUNKS_PER_BEAT   = 5,
  parameter int    BITS_PER_CHUNK           = 8,

  localparam       INPUT_DATA_WIDTH         = BITS_PER_CHUNK * INPUT_CHUNKS_PER_BEAT,
  localparam       OUTPUT_DATA_WIDTH        = BITS_PER_CHUNK * OUTPUT_CHUNKS_PER_BEAT,

  localparam int   MAX_TFER_CHUNKS          = (INPUT_CHUNKS_PER_BEAT > OUTPUT_CHUNKS_PER_BEAT) ? INPUT_CHUNKS_PER_BEAT : OUTPUT_CHUNKS_PER_BEAT,
  localparam int   BUFFER_CAPACITY_CHUNKS   = 2 * MAX_TFER_CHUNKS,
  localparam int   BUFFER_DATA_WIDTH        = BITS_PER_CHUNK * BUFFER_CAPACITY_CHUNKS,

  localparam int   BUFFER_PTR_WIDTH         = $clog2(BUFFER_CAPACITY_CHUNKS),
  localparam int   BUFFER_COUNT_WIDTH       = $clog2(BUFFER_CAPACITY_CHUNKS + 1),

  localparam logic [BUFFER_PTR_WIDTH-1:0] INPUT_PTR_STEP    = INPUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_PTR_WIDTH-1:0] OUTPUT_PTR_STEP   = OUTPUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_PTR_WIDTH:0]   BUFFER_PTR_LIMIT  = BUFFER_CAPACITY_CHUNKS,

  localparam logic [BUFFER_COUNT_WIDTH-1:0]   INPUT_CHUNK_COUNT      = INPUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0]   OUTPUT_CHUNK_COUNT     = OUTPUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0]   BUFFER_CHUNK_COUNT     = BUFFER_CAPACITY_CHUNKS
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

  // Handshake tfers are accepted only when valid and ready are high in the
  // same cycle. The chunk counters below use these pulses as the single source
  // of truth for buffer occupancy.
  logic input_stream_tfer;
  logic output_stream_tfer;

  logic [BUFFER_COUNT_WIDTH-1:0] stored_chunk_count_q;
  logic [BUFFER_COUNT_WIDTH-1:0] stored_chunk_count_next;

  logic [BUFFER_COUNT_WIDTH-1:0] chunks_added;
  logic [BUFFER_COUNT_WIDTH-1:0] chunks_removed;

  logic [BUFFER_COUNT_WIDTH:0]   next_stored_chunk_count;
  logic [BUFFER_COUNT_WIDTH:0]   free_chunk_count_after_output;

  assign input_stream_tfer =
      input_stream_valid
    & input_stream_ready;

  assign output_stream_tfer =
      output_stream_valid
    & output_stream_ready;

  assign free_chunk_count_after_output =
      {1'b0, BUFFER_CHUNK_COUNT}
    - {1'b0, stored_chunk_count_q}
    + {1'b0, chunks_removed};

  assign next_stored_chunk_count =
      {1'b0, stored_chunk_count_q}
    + {1'b0, chunks_added}
    - {1'b0, chunks_removed};

  assign stored_chunk_count_next =
    next_stored_chunk_count[BUFFER_COUNT_WIDTH-1:0];

  always_ff @(posedge clk or negedge rstn) begin
    if(~rstn)
      stored_chunk_count_q <= '0;
    else
      stored_chunk_count_q <= stored_chunk_count_next;
  end

  // Pack mode: several narrow input beats are assembled into one wider output
  // beat. The write side has variable chunk alignment, while the read side
  // selects one fixed output-width lane from the circular pack buffer.
  if(INPUT_CHUNKS_PER_BEAT < OUTPUT_CHUNKS_PER_BEAT) begin : g_small_to_large

    logic staged_input_valid_q;
    logic staged_input_valid_next;

    logic pack_buffer_has_space;
    logic staged_input_tfer;

    logic [INPUT_DATA_WIDTH-1:0]     staged_input_data_q;

    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_data_q;
    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_data_next;

    logic [BUFFER_PTR_WIDTH-1:0] write_chunk_ptr_q;
    logic [BUFFER_PTR_WIDTH-1:0] write_chunk_ptr_next;
    logic [BUFFER_PTR_WIDTH:0]   write_chunk_ptr_sum;
    logic [BUFFER_PTR_WIDTH:0]   write_chunk_ptr_wrap;

    logic output_lane_q;
    logic output_lane_next;

    assign output_stream_data =
        output_lane_q
      ? pack_buffer_data_q[2*OUTPUT_DATA_WIDTH-1:OUTPUT_DATA_WIDTH]
      : pack_buffer_data_q[OUTPUT_DATA_WIDTH-1:0];

    assign output_stream_valid =
        stored_chunk_count_q >= OUTPUT_CHUNK_COUNT;

    assign chunks_removed =
        output_stream_tfer
      ? OUTPUT_CHUNK_COUNT
      : '0;

    assign pack_buffer_has_space =
        free_chunk_count_after_output >= {1'b0, INPUT_CHUNK_COUNT};

    assign input_stream_ready =
        ~staged_input_valid_q
      |  pack_buffer_has_space;

    assign staged_input_tfer =
        staged_input_valid_q
      & pack_buffer_has_space;

    assign staged_input_valid_next =
        input_stream_tfer
      | (  staged_input_valid_q
         & ~staged_input_tfer);

    assign chunks_added =
        staged_input_tfer
      ? INPUT_CHUNK_COUNT
      : '0;

    assign write_chunk_ptr_sum =
        {1'b0, write_chunk_ptr_q}
      + {1'b0, INPUT_PTR_STEP};

    assign write_chunk_ptr_wrap =
        write_chunk_ptr_sum
      - BUFFER_PTR_LIMIT;

    assign write_chunk_ptr_next =
        staged_input_tfer
      ? ((write_chunk_ptr_sum >= BUFFER_PTR_LIMIT)
        ? write_chunk_ptr_wrap[BUFFER_PTR_WIDTH-1:0]
        : write_chunk_ptr_sum[BUFFER_PTR_WIDTH-1:0])
      : write_chunk_ptr_q;

    assign output_lane_next =
        output_lane_q
      ^ output_stream_tfer;

    // Write barrel: each staged input chunk is decoded against the current
    // write ptr and routed into the matching chunk lane of the pack buffer.
    for(genvar out_chunk_i = 0; out_chunk_i < BUFFER_CAPACITY_CHUNKS; out_chunk_i = out_chunk_i + 1) begin : g_pack_buffer_chunk

      localparam logic [BUFFER_PTR_WIDTH-1:0] OUTPUT_BUFFER_CHUNK_INDEX = out_chunk_i;

      logic [BUFFER_PTR_WIDTH:0] write_chunk_offset;
      logic [BUFFER_PTR_WIDTH:0] write_chunk_index;
      logic write_chunk_enable;
      logic [BITS_PER_CHUNK-1:0]      write_chunk_data;

      assign write_chunk_offset =
          ({1'b0, OUTPUT_BUFFER_CHUNK_INDEX} >= {1'b0, write_chunk_ptr_q})
        ? ({1'b0, OUTPUT_BUFFER_CHUNK_INDEX} - {1'b0, write_chunk_ptr_q})
        : ({1'b0, OUTPUT_BUFFER_CHUNK_INDEX} + BUFFER_PTR_LIMIT - {1'b0, write_chunk_ptr_q});

      assign write_chunk_enable =
          write_chunk_offset < {1'b0, INPUT_PTR_STEP};

      assign write_chunk_index =
          write_chunk_enable 
        ? write_chunk_offset : '0;

      assign write_chunk_data =
          staged_input_data_q[BITS_PER_CHUNK*write_chunk_index +: BITS_PER_CHUNK];

      assign pack_buffer_data_next[BITS_PER_CHUNK*out_chunk_i +: BITS_PER_CHUNK] =
          staged_input_tfer & write_chunk_enable
        ? write_chunk_data
        : pack_buffer_data_q[BITS_PER_CHUNK*out_chunk_i +: BITS_PER_CHUNK];

    end

    always_ff @(posedge clk) begin
      if(input_stream_tfer)
        staged_input_data_q <= input_stream_data;
    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        staged_input_valid_q <= '0;
        pack_buffer_data_q   <= '0;
        write_chunk_ptr_q <= '0;
        output_lane_q        <= '0;
      end
      else begin
        staged_input_valid_q <= staged_input_valid_next;
        pack_buffer_data_q   <= pack_buffer_data_next;
        write_chunk_ptr_q <= write_chunk_ptr_next;
        output_lane_q        <= output_lane_next;
      end
    end

  end
  else if(INPUT_CHUNKS_PER_BEAT > OUTPUT_CHUNKS_PER_BEAT) begin : g_large_to_small

    // Unpack mode: one wide input beat is stored in an aligned buffer lane and
    // then emitted as multiple narrower output beats. Backpressure is absorbed
    // by the output stage so output data remains stable while valid is held.
    logic output_from_buffer_valid;
    logic output_from_buffer_tfer;

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

    logic [BUFFER_PTR_WIDTH-1:0] read_chunk_ptr_q;
    logic [BUFFER_PTR_WIDTH-1:0] read_chunk_ptr_next;
    logic [BUFFER_PTR_WIDTH:0]   read_chunk_ptr_sum;
    logic [BUFFER_PTR_WIDTH:0]   read_chunk_ptr_wrap;

    assign output_stream_valid =
        output_stage_valid_q;

    assign output_stream_data =
        output_stage_data_q;

    assign output_stage_ready =
        ~output_stage_valid_q
      | output_stream_ready;

    assign output_from_buffer_valid =
        stored_chunk_count_q >= OUTPUT_CHUNK_COUNT;

    assign output_from_buffer_tfer =
        output_from_buffer_valid
      & output_stage_ready;

    assign output_stage_load =
        output_from_buffer_tfer;

    assign output_stage_valid_next =
         output_stage_load
      | (  output_stage_valid_q
         & ~output_stream_ready);

    assign output_stage_data_next =
        output_stage_load
      ? selected_output_data
      : output_stage_data_q;

    assign chunks_removed =
        output_from_buffer_tfer
      ? OUTPUT_CHUNK_COUNT
      : '0;

    assign input_stream_ready =
        free_chunk_count_after_output >= {1'b0, INPUT_CHUNK_COUNT};

    assign chunks_added =
        input_stream_tfer
      ? INPUT_CHUNK_COUNT
      : '0;

    assign input_lane_next =
        input_lane_q
      ^ input_stream_tfer;

    assign unpack_buffer_data_next =
        input_stream_tfer
      ? (  input_lane_q
        ? {input_stream_data, unpack_buffer_data_q[INPUT_DATA_WIDTH-1:0]}
        : {unpack_buffer_data_q[2*INPUT_DATA_WIDTH-1:INPUT_DATA_WIDTH], input_stream_data})
      : unpack_buffer_data_q;

    assign read_chunk_ptr_sum =
        {1'b0, read_chunk_ptr_q}
      + {1'b0, OUTPUT_PTR_STEP};

    assign read_chunk_ptr_wrap =
        read_chunk_ptr_sum
      - BUFFER_PTR_LIMIT;

    assign read_chunk_ptr_next =
        output_from_buffer_tfer
      ? (( read_chunk_ptr_sum >= BUFFER_PTR_LIMIT)
         ? read_chunk_ptr_wrap[BUFFER_PTR_WIDTH-1:0]
         : read_chunk_ptr_sum[BUFFER_PTR_WIDTH-1:0])
      : read_chunk_ptr_q;

    // Read barrel: each output chunk lane selects the buffer chunk addressed by
    // the read ptr plus that lane's chunk offset, wrapping at buffer depth.
    for(genvar out_chunk_i = 0; out_chunk_i < OUTPUT_CHUNKS_PER_BEAT; out_chunk_i = out_chunk_i + 1) begin : g_output_chunk_selector

      localparam logic [BUFFER_PTR_WIDTH:0] OUTPUT_CHUNK_OFFSET = out_chunk_i;

      logic [BUFFER_PTR_WIDTH:0]   read_chunk_sum;
      logic [BUFFER_PTR_WIDTH:0]   read_chunk_wrap;
      logic [BUFFER_PTR_WIDTH-1:0] read_chunk_ptr;

      assign read_chunk_sum =
          {1'b0, read_chunk_ptr_q}
        + OUTPUT_CHUNK_OFFSET;

      assign read_chunk_wrap =
          read_chunk_sum
        - BUFFER_PTR_LIMIT;

      assign read_chunk_ptr =
          (read_chunk_sum >= BUFFER_PTR_LIMIT)
        ? read_chunk_wrap[BUFFER_PTR_WIDTH-1:0]
        : read_chunk_sum[BUFFER_PTR_WIDTH-1:0];

      assign selected_output_data[BITS_PER_CHUNK*out_chunk_i +: BITS_PER_CHUNK] =
          unpack_buffer_data_q[BITS_PER_CHUNK*read_chunk_ptr +: BITS_PER_CHUNK];

    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        unpack_buffer_data_q <= '0;
        input_lane_q         <= '0;
        read_chunk_ptr_q  <= '0;
        output_stage_valid_q <= '0;
        output_stage_data_q  <= '0;
      end
      else begin
        unpack_buffer_data_q <= unpack_buffer_data_next;
        input_lane_q         <= input_lane_next;
        read_chunk_ptr_q  <= read_chunk_ptr_next;
        output_stage_valid_q <= output_stage_valid_next;
        output_stage_data_q  <= output_stage_data_next;
      end
    end

  end
  else begin : g_equal_width

    // Equal-width mode is a one-beat ready/valid skid stage. No chunk packing is
    // needed, so the shared chunk counter stays at zero.
    always_ff@(posedge clk or negedge rstn) begin
      if(~rstn)
         output_stream_valid <= 1'b0;
      else
         output_stream_valid <= input_stream_valid
                                  | (  output_stream_valid
                                     & ~output_stream_ready);
    end

    always_ff@(posedge clk) begin
      if(input_stream_tfer)
         output_stream_data <= input_stream_data;
    end

    assign input_stream_ready =
             output_stream_ready
          | ~output_stream_valid;

    assign chunks_added = '0;
    assign chunks_removed = '0;

  end

`ifndef SYNTHESIS
  // Simulation-only protocol checks. These stay outside the generated datapath
  // branches so the same safety properties apply to every parameter set.
  assert_stored_chunk_count_in_range:
    assert property (@(posedge clk) disable iff (~rstn)
      stored_chunk_count_q <= BUFFER_CHUNK_COUNT)
    else $error("gearbox stored chunk count exceeded buffer capacity");

  assert_no_chunk_count_underflow:
    assert property (@(posedge clk) disable iff (~rstn)
      {1'b0, chunks_removed} <= {1'b0, stored_chunk_count_q})
    else $error("gearbox attempted to remove more chunks than stored");

  assert_next_chunk_count_in_range:
    assert property (@(posedge clk) disable iff (~rstn)
      next_stored_chunk_count <= {1'b0, BUFFER_CHUNK_COUNT})
    else $error("gearbox next stored chunk count exceeded buffer capacity");

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