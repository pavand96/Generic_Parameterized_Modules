import common_pkg::*;

module gearbox #(
  parameter int unsigned IN_DATA_WIDTH      = 24,
  parameter int unsigned OUT_DATA_WIDTH     = 40,

  localparam int unsigned CHUNK_WIDTH         = greatest_common_divisor(IN_DATA_WIDTH, OUT_DATA_WIDTH),
  localparam int unsigned IN_CHUNKS_PER_BEAT  = IN_DATA_WIDTH / CHUNK_WIDTH,
  localparam int unsigned OUT_CHUNKS_PER_BEAT = OUT_DATA_WIDTH / CHUNK_WIDTH,

  localparam bit   IN_LT_OUT                = IN_CHUNKS_PER_BEAT < OUT_CHUNKS_PER_BEAT,
  localparam bit   IN_GT_OUT                = IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT,
  localparam bit   WIDTH_CONVERT            = IN_LT_OUT || IN_GT_OUT,
  localparam int   MAX_TFER_CHUNKS          = IN_GT_OUT ? IN_CHUNKS_PER_BEAT : OUT_CHUNKS_PER_BEAT,
  localparam int   MIN_TFER_CHUNKS          = IN_LT_OUT ? IN_CHUNKS_PER_BEAT : OUT_CHUNKS_PER_BEAT,
  localparam bit   NON_INTEGER_RATIO        = WIDTH_CONVERT && ((MAX_TFER_CHUNKS % MIN_TFER_CHUNKS) != 0),
  localparam int   BUFFER_CAPACITY_CHUNKS   = NON_INTEGER_RATIO ? (2 * MAX_TFER_CHUNKS) : MAX_TFER_CHUNKS,
  localparam int   BUFFER_DATA_WIDTH        = CHUNK_WIDTH * BUFFER_CAPACITY_CHUNKS,

  localparam int   BUFFER_PTR_WIDTH         = (BUFFER_CAPACITY_CHUNKS > 1) ? $clog2(BUFFER_CAPACITY_CHUNKS) : 1,
  localparam int   BUFFER_COUNT_WIDTH       = $clog2(BUFFER_CAPACITY_CHUNKS + 1),

  localparam logic [BUFFER_PTR_WIDTH-1:0]     IN_PTR_STEP         = IN_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_PTR_WIDTH-1:0]     OUT_PTR_STEP        = OUT_CHUNKS_PER_BEAT,
  localparam logic [BUFFER_PTR_WIDTH:0]       BUFFER_PTR_LIMIT    = BUFFER_CAPACITY_CHUNKS,

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

  // Handshake tfers are accepted only when vld and rdy are high in the same
  // cycle. The selected datapath branch uses these pulses to update its local
  // occupancy/control state.
  logic in_strm_tfer;
  logic out_strm_tfer;

  assign in_strm_tfer =
      in_strm_vld
    & in_strm_rdy;

  assign out_strm_tfer =
      out_strm_vld
    & out_strm_rdy;

  if(!WIDTH_CONVERT) begin : g_equal_width

    // Equal-width mode is a one-beat rdy/vld skid stage. No chunk packing is
    // needed.
    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn)
        out_strm_vld <= 1'b0;
      else
        out_strm_vld <=
            in_strm_vld
          | (out_strm_vld & ~out_strm_rdy);
    end

    always_ff @(posedge clk) begin
      if(in_strm_tfer)
        out_strm_data <= in_strm_data;
    end

    assign in_strm_rdy =
        out_strm_rdy
      | ~out_strm_vld;

  end
  else if(NON_INTEGER_RATIO) begin : g_non_exact
    begin : g_barrel

      logic [BUFFER_COUNT_WIDTH-1:0] stored_chunk_count_q;
      logic [BUFFER_COUNT_WIDTH-1:0] stored_chunk_count_next;

      logic [BUFFER_COUNT_WIDTH-1:0] chunks_added;
      logic [BUFFER_COUNT_WIDTH-1:0] chunks_removed;

      logic [BUFFER_COUNT_WIDTH:0]   next_stored_chunk_count;

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

      // Non-exact pack mode uses a circular buffer because incoming beats can
      // land at different chunk offsets relative to the output beat.
      if(IN_LT_OUT) begin : g_small_to_large

        localparam logic [BUFFER_COUNT_WIDTH-1:0] PACK_ROOM_NO_OUT_LIMIT =
            BUFFER_CAPACITY_CHUNKS
          - IN_CHUNKS_PER_BEAT;

        logic staged_in_vld_q;
        logic staged_in_vld_next;

        logic pack_buffer_has_space;
        logic staged_in_tfer;

        logic [IN_DATA_WIDTH-1:0]     staged_in_data_q;

        logic [BUFFER_DATA_WIDTH-1:0] pack_buffer_data_q;
        logic [BUFFER_DATA_WIDTH-1:0] pack_buffer_data_next;

        logic [BUFFER_PTR_WIDTH-1:0] write_chunk_ptr_q;
        logic [BUFFER_PTR_WIDTH-1:0] write_chunk_ptr_next;
        logic [BUFFER_PTR_WIDTH:0]   write_chunk_ptr_sum;
        logic [BUFFER_PTR_WIDTH:0]   write_chunk_ptr_wrap;

        logic out_lane_q;
        logic out_lane_next;

        logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_PTR_WIDTH-1:0] write_dst_chunk_ptr;

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
            out_strm_tfer
          | (stored_chunk_count_q <= PACK_ROOM_NO_OUT_LIMIT);

        assign in_strm_rdy =
            ~staged_in_vld_q
          |  pack_buffer_has_space;

        assign staged_in_tfer =
            staged_in_vld_q
          & pack_buffer_has_space;

        assign staged_in_vld_next =
            in_strm_tfer
          | (staged_in_vld_q & ~staged_in_tfer);

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

        // Write barrel: calculate the wrapped destination ptr once per input
        // chunk, then each buffer lane only compares against those ptrs.
        for(genvar in_chunk_i = 0; in_chunk_i < IN_CHUNKS_PER_BEAT; in_chunk_i = in_chunk_i + 1) begin : g_write_dst_chunk_ptr

          localparam logic [BUFFER_PTR_WIDTH:0] IN_CHUNK_OFFSET = in_chunk_i;

          if(in_chunk_i == 0) begin : g_base_chunk

            assign write_dst_chunk_ptr[in_chunk_i] =
                write_chunk_ptr_q;

          end
          else begin : g_offset_chunk

            logic [BUFFER_PTR_WIDTH:0] write_dst_chunk_sum;
            logic [BUFFER_PTR_WIDTH:0] write_dst_chunk_wrap;

            assign write_dst_chunk_sum =
                {1'b0, write_chunk_ptr_q}
              + IN_CHUNK_OFFSET;

            assign write_dst_chunk_wrap =
                write_dst_chunk_sum
              - BUFFER_PTR_LIMIT;

            assign write_dst_chunk_ptr[in_chunk_i] =
                (write_dst_chunk_sum >= BUFFER_PTR_LIMIT)
              ? write_dst_chunk_wrap[BUFFER_PTR_WIDTH-1:0]
              : write_dst_chunk_sum[BUFFER_PTR_WIDTH-1:0];

          end

        end

        for(genvar out_chunk_i = 0; out_chunk_i < BUFFER_CAPACITY_CHUNKS; out_chunk_i = out_chunk_i + 1) begin : g_pack_buffer_chunk

          localparam logic [BUFFER_PTR_WIDTH-1:0] OUT_BUFFER_CHUNK_INDEX = out_chunk_i;

          logic [IN_CHUNKS_PER_BEAT-1:0] write_src_chunk_sel_oh;
          logic write_src_chunk_sel_vld;
          logic [CHUNK_WIDTH-1:0] pack_buffer_chunk_q;
          logic [CHUNK_WIDTH-1:0] write_src_chunk_data;

          assign pack_buffer_chunk_q =
              pack_buffer_data_q[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH];

          for(genvar in_chunk_i = 0; in_chunk_i < IN_CHUNKS_PER_BEAT; in_chunk_i = in_chunk_i + 1) begin : g_in_chunk_match
            assign write_src_chunk_sel_oh[in_chunk_i] =
                write_dst_chunk_ptr[in_chunk_i] == OUT_BUFFER_CHUNK_INDEX;
          end

          assign write_src_chunk_sel_vld =
              |write_src_chunk_sel_oh;

          common_chunk_mux #(
            .CHUNK_WIDTH(CHUNK_WIDTH),
            .CHUNK_COUNT(IN_CHUNKS_PER_BEAT),
            .ONEHOT_SELECT(1'b1)
          ) u_write_chunk_mux (
            .in_chunk_select(write_src_chunk_sel_oh),
            .in_chunk_data(staged_in_data_q),
            .out_chunk_data(write_src_chunk_data)
          );

          assign pack_buffer_data_next[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH] =
              staged_in_tfer & write_src_chunk_sel_vld
            ? write_src_chunk_data
            : pack_buffer_chunk_q;

        end

        always_ff @(posedge clk) begin
          if(in_strm_tfer)
            staged_in_data_q <= in_strm_data;
        end

        always_ff @(posedge clk) begin
          pack_buffer_data_q <= pack_buffer_data_next;
        end

        always_ff @(posedge clk or negedge rstn) begin
          if(~rstn) begin
            staged_in_vld_q <= '0;
            write_chunk_ptr_q <= '0;
            out_lane_q <= '0;
          end
          else begin
            staged_in_vld_q <= staged_in_vld_next;
            write_chunk_ptr_q <= write_chunk_ptr_next;
            out_lane_q <= out_lane_next;
          end
        end

      end
      else begin : g_large_to_small

        localparam logic [BUFFER_COUNT_WIDTH-1:0] UNPACK_ROOM_NO_OUT_LIMIT =
            BUFFER_CAPACITY_CHUNKS
          - IN_CHUNKS_PER_BEAT;
        localparam logic [BUFFER_COUNT_WIDTH-1:0] UNPACK_ROOM_WITH_OUT_LIMIT =
            BUFFER_CAPACITY_CHUNKS
          - IN_CHUNKS_PER_BEAT
          + OUT_CHUNKS_PER_BEAT;
        logic [BUFFER_COUNT_WIDTH-1:0] unpack_room_limit;

        // Non-exact unpack mode uses a circular read barrel because successive
        // output beats can start at different chunk offsets.
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

        logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_PTR_WIDTH-1:0] read_src_chunk_ptr;

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
          | (out_stage_vld_q & ~out_strm_rdy);

        assign out_stage_data_next =
            out_stage_load
          ? selected_out_data
          : out_stage_data_q;

        assign chunks_removed =
            out_from_buffer_tfer
          ? OUT_CHUNK_COUNT
          : '0;

        assign unpack_room_limit =
            out_from_buffer_tfer
          ? UNPACK_ROOM_WITH_OUT_LIMIT
          : UNPACK_ROOM_NO_OUT_LIMIT;

        assign in_strm_rdy =
            stored_chunk_count_q <= unpack_room_limit;

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
          ? ((read_chunk_ptr_sum >= BUFFER_PTR_LIMIT)
              ? read_chunk_ptr_wrap[BUFFER_PTR_WIDTH-1:0]
              : read_chunk_ptr_sum[BUFFER_PTR_WIDTH-1:0])
          : read_chunk_ptr_q;

        // Read barrel: calculate the wrapped source ptr once per output chunk,
        // then use an indexed chunk mux for the buffer read.
        for(genvar out_chunk_i = 0; out_chunk_i < OUT_CHUNKS_PER_BEAT; out_chunk_i = out_chunk_i + 1) begin : g_read_src_chunk_ptr

          localparam logic [BUFFER_PTR_WIDTH:0] OUT_CHUNK_OFFSET = out_chunk_i;

          if(out_chunk_i == 0) begin : g_base_chunk

            assign read_src_chunk_ptr[out_chunk_i] =
                read_chunk_ptr_q;

          end
          else begin : g_offset_chunk

            logic [BUFFER_PTR_WIDTH:0] read_chunk_sum;
            logic [BUFFER_PTR_WIDTH:0] read_chunk_wrap;

            assign read_chunk_sum =
                {1'b0, read_chunk_ptr_q}
              + OUT_CHUNK_OFFSET;

            assign read_chunk_wrap =
                read_chunk_sum
              - BUFFER_PTR_LIMIT;

            assign read_src_chunk_ptr[out_chunk_i] =
                (read_chunk_sum >= BUFFER_PTR_LIMIT)
              ? read_chunk_wrap[BUFFER_PTR_WIDTH-1:0]
              : read_chunk_sum[BUFFER_PTR_WIDTH-1:0];

          end

        end

        for(genvar out_chunk_i = 0; out_chunk_i < OUT_CHUNKS_PER_BEAT; out_chunk_i = out_chunk_i + 1) begin : g_out_chunk_selector

          common_chunk_mux #(
            .CHUNK_WIDTH(CHUNK_WIDTH),
            .CHUNK_COUNT(BUFFER_CAPACITY_CHUNKS),
            .ONEHOT_SELECT(1'b0)
          ) u_read_chunk_mux (
            .in_chunk_select(read_src_chunk_ptr[out_chunk_i]),
            .in_chunk_data(unpack_buffer_data_q),
            .out_chunk_data(selected_out_data[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH])
          );

        end

        always_ff @(posedge clk) begin
          unpack_buffer_data_q <= unpack_buffer_data_next;
          out_stage_data_q <= out_stage_data_next;
        end

        always_ff @(posedge clk or negedge rstn) begin
          if(~rstn) begin
            in_lane_q <= '0;
            read_chunk_ptr_q <= '0;
            out_stage_vld_q <= '0;
          end
          else begin
            in_lane_q <= in_lane_next;
            read_chunk_ptr_q <= read_chunk_ptr_next;
            out_stage_vld_q <= out_stage_vld_next;
          end
        end

      end

    end

  end
  // Pack mode with an exact ratio fills fixed lanes in one output beat, so it
  // does not need the circular write barrel.
  else if(IN_LT_OUT) begin : g_exact_small_to_large

    localparam int PACK_RATIO       = OUT_CHUNKS_PER_BEAT / IN_CHUNKS_PER_BEAT;
    localparam int PACK_IDX_WIDTH   = $clog2(PACK_RATIO);
    localparam logic [PACK_IDX_WIDTH-1:0] PACK_LAST_INDEX = PACK_RATIO - 1;

    logic [PACK_IDX_WIDTH-1:0] pack_in_idx_q;
    logic [PACK_IDX_WIDTH-1:0] pack_in_idx_next;
    logic [PACK_IDX_WIDTH-1:0] pack_write_idx;

    logic pack_out_vld_q;
    logic pack_out_vld_next;

    logic [OUT_DATA_WIDTH-1:0] pack_data_q;
    logic [OUT_DATA_WIDTH-1:0] pack_data_next;

    assign out_strm_data =
        pack_data_q;

    assign out_strm_vld =
        pack_out_vld_q;

    assign in_strm_rdy =
        ~pack_out_vld_q
      |  out_strm_rdy;

    assign pack_write_idx =
        out_strm_tfer
      ? '0
      : pack_in_idx_q;

    assign pack_in_idx_next =
        in_strm_tfer
      ? ((pack_write_idx == PACK_LAST_INDEX) ? '0 : (pack_write_idx + 1'b1))
      : (out_strm_tfer ? '0 : pack_in_idx_q);

    assign pack_out_vld_next =
        (pack_out_vld_q & ~out_strm_tfer)
      | (in_strm_tfer & (pack_write_idx == PACK_LAST_INDEX));

    for(genvar pack_lane_i = 0; pack_lane_i < PACK_RATIO; pack_lane_i = pack_lane_i + 1) begin : g_pack_lane

      localparam logic [PACK_IDX_WIDTH-1:0] PACK_LANE_INDEX = pack_lane_i;

      assign pack_data_next[IN_DATA_WIDTH*pack_lane_i +: IN_DATA_WIDTH] =
          in_strm_tfer & (pack_write_idx == PACK_LANE_INDEX)
        ? in_strm_data
        : pack_data_q[IN_DATA_WIDTH*pack_lane_i +: IN_DATA_WIDTH];

    end

    always_ff @(posedge clk) begin
      pack_data_q <= pack_data_next;
    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        pack_in_idx_q <= '0;
        pack_out_vld_q <= '0;
      end
      else begin
        pack_in_idx_q <= pack_in_idx_next;
        pack_out_vld_q <= pack_out_vld_next;
      end
    end

  end
  // Unpack mode with an exact ratio shifts by a fixed output beat width, so it
  // does not need the circular read barrel.
  else begin : g_exact_large_to_small

    localparam int UNPACK_RATIO       = IN_CHUNKS_PER_BEAT / OUT_CHUNKS_PER_BEAT;
    localparam int UNPACK_REM_WIDTH   = $clog2(UNPACK_RATIO + 1);
    localparam logic [UNPACK_REM_WIDTH-1:0] UNPACK_RATIO_COUNT = UNPACK_RATIO;
    localparam logic [UNPACK_REM_WIDTH-1:0] UNPACK_ONE_COUNT   = 1;

    logic [UNPACK_REM_WIDTH-1:0] unpack_rem_count_q;
    logic [UNPACK_REM_WIDTH-1:0] unpack_rem_count_next;
    logic unpack_last_out;
    logic out_strm_vld_next;

    logic [IN_DATA_WIDTH-1:0] unpack_data_q;
    logic [IN_DATA_WIDTH-1:0] unpack_data_next;
    logic [IN_DATA_WIDTH-1:0] unpack_shift_data;

    assign out_strm_vld_next =
        unpack_rem_count_next != '0;

    assign out_strm_data =
        unpack_data_q[OUT_DATA_WIDTH-1:0];

    assign in_strm_rdy =
        (unpack_rem_count_q == '0)
      | (unpack_last_out & out_strm_rdy);

    assign unpack_last_out =
        unpack_rem_count_q == UNPACK_ONE_COUNT;

    assign unpack_shift_data =
        {unpack_data_q[OUT_DATA_WIDTH-1:0], unpack_data_q[IN_DATA_WIDTH-1:OUT_DATA_WIDTH]};

    assign unpack_rem_count_next =
        in_strm_tfer
      ? UNPACK_RATIO_COUNT
      : (out_strm_tfer ? (unpack_rem_count_q - UNPACK_ONE_COUNT) : unpack_rem_count_q);

    assign unpack_data_next =
        in_strm_tfer
      ? in_strm_data
      : (out_strm_tfer ? unpack_shift_data : unpack_data_q);

    always_ff @(posedge clk) begin
      unpack_data_q <= unpack_data_next;
    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        unpack_rem_count_q <= '0;
        out_strm_vld <= 1'b0;
      end
      else begin
        unpack_rem_count_q <= unpack_rem_count_next;
        out_strm_vld <= out_strm_vld_next;
      end
    end

  end

  `ifndef SYNTHESIS
  // Simulation-only protocol checks. These stay outside the generated datapath
  // branches so the same safety properties apply to every parameter set.
  if(NON_INTEGER_RATIO) begin : g_barrel_assertions

    assert_stored_chunk_count_in_range:
      assert property (@(posedge clk) disable iff (~rstn)
        g_non_exact.g_barrel.stored_chunk_count_q <= BUFFER_CHUNK_COUNT)
      else $error("gearbox stored chunk count exceeded buffer capacity");

    assert_no_chunk_count_underflow:
      assert property (@(posedge clk) disable iff (~rstn)
        {1'b0, g_non_exact.g_barrel.chunks_removed} <= {1'b0, g_non_exact.g_barrel.stored_chunk_count_q})
      else $error("gearbox attempted to remove more chunks than stored");

    assert_next_chunk_count_in_range:
      assert property (@(posedge clk) disable iff (~rstn)
        g_non_exact.g_barrel.next_stored_chunk_count <= {1'b0, BUFFER_CHUNK_COUNT})
      else $error("gearbox next stored chunk count exceeded buffer capacity");

  end

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
