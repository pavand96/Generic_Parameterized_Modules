# Generic Parameterized Gearbox

SystemVerilog byte-stream gearbox with a cocotb regression testbench. The
module converts an input stream with `INPUT_BYTES_PER_BEAT` bytes per beat into an output stream
with `OUTPUT_BYTES_PER_BEAT` bytes per beat while preserving byte order and supporting
ready/valid backpressure.

## Files

- `gearbox.sv` - parameterized SystemVerilog gearbox RTL.
- `testbench.py` - cocotb byte-stream regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized regression runner for multiple
  `INPUT_BYTES_PER_BEAT`/`OUTPUT_BYTES_PER_BEAT` parameter pairs.
- `wavedrom.md` - sample ready/valid and backpressure waveforms.

## Parameters

- `INPUT_BYTES_PER_BEAT` - number of input bytes per transfer beat.
- `OUTPUT_BYTES_PER_BEAT` - number of output bytes per transfer beat.

Both parameters must be greater than zero. Data widths are derived as
`INPUT_DATA_WIDTH = BITS_PER_BYTE * INPUT_BYTES_PER_BEAT` and
`OUTPUT_DATA_WIDTH = BITS_PER_BYTE * OUTPUT_BYTES_PER_BEAT`.

## Datapath Context

The gearbox uses a byte-granular datapath. In the notes below,
`IN_DB` refers to `INPUT_BYTES_PER_BEAT` and `OUT_DB` refers to
`OUTPUT_BYTES_PER_BEAT`.

When `IN_DB < OUT_DB`, the gearbox packs multiple narrower input beats into one
wider output beat. The write side has variable byte alignment because each
incoming beat can land at a different byte offset inside the output-sized
buffer. The read side is fixed because the output always selects one aligned
`OUT_DB` lane. This shape needs one write barrel to steer input bytes into the
correct buffer lanes.

When `IN_DB > OUT_DB`, the gearbox unpacks one wider input beat into multiple
narrower output beats. The write side stores the input beat at a fixed aligned
location, while the read side has variable byte alignment as it selects each
successive `OUT_DB` slice. This shape needs one read barrel to steer the
selected byte lanes to the output.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom byte widths:

```sh
make INPUT_BYTES_PER_BEAT=3 OUTPUT_BYTES_PER_BEAT=5
```

Disable waveform tracing:

```sh
make WAVES=0
```

## Check Lint

Run Verilator in lint-only mode with assertions enabled:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GINPUT_BYTES_PER_BEAT=3 -GOUTPUT_BYTES_PER_BEAT=5 gearbox.sv
```

## Waveform Examples

See [`wavedrom.md`](wavedrom.md) for sample WaveDrom timing diagrams covering
input handshakes, output backpressure, packing behavior, and randomized
backpressure.

## Randomized Regression

Run randomized parameter combinations:

```sh
./run_random_params.py
```

Useful options:

```sh
./run_random_params.py -n 50 --min-bytes-per-beat 1 --max-bytes-per-beat 16 --keep-going --waves 0
```

Use a fixed seed to reproduce a failing run:

```sh
./run_random_params.py --seed 1234
```

## Clean

```sh
make clean
```
