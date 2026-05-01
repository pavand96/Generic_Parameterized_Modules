module gearbox #(
  parameter IN_DB  = 4,
  parameter OUT_DB = 5,

  localparam IN_DW  = 8 * IN_DB,
  localparam OUT_DW = 8 * OUT_DB,

  localparam int MAX_DB = (IN_DB > OUT_DB) ? IN_DB : OUT_DB,
  localparam int BUF_DB = 2 * MAX_DB,
  localparam int BUF_DW = 8 * BUF_DB,

  localparam int PTR_W = $clog2(BUF_DB),
  localparam int CNT_W = $clog2(BUF_DB + 1),

  localparam logic [PTR_W-1:0] IN_DB_PTR  = IN_DB,
  localparam logic [PTR_W-1:0] OUT_DB_PTR = OUT_DB,
  localparam logic [PTR_W:0]   BUF_DB_PTR = BUF_DB,

  localparam logic [CNT_W-1:0] IN_DB_CNT  = IN_DB,
  localparam logic [CNT_W-1:0] OUT_DB_CNT = OUT_DB,
  localparam logic [CNT_W-1:0] BUF_DB_CNT = BUF_DB
)
(
  input valid_in,
  input [IN_DW-1:0] data_in,
  output logic ready_out,

  input ready_in,
  output logic [OUT_DW-1:0] data_out,
  output logic valid_out,

  input clk,
  input rstn
);

  logic in_data_moving;
  logic out_data_moving;

  logic [CNT_W-1:0] stored_bytes_q;
  logic [CNT_W-1:0] stored_bytes_in;

  logic [CNT_W-1:0] bytes_inc;
  logic [CNT_W-1:0] bytes_dec;

  logic [CNT_W:0] stored_bytes_calc;
  logic [CNT_W:0] free_bytes_after_read;

  initial begin
    if(IN_DB == 0)  $error("gearbox requires IN_DB > 0");
    if(OUT_DB == 0) $error("gearbox requires OUT_DB > 0");
  end

  assign in_data_moving =
      valid_in
    & ready_out;

  assign out_data_moving =
      valid_out
    & ready_in;

  assign free_bytes_after_read =
      {1'b0, BUF_DB_CNT}
    - {1'b0, stored_bytes_q}
    + {1'b0, bytes_dec};

  assign stored_bytes_calc =
      {1'b0, stored_bytes_q}
    + {1'b0, bytes_inc}
    - {1'b0, bytes_dec};

  assign stored_bytes_in =
    stored_bytes_calc[CNT_W-1:0];

  always_ff @(posedge clk or negedge rstn) begin
    if(~rstn)
      stored_bytes_q <= '0;
    else
      stored_bytes_q <= stored_bytes_in;
  end

  if(IN_DB < OUT_DB) begin : g_small_to_large

    logic pack_data_valid_q;
    logic pack_data_valid_in;

    logic packrot_has_space;
    logic pack_data_moving;

    logic [IN_DW-1:0] pack_data_q;

    logic [BUF_DW-1:0] packrot_data_q;
    logic [BUF_DW-1:0] packrot_data_in;
    logic [BUF_DW-1:0] packrot_write_data;
    logic [BUF_DW-1:0] packrot_write_mask;

    logic [PTR_W-1:0] wr_ptr_q;
    logic [PTR_W-1:0] wr_ptr_in;
    logic [PTR_W:0] wr_ptr_sum;
    logic [PTR_W:0] wr_ptr_wrap;

    logic rd_lane_q;
    logic rd_lane_in;

    assign data_out =
        rd_lane_q
      ? packrot_data_q[2*OUT_DW-1:OUT_DW]
      : packrot_data_q[OUT_DW-1:0];

    assign valid_out =
      stored_bytes_q >= OUT_DB_CNT;

    assign bytes_dec =
        out_data_moving
      ? OUT_DB_CNT
      : '0;

    assign packrot_has_space =
      free_bytes_after_read >= {1'b0, IN_DB_CNT};

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
      ? IN_DB_CNT
      : '0;

    assign wr_ptr_sum =
        {1'b0, wr_ptr_q}
      + {1'b0, IN_DB_PTR};

    assign wr_ptr_wrap =
        wr_ptr_sum
      - BUF_DB_PTR;

    assign wr_ptr_in =
        pack_data_moving
      ? ((wr_ptr_sum >= BUF_DB_PTR)
        ? wr_ptr_wrap[PTR_W-1:0]
        : wr_ptr_sum[PTR_W-1:0])
      : wr_ptr_q;

    assign rd_lane_in =
        rd_lane_q
      ^ out_data_moving;

    for(genvar out_byte_i = 0; out_byte_i < BUF_DB; out_byte_i = out_byte_i + 1) begin : g_packrot_out_byte

      localparam logic [PTR_W-1:0] OUT_BYTE_PTR = out_byte_i;

      logic [IN_DB-1:0] write_byte_sel;
      logic [7:0] [IN_DB-1:0] candidate_bit;

      for(genvar in_byte_i = 0; in_byte_i < IN_DB; in_byte_i = in_byte_i + 1) begin : g_pack_data_in_byte

        localparam logic [PTR_W:0] IN_BYTE_OFFSET = in_byte_i;

        logic [PTR_W:0] write_byte_sum;
        logic [PTR_W:0] write_byte_wrap;
        logic [PTR_W-1:0] write_byte_ptr;

        assign write_byte_sum =
            {1'b0, wr_ptr_q}
          + IN_BYTE_OFFSET;

        assign write_byte_wrap =
            write_byte_sum
          - BUF_DB_PTR;

        assign write_byte_ptr =
            write_byte_sum >= BUF_DB_PTR
          ? write_byte_wrap[PTR_W-1:0]
          : write_byte_sum[PTR_W-1:0];

        assign write_byte_sel[in_byte_i] =
          write_byte_ptr == OUT_BYTE_PTR;

        for(genvar bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin : g_pack_data_bit
          assign candidate_bit[bit_i][in_byte_i] =
              write_byte_sel[in_byte_i]
            & pack_data_q[8*in_byte_i + bit_i];
        end

      end

      for(genvar bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin : g_packrot_bit
        assign packrot_write_data[8*out_byte_i + bit_i] =
          |candidate_bit[bit_i];
      end

      assign packrot_write_mask[8*out_byte_i +: 8] =
        (|write_byte_sel)
        ? 8'hFF
        : 8'h00;

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
  else if(IN_DB > OUT_DB) begin : g_large_to_small

    logic buffer_output_valid;
    logic buffer_output_moving;

    logic out_stage_ready;
    logic out_stage_load;

    logic out_stage_valid_q;
    logic out_stage_valid_in;

    logic [OUT_DW-1:0] out_stage_data_q;
    logic [OUT_DW-1:0] out_stage_data_in;
    logic [OUT_DW-1:0] barrel_data_out;

    logic [BUF_DW-1:0] unpack_data_q;
    logic [BUF_DW-1:0] unpack_data_in;

    logic wr_lane_q;
    logic wr_lane_in;

    logic [PTR_W-1:0] rd_ptr_q;
    logic [PTR_W-1:0] rd_ptr_in;
    logic [PTR_W:0] rd_ptr_sum;
    logic [PTR_W:0] rd_ptr_wrap;

    assign valid_out =
       out_stage_valid_q;

    assign data_out =
       out_stage_data_q;

    assign out_stage_ready =
        ~out_stage_valid_q
      | ready_in;

    assign buffer_output_valid =
      stored_bytes_q >= OUT_DB_CNT;

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
      ? OUT_DB_CNT
      : '0;

    assign ready_out =
      free_bytes_after_read >= {1'b0, IN_DB_CNT};

    assign bytes_inc =
        in_data_moving
      ? IN_DB_CNT
      : '0;

    assign wr_lane_in =
        wr_lane_q
      ^ in_data_moving;

    assign unpack_data_in =
        in_data_moving
      ? (  wr_lane_q
        ? {data_in, unpack_data_q[IN_DW-1:0]}
        : {unpack_data_q[2*IN_DW-1:IN_DW], data_in})
      : unpack_data_q;

    assign rd_ptr_sum =
        {1'b0, rd_ptr_q}
      + {1'b0, OUT_DB_PTR};

    assign rd_ptr_wrap =
        rd_ptr_sum
      - BUF_DB_PTR;

    assign rd_ptr_in =
        buffer_output_moving
      ? (( rd_ptr_sum >= BUF_DB_PTR)
         ? rd_ptr_wrap[PTR_W-1:0]
         : rd_ptr_sum[PTR_W-1:0])
      : rd_ptr_q;

    for(genvar out_byte_i = 0; out_byte_i < OUT_DB; out_byte_i = out_byte_i + 1) begin : g_barrel_out_byte

      localparam logic [PTR_W:0] OUT_BYTE_OFFSET = out_byte_i;

      logic [PTR_W:0] read_byte_sum;
      logic [PTR_W:0] read_byte_wrap;
      logic [PTR_W-1:0] read_byte_ptr;

      logic [BUF_DB-1:0] buffer_byte_sel;
      logic [BUF_DB-1:0] candidate_bit [7:0];

      assign read_byte_sum =
          {1'b0, rd_ptr_q}
        + OUT_BYTE_OFFSET;

      assign read_byte_wrap =
          read_byte_sum
        - BUF_DB_PTR;

      assign read_byte_ptr =
          (read_byte_sum >= BUF_DB_PTR)
        ? read_byte_wrap[PTR_W-1:0]
        : read_byte_sum[PTR_W-1:0];

      for(genvar buf_byte_i = 0; buf_byte_i < BUF_DB; buf_byte_i = buf_byte_i + 1) begin : g_buffer_byte

        localparam logic [PTR_W-1:0] BUFFER_BYTE_PTR = buf_byte_i;

        assign buffer_byte_sel[buf_byte_i] =
          read_byte_ptr == BUFFER_BYTE_PTR;

        for(genvar bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin : g_buffer_bit
          assign candidate_bit[bit_i][buf_byte_i] =
              buffer_byte_sel[buf_byte_i]
            & unpack_data_q[8*buf_byte_i + bit_i];
        end

      end

      for(genvar bit_i = 0; bit_i < 8; bit_i = bit_i + 1) begin : g_barrel_out_bit
        assign barrel_data_out[8*out_byte_i + bit_i] =
            |candidate_bit[bit_i];
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

endmodule
