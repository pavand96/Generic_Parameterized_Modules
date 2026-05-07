# Gearbox Context

This file is a local handoff note for the work done on the `gearbox` module,
its verification flow, and the synthesis/area experiments that were run.

## Repo Scope

- Main RTL: `gearbox/gearbox.sv`
- Shared helpers: `common/common_pkg.sv`
- Cocotb TB: `gearbox/testbench.py`
- Random sim sweep: `gearbox/run_random_params.py`
- Standalone synth runner: `gearbox/run_synth.py`
- Area comparison runner: `gearbox/run_area_compare.py`
- Main docs already updated: `gearbox/README.md`
- Existing repo context file also updated: `context.md`

## Current RTL State

### Public interface and naming

- Public params are now:
  - `IN_DATA_WIDTH`
  - `OUT_DATA_WIDTH`
- Stream signal naming uses:
  - `in_strm_*`
  - `out_strm_*`
  - `vld`, `rdy`, `tfer`, `ptr`
- Internal naming intentionally uses:
  - `chunk` instead of `byte`
  - `ptr` instead of `pointer`
  - `tfer` instead of `transfer`

### Derived datapath shape

`gearbox.sv` now derives chunking from GCD rather than taking chunk size as a
module parameter:

- `CHUNK_WIDTH = greatest_common_divisor(IN_DATA_WIDTH, OUT_DATA_WIDTH)`
- `IN_CHUNKS_PER_BEAT = IN_DATA_WIDTH / CHUNK_WIDTH`
- `OUT_CHUNKS_PER_BEAT = OUT_DATA_WIDTH / CHUNK_WIDTH`

This helper lives in `common/common_pkg.sv` as:

- `function automatic int unsigned greatest_common_divisor(...)`

### Branch organization

The RTL is split into three elaboration-time shapes:

- Equal width:
  - simple one-beat skid stage
- Integer ratio:
  - exact pack / exact unpack
  - avoids the circular barrel datapath
- Non-integer ratio:
  - circular barrel datapath

The key selector is:

- `NON_INTEGER_RATIO = WIDTH_CONVERT && ((MAX_TFER_CHUNKS % MIN_TFER_CHUNKS) != 0)`

### Exact ratio changes

- Shared exact/non-exact organization was cleaned up.
- `INTEGER_RATIO` was replaced by `NON_INTEGER_RATIO`.
- Assertions were pushed to the end of the file and grouped in one place.
- Exact pack/unpack paths do not use the barrel buffer.
- Data flops in exact paths no longer reset.
- Exact large-to-small path uses one `if` for `unpack_data_q` update:
  - load from `in_strm_data` on input transfer
  - otherwise shift on output transfer

### Non-integer `IN < OUT` changes

This is the small-to-large barrel pack case.

Old style in `origin/main`:

- binary write pointer
- per-input wrapped destination pointer arithmetic
- `common_chunk_mux` on write path

Current style:

- one-hot write pointer:
  - `write_chunk_ptr_oh_q`
  - rotated by constant chunk offsets
- destination decode is wiring:
  - `in_chunk_wr_dst_oh`
- per-chunk write flops:
  - `pack_buffer_q[out_chunk_i]` only updates when `chunk_wr_en[out_chunk_i]`
- no write-path `common_chunk_mux`

Important point:

- this reduces arithmetic/decode on the write side, but synthesis results show
  it is not universally lower area after mapping

### Non-integer `IN > OUT` changes

This is the large-to-small barrel unpack case.

Old style in `origin/main`:

- binary read pointer
- per-output wrapped source pointer arithmetic
- indexed `common_chunk_mux` on read path

Current style:

- one-hot read pointer:
  - `read_chunk_ptr_oh_q`
  - rotated by constant chunk offsets
- source select is one-hot:
  - `out_chunk_rd_src_oh`
- selected chunk data is built with one-hot gated OR terms
- no read-path `common_chunk_mux`

### Buffer / occupancy logic

