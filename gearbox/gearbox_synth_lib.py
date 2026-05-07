"""Shared synthesis helpers for gearbox area and timing scripts."""

import math
import random
import re
import subprocess
from pathlib import Path


PDK_CHOICES = ("sky130", "asap7")

_PDK_LIBERTY_REL = {
    "sky130": "third_party/sky130_fd_sc_hd/timing/sky130_fd_sc_hd__tt_025C_1v80.lib",
    "asap7":  "third_party/asap7/asap7sc7p5t_RVT_TT_nldm_merged.lib",
}


def pdk_liberty_path(pdk_name, repo_root):
    return repo_root / _PDK_LIBERTY_REL[pdk_name]


VARIANT_ADDER = "adder_origin_main"
VARIANT_ONEHOT = "onehot_current"
VARIANTS = (
    (VARIANT_ADDER, "origin/main:gearbox/gearbox.sv"),
    (VARIANT_ONEHOT, None),
)


def run_command(cmd, cwd):
    return subprocess.check_output(cmd, cwd=cwd, text=True)


def read_variant_rtl(repo_root, variant_source):
    if variant_source is None:
        return (repo_root / "gearbox" / "gearbox.sv").read_text(encoding="utf-8")
    return run_command(["git", "show", variant_source], repo_root)


def read_common_mux(repo_root):
    common_text = (repo_root / "common" / "common_pkg.sv").read_text(encoding="utf-8")
    module_start = common_text.index("module common_chunk_mux")
    return common_text[module_start:]


def replace_common_parameters(rtl_text, in_data_width, out_data_width):
    chunk_width = math.gcd(in_data_width, out_data_width)
    rtl_text = rtl_text.replace("import common_pkg::*;\n\n", "")
    rtl_text = re.sub(
        r"parameter int unsigned IN_DATA_WIDTH\s*=\s*\d+",
        f"parameter int unsigned IN_DATA_WIDTH      = {in_data_width}",
        rtl_text,
    )
    rtl_text = re.sub(
        r"parameter int unsigned OUT_DATA_WIDTH\s*=\s*\d+",
        f"parameter int unsigned OUT_DATA_WIDTH     = {out_data_width}",
        rtl_text,
    )
    rtl_text = re.sub(
        r"(localparam int unsigned CHUNK_WIDTH\s*=\s*)greatest_common_divisor\(IN_DATA_WIDTH, OUT_DATA_WIDTH\)([,;])",
        rf"\g<1>{chunk_width}\2",
        rtl_text,
    )
    return rtl_text


def flatten_current_onehot_arrays(rtl_text):
    replacements = (
        (
            "logic [BUFFER_CAPACITY_CHUNKS-1:0][CHUNK_WIDTH-1:0] pack_buffer_q;",
            "logic [BUFFER_DATA_WIDTH-1:0] pack_buffer_q;",
        ),
        (
            "logic [BUFFER_CAPACITY_CHUNKS-1:0][CHUNK_WIDTH-1:0] chunk_wr_data;",
            "logic [BUFFER_DATA_WIDTH-1:0] chunk_wr_data;",
        ),
        (
            "logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;",
            "logic [IN_CHUNKS_PER_BEAT*BUFFER_CAPACITY_CHUNKS-1:0] in_chunk_wr_dst_oh;",
        ),
        (
            "logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;",
            "logic [OUT_CHUNKS_PER_BEAT*BUFFER_CAPACITY_CHUNKS-1:0] out_chunk_rd_src_oh;",
        ),
        (
            "pack_buffer_q[out_chunk_i]",
            "pack_buffer_q[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH]",
        ),
        (
            "chunk_wr_data[out_chunk_i][chunk_bit_i]",
            "chunk_wr_data[CHUNK_WIDTH*out_chunk_i+chunk_bit_i]",
        ),
        (
            "chunk_wr_data[out_chunk_i]",
            "chunk_wr_data[CHUNK_WIDTH*out_chunk_i +: CHUNK_WIDTH]",
        ),
        (
            "in_chunk_wr_dst_oh[in_chunk_i][out_chunk_i]",
            "in_chunk_wr_dst_oh[BUFFER_CAPACITY_CHUNKS*in_chunk_i+out_chunk_i]",
        ),
        (
            "assign in_chunk_wr_dst_oh[in_chunk_i] =",
            "assign in_chunk_wr_dst_oh[BUFFER_CAPACITY_CHUNKS*in_chunk_i +: BUFFER_CAPACITY_CHUNKS] =",
        ),
        (
            "out_chunk_rd_src_oh[out_chunk_i][buffer_chunk_i]",
            "out_chunk_rd_src_oh[BUFFER_CAPACITY_CHUNKS*out_chunk_i+buffer_chunk_i]",
        ),
        (
            "assign out_chunk_rd_src_oh[out_chunk_i] =",
            "assign out_chunk_rd_src_oh[BUFFER_CAPACITY_CHUNKS*out_chunk_i +: BUFFER_CAPACITY_CHUNKS] =",
        ),
    )
    for old, new in replacements:
        rtl_text = rtl_text.replace(old, new)
    return rtl_text


