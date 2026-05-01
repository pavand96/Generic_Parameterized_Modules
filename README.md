# Generic Parameterized Modules

Reusable parameterized hardware modules with simulation collateral and
regression tests.

## Modules

### Gearbox

The `gearbox` module converts a ready/valid byte stream from `IN_DB` input bytes
per beat to `OUT_DB` output bytes per beat while preserving byte order.

Files are in [`gearbox/`](gearbox/):

- `gearbox.sv` - parameterized SystemVerilog RTL.
- `testbench.py` - cocotb regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized parameter regression runner.
- `README.md` - module-specific setup and run instructions.

## Quick Start

```sh
cd gearbox
make
```

Run randomized gearbox parameter regressions:

```sh
cd gearbox
./run_random_params.py
```

See [`gearbox/README.md`](gearbox/README.md) for dependency installation,
simulation options, and parameter details.
