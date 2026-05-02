module gearbox #(
  parameter        IN_CHUNKS_PER_BEAT    = 4,
  parameter        OUT_CHUNKS_PER_BEAT   = 5,
  parameter        BITS_PER_CHUNK        = 8,

  localparam       IN_DATA_WIDTH            = BITS_PER_CHUNK * IN_CHUNKS_PER_BEAT,
  localparam       OUT_DATA_WIDTH           = BITS_PER_CHUNK * OUT_CHUNKS_PER_BEAT,

  localparam int   MAX_TFER_CHUNKS          = (IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT) ? IN_CHUNKS_PER_BEAT : OUT_CHUNKS_PER_BEAT,
  localparam int   BUFFER_CAPACITY_CHUNKS   = 2 * MAX_TFER_CHUNKS,
  localparam int   BUFFER_DATA_WIDTH        = BITS_PER_CHUNK * BUFFER_CAPACITY_CHUNKS,

  localparam int   BUFFER_PTR_WIDTH         = $clog2(BUFFER_CAPACITY_CHUNKS),
  localparam int   BUFFER_COUNT_WIDTH       = $clog2(BUFFER_CAPACITY_CHUNKS + 1),

  localparam logic [BUFFER_PTR_WIDTH-1:0] IN_PTR_STEP       = IN_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_PTR_WIDTH-1:0] OUT_PTR_STEP      = OUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_PTR_WIDTH:0]   BUFFER_PTR_LIMIT  = BUFFER_CAPACITY_CHUNKS,

  localparam logic [BUFFER_COUNT_WIDTH-1:0]   IN_CHUNK_COUNT      = IN_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0]   OUT_CHUNK_COUNT     = OUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0]   BUFFER_CHUNK_COUNT  = BUFFER_CAPACITY_CHUNKS
)
(
  input in_strm_vld,
  input [IN_DATA_WIDTH-1:0] in_strm_data,
  output logic in_strm_rdy,

  input out_strm_rdy,
  output logic [OUT_DATA_WIDTH-1:0] out_strm_data,
  output logic out_strm_vld,

  input clk,
  input rstn
);

  // Handshake tfers are accepted only when vld and rdy are high in the
  // same cycle. The chunk counters below use these pulses as the single source
  // of truth for buffer occupancy.
  logic in_strm_tfer;
  logic out_strm_tfer;

  logic [BUFFER_COUNT_WIDTH-1:0] stored_chunk_count_q;
  logic [BUFFER_COUNT_WIDTH-1:0] stored_chunk_count_next;

  logic [BUFFER_COUNT_WIDTH-1:0] chunks_added;
  logic [BUFFER_COUNT_WIDTH-1:0] chunks_removed;

  logic [BUFFER_COUNT_WIDTH:0]   next_stored_chunk_count;
  logic [BUFFER_COUNT_WIDTH:0]   free_chunk_count_after_out;

  assign in_strm_tfer =
      in_strm_vld
    & in_strm_rdy;

  assign out_strm_tfer =
      out_strm_vld
    & out_strm_rdy;

  assign free_chunk_count_after_out =
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

  // Pack mode: several narrow in beats are assembled into one wider output
  // beat. The write side has variable chunk alignment, while the read side
  // selects one fixed output-width lane from the circular pack buffer.
  if(IN_CHUNKS_PER_BEAT < OUT_CHUNKS_PER_BEAT) begin : g_small_to_large

    logic staged_in_vld_q;
    logic staged_in_vld_next;

    logic pack_buffer_has_space;
    logic staged_in_tfer;

    logic [IN_DATA_WIDTH-1:0]     staged_in_data_q;

    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_data_q;
    logic [BUFFER_DATA_WIDTH-1:0]    pack_buffer_data_next;

    logic [BUFFER_PTR_WIDTH-1:0] write_chunk_ptr_q;
    logic [BUFFER_PTR_WIDTH-1:0] write_chunk_ptr_next;
    logic [BUFFER_PTR_WIDTH:0]   write_chunk_ptr_sum;
    logic [BUFFER_PTR_WIDTH:0]   write_chunk_ptr_wrap;

    logic out_lane_q;
    logic out_lane_next;

    assign out_strm_data =
        out_lane_q
      ? pack_buffer_data_q[2*OUT_DATA_WIDTH-1:OUT_DATA_WIDTH]
      : pack_buffer_data_q[OUT_DATA_WIDTH-1:0];

    assign out_strm_vld =
        stored_chunk_count_q >= OUT_CHUNK_COUNT;

    assign chunks_removed =
        out_strm_tfer
      ? OUT_CHUNK_COUNT
      : '0;

    assign pack_buffer_has_space =
        free_chunk_count_after_out >= {1'b0, IN_CHUNK_COUNT};

    assign in_strm_rdy =
        ~staged_in_vld_q
      |  pack_buffer_has_space;

    assign staged_in_tfer =
        staged_in_vld_q
      & pack_buffer_has_space;

    assign staged_in_vld_next =
        in_strm_tfer
      | (  staged_in_vld_q
         & ~staged_in_tfer);

    assign chunks_added =
        staged_in_tfer
      ? IN_CHUNK_COUNT
      : '0;

    assign write_chunk_ptr_sum =
        {1'b0, write_chunk_ptr_q}
      + {1'b0, IN_PTR_STEP};

    assign write_chunk_ptr_wrap =
        write_chunk_ptr_sum
      - BUFFER_PTR_LIMIT;

    assign write_chunk_ptr_next =
        staged_in_tfer
      ? ((write_chunk_ptr_sum >= BUFFER_PTR_LIMIT)
        ? write_chunk_ptr_wrap[BUFFER_PTR_WIDTH-1:0]
        : write_chunk_ptr_sum[BUFFER_PTR_WIDTH-1:0])
      : write_chunk_ptr_q;

    assign out_lane_next =
        out_lane_q
      ^ out_strm_tfer;

    // Write barrel: each staged in chunk is decoded against the current
    // write ptr and routed into the matching chunk lane of the pack buffer.
    for(genvar out_chunk_i = 0; out_chunk_i < BUFFER_CAPACITY_CHUNKS; out_chunk_i = out_chunk_i + 1) begin : g_pack_buffer_chunk

      localparam logic [BUFFER_PTR_WIDTH-1:0] OUT_BUFFER_CHUNK_INDEX = out_chunk_i;

      logic [BUFFER_PTR_WIDTH:0] write_chunk_offset;
      logic [BUFFER_PTR_WIDTH:0] write_chunk_index;
      logic write_chunk_enable;
      logic [BITS_PER_CHUNK-1:0]      write_chunk_data;

      assign write_chunk_offset =
          ({1'b0, OUT_BUFFER_CHUNK_INDEX} >= {1'b0, write_chunk_ptr_q})
        ? ({1'b0, OUT_BUFFER_CHUNK_INDEX} - {1'b0, write_chunk_ptr_q})
        : ({1'b0, OUT_BUFFER_CHUNK_INDEX} + BUFFER_PTR_LIMIT - {1'b0, write_chunk_ptr_q});

      assign write_chunk_enable =
          write_chunk_offset < {1'b0, IN_PTR_STEP};

      assign write_chunk_index =
          write_chunk_enable 
        ? write_chunk_offset : '0;

      assign write_chunk_data =
          staged_in_data_q[BITS_PER_CHUNK*write_chunk_index +: BITS_PER_CHUNK];

      assign pack_buffer_data_next[BITS_PER_CHUNK*out_chunk_i +: BITS_PER_CHUNK] =
          staged_in_tfer & write_chunk_enable
        ? write_chunk_data
        : pack_buffer_data_q[BITS_PER_CHUNK*out_chunk_i +: BITS_PER_CHUNK];

    end

    always_ff @(posedge clk) begin
      if(in_strm_tfer)
        staged_in_data_q <= in_strm_data;
    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        staged_in_vld_q <= '0;
        pack_buffer_data_q   <= '0;
        write_chunk_ptr_q <= '0;
        out_lane_q        <= '0;
      end
      else begin
        staged_in_vld_q <= staged_in_vld_next;
        pack_buffer_data_q   <= pack_buffer_data_next;
        write_chunk_ptr_q <= write_chunk_ptr_next;
        out_lane_q        <= out_lane_next;
      end
    end

  end
  else if(IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT) begin : g_large_to_small

    // Unpack mode: one wide in beat is stored in an aligned buffer lane and
    // then emitted as multiple narrower output beats. Backpressure is absorbed
    // by the output stage so output data remains stable while vld is held.
    logic out_from_buffer_vld;
    logic out_from_buffer_tfer;

    logic out_stage_rdy;
    logic out_stage_load;

    logic out_stage_vld_q;
    logic out_stage_vld_next;

    logic [OUT_DATA_WIDTH-1:0] out_stage_data_q;
    logic [OUT_DATA_WIDTH-1:0] out_stage_data_next;
    logic [OUT_DATA_WIDTH-1:0] selected_out_data;

    logic [BUFFER_DATA_WIDTH-1:0] unpack_buffer_data_q;
    logic [BUFFER_DATA_WIDTH-1:0] unpack_buffer_data_next;

    logic in_lane_q;
    logic in_lane_next;

    logic [BUFFER_PTR_WIDTH-1:0] read_chunk_ptr_q;
    logic [BUFFER_PTR_WIDTH-1:0] read_chunk_ptr_next;
    logic [BUFFER_PTR_WIDTH:0]   read_chunk_ptr_sum;
    logic [BUFFER_PTR_WIDTH:0]   read_chunk_ptr_wrap;

    assign out_strm_vld =
        out_stage_vld_q;

    assign out_strm_data =
        out_stage_data_q;

    assign out_stage_rdy =
        ~out_stage_vld_q
      | out_strm_rdy;

    assign out_from_buffer_vld =
        stored_chunk_count_q >= OUT_CHUNK_COUNT;

    assign out_from_buffer_tfer =
        out_from_buffer_vld
      & out_stage_rdy;

    assign out_stage_load =
        out_from_buffer_tfer;

    assign out_stage_vld_next =
         out_stage_load
      | (  out_stage_vld_q
         & ~out_strm_rdy);

    assign out_stage_data_next =
        out_stage_load
      ? selected_out_data
      : out_stage_data_q;

    assign chunks_removed =
        out_from_buffer_tfer
      ? OUT_CHUNK_COUNT
      : '0;

    assign in_strm_rdy =
        free_chunk_count_after_out >= {1'b0, IN_CHUNK_COUNT};

    assign chunks_added =
        in_strm_tfer
      ? IN_CHUNK_COUNT
      : '0;

    assign in_lane_next =
        in_lane_q
      ^ in_strm_tfer;

    assign unpack_buffer_data_next =
        in_strm_tfer
      ? (  in_lane_q
        ? {in_strm_data, unpack_buffer_data_q[IN_DATA_WIDTH-1:0]}
        : {unpack_buffer_data_q[2*IN_DATA_WIDTH-1:IN_DATA_WIDTH], in_strm_data})
      : unpack_buffer_data_q;

    assign read_chunk_ptr_sum =
        {1'b0, read_chunk_ptr_q}
      + {1'b0, OUT_PTR_STEP};

    assign read_chunk_ptr_wrap =
        read_chunk_ptr_sum
      - BUFFER_PTR_LIMIT;

    assign read_chunk_ptr_next =
        out_from_buffer_tfer
      ? (( read_chunk_ptr_sum >= BUFFER_PTR_LIMIT)
         ? read_chunk_ptr_wrap[BUFFER_PTR_WIDTH-1:0]
         : read_chunk_ptr_sum[BUFFER_PTR_WIDTH-1:0])
      : read_chunk_ptr_q;

    // Read barrel: each output chunk lane selects the buffer chunk addressed by
    // the read ptr plus that lane's chunk offset, wrapping at buffer depth.
    for(genvar out_chunk_i = 0; out_chunk_i < OUT_CHUNKS_PER_BEAT; out_chunk_i = out_chunk_i + 1) begin : g_out_chunk_selector

      localparam logic [BUFFER_PTR_WIDTH:0] OUT_CHUNK_OFFSET = out_chunk_i;

      logic [BUFFER_PTR_WIDTH:0]   read_chunk_sum;
      logic [BUFFER_PTR_WIDTH:0]   read_chunk_wrap;
      logic [BUFFER_PTR_WIDTH-1:0] read_chunk_ptr;

      assign read_chunk_sum =
          {1'b0, read_chunk_ptr_q}
        + OUT_CHUNK_OFFSET;

      assign read_chunk_wrap =
          read_chunk_sum
        - BUFFER_PTR_LIMIT;

      assign read_chunk_ptr =
          (read_chunk_sum >= BUFFER_PTR_LIMIT)
        ? read_chunk_wrap[BUFFER_PTR_WIDTH-1:0]
        : read_chunk_sum[BUFFER_PTR_WIDTH-1:0];

      assign selected_out_data[BITS_PER_CHUNK*out_chunk_i +: BITS_PER_CHUNK] =
          unpack_buffer_data_q[BITS_PER_CHUNK*read_chunk_ptr +: BITS_PER_CHUNK];

    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        unpack_buffer_data_q <= '0;
        in_lane_q         <= '0;
        read_chunk_ptr_q  <= '0;
        out_stage_vld_q <= '0;
        out_stage_data_q  <= '0;
      end
      else begin
        unpack_buffer_data_q <= unpack_buffer_data_next;
        in_lane_q         <= in_lane_next;
        read_chunk_ptr_q  <= read_chunk_ptr_next;
        out_stage_vld_q <= out_stage_vld_next;
        out_stage_data_q  <= out_stage_data_next;
      end
    end

  end
  else begin : g_equal_width

    // Equal-width mode is a one-beat rdy/vld skid stage. No chunk packing is
    // needed, so the shared chunk counter stays at zero.
    always_ff@(posedge clk or negedge rstn) begin
      if(~rstn)
         out_strm_vld <= 1'b0;
      else
         out_strm_vld <= in_strm_vld
                                  | (  out_strm_vld
                                     & ~out_strm_rdy);
    end

    always_ff@(posedge clk) begin
      if(in_strm_tfer)
         out_strm_data <= in_strm_data;
    end

    assign in_strm_rdy =
             out_strm_rdy
          | ~out_strm_vld;

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

  assert_out_strm_vld_known:
    assert property (@(posedge clk) disable iff (~rstn)
      !$isunknown(out_strm_vld))
    else $error("gearbox out_strm_vld is unknown");

  assert_out_strm_data_known_when_vld:
    assert property (@(posedge clk) disable iff (~rstn)
      out_strm_vld |-> !$isunknown(out_strm_data))
    else $error("gearbox out_strm_data is unknown while out_strm_vld is high");
`endif

endmodule
