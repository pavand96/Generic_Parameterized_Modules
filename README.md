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

## Install Dependencies

This repository uses cocotb for Python-based HDL testbenches, Verilator as the
default simulator, and Surfer as an optional waveform viewer.

On Ubuntu or Debian, install Verilator and Python tooling:

```sh
sudo apt update
sudo apt install verilator python3 python3-pip make
```

Install cocotb with pip:

```sh
python3 -m pip install cocotb
```

Install Surfer from source with Cargo:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install --git https://gitlab.com/surfer-project/surfer.git surfer
```

On systems with Homebrew, Surfer can also be installed with:

```sh
brew install surfer
```

Check that the tools are available:

```sh
verilator --version
cocotb-config --version
surfer --version
```

After running a simulation with `WAVES=1`, open the generated waveform with:

```sh
surfer gearbox/dump.vcd
```

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

See [`gearbox/README.md`](gearbox/README.md) for simulation options and
parameter details.
