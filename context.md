# RTL And Simulation Style Context

This note captures the preferred coding, naming, lint, and cocotb simulation
style for modules in this repository. Keep it as reusable project guidance,
not as a changelog for one module.

## RTL Naming Style

Use descriptive names that state what a signal represents. The gearbox RTL uses
short project-standard abbreviations for common handshake and pointer terms.

Preferred:

- `in_strm_vld`, `in_strm_data`, `in_strm_rdy`
- `out_strm_vld`, `out_strm_data`, `out_strm_rdy`
- `IN_DATA_WIDTH`, `OUT_DATA_WIDTH`
- `IN_CHUNKS_PER_BEAT`, `OUT_CHUNKS_PER_BEAT`
- `BUFFER_CAPACITY_CHUNKS`, `BUFFER_PTR_WIDTH`, `BUFFER_COUNT_WIDTH`
- `stored_chunk_count_q`, `stored_chunk_count_next`
- `chunks_added`, `chunks_removed`
- `read_chunk_ptr_q`, `write_chunk_ptr_q`
- `in_strm_tfer`, `out_strm_tfer`

Avoid:

- unclear width names like `IN_DW`, `OUT_DW`, `CNT_W`, `PTR_W`
- unclear chunk-count names like `IN_DB`, `OUT_DB`, `BUF_DB`
- vague temporary names like `candidate_hit`, `candidate_bit`
- directionally confusing stream names such as `ready_out` for input-side rdy
- spelling out `pointer`, `transfer`, `valid`, `ready`, `stream`, `input`, or
  `output` inside gearbox RTL signal names; use `ptr`, `tfer`, `vld`, `rdy`,
  `strm`, `in`, and `out`

Use `_q` for registered state and `_next` for next-state combinational values.
Use active-low reset name `rstn`.

## Constants And Parameters

Prefer named constants over raw literals when the literal has semantic meaning.

Examples:

- `CHUNK_WIDTH`
- `CHUNK_MASK` in Python testbenches
- `BUFFER_CAPACITY_CHUNKS = 2 * MAX_TFER_CHUNKS`

Parameter names should describe units. Prefer `*_CHUNKS_PER_BEAT`,
`*_DATA_WIDTH`, and `*_COUNT` over abbreviated suffixes.

## Packed Array Style

For generated RTL vectors, prefer packed multidimensional arrays instead of
unpacked arrays of packed vectors. Packed arrays flatten predictably, work well
with slices, and keep generated datapath wiring easier for tools to optimize.

Preferred:

```systemverilog
logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;
logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;
```

Avoid:

```systemverilog
logic [BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh [OUT_CHUNKS_PER_BEAT];
logic [BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh [IN_CHUNKS_PER_BEAT];
```

Use normal generated indexing such as `out_chunk_rd_src_oh[out_chunk_i]` after
declaring the array in packed form.

## Interface Style

For ready/valid streams, name signals by stream side:

```systemverilog
input  logic                  in_strm_vld,
input  logic [DATA_WIDTH-1:0] in_strm_data,
output logic                  in_strm_rdy,

input  logic                  out_strm_rdy,
output logic [DATA_WIDTH-1:0] out_strm_data,
output logic                  out_strm_vld
```

This makes it clear that `in_strm_rdy` is the module's readiness to accept
input, while `out_strm_rdy` comes from the downstream consumer.

## Assertion Style

Put module-level assertions near the end of the RTL, just before `endmodule`,
inside:

```systemverilog
`ifndef SYNTHESIS
  // assertions
`endif
```

Use labeled concurrent assertions:

```systemverilog
assert_out_strm_vld_known:
  assert property (@(posedge clk) disable iff (~rstn)
    !$isunknown(out_strm_vld))
  else $error("module out_strm_vld is unknown");
```

Useful assertion categories:

- counter range checks
- underflow and overflow checks
- known-value checks on vld/control signals
- data known when vld is high

Enable assertions in Verilator simulations with `--assert`.

## Verilator Lint

Run lint from the module directory. Use the same parameters and warning options
as the simulation Makefile.

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GIN_DATA_WIDTH=24 -GOUT_DATA_WIDTH=40 ../common/common_pkg.sv gearbox.sv
```

Keep the lint command documented in the module README. If more modules are
added, each module README should include its own lint command.

## cocotb Testbench Style

Keep testbench helper names descriptive:

- `signal_byte_width`
- `bytes_to_word`
- `word_to_bytes`
- `signal_to_int`
- `aligned_input_beats`
- `input_bytes_for_beat`
- `chunk_bits`
- `in_chunks_per_beat`
- `out_chunks_per_beat`

Use named constants in the testbench:

```python
CLK_PERIOD_NS = 1
BITS_PER_BYTE = 8
BYTE_MASK = 0xFF
```

Convert unresolved HDL values into assertion failures with a helper:

```python
def signal_to_int(signal, name):
    try:
        return int(signal.value)
    except ValueError as exc:
        raise AssertionError(f"{name} has unresolved bits: {signal.value}") from exc
