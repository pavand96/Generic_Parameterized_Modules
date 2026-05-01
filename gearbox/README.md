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

## Parameters

- `INPUT_BYTES_PER_BEAT` - number of input bytes per transfer beat.
- `OUTPUT_BYTES_PER_BEAT` - number of output bytes per transfer beat.

Both parameters must be greater than zero. Data widths are derived as
`INPUT_DATA_WIDTH = BITS_PER_BYTE * INPUT_BYTES_PER_BEAT` and
`OUTPUT_DATA_WIDTH = BITS_PER_BYTE * OUTPUT_BYTES_PER_BEAT`.

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
