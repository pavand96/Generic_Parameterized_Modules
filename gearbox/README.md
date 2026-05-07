# Generic Parameterized Gearbox

SystemVerilog chunk-stream gearbox with a cocotb regression testbench. The
module converts an in stream with `IN_DATA_WIDTH` bits per beat into an output
stream with `OUT_DATA_WIDTH` bits per beat while preserving chunk order and
supporting rdy/vld backpressure.

## Files

- `gearbox.sv` - parameterized SystemVerilog gearbox RTL (current one-hot).
- `../common/common_pkg.sv` - shared SystemVerilog package with math helpers.
- `testbench.py` - cocotb chunk-stream regression testbench.
- `Makefile` - cocotb simulation Makefile.
- `run_random_params.py` - randomized regression runner for multiple
  `IN_DATA_WIDTH`/`OUT_DATA_WIDTH` parameter pairs.
- `run_synth.py` - standalone Yosys synthesis runner, area-only, one width pair.
- `run_area_compare.py` - multi-case area sweep comparing adder vs one-hot.
- `run_timing_sweep.py` - frequency sweep for one width pair; shows the timing–area curve.
- `run_fmax_compare.py` - multi-case Fmax binary search; finds max clock for each variant.
- `wavedrom.md` - sample rdy/vld and backpressure waveforms.

## Parameters

- `IN_DATA_WIDTH` - number of bits in each in transfer beat.
- `OUT_DATA_WIDTH` - number of bits in each output transfer beat.

Both parameters must be greater than zero. The RTL derives chunk shape from
the greatest common divisor of the two data widths:

- `CHUNK_WIDTH = gcd(IN_DATA_WIDTH, OUT_DATA_WIDTH)`
- `IN_CHUNKS_PER_BEAT = IN_DATA_WIDTH / CHUNK_WIDTH`
- `OUT_CHUNKS_PER_BEAT = OUT_DATA_WIDTH / CHUNK_WIDTH`

The GCD helper lives in `common_pkg` as `greatest_common_divisor`.

## Datapath Context

The gearbox uses a chunk-granular datapath.

The RTL selects one of three datapath shapes at elaboration time:

- Equal width (`IN_CHUNKS_PER_BEAT == OUT_CHUNKS_PER_BEAT`) uses a simple
  one-beat rdy/vld skid stage.
- Integer-ratio width conversion uses exact pack/unpack logic and avoids the
  circular barrel datapath.
- Non-integer-ratio width conversion uses the circular barrel datapath because
  output beat boundaries walk across the stored chunks.

When `IN_CHUNKS_PER_BEAT < OUT_CHUNKS_PER_BEAT`, the gearbox packs multiple narrower in beats into one
wider output beat. Integer ratios use fixed lanes and one output beat of
storage. Non-integer ratios use a write barrel because each incoming beat can
land at a different chunk offset inside the output-sized buffer.

When `IN_CHUNKS_PER_BEAT > OUT_CHUNKS_PER_BEAT`, the gearbox unpacks one wider in beat into multiple
narrower output beats. Integer ratios use a fixed-width shift path and one in
beat of storage. Non-integer ratios use a read barrel as they select each
successive `OUT_CHUNKS_PER_BEAT` slice.

For integer-ratio conversions, `BUFFER_CAPACITY_CHUNKS` collapses to
`MAX_TFER_CHUNKS`, so the design does not allocate the `2 * MAX_TFER_CHUNKS`
barrel buffer. The larger buffer is only used when `NON_INTEGER_RATIO` is true,
which also requires `IN_CHUNKS_PER_BEAT != OUT_CHUNKS_PER_BEAT`.

## Area Warning

Small derived `CHUNK_WIDTH` values can make `IN_CHUNKS_PER_BEAT` and
`OUT_CHUNKS_PER_BEAT` large. That matters most in non-integer-ratio cases,
where this implementation keeps enough storage for `2 * MAX_TFER_CHUNKS` and
uses combinational barrel logic to route chunks between arbitrary offsets.

The barrel implementation is good when the design needs beat-level throughput:
it can accept or produce a full strm beat whenever rdy/vld allows. The cost is
that muxing and decode grow with the number of chunk lanes. If the GCD-derived
`CHUNK_WIDTH` is small, a wide datapath can turn into many lanes, and each lane
adds mux inputs, compare/decode logic, and buffer flops.

An FSM-style gearbox can reduce area when `IN_DATA_WIDTH` and `OUT_DATA_WIDTH`
are co-prime, or when their GCD is otherwise small. Instead of building a full
chunk-lane barrel path, an FSM can reuse a narrow shifter, small counter, and a
smaller staging register across multiple cycles. That trades peak throughput and
latency for less muxing, less decode, and fewer buffer flops.

## Run A Simulation

The default simulator is Verilator.

```sh
make
```

Run with custom data widths:

```sh
make IN_DATA_WIDTH=24 OUT_DATA_WIDTH=40
```

Disable waveform tracing:

```sh
make WAVES=0
```

## Check Lint

Run Verilator in lint-only mode with assertions enabled:

```sh
verilator --lint-only --timing --assert -Wno-WIDTHTRUNC -GIN_DATA_WIDTH=24 -GOUT_DATA_WIDTH=40 ../common/common_pkg.sv gearbox.sv
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

The random runner still accepts chunk-count and chunk-width ranges as a
convenient way to generate data widths. The RTL receives only `IN_DATA_WIDTH`
and `OUT_DATA_WIDTH`; its actual chunk width is derived from their GCD.

Use a fixed seed to reproduce a failing run:

```sh
./run_random_params.py --seed 1234
```

## Synthesis and Comparison

All synthesis scripts use Yosys with a Liberty file.  Two PDKs are available:

```text
# SKY130 HD  (0.13 µm, TT 25°C 1.8V)
../third_party/sky130_fd_sc_hd/timing/sky130_fd_sc_hd__tt_025C_1v80.lib

# ASAP7 RVT  (7 nm predictive, TT)
../third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib
```

Pass `--liberty <path>` to any script to switch PDKs.

### Quick single-case synthesis

`run_synth.py` maps one width pair and writes the mapped netlist, area report,
and DRC check under `synth_build/`.

```sh
./run_synth.py                                    # default 24→40, SKY130
./run_synth.py --in-data-width 40 --out-data-width 24
```

### Multi-case area comparison

`run_area_compare.py` generates random width pairs, synthesizes both the
`origin/main` adder implementation and the current one-hot implementation, and
reports mapped area for each case side-by-side.

```sh
# 50 non-integer-ratio cases on SKY130
./run_area_compare.py --count 50 --case-set non-integer --jobs 4

# Same cases on ASAP7
./run_area_compare.py --count 50 --case-set non-integer --jobs 4 \
    --liberty ../third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib \
    --build-dir area_compare_asap7
```

Outputs `area_compare.csv` and `area_compare.md`.

**Area results (SKY130, 50 non-integer cases):**

| Category | One-hot area vs adder |
|---|---|
| `non_integer_pack` | +6.3% |
| `non_integer_unpack` | +2.3% |
| Overall geomean | +3.8% |

### Timing sweep for one case

`run_timing_sweep.py` synthesizes one width pair across a list of target
frequencies and reports the **critical-path delay** and **full-chip area** at
each point.  Use this to see the timing–area Pareto curve and locate the
natural Fmax of each variant.

```sh
# SKY130, 24→40, 200 MHz – 1 GHz
./run_timing_sweep.py --in-data-width 24 --out-data-width 40 \
    --freqs 200,300,400,500,600,700,800,900,1000

# ASAP7, same conversion, 500 MHz – 4 GHz
./run_timing_sweep.py --in-data-width 24 --out-data-width 40 \
    --liberty ../third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib \
    --freqs 500,1000,1500,2000,2500,3000,3500,4000 \
    --build-dir timing_sweep_asap7
```

Example output columns (SKY130, 24→40):

```
 MHz  Period(ps)  Variant                Delay(ps)  Fmax Est   Met    Area(µm²)  Cells
------------------------------------------------------------------------------------
 500        2000  adder_origin_main       2448.06       408     NO    5408.938    453
 500        2000  onehot_current          1410.22       709    YES    5440.218    391
 700        1429  adder_origin_main       2448.06       408     NO    5408.938    453
 700        1429  onehot_current          1410.22       709    YES    5440.218    391
```

Outputs `timing_sweep.csv` and `timing_sweep.md`.

### Fmax binary search across multiple cases

`run_fmax_compare.py` binary-searches the tightest achievable clock period for
each (case, variant) pair.  For each candidate period it synthesizes with a
timing-constrained ABC script and checks whether the reported delay meets the
target.  Convergence takes ~9–11 synthesis runs per (case, variant); cases run
in parallel via `--jobs`.

```sh
# SKY130, 20 non-integer cases, search 50 MHz – 2 GHz
./run_fmax_compare.py --count 20 --case-set non-integer \
    --fmax-lo-mhz 50 --fmax-hi-mhz 2000 --jobs 4

# ASAP7, same cases, search up to 5 GHz
./run_fmax_compare.py --count 20 --case-set non-integer \
    --liberty ../third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib \
    --fmax-lo-mhz 100 --fmax-hi-mhz 5000 --jobs 4 \
    --build-dir fmax_compare_asap7
```

Key options:

| Option | Default | Purpose |
|---|---|---|
| `--fmax-lo-mhz` | 50 | Loosest target; should always meet timing |
| `--fmax-hi-mhz` | 3000 | Tightest target; results above this read as `≥ <hi>` |
| `--fmax-precision-ps` | 50 | Search stops when period window < this |
| `--jobs` | 1 | Parallel binary searches |

Outputs `fmax_compare.csv` and `fmax_compare.md`, and prints a per-category
geomean summary:

```
Summary statistics (onehot / adder)
  Fmax geomean ratio  (all): X.XX
  Area geomean ratio  (all): X.XX
  non_integer_pack     fmax_ratio=X.XX  area_ratio=X.XX
  non_integer_unpack   fmax_ratio=X.XX  area_ratio=X.XX
```

**Preliminary Fmax results (SKY130, 2-case smoke):**

| Case | Adder Fmax | One-hot Fmax | Fmax ratio | Area ratio |
|---|---|---|---|---|
| 120→160 non-int pack | 137 MHz | 1046 MHz | 7.6× | 1.00 |
| 72→64 non-int unpack | 236 MHz | 452 MHz | 1.9× | 1.10 |

The one-hot barrel eliminates the multiplexer-tree logic on the critical path
(`common_chunk_mux` in the adder variant), giving substantially better Fmax at
near-equal area.  The area comparison results (+3–6% for one-hot) represent the
area-optimized mapping only; at the same target frequency, both implementations
use more area than their unconstrained minimum.

## Clean

```sh
make clean
```