def flatten_origin_adder_arrays(rtl_text):
    replacements = (
        (
            "logic [IN_CHUNKS_PER_BEAT-1:0][BUFFER_PTR_WIDTH-1:0] write_dst_chunk_ptr;",
            "logic [IN_CHUNKS_PER_BEAT*BUFFER_PTR_WIDTH-1:0] write_dst_chunk_ptr;",
        ),
        (
            "logic [OUT_CHUNKS_PER_BEAT-1:0][BUFFER_PTR_WIDTH-1:0] read_src_chunk_ptr;",
            "logic [OUT_CHUNKS_PER_BEAT*BUFFER_PTR_WIDTH-1:0] read_src_chunk_ptr;",
        ),
        (
            "write_dst_chunk_ptr[in_chunk_i]",
            "write_dst_chunk_ptr[BUFFER_PTR_WIDTH*in_chunk_i +: BUFFER_PTR_WIDTH]",
        ),
        (
            "read_src_chunk_ptr[out_chunk_i]",
            "read_src_chunk_ptr[BUFFER_PTR_WIDTH*out_chunk_i +: BUFFER_PTR_WIDTH]",
        ),
    )
    for old, new in replacements:
        rtl_text = rtl_text.replace(old, new)
    return rtl_text


def prepare_rtl(variant_name, rtl_text, common_mux_text, in_data_width, out_data_width):
    rtl_text = replace_common_parameters(rtl_text, in_data_width, out_data_width)
    if variant_name == VARIANT_ONEHOT:
        rtl_text = flatten_current_onehot_arrays(rtl_text)
    else:
        rtl_text = flatten_origin_adder_arrays(rtl_text)
        rtl_text = common_mux_text + "\n\n" + rtl_text
    return rtl_text


def classify_case(in_data_width, out_data_width):
    chunk_width = math.gcd(in_data_width, out_data_width)
    in_chunks = in_data_width // chunk_width
    out_chunks = out_data_width // chunk_width
    if in_chunks == out_chunks:
        return "equal", chunk_width, in_chunks, out_chunks
    max_chunks = max(in_chunks, out_chunks)
    min_chunks = min(in_chunks, out_chunks)
    exact = (max_chunks % min_chunks) == 0
    direction = "pack" if in_chunks < out_chunks else "unpack"
    ratio = "integer" if exact else "non_integer"
    return f"{ratio}_{direction}", chunk_width, in_chunks, out_chunks


def add_unique_case(cases, seen, in_units, out_units, max_units, max_chunks_per_beat):
    if in_units < 1 or out_units < 1:
        return False
    if in_units > max_units or out_units > max_units:
        return False
    pair = (8 * in_units, 8 * out_units)
    if pair in seen:
        return False
    _, _, in_chunks, out_chunks = classify_case(pair[0], pair[1])
    if max(in_chunks, out_chunks) > max_chunks_per_beat:
        return False
    seen.add(pair)
    cases.append(pair)
    return True


