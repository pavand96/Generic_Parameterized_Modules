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
- `CHUNK_WIDTH` - number of bits in each chunk.

Both parameters must be greater than zero. Data widths are derived as
`IN_DATA_WIDTH = CHUNK_WIDTH * IN_CHUNKS_PER_BEAT` and
`OUT_DATA_WIDTH = CHUNK_WIDTH * OUT_CHUNKS_PER_BEAT`.

## Datapath Context

The gearbox uses a chunk-granular datapath.

When `IN_CHUNKS_PER_BEAT < OUT_CHUNKS_PER_BEAT`, the gearbox packs multiple narrower in beats into one
wider output beat. Exact ratios use fixed lanes and one output beat of storage.
Non-exact ratios use a write barrel because each incoming beat can land at a
different chunk offset inside the output-sized buffer.

When `IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT`, the gearbox unpacks one wider in beat into multiple
narrower output beats. Exact ratios use a fixed-width shift path and one in
beat of storage. Non-exact ratios use a read barrel as they select each
successive `OUT_CHUNKS_PER_BEAT` slice.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom chunks per beat:

```sh
make IN_CHUNKS_PER_BEAT=3 OUT_CHUNKS_PER_BEAT=5 CHUNK_WIDTH=8
```

Disable waveform tracing:

```sh
make WAVES=0
```

## Check Lint

Run Verilator in lint-only mode with assertions enabled:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GIN_CHUNKS_PER_BEAT=3 -GOUT_CHUNKS_PER_BEAT=5 -GCHUNK_WIDTH=8 gearbox.sv
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
./run_random_params.py -n 50 --min-chunks-per-beat 1 --max-chunks-per-beat 16 --chunk-width 8 --keep-going --waves 0
```

Use a fixed seed to reproduce a failing run:

```sh
./run_random_params.py --seed 1234
```

## Clean

```sh
make clean
```
