# Project Context

This repository is `pavand96/Generic_Parameterized_Modules`. The current module
in the repo is `gearbox/`, a parameterized SystemVerilog byte-stream gearbox
with cocotb tests.

## Repository Layout

- `README.md` - top-level repository overview, dependency installation, Surfer
  setup, and quick-start commands.
- `gearbox/README.md` - gearbox-specific parameters, simulation, lint, and
  regression commands.
- `gearbox/gearbox.sv` - SystemVerilog RTL.
- `gearbox/testbench.py` - cocotb byte-stream regression testbench.
- `gearbox/Makefile` - cocotb simulation Makefile.
- `gearbox/run_random_params.py` - randomized parameter regression runner.

Generated files are intentionally not tracked:

- `gearbox/sim_build/`
- `gearbox/results.xml`
- `gearbox/__pycache__/`

## Gearbox Interface

The public stream interface uses explicit input/output stream names:

- `input_stream_valid`
- `input_stream_data`
- `input_stream_ready`
- `output_stream_ready`
- `output_stream_data`
- `output_stream_valid`
- `clk`
- `rstn`

The active-low reset name is intentionally `rstn`.

## Parameters And Derived Widths

The public byte-count parameters are:

- `INPUT_BYTES_PER_BEAT`
- `OUTPUT_BYTES_PER_BEAT`

Important derived names in `gearbox.sv`:

- `BITS_PER_BYTE`
- `INPUT_DATA_WIDTH`
- `OUTPUT_DATA_WIDTH`
- `MAX_TRANSFER_BYTES`
- `BUFFER_CAPACITY_BYTES`
- `BUFFER_DATA_WIDTH`
- `BUFFER_POINTER_WIDTH`
- `BUFFER_COUNT_WIDTH`

Older names such as `IN_DB`, `OUT_DB`, `IN_DW`, `OUT_DW`, `CNT_W`, `PTR_W`,
`BUF_DB`, `BUF_DW`, `candidate_hit`, and `candidate_bit` were replaced with
more descriptive names.

## Assertions

Assertions live at the end of `gearbox.sv` and use labeled concurrent
`assert property` statements. They check:

- stored byte count does not exceed buffer capacity
- bytes removed never exceed stored bytes
- next stored byte count stays in range
- `output_stream_valid` is never unknown after reset
- `output_stream_data` is not unknown when `output_stream_valid` is high

Verilator assertions are enabled in `gearbox/Makefile` with `--assert`.

## Verification Commands

Run from `gearbox/`.

Lint:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GINPUT_BYTES_PER_BEAT=3 -GOUTPUT_BYTES_PER_BEAT=5 gearbox.sv
```

Default cocotb regression:

```sh
make WAVES=0
```

Randomized parameter smoke test:

```sh
./run_random_params.py -n 1 --min-bytes-per-beat 1 --max-bytes-per-beat 4 --waves 0
```

Larger randomized regression:

```sh
./run_random_params.py -n 50 --min-bytes-per-beat 1 --max-bytes-per-beat 16 --keep-going --waves 0
```

## Tooling Context

The top-level README documents installation for:

- Verilator
- Python and pip
- cocotb
- Surfer waveform viewer
- Surfer VS Code extension: `surfer-project.surfer`

## Recent Work Summary

Recent commits cleaned up and documented the gearbox module:

- moved project files into `gearbox/`
- added top-level and module READMEs
- moved dependency installation instructions to the top-level README
- added Surfer and VS Code Surfer extension notes
- renamed unclear internal RTL signals
- renamed public parameters to `INPUT_BYTES_PER_BEAT` and
  `OUTPUT_BYTES_PER_BEAT`
- renamed stream ports to explicit `input_stream_*` and `output_stream_*`
- kept reset as `rstn`
- added and expanded assertions
- documented the Verilator lint command

The latest verified state passed Verilator lint, the cocotb regression, and a
one-iteration randomized parameter regression.