def generate_cases(count, seed, max_data_width, max_chunks_per_beat, case_set):
    if max_data_width % 8 != 0:
        raise SystemExit("--max-data-width must be byte aligned")
    rng = random.Random(seed)
    max_units = max_data_width // 8
    cases = []
    seen = set()
    if case_set == "non-integer":
        categories = ("non_integer_pack", "non_integer_unpack")
    else:
        categories = (
            "equal", "integer_pack", "integer_unpack",
            "non_integer_pack", "non_integer_unpack",
        )
    attempts = 0
    while len(cases) < count and attempts < count * 1000:
        attempts += 1
        category = categories[len(cases) % len(categories)]
        if category == "equal":
            units = rng.randint(1, max_units)
            add_unique_case(cases, seen, units, units, max_units, max_chunks_per_beat)
        elif category == "integer_pack":
            ratio = rng.choice((2, 3, 4, 5, 6, 8, 16))
            in_units = rng.randint(1, max(1, max_units // ratio))
            add_unique_case(cases, seen, in_units, in_units * ratio, max_units, max_chunks_per_beat)
        elif category == "integer_unpack":
            ratio = rng.choice((2, 3, 4, 5, 6, 8, 16))
            out_units = rng.randint(1, max(1, max_units // ratio))
            add_unique_case(cases, seen, out_units * ratio, out_units, max_units, max_chunks_per_beat)
        elif category == "non_integer_pack":
            in_units = rng.randint(1, max_units - 1)
            out_units = rng.randint(in_units + 1, max_units)
            if out_units % in_units != 0:
                add_unique_case(cases, seen, in_units, out_units, max_units, max_chunks_per_beat)
        else:
            out_units = rng.randint(1, max_units - 1)
            in_units = rng.randint(out_units + 1, max_units)
            if in_units % out_units != 0:
                add_unique_case(cases, seen, in_units, out_units, max_units, max_chunks_per_beat)
    if len(cases) != count:
        raise SystemExit(f"Could only generate {len(cases)} unique cases (needed {count})")
    return cases


def parse_area(stat_text):
    match = re.search(r"Chip area for module '\\gearbox':\s+([0-9.]+)", stat_text)
    return float(match.group(1)) if match else None


def parse_cell_count(stat_text):
    match = re.search(r"\n\s+(\d+)\s+[0-9.Ee+-]+\s+cells\n", stat_text)
    return int(match.group(1)) if match else None


def parse_check_ok(check_text):
    return "Found and reported 0 problems." in check_text


def parse_delay_ps(timing_text):
    match = re.search(r"Delay\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*ps", timing_text)
    return float(match.group(1)) if match else None


def make_abc_script(period_ps):
    return (
        f"strash\n"
        f"&get -n\n"
        f"&fraig -x\n"
        f"&put\n"
        f"scorr\n"
        f"dc2\n"
        f"dretime\n"
        f"retime -o -D {period_ps}\n"
        f"strash\n"
        f"&get -n\n"
        f"&dch -f\n"
        f"&nf -D {period_ps}\n"
        f"&put\n"
        f"stime\n"
    )


def make_yosys_script_timing(
    liberty, rtl_path, netlist_path, stat_path, check_path,
    timing_path, abc_script_path,
):
    return (
        f"read_liberty -lib {liberty.resolve()}\n"
        f"read_verilog -sv -DSYNTHESIS {rtl_path.resolve()}\n"
        f"hierarchy -check -top gearbox\n"
        f"proc\n"
        f"opt\n"
        f"synth -top gearbox -flatten\n"
        f"dfflibmap -liberty {liberty.resolve()}\n"
        f"tee -o {timing_path.resolve()} "
        f"abc -liberty {liberty.resolve()} -script {abc_script_path.resolve()}\n"
        f"clean\n"
        f"tee -o {stat_path.resolve()} stat -liberty {liberty.resolve()}\n"
        f"tee -o {check_path.resolve()} check\n"
        f"write_verilog -noattr {netlist_path.resolve()}\n"
    )
