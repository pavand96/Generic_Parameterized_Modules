# RTL And Simulation Style Context

This note captures the preferred coding, naming, lint, and cocotb simulation
style for modules in this repository. Keep it as reusable project guidance,
not as a changelog for one module.

## RTL Naming Style

Use descriptive names that state what a signal represents. Avoid short
abbreviations unless they are established HDL conventions.

Preferred:

- `input_stream_valid`, `input_stream_data`, `input_stream_ready`
- `output_stream_valid`, `output_stream_data`, `output_stream_ready`
- `INPUT_BYTES_PER_BEAT`, `OUTPUT_BYTES_PER_BEAT`
- `INPUT_DATA_WIDTH`, `OUTPUT_DATA_WIDTH`
- `BUFFER_CAPACITY_BYTES`, `BUFFER_POINTER_WIDTH`, `BUFFER_COUNT_WIDTH`
- `stored_byte_count_q`, `stored_byte_count_next`
- `bytes_added`, `bytes_removed`
- `read_byte_pointer_q`, `write_byte_pointer_q`

Avoid:

- unclear width names like `IN_DW`, `OUT_DW`, `CNT_W`, `PTR_W`
- unclear byte-count names like `IN_DB`, `OUT_DB`, `BUF_DB`
- vague temporary names like `candidate_hit`, `candidate_bit`
- directionally confusing stream names such as `ready_out` for input-side ready

Use `_q` for registered state and `_next` for next-state combinational values.
Use active-low reset name `rstn`.

## Constants And Parameters

Prefer named constants over raw literals when the literal has semantic meaning.

Examples:

- `BITS_PER_BYTE = 8`
- `BYTE_MASK = 0xFF` in Python testbenches
- `BUFFER_CAPACITY_BYTES = 2 * MAX_TRANSFER_BYTES`

Parameter names should describe units. Prefer `*_BYTES_PER_BEAT`,
`*_DATA_WIDTH`, and `*_COUNT` over abbreviated suffixes.

## Interface Style

For ready/valid streams, name signals by stream side:

```systemverilog
input  logic                  input_stream_valid,
input  logic [DATA_WIDTH-1:0] input_stream_data,
output logic                  input_stream_ready,

input  logic                  output_stream_ready,
output logic [DATA_WIDTH-1:0] output_stream_data,
output logic                  output_stream_valid
```

This makes it clear that `input_stream_ready` is the module's readiness to
accept input, while `output_stream_ready` comes from the downstream consumer.

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
assert_output_stream_valid_known:
  assert property (@(posedge clk) disable iff (~rstn)
    !$isunknown(output_stream_valid))
  else $error("module output_stream_valid is unknown");
```

Useful assertion categories:

- counter range checks
- underflow and overflow checks
- known-value checks on valid/control signals
- data known when valid is high

Enable assertions in Verilator simulations with `--assert`.

## Verilator Lint

Run lint from the module directory. Use the same parameters and warning options
as the simulation Makefile.

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GINPUT_BYTES_PER_BEAT=3 -GOUTPUT_BYTES_PER_BEAT=5 gearbox.sv
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

Drive `valid` and `ready` independently with seeded randomness. Hold an input
beat stable until the input handshake completes.

Pattern:

```python
if not held_valid and sent_beats < input_beats:
    held_valid = rng.random() < valid_probability
    if held_valid:
        held_bytes = input_bytes_for_beat(sent_beats, input_bytes_per_beat)
        held_word = bytes_to_word(held_bytes)

dut.input_stream_valid.value = int(held_valid)
dut.input_stream_data.value = held_word if held_valid else 0

draining = sent_beats >= input_beats and not held_valid
ready_probability_now = 1.0 if draining else ready_probability
dut.output_stream_ready.value = int(rng.random() < ready_probability_now)
```

After a short timer delay, sample ready/valid and update the scoreboard only on
handshakes:

```python
input_handshake = held_valid and input_stream_ready
output_handshake = output_stream_valid and output_stream_ready
```

When draining after all inputs are sent, force output ready high so the test can
complete deterministically.

## Scoreboard Style

Use a byte queue as the reference model for stream ordering.

- Push expected bytes into a `deque` on input handshake.
- Pop `output_bytes_per_beat` bytes on output handshake.
- Compare output bytes exactly.
- Assert the queue is empty at the end of the test.
- After drain, hold output ready high for a few cycles and check valid drops.

This keeps the test independent of the internal implementation.

## Randomized Parameter Regression

Use a small Python runner to exercise multiple parameter combinations by calling
`make` with generated parameter values.

Recommended options:

- `--iterations`
- `--seed`
- `--min-bytes-per-beat`
- `--max-bytes-per-beat`
- `--keep-going`
- `--waves`

Always print the seed so a failing random run can be reproduced.

Useful smoke command:

```sh
./run_random_params.py -n 1 --min-bytes-per-beat 1 --max-bytes-per-beat 4 --waves 0
```

Useful broader regression:

```sh
./run_random_params.py -n 50 --min-bytes-per-beat 1 --max-bytes-per-beat 16 --keep-going --waves 0
```

## Standard Verification Flow

Before committing RTL or testbench changes, run:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GINPUT_BYTES_PER_BEAT=3 -GOUTPUT_BYTES_PER_BEAT=5 gearbox.sv
make WAVES=0
./run_random_params.py -n 1 --min-bytes-per-beat 1 --max-bytes-per-beat 4 --waves 0
```

Generated simulation artifacts such as `sim_build/`, `results.xml`, and
`__pycache__/` should stay untracked.
