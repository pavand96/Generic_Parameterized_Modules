# Generic Parameterized Modules

Reusable parameterized hardware modules with simulation collateral and
regression tests.

## Modules

- [`gearbox/`](gearbox/) - see [`gearbox/README.md`](gearbox/README.md) for
  module-specific setup, simulation options, and parameter details.

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

## VS Code Surfer Extension

Surfer is also available as a VS Code extension. Install the extension named
`surfer` from publisher `surfer-project` in the VS Code Extensions view.

You can also install it from the command line:

```sh
code --install-extension surfer-project.surfer
```

After installation, open a generated `.vcd`, `.fst`, or `.ghw` file in VS Code
to view the waveform with Surfer.

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

See each module README for simulation options and parameter details.