```

## Random Backpressure Pattern

Drive `vld` and `rdy` independently with seeded randomness. Hold an input
beat stable until the input handshake completes.

Pattern:

```python
if not held_valid and sent_beats < input_beats:
    held_valid = rng.random() < valid_probability
    if held_valid:
        held_bytes = input_bytes_for_beat(sent_beats, input_bytes_per_beat)
        held_word = bytes_to_word(held_bytes)

dut.in_strm_vld.value = int(held_valid)
dut.in_strm_data.value = held_word if held_valid else 0

draining = sent_beats >= input_beats and not held_valid
ready_probability_now = 1.0 if draining else ready_probability
dut.out_strm_rdy.value = int(rng.random() < ready_probability_now)
```

After a short timer delay, sample rdy/vld and update the scoreboard only on
handshakes:

```python
input_handshake = held_valid and in_strm_rdy
output_handshake = out_strm_vld and out_strm_rdy
```

When draining after all inputs are sent, force output rdy high so the test can
complete deterministically.

## Scoreboard Style

Use a byte or chunk queue as the reference model for stream ordering. For
gearbox, derive `CHUNK_WIDTH` in the test from the GCD of the two signal widths
and compare data at chunk granularity when exercising non-byte chunk widths.

- Push expected chunks into a `deque` on input handshake.
- Pop `out_chunks_per_beat` chunks on output handshake.
- Compare output chunks exactly.
- Assert the queue is empty at the end of the test.
- After drain, hold output rdy high for a few cycles and check vld drops.

This keeps the test independent of the internal implementation.

## Randomized Parameter Regression

Use a small Python runner to exercise multiple parameter combinations by calling
`make` with generated parameter values.

Recommended options:

- `--iterations`
- `--seed`
- `--min-chunks-per-beat`
- `--max-chunks-per-beat`
- `--keep-going`
- `--waves`

Always print the seed so a failing random run can be reproduced.

Useful smoke command:

```sh
./run_random_params.py -n 1 --min-chunks-per-beat 1 --max-chunks-per-beat 4 --waves 0
```

Useful broader regression:

```sh
./run_random_params.py -n 50 --min-chunks-per-beat 1 --max-chunks-per-beat 16 --keep-going --waves 0
```

## Gearbox Area Notes

The gearbox has two datapath families:

- Integer-ratio conversions avoid the circular barrel path. `IN < OUT` fills
  fixed pack lanes; `IN > OUT` shifts a fixed unpack word by one output beat.
  These cases do not need the non-integer barrel buffer or `2 * MAX_TFER_CHUNKS`
  storage.
- Non-integer-ratio conversions use a circular chunk buffer because successive
  beats can land on different chunk offsets.

Current area-oriented choices:

- `CHUNK_WIDTH` is derived from the GCD of `IN_DATA_WIDTH` and
  `OUT_DATA_WIDTH`; a very small `CHUNK_WIDTH` creates many chunks and can grow
  mux/barrel area quickly. For small chunks or wide ratios, prefer an FSM-style
  gearbox that moves fewer chunks per cycle over a smaller datapath.
- Occupancy ready logic avoids computing
  `BUFFER_CAPACITY_CHUNKS - stored_chunk_count_q + chunks_removed` in the ready
  path. Pack uses one threshold compare plus the output-tfer bypass; unpack
  muxes the threshold and uses one compare.
- Non-integer pack barrel writes use a one-hot write ptr. Destination ptrs are
  constant rotations of that one-hot vector, so write destination generation is
  wiring instead of add/subtract/compare logic. Buffer data is written with
  chunk-wise flops gated by `chunk_wr_en`; the write path does not instantiate
  `common_chunk_mux`.
- Non-integer unpack barrel reads use a one-hot read ptr. Source ptrs are
  constant rotations of that one-hot vector, so read source generation is wiring
  instead of add/subtract/compare logic. Selected output data is built with a
  one-hot gated OR; the read path does not instantiate `common_chunk_mux`.
- `common_chunk_mux` is a recursive tree. One-hot mode OR-reduces selected
  chunks. Indexed mode splits on power-of-two boundaries so the right subtree
  select uses lower index bits, avoiding per-level subtract-by-constant and
  range comparator logic.
- Data flops are not reset; only control state is reset. Datapath flops should
  use clock-enable style updates so they only clock on real data movement:
  input load, output stage load, chunk write, or unpack shift. Avoid assigning a
  held `_next` value to wide data flops every cycle.

## Standard Verification Flow

Before committing RTL or testbench changes, run:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GIN_DATA_WIDTH=24 -GOUT_DATA_WIDTH=40 ../common/common_pkg.sv gearbox.sv
make IN_DATA_WIDTH=24 OUT_DATA_WIDTH=40 WAVES=0
./run_random_params.py -n 1 --min-chunks-per-beat 1 --max-chunks-per-beat 4 --waves 0
```

Generated simulation artifacts such as `sim_build/`, `results.xml`, and
`__pycache__/` should stay untracked.
