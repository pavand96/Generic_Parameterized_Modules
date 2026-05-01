module gearbox #(
  parameter INPUT_BYTES_PER_BEAT  = 4,
  parameter OUTPUT_BYTES_PER_BEAT = 5,

  localparam int BITS_PER_BYTE = 8,

  localparam INPUT_DATA_WIDTH  = BITS_PER_BYTE * INPUT_BYTES_PER_BEAT,
  localparam OUTPUT_DATA_WIDTH = BITS_PER_BYTE * OUTPUT_BYTES_PER_BEAT,

  localparam int MAX_TRANSFER_BYTES    = (INPUT_BYTES_PER_BEAT > OUTPUT_BYTES_PER_BEAT) ? INPUT_BYTES_PER_BEAT : OUTPUT_BYTES_PER_BEAT,
  localparam int BUFFER_CAPACITY_BYTES = 2 * MAX_TRANSFER_BYTES,
  localparam int BUFFER_DATA_WIDTH     = BITS_PER_BYTE * BUFFER_CAPACITY_BYTES,

  localparam int BUFFER_POINTER_WIDTH = $clog2(BUFFER_CAPACITY_BYTES),
  localparam int BUFFER_COUNT_WIDTH   = $clog2(BUFFER_CAPACITY_BYTES + 1),

  localparam logic [BUFFER_POINTER_WIDTH-1:0] INPUT_POINTER_STEP   = INPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_POINTER_WIDTH-1:0] OUTPUT_POINTER_STEP  = OUTPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_POINTER_WIDTH:0]   BUFFER_POINTER_LIMIT = BUFFER_CAPACITY_BYTES,

  localparam logic [BUFFER_COUNT_WIDTH-1:0] INPUT_BYTE_COUNT  = INPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0] OUTPUT_BYTE_COUNT = OUTPUT_BYTES_PER_BEAT,
  localparam logic [BUFFER_COUNT_WIDTH-1:0] BUFFER_BYTE_COUNT = BUFFER_CAPACITY_BYTES
)
(
  input valid_in,
  input [INPUT_DATA_WIDTH-1:0] data_in,
  output logic ready_out,

  input ready_in,
  output logic [OUTPUT_DATA_WIDTH-1:0] data_out,
  output logic valid_out,

  input clk,
  input rstn
);

  logic in_data_moving;
  logic out_data_moving;

  logic [BUFFER_COUNT_WIDTH-1:0] stored_bytes_q;
  logic [BUFFER_COUNT_WIDTH-1:0] stored_bytes_in;

  logic [BUFFER_COUNT_WIDTH-1:0] bytes_inc;
  logic [BUFFER_COUNT_WIDTH-1:0] bytes_dec;

  logic [BUFFER_COUNT_WIDTH:0] stored_bytes_calc;
  logic [BUFFER_COUNT_WIDTH:0] free_bytes_after_read;

  assign in_data_moving =
      valid_in
    & ready_out;

  assign out_data_moving =
      valid_out
    & ready_in;

  assign free_bytes_after_read =
      {1'b0, BUFFER_BYTE_COUNT}
    - {1'b0, stored_bytes_q}
    + {1'b0, bytes_dec};

  assign stored_bytes_calc =
      {1'b0, stored_bytes_q}
    + {1'b0, bytes_inc}
    - {1'b0, bytes_dec};

  assign stored_bytes_in =
    stored_bytes_calc[BUFFER_COUNT_WIDTH-1:0];

  always_ff @(posedge clk or negedge rstn) begin
    if(~rstn)
      stored_bytes_q <= '0;
    else
      stored_bytes_q <= stored_bytes_in;
  end

  if(INPUT_BYTES_PER_BEAT < OUTPUT_BYTES_PER_BEAT) begin : g_small_to_large

    logic pack_data_valid_q;
    logic pack_data_valid_in;

    logic packrot_has_space;
    logic pack_data_moving;

    logic [INPUT_DATA_WIDTH-1:0] pack_data_q;

    logic [BUFFER_DATA_WIDTH-1:0] packrot_data_q;
    logic [BUFFER_DATA_WIDTH-1:0] packrot_data_in;
    logic [BUFFER_DATA_WIDTH-1:0] packrot_write_data;
    logic [BUFFER_DATA_WIDTH-1:0] packrot_write_mask;

    logic [BUFFER_POINTER_WIDTH-1:0] wr_ptr_q;
    logic [BUFFER_POINTER_WIDTH-1:0] wr_ptr_in;
    logic [BUFFER_POINTER_WIDTH:0] wr_ptr_sum;
    logic [BUFFER_POINTER_WIDTH:0] wr_ptr_wrap;

    logic rd_lane_q;
    logic rd_lane_in;

    assign data_out =
        rd_lane_q
      ? packrot_data_q[2*OUTPUT_DATA_WIDTH-1:OUTPUT_DATA_WIDTH]
      : packrot_data_q[OUTPUT_DATA_WIDTH-1:0];

    assign valid_out =
      stored_bytes_q >= OUTPUT_BYTE_COUNT;

    assign bytes_dec =
        out_data_moving
      ? OUTPUT_BYTE_COUNT
      : '0;

    assign packrot_has_space =
      free_bytes_after_read >= {1'b0, INPUT_BYTE_COUNT};

    assign ready_out =
        ~pack_data_valid_q
      |  packrot_has_space;

    assign pack_data_moving =
        pack_data_valid_q
      & packrot_has_space;

    assign pack_data_valid_in =
        in_data_moving
      | (  pack_data_valid_q 
         & ~pack_data_moving);

    assign bytes_inc =
        pack_data_moving
      ? INPUT_BYTE_COUNT
      : '0;

    assign wr_ptr_sum =
        {1'b0, wr_ptr_q}
      + {1'b0, INPUT_POINTER_STEP};

    assign wr_ptr_wrap =
        wr_ptr_sum
      - BUFFER_POINTER_LIMIT;

    assign wr_ptr_in =
        pack_data_moving
      ? ((wr_ptr_sum >= BUFFER_POINTER_LIMIT)
        ? wr_ptr_wrap[BUFFER_POINTER_WIDTH-1:0]
        : wr_ptr_sum[BUFFER_POINTER_WIDTH-1:0])
      : wr_ptr_q;

    assign rd_lane_in =
        rd_lane_q
      ^ out_data_moving;

    for(genvar out_byte_i = 0; out_byte_i < BUFFER_CAPACITY_BYTES; out_byte_i = out_byte_i + 1) begin : g_packrot_out_byte

      localparam logic [BUFFER_POINTER_WIDTH-1:0] OUT_BYTE_PTR = out_byte_i;

      logic [INPUT_BYTES_PER_BEAT-1:0] write_byte_sel;
      logic [BITS_PER_BYTE-1:0] [INPUT_BYTES_PER_BEAT-1:0] write_bit_sel;

      for(genvar in_byte_i = 0; in_byte_i < INPUT_BYTES_PER_BEAT; in_byte_i = in_byte_i + 1) begin : g_pack_data_in_byte

        localparam logic [BUFFER_POINTER_WIDTH:0] IN_BYTE_OFFSET = in_byte_i;

        logic [BUFFER_POINTER_WIDTH:0] write_byte_sum;
        logic [BUFFER_POINTER_WIDTH:0] write_byte_wrap;
        logic [BUFFER_POINTER_WIDTH-1:0] write_byte_ptr;

        assign write_byte_sum =
            {1'b0, wr_ptr_q}
          + IN_BYTE_OFFSET;

        assign write_byte_wrap =
            write_byte_sum
          - BUFFER_POINTER_LIMIT;

        assign write_byte_ptr =
            write_byte_sum >= BUFFER_POINTER_LIMIT
          ? write_byte_wrap[BUFFER_POINTER_WIDTH-1:0]
          : write_byte_sum[BUFFER_POINTER_WIDTH-1:0];

        assign write_byte_sel[in_byte_i] =
          write_byte_ptr == OUT_BYTE_PTR;

        for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_pack_data_bit
          assign write_bit_sel[bit_i][in_byte_i] =
              write_byte_sel[in_byte_i]
            & pack_data_q[BITS_PER_BYTE*in_byte_i + bit_i];
        end

      end

      for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_packrot_bit
        assign packrot_write_data[BITS_PER_BYTE*out_byte_i + bit_i] =
          |write_bit_sel[bit_i];
      end

      assign packrot_write_mask[BITS_PER_BYTE*out_byte_i +: BITS_PER_BYTE] =
        (|write_byte_sel)
        ? {BITS_PER_BYTE{1'b1}}
        : {BITS_PER_BYTE{1'b0}};

    end

    assign packrot_data_in =
        pack_data_moving
      ? ((packrot_data_q & ~packrot_write_mask) | packrot_write_data)
      : packrot_data_q;

    always_ff @(posedge clk) begin
      if(in_data_moving)
        pack_data_q <= data_in;
    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        pack_data_valid_q <= '0;
        packrot_data_q    <= '0;
        wr_ptr_q          <= '0;
        rd_lane_q         <= '0;
      end
      else begin
        pack_data_valid_q <= pack_data_valid_in;
        packrot_data_q    <= packrot_data_in;
        wr_ptr_q          <= wr_ptr_in;
        rd_lane_q         <= rd_lane_in;
      end
    end

  end
  else if(INPUT_BYTES_PER_BEAT > OUTPUT_BYTES_PER_BEAT) begin : g_large_to_small

    logic buffer_output_valid;
    logic buffer_output_moving;

    logic out_stage_ready;
    logic out_stage_load;

    logic out_stage_valid_q;
    logic out_stage_valid_in;

    logic [OUTPUT_DATA_WIDTH-1:0] out_stage_data_q;
    logic [OUTPUT_DATA_WIDTH-1:0] out_stage_data_in;
    logic [OUTPUT_DATA_WIDTH-1:0] barrel_data_out;

    logic [BUFFER_DATA_WIDTH-1:0] unpack_data_q;
    logic [BUFFER_DATA_WIDTH-1:0] unpack_data_in;

    logic wr_lane_q;
    logic wr_lane_in;

    logic [BUFFER_POINTER_WIDTH-1:0] rd_ptr_q;
    logic [BUFFER_POINTER_WIDTH-1:0] rd_ptr_in;
    logic [BUFFER_POINTER_WIDTH:0] rd_ptr_sum;
    logic [BUFFER_POINTER_WIDTH:0] rd_ptr_wrap;

    assign valid_out =
       out_stage_valid_q;

    assign data_out =
       out_stage_data_q;

    assign out_stage_ready =
        ~out_stage_valid_q
      | ready_in;

    assign buffer_output_valid =
      stored_bytes_q >= OUTPUT_BYTE_COUNT;

    assign buffer_output_moving =
        buffer_output_valid
      & out_stage_ready;

    assign out_stage_load =
        buffer_output_moving;

    assign out_stage_valid_in =
         out_stage_load
      | (  out_stage_valid_q 
         & ~ready_in);

    assign out_stage_data_in =
        out_stage_load
      ? barrel_data_out
      : out_stage_data_q;

    assign bytes_dec =
        buffer_output_moving
      ? OUTPUT_BYTE_COUNT
      : '0;

    assign ready_out =
        free_bytes_after_read >= {1'b0, INPUT_BYTE_COUNT};

    assign bytes_inc =
        in_data_moving
      ? INPUT_BYTE_COUNT
      : '0;

    assign wr_lane_in =
        wr_lane_q
      ^ in_data_moving;

    assign unpack_data_in =
        in_data_moving
      ? (  wr_lane_q
        ? {data_in, unpack_data_q[INPUT_DATA_WIDTH-1:0]}
        : {unpack_data_q[2*INPUT_DATA_WIDTH-1:INPUT_DATA_WIDTH], data_in})
      : unpack_data_q;

    assign rd_ptr_sum =
        {1'b0, rd_ptr_q}
      + {1'b0, OUTPUT_POINTER_STEP};

    assign rd_ptr_wrap =
        rd_ptr_sum
      - BUFFER_POINTER_LIMIT;

    assign rd_ptr_in =
        buffer_output_moving
      ? (( rd_ptr_sum >= BUFFER_POINTER_LIMIT)
         ? rd_ptr_wrap[BUFFER_POINTER_WIDTH-1:0]
         : rd_ptr_sum[BUFFER_POINTER_WIDTH-1:0])
      : rd_ptr_q;

    for(genvar out_byte_i = 0; out_byte_i < OUTPUT_BYTES_PER_BEAT; out_byte_i = out_byte_i + 1) begin : g_barrel_out_byte

      localparam logic [BUFFER_POINTER_WIDTH:0] OUT_BYTE_OFFSET = out_byte_i;

      logic [BUFFER_POINTER_WIDTH:0] read_byte_sum;
      logic [BUFFER_POINTER_WIDTH:0] read_byte_wrap;
      logic [BUFFER_POINTER_WIDTH-1:0] read_byte_ptr;

      logic [BUFFER_CAPACITY_BYTES-1:0] buffer_byte_sel;
      logic [BUFFER_CAPACITY_BYTES-1:0] buffer_bit_sel [BITS_PER_BYTE-1:0];

      assign read_byte_sum =
          {1'b0, rd_ptr_q}
        + OUT_BYTE_OFFSET;

      assign read_byte_wrap =
          read_byte_sum
        - BUFFER_POINTER_LIMIT;

      assign read_byte_ptr =
          (read_byte_sum >= BUFFER_POINTER_LIMIT)
        ? read_byte_wrap[BUFFER_POINTER_WIDTH-1:0]
        : read_byte_sum[BUFFER_POINTER_WIDTH-1:0];

      for(genvar buf_byte_i = 0; buf_byte_i < BUFFER_CAPACITY_BYTES; buf_byte_i = buf_byte_i + 1) begin : g_buffer_byte

        localparam logic [BUFFER_POINTER_WIDTH-1:0] BUFFER_BYTE_PTR = buf_byte_i;

        assign buffer_byte_sel[buf_byte_i] =
          read_byte_ptr == BUFFER_BYTE_PTR;

        for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_buffer_bit
          assign buffer_bit_sel[bit_i][buf_byte_i] =
              buffer_byte_sel[buf_byte_i]
            & unpack_data_q[BITS_PER_BYTE*buf_byte_i + bit_i];
        end

      end

      for(genvar bit_i = 0; bit_i < BITS_PER_BYTE; bit_i = bit_i + 1) begin : g_barrel_out_bit
        assign barrel_data_out[BITS_PER_BYTE*out_byte_i + bit_i] =
            |buffer_bit_sel[bit_i];
      end

    end

    always_ff @(posedge clk or negedge rstn) begin
      if(~rstn) begin
        unpack_data_q     <= '0;
        wr_lane_q         <= '0;
        rd_ptr_q          <= '0;
        out_stage_valid_q <= '0;
        out_stage_data_q  <= '0;
      end
      else begin
        unpack_data_q     <= unpack_data_in;
        wr_lane_q         <= wr_lane_in;
        rd_ptr_q          <= rd_ptr_in;
        out_stage_valid_q <= out_stage_valid_in;
        out_stage_data_q  <= out_stage_data_in;
      end
    end

  end
  else begin : g_equal_width

    always_ff@(posedge clk or negedge rstn) begin
      if(~rstn) 
         valid_out <= 1'b0;
      else
         valid_out <=   valid_in 
                     | (valid_out & ~ready_in); 
    end

    always_ff@(posedge clk) begin
      if(in_data_moving)
         data_out <= data_in;
    end

    assign ready_out = 
             ready_in
          | ~valid_out;
      
    assign bytes_inc = '0;
    assign bytes_dec = '0;

  end

`ifndef SYNTHESIS
  assert_stored_byte_count_in_range:
    assert property (@(posedge clk) disable iff (~rstn)
      stored_bytes_q <= BUFFER_BYTE_COUNT)
    else $error("gearbox stored byte count exceeded buffer capacity");

  assert_no_byte_count_underflow:
    assert property (@(posedge clk) disable iff (~rstn)
      {1'b0, bytes_dec} <= {1'b0, stored_bytes_q})
    else $error("gearbox attempted to remove more bytes than stored");

  assert_next_byte_count_in_range:
    assert property (@(posedge clk) disable iff (~rstn)
      stored_bytes_calc <= {1'b0, BUFFER_BYTE_COUNT})
    else $error("gearbox next stored byte count exceeded buffer capacity");

  assert_valid_out_known:
    assert property (@(posedge clk) disable iff (~rstn)
      !$isunknown(valid_out))
    else $error("gearbox valid_out is unknown");

  assert_data_out_known_when_valid:
    assert property (@(posedge clk) disable iff (~rstn)
      valid_out |-> !$isunknown(data_out))
    else $error("gearbox data_out is unknown while valid_out is high");
`endif

endmodule
