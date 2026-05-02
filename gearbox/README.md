# Generic Parameterized Gearbox

SystemVerilog chunk-stream gearbox with a cocotb regression testbench. The
module converts an input stream with `INPUT_CHUNKS_PER_BEAT` chunks per beat into an output stream
with `OUTPUT_CHUNKS_PER_BEAT` chunks per beat while preserving chunk order and supporting
ready/valid backpressure.

## Files

- `gearbox.sv` - parameterized SystemVerilog gearbox RTL.
- `testbench.py` - cocotb chunk-stream regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized regression runner for multiple
  `INPUT_CHUNKS_PER_BEAT`/`OUTPUT_CHUNKS_PER_BEAT` parameter pairs.
- `wavedrom.md` - sample ready/valid and backpressure waveforms.

## Parameters

- `INPUT_CHUNKS_PER_BEAT` - number of input chunks per transfer beat.
- `OUTPUT_CHUNKS_PER_BEAT` - number of output chunks per transfer beat.
- `BITS_PER_CHUNK` - number of bits in each chunk.

Both parameters must be greater than zero. Data widths are derived as
`INPUT_DATA_WIDTH = BITS_PER_CHUNK * INPUT_CHUNKS_PER_BEAT` and
`OUTPUT_DATA_WIDTH = BITS_PER_CHUNK * OUTPUT_CHUNKS_PER_BEAT`.

## Datapath Context

The gearbox uses a chunk-granular datapath.

When `INPUT_CHUNKS_PER_BEAT < OUTPUT_CHUNKS_PER_BEAT`, the gearbox packs multiple narrower input beats into one
wider output beat. The write side has variable chunk alignment because each
incoming beat can land at a different chunk offset inside the output-sized
buffer. The read side is fixed because the output always selects one aligned
`OUTPUT_CHUNKS_PER_BEAT` lane. This shape needs one write barrel to steer input chunks into the
correct buffer lanes.

When `INPUT_CHUNKS_PER_BEAT > OUTPUT_CHUNKS_PER_BEAT`, the gearbox unpacks one wider input beat into multiple
narrower output beats. The write side stores the input beat at a fixed aligned
location, while the read side has variable chunk alignment as it selects each
successive `OUTPUT_CHUNKS_PER_BEAT` slice. This shape needs one read barrel to steer the
selected chunk lanes to the output.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom chunks per beat:

```sh
make INPUT_CHUNKS_PER_BEAT=3 OUTPUT_CHUNKS_PER_BEAT=5 BITS_PER_CHUNK=8
```

Disable waveform tracing:

```sh
make WAVES=0
```

## Check Lint

Run Verilator in lint-only mode with assertions enabled:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GINPUT_CHUNKS_PER_BEAT=3 -GOUTPUT_CHUNKS_PER_BEAT=5 -GBITS_PER_CHUNK=8 gearbox.sv
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
./run_random_params.py -n 50 --min-chunks-per-beat 1 --max-chunks-per-beat 16 --bits-per-chunk 8 --keep-going --waves 0
```

Use a fixed seed to reproduce a failing run:

```sh
./run_random_params.py --seed 1234
```

## Clean

```sh
make clean
```
