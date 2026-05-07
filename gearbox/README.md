# Generic Parameterized Gearbox

SystemVerilog chunk-stream gearbox with a cocotb regression testbench. The
module converts an in stream with `IN_DATA_WIDTH` bits per beat into an output
stream with `OUT_DATA_WIDTH` bits per beat while preserving chunk order and
supporting rdy/vld backpressure.

## Files

- `gearbox.sv` - parameterized SystemVerilog gearbox RTL.
- `../common/common_pkg.sv` - shared SystemVerilog package with math helpers.
- `testbench.py` - cocotb chunk-stream regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized regression runner for multiple
  `IN_DATA_WIDTH`/`OUT_DATA_WIDTH` parameter pairs.
- `run_synth.py` - standalone Yosys synthesis runner for SKY130 HD mapping.
- `wavedrom.md` - sample rdy/vld and backpressure waveforms.

## Parameters

- `IN_DATA_WIDTH` - number of bits in each in transfer beat.
- `OUT_DATA_WIDTH` - number of bits in each output transfer beat.

Both parameters must be greater than zero. The RTL derives chunk shape from
the greatest common divisor of the two data widths:

- `CHUNK_WIDTH = gcd(IN_DATA_WIDTH, OUT_DATA_WIDTH)`
- `IN_CHUNKS_PER_BEAT = IN_DATA_WIDTH / CHUNK_WIDTH`
- `OUT_CHUNKS_PER_BEAT = OUT_DATA_WIDTH / CHUNK_WIDTH`

The GCD helper lives in `common_pkg` as `greatest_common_divisor`.

## Datapath Context

The gearbox uses a chunk-granular datapath.

The RTL selects one of three datapath shapes at elaboration time:

- Equal width (`IN_CHUNKS_PER_BEAT == OUT_CHUNKS_PER_BEAT`) uses a simple
  one-beat rdy/vld skid stage.
- Integer-ratio width conversion uses exact pack/unpack logic and avoids the
  circular barrel datapath.
- Non-integer-ratio width conversion uses the circular barrel datapath because
  output beat boundaries walk across the stored chunks.

When `IN_CHUNKS_PER_BEAT < OUT_CHUNKS_PER_BEAT`, the gearbox packs multiple narrower in beats into one
wider output beat. Integer ratios use fixed lanes and one output beat of
storage. Non-integer ratios use a write barrel because each incoming beat can
land at a different chunk offset inside the output-sized buffer.

When `IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT`, the gearbox unpacks one wider in beat into multiple
narrower output beats. Integer ratios use a fixed-width shift path and one in
beat of storage. Non-integer ratios use a read barrel as they select each
successive `OUT_CHUNKS_PER_BEAT` slice.

For integer-ratio conversions, `BUFFER_CAPACITY_CHUNKS` collapses to
`MAX_TFER_CHUNKS`, so the design does not allocate the `2 * MAX_TFER_CHUNKS`
barrel buffer. The larger buffer is only used when `NON_INTEGER_RATIO` is true,
which also requires `IN_CHUNKS_PER_BEAT != OUT_CHUNKS_PER_BEAT`.

## Area Warning

Small derived `CHUNK_WIDTH` values can make `IN_CHUNKS_PER_BEAT` and
`OUT_CHUNKS_PER_BEAT` large. That matters most in non-integer-ratio cases,
where this implementation keeps enough storage for `2 * MAX_TFER_CHUNKS` and
uses combinational barrel logic to route chunks between arbitrary offsets.

The barrel implementation is good when the design needs beat-level throughput:
it can accept or produce a full strm beat whenever rdy/vld allows. The cost is
that muxing and decode grow with the number of chunk lanes. If the GCD-derived
`CHUNK_WIDTH` is small, a wide datapath can turn into many lanes, and each lane
adds mux inputs, compare/decode logic, and buffer flops.

An FSM-style gearbox can reduce area when `IN_DATA_WIDTH` and
`OUT_DATA_WIDTH` are co-prime, or when their GCD is otherwise small. Instead
of building a full chunk-lane barrel path, an FSM can reuse a narrow shifter,
small counter, and a smaller staging register across multiple cycles. That
trades peak throughput and latency for less muxing, less decode, and fewer
buffer flops.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom data widths:

```sh
make IN_DATA_WIDTH=24 OUT_DATA_WIDTH=40
```

Disable waveform tracing:

```sh
make WAVES=0
```

## Check Lint

Run Verilator in lint-only mode with assertions enabled:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GIN_DATA_WIDTH=24 -GOUT_DATA_WIDTH=40 ../common/common_pkg.sv gearbox.sv
```

## Run Synthesis

`run_synth.py` runs standalone Yosys and maps the gearbox to a SKY130 HD
Liberty file. The default Liberty location is:

```text
../third_party/sky130_fd_sc_hd/timing/sky130_fd_sc_hd__tt_025C_1v80.lib
```

Run a synthesis check with the default `24 -> 40` conversion:

```sh
./run_synth.py
```

Run a custom conversion:

```sh
./run_synth.py --in-data-width 40 --out-data-width 24
```

The script writes the generated Yosys RTL, Yosys script, mapped netlist, area
report, and `check` report under `synth_build/`. Use `--liberty <path>` if the
SKY130 Liberty lives elsewhere.

## Waveform Examples

See [`wavedrom.md`](wavedrom.md) for sample WaveDrom timing diagrams covering
in handshakes, output backpressure, packing behavior, and randomized
backpressure.

## Randomized Regression

Run randomized parameter combinations:

```sh
./run_random_params.py
```

Useful options:

```sh
./run_random_params.py -n 50 --min-chunks-per-beat 1 --max-chunks-per-beat 16 --chunk-width 8 --keep-going --waves 0
```

The random runner still accepts chunk-count and chunk-width ranges as a
convenient way to generate data widths. The RTL receives only `IN_DATA_WIDTH`
and `OUT_DATA_WIDTH`; its actual chunk width is derived from their GCD.

Use a fixed seed to reproduce a failing run:

```sh
./run_random_params.py --seed 1234
```

## Clean

```sh
make clean
```
