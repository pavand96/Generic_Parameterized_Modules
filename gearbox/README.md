# Generic Parameterized Gearbox

SystemVerilog byte-stream gearbox with a cocotb regression testbench. The
module converts an input stream with `IN_DB` bytes per beat into an output stream
with `OUT_DB` bytes per beat while preserving byte order and supporting
ready/valid backpressure.

## Files

- `gearbox.sv` - parameterized SystemVerilog gearbox RTL.
- `testbench.py` - cocotb byte-stream regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized regression runner for multiple
  `IN_DB`/`OUT_DB` parameter pairs.

## Parameters

- `IN_DB` - number of input bytes per transfer beat.
- `OUT_DB` - number of output bytes per transfer beat.

Both parameters must be greater than zero. Data widths are derived as
`IN_DW = 8 * IN_DB` and `OUT_DW = 8 * OUT_DB`.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom byte widths:

```sh
make IN_DB=3 OUT_DB=5
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
./run_random_params.py -n 50 --min-db 1 --max-db 16 --keep-going --waves 0
```

Use a fixed seed to reproduce a failing run:

```sh
./run_random_params.py --seed 1234
```

## Clean

```sh
make clean
```