- `stored_chunk_count_q` tracks barrel occupancy
- shared count logic remains in the non-integer branch
- `BUFFER_CAPACITY_CHUNKS` is:
  - `MAX_TFER_CHUNKS` for integer ratio
  - `2 * MAX_TFER_CHUNKS` for non-integer ratio

Note:

- the user explicitly requested that `2 * MAX_TFER_CHUNKS` not be used for the
  exact ratio cases

### Reset / clock-enable style

- Data flops were changed to no-reset style in all datapath cases
- Control flops still reset where needed
- Datapath flops now use clock-enable behavior where possible:
  - only update on `in_strm_tfer`
  - only update on `out_stage_load`
  - only update chunk flops on `chunk_wr_en[...]`

### Array style

Packed arrays were preferred over unpacked array declarations for many internal
signals. Example style the user requested:

- `logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;`

## Shared Package Status

File: `common/common_pkg.sv`

Contains:

- `greatest_common_divisor`
- `common_chunk_mux`

Current use:

- `greatest_common_divisor` is used by `gearbox.sv`
- `common_chunk_mux` still exists for shared utility and for comparing against
  `origin/main`, but the current one-hot gearbox implementation does not use it
  in the non-integer read/write datapaths

## Verification Status

### Cocotb testbench

File: `gearbox/testbench.py`

Current TB behavior:

- derives `CHUNK_WIDTH` at runtime using `gcd(IN_DATA_WIDTH, OUT_DATA_WIDTH)`
- drives input data on the posedge cadence requested by the user
- uses chunk-level scoreboard checking
- verifies actual output chunks against the expected FIFO of chunks
- covers:
  - continuous traffic
  - randomized backpressure

Important implementation details:

- data generation is deterministic from beat index
- scoreboard is chunk-order based, not word-shape based
- the TB checks correctness for `IN_DATA_WIDTH > OUT_DATA_WIDTH` and other
  direction combinations as well

### Randomized sim runner

File: `gearbox/run_random_params.py`

Current behavior:

- randomizes widths from chunk-count ranges and a chosen chunk width
- drives `make` with:
  - `IN_DATA_WIDTH`
  - `OUT_DATA_WIDTH`
- useful for broad simulation coverage

## Standalone Yosys Synthesis

### Tooling

- Local Yosys present:
  - `/opt/eda/bin/yosys`
- Version used:
  - `Yosys 0.63+190`

### SKY130 setup

Liberty file used:

- `third_party/sky130_fd_sc_hd/timing/sky130_fd_sc_hd__tt_025C_1v80.lib`

This file was downloaded locally and used successfully for mapped synthesis.

### `run_synth.py`

File: `gearbox/run_synth.py`

Purpose:

- run standalone Yosys on the current gearbox RTL for a single width pair

Important behavior:

- generates a Yosys-friendly RTL copy in `synth_build/`
- replaces GCD-derived `CHUNK_WIDTH` with a numeric constant
- strips `import common_pkg::*;`
- flattens some packed multidimensional arrays in the generated copy because
  Yosys frontend had trouble with the native current RTL form

Outputs:

- `gearbox_mapped.v`
- `gearbox_stat.rpt`
- `gearbox_check.rpt`
- `gearbox_synth.ys`
- `gearbox_yosys.sv`

Important limitation:

- this is unconstrained mapping
- no SDC / no explicit clock target / no `abc -D`
- results are area-only comparisons, not frequency signoff

## Area Comparison Runner

### `run_area_compare.py`

File: `gearbox/run_area_compare.py`

Purpose:

- compare `origin/main` gearbox RTL against current working-tree RTL

Variants:

- `adder_origin_main`
- `onehot_current`

How it works:

- reads `origin/main:gearbox/gearbox.sv` using `git show`
- reads current `gearbox/gearbox.sv`
- generates Yosys-friendly RTL copies for both
- for current RTL:
  - flattens one-hot packed arrays for Yosys frontend compatibility
- for `origin/main` RTL:
  - flattens binary ptr arrays for Yosys frontend compatibility
  - prefixes `common_chunk_mux` from `common_pkg.sv`

Key options:

- `--count`
- `--seed`
- `--max-data-width`
- `--max-chunks-per-beat`
- `--case-set all|non-integer`
- `--liberty`
- `--jobs`
- `--rerun`

