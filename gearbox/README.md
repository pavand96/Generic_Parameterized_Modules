# Generic Parameterized Gearbox

SystemVerilog chunk-strm gearbox with a cocotb regression testbench. The
module converts an in strm with `IN_CHUNKS_PER_BEAT` chunks per beat into an output strm
with `OUT_CHUNKS_PER_BEAT` chunks per beat while preserving chunk order and supporting
rdy/vld backpressure.

## Files

- `gearbox.sv` - parameterized SystemVerilog gearbox RTL.
- `testbench.py` - cocotb chunk-strm regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized regression runner for multiple
  `IN_CHUNKS_PER_BEAT`/`OUT_CHUNKS_PER_BEAT` parameter pairs.
- `wavedrom.md` - sample rdy/vld and backpressure waveforms.

## Parameters

- `IN_CHUNKS_PER_BEAT` - number of in chunks per transfer beat.
- `OUT_CHUNKS_PER_BEAT` - number of output chunks per transfer beat.
- `BITS_PER_CHUNK` - number of bits in each chunk.

Both parameters must be greater than zero. Data widths are derived as
`IN_DATA_WIDTH = BITS_PER_CHUNK * IN_CHUNKS_PER_BEAT` and
`OUT_DATA_WIDTH = BITS_PER_CHUNK * OUT_CHUNKS_PER_BEAT`.

## Datapath Context

The gearbox uses a chunk-granular datapath.

When `IN_CHUNKS_PER_BEAT < OUT_CHUNKS_PER_BEAT`, the gearbox packs multiple narrower in beats into one
wider output beat. The write side has variable chunk alignment because each
incoming beat can land at a different chunk offset inside the output-sized
buffer. The read side is fixed because the output always selects one aligned
`OUT_CHUNKS_PER_BEAT` lane. This shape needs one write barrel to steer in chunks into the
correct buffer lanes.

When `IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT`, the gearbox unpacks one wider in beat into multiple
narrower output beats. The write side stores the in beat at a fixed aligned
location, while the read side has variable chunk alignment as it selects each
successive `OUT_CHUNKS_PER_BEAT` slice. This shape needs one read barrel to steer the
selected chunk lanes to the output.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom chunks per beat:

```sh
make IN_CHUNKS_PER_BEAT=3 OUT_CHUNKS_PER_BEAT=5 BITS_PER_CHUNK=8
```

Disable waveform tracing:

```sh
make WAVES=0
```

## Check Lint

Run Verilator in lint-only mode with assertions enabled:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GIN_CHUNKS_PER_BEAT=3 -GOUT_CHUNKS_PER_BEAT=5 -GBITS_PER_CHUNK=8 gearbox.sv
```

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