Generated outputs per run:

- per-case generated RTL, Yosys script, mapped netlist, log, stat report, check report
- top-level:
  - `area_compare.csv`
  - `area_compare.md`

### Why `max-chunks-per-beat` was bounded

Originally wider pathological non-integer cases were attempted directly up to
1024 bits with no extra guard. That produced very long Yosys elaboration times,
especially for current one-hot non-integer pack cases such as:

- `512 -> 984`
- `928 -> 896`
- `960 -> 1024`

To keep the 50-case sweeps practical and comparable, the area-comparison runs
were bounded with:

- `max(IN_CHUNKS_PER_BEAT, OUT_CHUNKS_PER_BEAT) <= 16`

This still allows widths up to 1024 bits when `CHUNK_WIDTH` is not tiny.

## Libraries Used In Experiments

### SKY130

- path:
  - `third_party/sky130_fd_sc_hd/timing/sky130_fd_sc_hd__tt_025C_1v80.lib`
- used directly as one Liberty file

### ASAP7

Repo cloned locally:

- `third_party/asap7sc7p5t_28`

Chosen library flavor:

- RVT / TT / NLDM

Source split across multiple `.lib.7z` archives:

- `asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib.7z`
- `asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib.7z`
- `asap7sc7p5t_AO_RVT_TT_nldm_211120.lib.7z`
- `asap7sc7p5t_OA_RVT_TT_nldm_211120.lib.7z`
- `asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib.7z`

Those were unpacked and then merged into one Liberty:

- `third_party/asap7sc7p5t_28/LIB/NLDM/asap7sc7p5t_RVT_TT_nldm_merged.lib`

For branch portability, a vendored copy was also placed at:

- `third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib`

Reason for merge:

- direct concatenation did not work for `dfflibmap`
- Yosys needed a single `library (...) { ... }` body containing all cells

## Experiments Run

### Single-case standalone synth checks

Using `run_synth.py` and SKY130:

- `8 -> 8`
- `24 -> 40`
- `40 -> 24`

These all passed Yosys `check`.

### 50-case mixed sweep on SKY130

Directory:

- `gearbox/area_compare_50_chunks16/`

Scope:

- equal
- integer pack
- integer unpack
- non-integer pack
- non-integer unpack

Summary:

- equal / integer-ratio cases matched exactly between implementations
- differences only showed up in non-integer cases
- overall geomean ratio:
  - `1.017615`
- interpretation:
  - current one-hot implementation was about `1.8%` larger overall in this
    mixed 50-case bounded sample

Per-category highlights:

- `non_integer_pack` geomean ratio:
  - `1.060977`
- `non_integer_unpack` geomean ratio:
  - `1.028515`

### 50-case non-integer-only sweep on SKY130

Directory:

- `gearbox/area_compare_50_non_integer/`

Scope:

- 25 non-integer pack
- 25 non-integer unpack

Summary:

- overall:
  - one-hot smaller in `21`
  - one-hot larger in `29`
  - geomean ratio `1.038375`
- interpretation:
  - current one-hot implementation was about `3.8%` larger overall in this
    non-integer-only SKY130 sample

Per-category:

- `non_integer_pack`
  - geomean ratio `1.057913`
  - average delta pct `+6.30%`
- `non_integer_unpack`
  - geomean ratio `1.019197`
  - average delta pct `+2.27%`

Best SKY130 one-hot wins:

- `616 -> 168`
  - `-11.12%`
- `640 -> 384`
  - `-8.94%`
- `920 -> 552`
  - `-8.94%`

Worst SKY130 one-hot regressions:

- `896 -> 960`
  - `+40.21%`
- `896 -> 1008`
  - `+23.60%`
- `160 -> 600`
  - `+19.47%`

### 50-case non-integer-only sweep on ASAP7

Directory:

- `gearbox/area_compare_50_non_integer_asap7/`

Scope:

- same seed and bounded case-generation style as the SKY130 non-integer sweep

Summary:

- overall:
  - one-hot smaller in `23`
  - one-hot larger in `27`
  - geomean ratio `1.034556`
- interpretation:
  - current one-hot implementation was about `3.5%` larger overall in this
    non-integer-only ASAP7 sample

Per-category:

- `non_integer_pack`
  - geomean ratio `1.065990`
  - average delta pct `+7.18%`
- `non_integer_unpack`
  - geomean ratio `1.004049`
  - average delta pct `+0.76%`

Best ASAP7 one-hot wins:

- `616 -> 168`
  - `-12.74%`
- `640 -> 384`
  - `-11.51%`
- `920 -> 552`
  - `-10.77%`

Worst ASAP7 one-hot regressions:

- `896 -> 960`
  - `+39.92%`
- `896 -> 1008`
  - `+23.97%`
- `384 -> 704`
  - `+20.16%`

## Main Technical Conclusions So Far

### On area

- Equal-width and integer-ratio paths are effectively identical between the
  two implementations because the structural change only affects the
  non-integer barrel datapaths.
- The one-hot rotation approach is not a universal area win after mapping.
- Across both SKY130 and ASAP7 bounded non-integer sweeps:
  - one-hot often helps some unpack cases
  - one-hot often hurts some pack cases
  - the regressions on some wide non-integer pack cases are larger than the
    savings elsewhere

### On Yosys behavior

- Current one-hot wide non-integer pack cases tend to spend much longer in
  Yosys frontend elaboration than the origin/main adder version.
- Example troublesome style:
  - wide non-integer pack near the chunk-count bound, such as `960 -> 1024`
- This is a tooling/runtime observation, separate from mapped area results.

### On timing

- No experiment so far used a timing target.
- All synthesis results are area-only, unconstrained mapping comparisons.
- If frequency-aware comparison is needed later, the next step is to add:
  - `abc -D <ps>`
  - or an equivalent constrained flow

## Known Workarounds / Caveats

- `run_synth.py` and `run_area_compare.py` both generate Yosys-friendly RTL
  copies because Yosys frontend had issues with:
  - package/import usage during parameter elaboration
  - some packed multidimensional array forms
- ASAP7 is a research PDK / predictive library, not signoff silicon data.
- The Liberty area units differ across libraries, so compare trends within a
  given library rather than raw numbers across SKY130 vs ASAP7.

## Local Files Of Interest

- Current RTL:
  - `gearbox/gearbox.sv`
- Shared helper package:
  - `common/common_pkg.sv`
- Synthesis helper:
  - `gearbox/run_synth.py`
- Area comparison helper:
  - `gearbox/run_area_compare.py`
- SKY130 non-integer results:
  - `gearbox/area_compare_50_non_integer/area_compare.csv`
  - `gearbox/area_compare_50_non_integer/area_compare.md`
- SKY130 mixed bounded results:
  - `gearbox/area_compare_50_chunks16/area_compare.csv`
  - `gearbox/area_compare_50_chunks16/area_compare.md`
- ASAP7 non-integer results:
  - `gearbox/area_compare_50_non_integer_asap7/area_compare.csv`
  - `gearbox/area_compare_50_non_integer_asap7/area_compare.md`
- ASAP7 merged Liberty used for the run:
  - `third_party/asap7sc7p5t_28/LIB/NLDM/asap7sc7p5t_RVT_TT_nldm_merged.lib`
- Vendored ASAP7 merged Liberty intended for tracking:
  - `third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib`

## Ignore Rules Added Locally

`.gitignore` was updated to ignore generated build directories:

- `sim_build*/`
- `synth_build*/`
- `area_compare*/`

## Current State Summary

- The current checked-out gearbox RTL is the one-hot rotation implementation.
- `origin/main` is still the comparison point for the older adder/indexed
  implementation.
- Simulation infrastructure and standalone synthesis infrastructure are both in
  place.
- The current evidence from both SKY130 and ASAP7 bounded non-integer area
  sweeps is:
  - one-hot is not clearly better overall for area
  - one-hot helps some cases, especially some unpack cases
  - one-hot hurts a number of non-integer pack cases enough to dominate the
    average
